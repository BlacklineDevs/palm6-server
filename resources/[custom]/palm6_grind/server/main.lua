-- ============================================================================
-- palm6_grind/server/main.lua
--
-- Gather / sell / XP for the legal grind activities. Pure logic — all
-- framework/native/inventory access goes through Bridge.* . Our own
-- grind_skill table (sql/0011_grind.sql) is portable, so it stays here.
-- ============================================================================

local xpCache   = {}  -- [cid] = { [activity] = xp }
local lastGather = {} -- [src] = { [activity] = os.time() }
local sellInFlight = {} -- [src] = true while one palm6_grind:sell is mid-flight

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Same shape as palm6_courier and palm6_ems:
-- Wait-for-oxmysql on the caller's thread, per-statement pcall, IF NOT EXISTS
-- so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- grind_skill at all. The failure is near-silent: loadXp raises inside the
-- gather net event AFTER seeding an empty cache entry, so gathering keeps
-- working while every XP write is lost and levels never move. On the live box
-- this statement is a pure no-op.
--
-- The DDL is copied VERBATIM from sql/0011_grind.sql. There are no additive
-- ALTERs for this table.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `grind_skill` (
    `citizenid` VARCHAR(64)  NOT NULL,
    `activity`  VARCHAR(32)  NOT NULL,
    `xp`        INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`, `activity`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_grind] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Runs on its own thread because ensureSchema has to Wait for oxmysql's
    -- connection before any query. Nothing else is loaded at boot: xpCache is
    -- filled lazily per player by loadXp, so no command or event depends on
    -- this thread having finished and no bootReady gate is needed.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        if not SchemaReady then
            print('^1[palm6_grind] schema MISSING - grind XP will not persist on this box.^0')
        end
    end)
end)

local function levelOf(xp)
    return math.min(Config.MaxLevel, math.floor((xp or 0) / Config.XpPerLevel))
end

local function loadXp(cid)
    if xpCache[cid] then return end
    xpCache[cid] = {}
    local rows = MySQL.query.await('SELECT activity, xp FROM grind_skill WHERE citizenid = ?', { cid }) or {}
    for _, r in ipairs(rows) do xpCache[cid][r.activity] = r.xp end
end

local function getXp(cid, activity)
    loadXp(cid)
    return xpCache[cid][activity] or 0
end

local function addXp(cid, activity, amount)
    loadXp(cid)
    local xp = (xpCache[cid][activity] or 0) + amount
    xpCache[cid][activity] = xp
    MySQL.query.await(
        'INSERT INTO grind_skill (citizenid, activity, xp) VALUES (?, ?, ?) \z
         ON DUPLICATE KEY UPDATE xp = VALUES(xp)',
        { cid, activity, xp })
    return xp
end

local function nearby(src, coords, extra)
    local c = Bridge.GetCoords(src)
    -- FAIL CLOSED. This used to return true ("can't verify -> allow"), which
    -- meant an unreadable server-side position let a range-gated action settle
    -- from anywhere: palm6_grind:sell has nearby(src, sell.coords) as its ONLY
    -- location gate before Bridge.AddCash. Every real caller passes a coords
    -- table (all three Config.Activities define sell.coords, and the gather path
    -- proves act.spots[spotIndex] exists before calling), so refusing here only
    -- rejects the cases we genuinely cannot verify.
    if not c or not coords then return false end
    return Bridge.Distance(c, coords) <= (Config.InteractRadius + (extra or 3.0))
end

-- ---------------------------------------------------------------------------
-- gather
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_grind:gather', function(activityKey, spotIndex)
    local src = source
    local act = Config.Activities[activityKey]
    if not act then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if not Bridge.HasItem(src, act.tool) then
        Bridge.Notify(src, act.label, ('You need a %s to do this.'):format(act.tool:gsub('_', ' ')), 'error')
        return
    end

    -- spotIndex is client-supplied, so an out-of-range value makes `spot` nil.
    -- nearby() now fails CLOSED on a nil coords (see its body above), so this is
    -- belt and braces rather than the only thing standing between a crafted event
    -- and gathering from anywhere. Keep it: it rejects the bad index explicitly
    -- and notifies, instead of relying on a distance check to refuse a nil.
    local spot = type(spotIndex) == 'number' and act.spots[spotIndex] or nil
    if not spot or not nearby(src, spot) then
        Bridge.Notify(src, act.label, 'You are not at a gathering spot.', 'error')
        return
    end

    lastGather[src] = lastGather[src] or {}
    local now = os.time()
    if now - (lastGather[src][activityKey] or 0) < Config.GatherCooldown then
        Bridge.Notify(src, act.label, 'You need to wait a moment.', 'error')
        return
    end
    lastGather[src][activityKey] = now

    local level = levelOf(getXp(cid, activityKey))
    local bonus = math.floor(level / 5)  -- +1 extra per 5 levels
    local gotAny, summary = false, {}
    for _, y in ipairs(act.yields) do
        local n = math.random(y.min, y.max)
        if y.min > 0 or y.max > 0 then n = n + (y.item ~= 'animal_pelt' and bonus or 0) end
        if n > 0 then
            if Bridge.GiveItem(src, y.item, n) then
                gotAny = true
                summary[#summary + 1] = ('%dx %s'):format(n, y.item:gsub('_', ' '))
            end
        end
    end

    if not gotAny then
        Bridge.Notify(src, act.label, 'Your inventory is full.', 'error')
        return
    end

    addXp(cid, activityKey, act.xp_per_gather)
    Bridge.Notify(src, act.label, ('Gathered %s'):format(table.concat(summary, ', ')), 'success')
end)

-- ---------------------------------------------------------------------------
-- sell
-- ---------------------------------------------------------------------------
-- IN-FLIGHT LATCH. This was the only money handler in the layer with no
-- synchronous latch of any kind, and its own sibling `gather` above has one
-- (lastGather, stamped before the getXp yield).
--
-- The race: this handler reads the full stack with Bridge.CountItem, then yields
-- -- getXp() hits MySQL whenever the xp cache is cold, which a reconnect
-- guarantees because playerDropped clears it -- and only afterwards calls
-- RemoveItem and AddCash. Two copies fired in one frame both read the same
-- `count` and both proceed to the grant.
--
-- WHETHER THAT DOUBLE-PAYS IS NOT KNOWABLE FROM THIS REPO, and this latch is not
-- claiming it does. ox_inventory is part of the base pack and lives on the game
-- box, so RemoveItem's semantics are unreadable here, and the bridge passes its
-- return value straight through. If RemoveItem clamps an over-large count and
-- still returns truthy, this is a cash dupe; if it is all-or-nothing and returns
-- false, the `if not Bridge.RemoveItem` below already catches it and nothing is
-- lost. The latch is added because a money path whose safety depends on an
-- unversioned out-of-repo dependency behaving one particular way is not a
-- hardened money path, regardless of which way it behaves today.
--
-- An in-flight latch rather than a timestamp: there is no Config.SellCooldown and
-- selling a whole stack in one action is intended, so a time window would be a
-- gameplay change. This only collapses concurrent copies.
RegisterNetEvent('palm6_grind:sell', function(activityKey)
    local src = source
    local act = Config.Activities[activityKey]
    if not act then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local sell = act.sell

    if not nearby(src, sell.coords) then
        Bridge.Notify(src, sell.label, 'You are not at the buyer.', 'error')
        return
    end

    -- Set before the first yield. Bridge.GetCitizenId and nearby() are both
    -- synchronous (a cached qbx player read and a server-side coord read), so
    -- nothing above this point can have suspended.
    if sellInFlight[src] then return end
    sellInFlight[src] = true

    local ok, err = pcall(function()
        local count = Bridge.CountItem(src, sell.item)
        if count <= 0 then
            Bridge.Notify(src, sell.label, ('You have no %s to sell.'):format(sell.item:gsub('_', ' ')), 'error')
            return
        end

        local level = levelOf(getXp(cid, activityKey))
        local price = math.floor(sell.price * (1 + level * Config.PriceBonusPerLevel))
        local total = count * price

        -- palm6_pulse "Boomtown" window boosts legal-grind sale value. Server-read +
        -- capped (a client can't assert a multiplier); pcall+ResourceState-gated so
        -- grind runs standalone if pulse is absent. This is an NPC-buyer faucet — the
        -- exact reward loop the Boomtown window is meant to amplify.
        local boomMult = 1.0
        pcall(function()
            if GetResourceState('palm6_pulse') == 'started' then
                local m = exports.palm6_pulse:GetActiveModifier('grind')
                if type(m) == 'number' and m > 1 then boomMult = m end
            end
        end)
        total = math.floor(total * boomMult)

        if not Bridge.RemoveItem(src, sell.item, count) then
            Bridge.Notify(src, sell.label, 'Sale failed.', 'error')
            return
        end
        Bridge.AddCash(src, total, 'grind-sell')
        -- Derive the each-price from the (possibly boosted) total so the numbers agree,
        -- and tag the Boomtown boost so it's legible.
        local each = count > 0 and math.floor(total / count) or total
        local boom = boomMult > 1 and (' [Boomtown x%.2f]'):format(boomMult) or ''
        Bridge.Notify(src, sell.label,
            ('Sold %dx %s for $%d ($%d each).%s'):format(count, sell.item:gsub('_', ' '), total, each, boom), 'success')
    end)

    -- Release unconditionally. A leaked latch would permanently stop that player
    -- selling, which is worse than the race it closes. The error is re-raised
    -- unchanged so nothing is swallowed.
    sellInFlight[src] = nil
    if not ok then error(err, 0) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastGather[src] = nil
    sellInFlight[src] = nil
    local cid = Bridge.GetCitizenId(src)
    if cid then xpCache[cid] = nil end  -- reloaded fresh from DB next session; keeps this bounded to online players
end)
