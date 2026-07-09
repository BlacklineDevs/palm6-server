-- ============================================================================
-- gtarp_laundering/server/main.lua
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
local frontHeat = 0.0   -- single-front heat accumulator (server-only, decays)

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_laundering] ' .. msg) end
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
            "SELECT COALESCE(SUM(dirty_in),0) AS n FROM gtarp_laundering_runs WHERE citizenid = ? AND created_at >= CURDATE()",
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

-- Open/append an evidence case for a flagged run. Returns the case id or nil.
-- Uses ONLY the gtarp_evidence v2 frozen exports (never its tables directly).
local function fileEvidence(cid, dirtyIn, cleanOut)
    if not Bridge.ResourceStarted('gtarp_evidence') then return nil end
    local caseId
    pcall(function()
        local incidentKey = ('%s%s-%d'):format(
            Config.Evidence.IncidentKeyPrefix, cid, math.floor(now() / 300))
        caseId = exports.gtarp_evidence:EnsureCase(
            incidentKey, Config.Evidence.CaseTitle, 'gtarp_laundering')
        if caseId then
            exports.gtarp_evidence:AppendEntry(caseId, 'laundering_run', {
                front = Config.Front.label, dirty_in = dirtyIn, clean_out = cleanOut,
            }, 'gtarp_laundering')
            exports.gtarp_evidence:LinkSuspect(caseId, cid, nil)
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
    -- Atomic check-and-set BEFORE any yield (the same rl() idiom gtarp_chopshop
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

    local cleanOut = math.floor(amount * (1.0 - Config.Cut))
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
            [[INSERT INTO gtarp_laundering_runs
                (citizenid, dirty_in, clean_out, fee_bps, flagged, evidence_case_id)
              VALUES (?, ?, ?, ?, ?, ?)]],
            { cid, amount, cleanOut, math.floor(Config.Cut * 10000 + 0.5), flagged and 1 or 0, caseId })
    end)

    Bridge.Notify(src, 'Laundromat',
        ('Washed $%d — $%d landed clean in your account.'):format(amount, cleanOut), 'success')
    dbg(('%s washed $%d -> $%d clean (flagged=%s, heat=%.1f)'):format(cid, amount, cleanOut, tostring(flagged), frontHeat))
end

-- ---------------------------------------------------------------------------
-- /dirtymoney — read-only: what you're holding + today's remaining ceiling.
-- ---------------------------------------------------------------------------
local function cmdDirtyMoney(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local held = Bridge.CountItem(src, Config.DirtyItem)
    local remaining = math.max(0, Config.DailyCap - dirtyWashedToday(cid))
    Bridge.Notify(src, 'Dirty Money',
        ('Holding $%d dirty · today you can still wash $%d · fee %d%%'):format(
            held, remaining, math.floor(Config.Cut * 100 + 0.5)), 'inform')
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
        print(('^1[gtarp_laundering] FATAL: dirty-money item "%s" is not registered in ox_inventory — '
            .. 'laundering disabled. Nothing to wash.^0'):format(Config.DirtyItem))
        return
    end
    local runs, washed = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(dirty_in),0) AS s FROM gtarp_laundering_runs')
        runs = r and tonumber(r.c) or 0
        washed = r and tonumber(r.s) or 0
    end)
    print(('[gtarp_laundering] laundromat open — $%d washed all-time across %d run(s); fee %d%%'):format(
        washed, runs, math.floor(Config.Cut * 100 + 0.5)))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalRuns = 0, totalDirtyWashed = 0, flaggedRuns = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(dirty_in),0) AS s, COALESCE(SUM(flagged),0) AS f FROM gtarp_laundering_runs')
        if r then
            out.totalRuns = tonumber(r.c) or 0
            out.totalDirtyWashed = tonumber(r.s) or 0
            out.flaggedRuns = tonumber(r.f) or 0
        end
    end)
    return out
end)
