-- ============================================================================
-- palm6_laundering/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- inventory / native access. No direct framework / native calls here (§6 gate).
--
-- The wash: a player standing at the hidden laundromat runs /launder. The
-- server reads their REAL dirty-money balance (black_money, count == dollars),
-- removes up to the smaller of {held, per-run cap, remaining daily cap},
-- credits the clean remainder to bank, logs the run, and warms the front's
-- heat. A large or high-heat run trips a native police alert + an evidence
-- case. Nothing here trusts a client-supplied amount, position, or item.
-- ============================================================================

local lastAction = {}   -- [src] = ts of last /launder (spam guard)
local lastQuote  = {}   -- [src] = ts of last /dirtymoney (spam guard)
AddEventHandler('playerDropped', function()  -- reclaim on disconnect
    lastAction[source] = nil
    lastQuote[source] = nil
end)
local frontHeat = 0.0   -- single-front heat accumulator (server-only, decays)

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_laundering] ' .. msg) end
end

local function atFront(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Front.coords) <= Config.Front.radius
end

-- Dirty dollars this character has already washed today (calendar day).
local function dirtyWashedToday(cid)
    local used = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(dirty_in),0) AS n FROM palm6_laundering_runs WHERE citizenid = ? AND created_at >= CURDATE()",
            { cid })
        used = r and tonumber(r.n) or 0
    end)
    return used
end

-- Decide whether a run of `amount` dollars trips police, and update heat.
-- Returns true if flagged. Heat is added regardless; the roll only decides
-- the alert.
local function assessHeat(amount)
    frontHeat = frontHeat + (amount / 1000.0) * Config.Heat.PerThousand
    if amount >= Config.Heat.BigRunAlways then
        return true
    end
    if frontHeat >= Config.Heat.AlertThreshold then
        -- Probability scales from 0 at the threshold up to AlertChanceMax as
        -- heat climbs a further AlertThreshold above it.
        local over = frontHeat - Config.Heat.AlertThreshold
        local chance = math.min(Config.Heat.AlertChanceMax,
            (over / Config.Heat.AlertThreshold) * Config.Heat.AlertChanceMax)
        if math.random() < chance then return true end
    end
    return false
end

-- Persistent-heat scrutiny at the front. Returns (extraCut, tier, refuse) for
-- the character. The front reads palm6_heat's frozen GetTier export and skims
-- harder off a citizen the whole city is already looking for. Soft-dep + pcall:
-- a stopped or throwing palm6_heat leaves the flat Config.Cut untouched, so the
-- wash can never break because the heat layer is down.
local function heatScrutiny(cid)
    if not Config.HeatScrutiny.Enabled then return 0.0, nil, false end
    if GetResourceState('palm6_heat') ~= 'started' then return 0.0, nil, false end
    local tier
    pcall(function() tier = exports.palm6_heat:GetTier(cid) end)
    if type(tier) ~= 'string' then return 0.0, nil, false end
    if Config.HeatScrutiny.Refuse[tier] then return 0.0, tier, true end
    return tonumber(Config.HeatScrutiny.ExtraCut[tier]) or 0.0, tier, false
end

-- Persistent police attention this run earns its launderer, amount-proportional
-- (see Config.PlayerHeat for why flat-per-run was the wrong shape).
--
-- EVERY key is read guarded (tonumber(...) or a default, Base included) so the
-- documented reversal to the old FLAT charge is genuinely config-only:
-- PerThousand = 0 (or absent) makes this return exactly Base, and an absent
-- MaxPerRun means "no cap". An absent Base falls back to 0, which charges
-- nothing rather than erroring, so a table must still set one. That matters
-- because the pre-reshape table was literally `{ Base = 5, FlaggedBonus = 8 }`,
-- and the obvious way to revert is to paste it back. Reading the missing keys
-- unguarded would throw inside the caller's pcall, which does not surface an
-- error, it just silently stops charging heat at all.
local function playerHeatFor(amount, flagged)
    local H = Config.PlayerHeat
    local h = math.floor((tonumber(H.Base) or 0)
        + (amount / 1000.0) * (tonumber(H.PerThousand) or 0))
    local cap = tonumber(H.MaxPerRun)
    if cap and h > cap then h = cap end
    if flagged then h = h + (tonumber(H.FlaggedBonus) or 0) end
    return h
end

-- Open/append an evidence case for a flagged run. Returns the case id or nil.
-- Uses ONLY the palm6_evidence v2 frozen exports (never its tables directly).
local function fileEvidence(cid, dirtyIn, cleanOut)
    if not Bridge.ResourceStarted('palm6_evidence') then return nil end
    local caseId
    pcall(function()
        local incidentKey = ('%s%s-%d'):format(
            Config.Evidence.IncidentKeyPrefix, cid, math.floor(now() / 300))
        caseId = exports.palm6_evidence:EnsureCase(
            incidentKey, Config.Evidence.CaseTitle, 'palm6_laundering')
        if caseId then
            exports.palm6_evidence:AppendEntry(caseId, 'laundering_run', {
                front = Config.Front.label, dirty_in = dirtyIn, clean_out = cleanOut,
            }, 'palm6_laundering')
            exports.palm6_evidence:LinkSuspect(caseId, cid, nil)
        end
    end)
    return caseId
end

-- ---------------------------------------------------------------------------
-- /launder — wash dirty money at the front.
-- ---------------------------------------------------------------------------
local function cmdLaunder(src)
    if src == 0 then return end
    local t = now()
    -- Atomic check-and-set BEFORE any yield (the same rl() idiom palm6_chopshop
    -- uses): cmdLaunder yields on the DB read below, so setting the cooldown
    -- here — not after — is what stops two same-tick /launder calls from both
    -- passing the gate and each bypassing the daily cap by a run. A rejected
    -- attempt burning the cooldown is the accepted trade for that safety.
    if (lastAction[src] or 0) + Config.CooldownSec > t then
        Bridge.Notify(src, 'Laundromat', 'The machines are still running — give it a moment.', 'error')
        return
    end
    lastAction[src] = t

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if not atFront(src) then
        Bridge.Notify(src, 'Laundromat', ('You need to be at %s.'):format(Config.Front.label), 'error')
        return
    end

    if Config.BlockWhileWanted and Bridge.HasActiveWarrant(cid) then
        Bridge.Notify(src, 'Laundromat',
            "The front won't touch a wanted man's cash — clear your warrant first.", 'error')
        return
    end

    -- How hot the launderer already is decides what the front charges them (or
    -- whether it deals with them at all). Read BEFORE any item is removed so a
    -- refusal costs the player nothing but the cooldown they already burned.
    local extraCut, heatTier, refused = heatScrutiny(cid)
    if refused then
        Bridge.Notify(src, 'Laundromat',
            'The front knows your face from the news. They want nothing to do with you.', 'error')
        return
    end

    local held = Bridge.CountItem(src, Config.DirtyItem)
    if held <= 0 then
        Bridge.Notify(src, 'Laundromat', 'You have no dirty money to wash.', 'error')
        return
    end
    if held < Config.MinPerRun then
        Bridge.Notify(src, 'Laundromat', ('Not worth the wash — bring at least $%d.'):format(Config.MinPerRun), 'error')
        return
    end

    local remaining = Config.DailyCap - dirtyWashedToday(cid)
    if remaining < Config.MinPerRun then
        Bridge.Notify(src, 'Laundromat', 'This front is done taking your money today — come back tomorrow.', 'error')
        return
    end

    -- Whole dollars, capped three ways (held / per-run / remaining daily).
    local amount = math.min(held, Config.MaxPerRun, remaining)
    if amount < Config.MinPerRun then return end

    if not Bridge.RemoveItem(src, Config.DirtyItem, amount) then
        Bridge.Notify(src, 'Laundromat', 'Could not process that — try again.', 'error')
        return
    end

    -- Total skim = the standing fee plus whatever the heat surcharge added.
    -- Clamped so a wash always pays out something, and recorded in the run row
    -- below (fee_bps) so the ledger reflects what was actually charged.
    local cut = math.min(0.90, Config.Cut + extraCut)
    local cleanOut = math.floor(amount * (1.0 - cut))
    if not Bridge.CreditBank(src, cleanOut, 'laundering') then
        -- Credit failed after we pulled the cash — hand it straight back so
        -- the player is never charged for a wash they didn't receive.
        Bridge.GiveItem(src, Config.DirtyItem, amount)
        Bridge.Notify(src, 'Laundromat', 'The wash jammed — your money was returned.', 'error')
        return
    end

    local flagged = assessHeat(amount)
    local caseId
    if flagged then
        Bridge.PoliceAlert(src, 'Suspicious cash activity reported')
        caseId = fileEvidence(cid, amount, cleanOut)
    end

    pcall(function()
        MySQL.insert.await(
            [[INSERT INTO palm6_laundering_runs
                (citizenid, dirty_in, clean_out, fee_bps, flagged, evidence_case_id)
              VALUES (?, ?, ?, ?, ?, ?)]],
            { cid, amount, cleanOut, math.floor(cut * 10000 + 0.5), flagged and 1 or 0, caseId })
    end)

    Bridge.Notify(src, 'Laundromat',
        (extraCut > 0.0)
            and ('Washed $%d for $%d clean. The front skimmed extra; you are too hot to be worth the risk.')
                :format(amount, cleanOut)
            or ('Washed $%d — $%d landed clean in your account.'):format(amount, cleanOut),
        (extraCut > 0.0) and 'warning' or 'success')

    -- Persistent police attention: moving dirty money is a crime, the SIZE of
    -- the wash is what makes it loud, and a run the law flagged (police alerted
    -- + evidence filed) bumps the launderer harder still. Keyed to the character
    -- (cid) so it follows them after they log. Fires only after the item pull +
    -- bank credit above committed. Soft-dep + pcall: a stopped palm6_heat never
    -- touches the wash.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(cid, playerHeatFor(amount, flagged), 'launder')
        end)
    end

    dbg(('%s washed $%d -> $%d clean (flagged=%s, tier=%s, cut=%.2f, heat=%.1f)'):format(
        cid, amount, cleanOut, tostring(flagged), tostring(heatTier), cut, frontHeat))
end

-- ---------------------------------------------------------------------------
-- /dirtymoney — read-only: what you're holding + today's remaining ceiling.
-- ---------------------------------------------------------------------------
local function cmdDirtyMoney(src)
    if src == 0 then return end
    -- Read-only, but not free: this command now costs up to THREE DB round-trips
    -- (the palm6_mdt warrant check, the dirtyWashedToday sum, and the palm6_heat
    -- GetTier read, all below), and unlike /launder it has no Config.CooldownSec
    -- behind it. Check-and-set before any yield, same idiom as cmdLaunder.
    local t = now()
    if (lastQuote[src] or 0) + Config.QuoteCooldownSec > t then return end
    lastQuote[src] = t

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local held = Bridge.CountItem(src, Config.DirtyItem)
    -- The door has TWO refusals and the quote has to honour both. This is the
    -- one that actually fires today: Config.BlockWhileWanted ships true and
    -- palm6_mdt is running, so a wanted character quoted 30% here would walk to
    -- the machine and be turned away outright. Checked before the daily-sum read
    -- so a refused quote costs one DB round-trip fewer. Same soft-dep as
    -- /launder: no palm6_mdt, or the flag off, and this is a no-op.
    if Config.BlockWhileWanted and Bridge.HasActiveWarrant(cid) then
        Bridge.Notify(src, 'Dirty Money',
            ("Holding $%d dirty · the front won't touch a wanted man's cash until you clear your warrant.")
                :format(held), 'error')
        return
    end
    local remaining = math.max(0, Config.DailyCap - dirtyWashedToday(cid))
    -- Quote the fee this character would ACTUALLY pay, surcharge included.
    -- Otherwise a hot launderer reads 30% here and gets charged 40% at the
    -- machine, which looks like a bug rather than a consequence. Same reason
    -- BOTH door refusals are honoured here (the warrant one above, the tier one
    -- just below): quoting a fee for a wash the front is going to turn away at
    -- the door is a worse lie than quoting the wrong fee.
    -- Config.HeatScrutiny.Refuse ships empty, so this branch is inert until an
    -- operator fills it in; it exists so that filling it in cannot produce a
    -- quote that contradicts /launder.
    local extraCut, _, refused = heatScrutiny(cid)
    if refused then
        Bridge.Notify(src, 'Dirty Money',
            ('Holding $%d dirty · the front knows your face from the news and wants nothing to do with you.')
                :format(held), 'error')
        return
    end
    local cut = math.min(0.90, Config.Cut + extraCut)
    Bridge.Notify(src, 'Dirty Money',
        ('Holding $%d dirty · today you can still wash $%d · fee %d%%%s'):format(
            held, remaining, math.floor(cut * 100 + 0.5),
            (extraCut > 0.0) and ' (the front is charging you extra)' or ''), 'inform')
end

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('launder', function(source) cmdLaunder(source) end)
Bridge.RegisterCommand('dirtymoney', function(source) cmdDirtyMoney(source) end)

-- Heat decay sweep.
CreateThread(function()
    while true do
        Wait(Config.Heat.SweepSec * 1000)
        if frontHeat > 0 then
            frontHeat = math.max(0.0, frontHeat - Config.Heat.DecayPerMin * (Config.Heat.SweepSec / 60.0))
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not Bridge.ItemExists(Config.DirtyItem) then
        print(('^1[palm6_laundering] FATAL: dirty-money item "%s" is not registered in ox_inventory — '
            .. 'laundering disabled. Nothing to wash.^0'):format(Config.DirtyItem))
        return
    end
    local runs, washed = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(dirty_in),0) AS s FROM palm6_laundering_runs')
        runs = r and tonumber(r.c) or 0
        washed = r and tonumber(r.s) or 0
    end)
    print(('[palm6_laundering] laundromat open — $%d washed all-time across %d run(s); fee %d%%'):format(
        washed, runs, math.floor(Config.Cut * 100 + 0.5)))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalRuns = 0, totalDirtyWashed = 0, flaggedRuns = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(dirty_in),0) AS s, COALESCE(SUM(flagged),0) AS f FROM palm6_laundering_runs')
        if r then
            out.totalRuns = tonumber(r.c) or 0
            out.totalDirtyWashed = tonumber(r.s) or 0
            out.flaggedRuns = tonumber(r.f) or 0
        end
    end)
    return out
end)
