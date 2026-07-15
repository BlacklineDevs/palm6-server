-- ============================================================================
-- palm6_grind/server/main.lua
--
-- Gather / sell / XP for the legal grind activities. Pure logic — all
-- framework/native/inventory access goes through Bridge.* . Our own
-- grind_skill table (sql/0011_grind.sql) is portable, so it stays here.
-- ============================================================================

local xpCache   = {}  -- [cid] = { [activity] = xp }
local lastGather = {} -- [src] = { [activity] = os.time() }

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
    if not c or not coords then return true end  -- can't verify -> allow
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

    -- spotIndex is client-supplied: an out-of-range value would make `spot`
    -- nil, and nearby(src, nil) fails open (returns true), letting a crafted
    -- event gather from anywhere. Require a real spot before the range check.
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

AddEventHandler('playerDropped', function()
    local src = source
    lastGather[src] = nil
    local cid = Bridge.GetCitizenId(src)
    if cid then xpCache[cid] = nil end  -- reloaded fresh from DB next session; keeps this bounded to online players
end)
