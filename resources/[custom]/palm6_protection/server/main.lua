-- ============================================================================
-- palm6_protection/server/main.lua
--
-- Pure logic. Calls Bridge.* for all framework / inventory / turf / native
-- access. No direct framework / native calls here (§6 gate).
--
-- The racket: a gang member standing at a business inside a turf zone THEIR
-- gang controls runs /shakedown to collect protection money (paid DIRTY, in
-- black_money). Each business is "paid up" for Config.CollectIntervalSec after
-- a collection, gang-agnostic. Turf control is read live from palm6_turf — lose
-- the zone, lose the income. Nothing here trusts a client-supplied gang, zone,
-- position, or item.
-- ============================================================================

local lastAction  = {}   -- [src] = ts of last /shakedown (spam guard)
AddEventHandler('playerDropped', function() lastAction[source] = nil end)  -- reclaim on disconnect
local collectLock = {}   -- [business_id] = true while a shakedown is in flight

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_protection] ' .. msg) end
end

-- The business the caller is standing at (within its radius), or nil.
local function businessAt(src)
    local c = Bridge.GetCoords(src)
    if not c then return nil end
    for _, b in ipairs(Config.Businesses) do
        if Bridge.Distance(c, b.coords) <= b.radius then return b end
    end
    return nil
end

-- Which turf zone a point sits in — the nearest zone center within OwnedZoneRadius,
-- or nil if the point is off any known zone. Centers mirror palm6_turf Config.Zones.
local function nearestZone(coords)
    local best, bestD
    for _, z in ipairs(Config.Zones or {}) do
        local d = Bridge.Distance(coords, z.coords)
        if d <= Config.OwnedZoneRadius and (not bestD or d < bestD) then best, bestD = z, d end
    end
    return best
end

-- A player-OWNED palm6_business storefront the caller is standing at, IF it sits in
-- a turf zone — shaped like a Config.Businesses entry (id/label/zone) so the
-- shakedown flow treats hardcoded and owned targets uniformly, plus isOwned/bizId/
-- balance for the drain path. Short-circuits nil when the dark gate is off, so
-- /shakedown stays byte-identical to today. An off-turf shop returns nil (a shop
-- nobody's crew controls the ground under is not shakeable).
local function ownedBusinessAt(src)
    if not Config.ExtortOwned then return nil end
    local c = Bridge.GetCoords(src)
    if not c then return nil end
    local biz = exports.palm6_business:BusinessAtCoords(c.x, c.y, c.z, Config.OwnedRadius)
    if not biz then return nil end
    local zone = nearestZone({ x = biz.x, y = biz.y, z = biz.z })
    if not zone then return nil end
    return {
        id = 'owned:' .. tostring(biz.id), label = biz.name, zone = zone.id,
        isOwned = true, bizId = biz.id, balance = biz.balance or 0,
    }
end

-- Seconds remaining before a business can be collected again, or 0 if ready.
local function cooldownRemaining(businessId)
    local newestAge
    pcall(function()
        local r = MySQL.single.await(
            "SELECT TIMESTAMPDIFF(SECOND, MAX(created_at), NOW()) AS age FROM palm6_protection_collections WHERE business_id = ?",
            { businessId })
        newestAge = r and r.age or nil
    end)
    if newestAge == nil then return 0 end          -- never collected
    local rem = Config.CollectIntervalSec - tonumber(newestAge)
    return rem > 0 and rem or 0
end

-- Open/append an extortion case for a reported shakedown (palm6_evidence v2
-- frozen exports only). Returns the case id or nil.
local function fileEvidence(cid, business, amount)
    if not Bridge.ResourceStarted('palm6_evidence') then return nil end
    local caseId
    pcall(function()
        local incidentKey = ('%s%s-%d'):format(
            Config.Evidence.IncidentKeyPrefix, business.id, math.floor(now() / 300))
        caseId = exports.palm6_evidence:EnsureCase(incidentKey, Config.Evidence.CaseTitle, 'palm6_protection')
        if caseId then
            exports.palm6_evidence:AppendEntry(caseId, 'extortion', {
                business = business.label, zone = business.zone, amount = amount,
            }, 'palm6_protection')
            exports.palm6_evidence:LinkSuspect(caseId, cid, nil)
        end
    end)
    return caseId
end

-- ---------------------------------------------------------------------------
-- /shakedown — collect protection at a business your gang's turf controls.
-- ---------------------------------------------------------------------------
local function cmdShakedown(src)
    if src == 0 then return end
    local t = now()
    -- Atomic check-and-set before any yield (rl() idiom).
    if (lastAction[src] or 0) + Config.CooldownSec > t then
        Bridge.Notify(src, 'Protection', 'Give it a second.', 'error')
        return
    end
    lastAction[src] = t

    local gang = Bridge.GetGang(src)
    if not gang then
        Bridge.Notify(src, 'Protection', "You're not in a crew.", 'error')
        return
    end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local business = businessAt(src) or ownedBusinessAt(src)
    if not business then
        Bridge.Notify(src, 'Protection', 'No business here to lean on.', 'error')
        return
    end

    local owner = Bridge.GetZoneOwner(business.zone)
    if owner ~= gang.name then
        Bridge.Notify(src, 'Protection', ("%s isn't your crew's block."):format(business.label), 'error')
        return
    end

    if collectLock[business.id] then
        Bridge.Notify(src, 'Protection', 'Someone from your crew is already working this place.', 'error')
        return
    end
    collectLock[business.id] = true

    local rem = cooldownRemaining(business.id)
    if rem > 0 then
        collectLock[business.id] = nil
        Bridge.Notify(src, 'Protection', ('%s already paid up — back in ~%dm.'):format(business.label, math.ceil(rem / 60)), 'error')
        return
    end

    local amount
    if business.isOwned then
        -- % cap: stings but never wipes — floor(balance * cut) vs the usual roll,
        -- whichever is smaller. A near-empty register yields nothing (no lock kept).
        local cap = math.floor((business.balance or 0) * Config.OwnedCutPct)
        amount = math.min(math.random(Config.PayoutMin, Config.PayoutMax), cap)
        if amount < 1 then
            collectLock[business.id] = nil
            Bridge.Notify(src, 'Protection',
                ("%s's register is empty — nothing to shake loose."):format(business.label), 'inform')
            return
        end
    else
        amount = math.random(Config.PayoutMin, Config.PayoutMax)
    end
    local flagged = math.random() < Config.ReportChance

    -- Record the collection (the durable per-business cooldown claim) BEFORE
    -- paying, so a swallowed insert can't leave the business collectable again
    -- right after a payout (free-repeat hole). If the insert fails, nobody pays.
    local rowId
    local okIns = pcall(function()
        rowId = MySQL.insert.await(
            [[INSERT INTO palm6_protection_collections
                (gang, business_id, zone_id, citizenid, amount, flagged)
              VALUES (?, ?, ?, ?, ?, ?)]],
            { gang.name, business.id, business.zone, cid, amount, flagged and 1 or 0 })
    end)
    if not okIns or not rowId then
        collectLock[business.id] = nil
        Bridge.Notify(src, 'Protection', "Couldn't work the books right now — try again.", 'error')
        return
    end

    -- Void the durable claim + release the lock (every pay-failure path below).
    local function voidClaim()
        pcall(function()
            MySQL.update.await("DELETE FROM palm6_protection_collections WHERE id = ?", { rowId })
        end)
        collectLock[business.id] = nil
    end

    -- Take the money. Hardcoded businesses MINT dirty cash. Owned businesses are
    -- DRAINED from their real pooled account first (bounded, never minted, never
    -- overdrawn), THEN the collector is handed the same dirty cash — if that item
    -- hand-off fails, the drain is refunded so no money is lost. Any failure voids
    -- the claim so the business isn't falsely locked for a payout that never happened.
    if business.isOwned then
        local taken = exports.palm6_business:Extort(business.bizId, amount, cid, 'Shakedown')
        if not taken or taken < 1 then
            voidClaim()
            Bridge.Notify(src, 'Protection', ("%s's register came up dry."):format(business.label), 'error')
            return
        end
        amount = taken   -- Extort is all-or-nothing at `amount`, so taken == amount.
        if not Bridge.GiveItem(src, Config.Payout, amount) then
            -- Refund the drain. It only fails if the owner CLOSED the business in the
            -- gap (its row is gone) — then the amount is destroyed (deflationary, rare,
            -- non-exploitable). Meter it rather than swallow it, per the money-safety note.
            if not exports.palm6_business:RefundExtortion(business.bizId, amount, 'shakedown-void') then
                print(('^3[palm6_protection] shakedown void: $%d could not be refunded to business %s ')
                    :format(amount, tostring(business.bizId))
                    .. '(closed mid-shakedown) — destroyed.^0')
            end
            voidClaim()
            Bridge.Notify(src, 'Protection', "Couldn't take the cash right now — try again.", 'error')
            return
        end
    else
        if not Bridge.GiveItem(src, Config.Payout, amount) then
            voidClaim()
            Bridge.Notify(src, 'Protection', "Couldn't take the cash right now — try again.", 'error')
            return
        end
    end

    -- Reported? fire the alert + evidence and attach the case to the row.
    if flagged then
        Bridge.PoliceAlert(src, 'Suspected extortion in progress')
        local caseId = fileEvidence(cid, business, amount)
        if caseId then
            pcall(function()
                MySQL.update.await("UPDATE palm6_protection_collections SET evidence_case_id = ? WHERE id = ?", { caseId, rowId })
            end)
        end
    end

    collectLock[business.id] = nil
    Bridge.Notify(src, 'Protection',
        ('Shook down %s for $%d (dirty). Get it washed.'):format(business.label, amount), 'success')

    -- Persistent police attention: extortion is a gang crime, and a reported
    -- (flagged) shakedown runs hotter. Keyed to the collector (cid) so it
    -- follows them after they log. Fires only after the payout committed above.
    -- Soft-dep + pcall — a stopped palm6_heat never touches the shakedown path.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(cid,
                Config.HeatOnShakedown + (flagged and Config.HeatFlaggedBonus or 0),
                'shakedown')
        end)
    end

    dbg(('%s (%s) shook %s for $%d, flagged=%s'):format(cid, gang.name, business.id, amount, tostring(flagged)))
end

-- ---------------------------------------------------------------------------
-- /rackets — read-only: businesses your crew controls + which are ready.
-- ---------------------------------------------------------------------------
local function cmdRackets(src)
    if src == 0 then return end
    local gang = Bridge.GetGang(src)
    if not gang then
        Bridge.Notify(src, 'Protection', "You're not in a crew.", 'error')
        return
    end
    local ready, cooling, held = 0, 0, 0
    for _, b in ipairs(Config.Businesses) do
        if Bridge.GetZoneOwner(b.zone) == gang.name then
            held = held + 1
            if cooldownRemaining(b.id) > 0 then cooling = cooling + 1 else ready = ready + 1 end
        end
    end
    if held == 0 then
        Bridge.Notify(src, 'Protection', "Your crew doesn't run any blocks with businesses right now.", 'inform')
        return
    end
    Bridge.Notify(src, 'Protection',
        ('%s controls %d business block(s): %d ready to collect, %d paid up.'):format(gang.label, held, ready, cooling), 'inform')
end

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('shakedown', function(source) cmdShakedown(source) end)
Bridge.RegisterCommand('rackets', function(source) cmdRackets(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not Bridge.ItemExists(Config.Payout) then
        print(('^1[palm6_protection] FATAL: payout item "%s" is not registered in ox_inventory — '
            .. 'protection racket disabled.^0'):format(Config.Payout))
        return
    end
    local turf = Bridge.ResourceStarted('palm6_turf')
    local total, collected = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s FROM palm6_protection_collections')
        total = r and tonumber(r.c) or 0
        collected = r and tonumber(r.s) or 0
    end)
    print(('[palm6_protection] racket open — %d business(es), %d shakedown(s) all-time ($%d); turf link %s'):format(
        #Config.Businesses, total, collected, turf and 'ONLINE' or 'OFFLINE (no owners → nothing collectable)'))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { businesses = #Config.Businesses, shakedowns = 0, totalCollected = 0, flagged = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s, COALESCE(SUM(flagged),0) AS f FROM palm6_protection_collections')
        if r then
            out.shakedowns = tonumber(r.c) or 0
            out.totalCollected = tonumber(r.s) or 0
            out.flagged = tonumber(r.f) or 0
        end
    end)
    return out
end)
