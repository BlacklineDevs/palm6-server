-- ============================================================================
-- palm6_onboarding/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- First-ever character load: prompt the mandatory rules dialog, record
-- server-side acceptance, grant a one-time starter cash amount, log to
-- palm6_staff, then show a short tour. Every later load is a no-op (the
-- `palm6_onboarding` row already exists) except /rules, which just
-- re-displays the text — it never re-triggers the accept flow.
--
-- Client-trust note: `palm6_onboarding:acceptRules` is a client-addressable
-- net event. It is NOT trusted as proof the dialog was actually shown or
-- accepted — the guard that matters is server-side: UNIQUE(citizenid) on
-- palm6_onboarding means the starter-cash grant can only ever land once
-- per citizen no matter how many times (or how fast) the event fires,
-- replayed or otherwise. Same idiom as every other guarded-write feature
-- this session (palm6_ransom's payout guard, palm6_pumpcoin's mint-ticker
-- fix, palm6_courier's escrow guard).
-- ============================================================================

local lastAccept = {} -- [src] = ts — accept-event rate limit
local lastCheck = {}  -- [src] = ts — checkStatus rate limit (it runs a DB query)

local function now() return os.time() end

local function alreadyOnboarded(citizenid)
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT id FROM palm6_onboarding WHERE citizenid = ?', { citizenid })
    end)
    return row ~= nil
end

-- ---------------------------------------------------------------------------
-- First load (or reconnect) — server decides whether the mandatory prompt
-- is owed. Nothing here is client-trusted: the DB row is the source of truth.
-- ---------------------------------------------------------------------------
Bridge.OnPlayerLoaded(function(src)
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if alreadyOnboarded(cid) then return end
    TriggerClientEvent('palm6_onboarding:promptRules', src)
end)

-- Client also explicitly asks on load (belt-and-suspenders — if the client
-- resource restarted after the player was already in the world, the
-- Bridge.OnPlayerLoaded event won't refire, but this will).
RegisterNetEvent('palm6_onboarding:checkStatus', function()
    local src = source
    local ct = os.time()
    if ct - (lastCheck[src] or 0) < 3 then return end  -- rate-limit: runs a DB query
    lastCheck[src] = ct
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if alreadyOnboarded(cid) then return end
    TriggerClientEvent('palm6_onboarding:promptRules', src)
end)

-- ---------------------------------------------------------------------------
-- Accept — guarded INSERT is the entire safety story here (see header).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_onboarding:acceptRules', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local t = now()
    if (lastAccept[src] or 0) + Config.AcceptCooldownSec > t then return end
    lastAccept[src] = t

    local inserted = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_onboarding (citizenid) VALUES (?)', { cid })
    end)
    if not inserted then
        -- UNIQUE(citizenid) rejected it — already onboarded (a race, or a
        -- replayed event from a modified client). Nothing left to grant.
        return
    end

    if Config.StarterCash.enabled then
        Bridge.CreditBank(src, Config.StarterCash.amount, Config.StarterCash.reason)
        pcall(function()
            MySQL.update.await(
                'UPDATE palm6_onboarding SET starter_cash_granted = 1 WHERE citizenid = ?',
                { cid })
        end)
    end

    -- Starter vehicle — owned car parked in a garage. Best-effort: if
    -- qbx_vehicles is down or the grant fails, cash still stands and the flag
    -- stays 0 (never re-granted, because the citizen row already exists — the
    -- guard is the once-per-citizen INSERT above, not this flag).
    if Config.StarterVehicle.enabled then
        local granted = Bridge.GiveStarterVehicle(cid, Config.StarterVehicle.model,
            Config.StarterVehicle.garage)
        if granted then
            pcall(function()
                MySQL.update.await(
                    'UPDATE palm6_onboarding SET starter_vehicle_granted = 1 WHERE citizenid = ?',
                    { cid })
            end)
            Bridge.Notify(src, 'Welcome to Palm6',
                ('Your starter vehicle is parked at the %s garage.'):format(Config.StarterVehicle.garage),
                'success')
        end
    end

    -- Starter outfit — deferred (Config.StarterOutfit.enabled is false by
    -- default); the Bridge hook is a no-op until the illenium path is validated.
    if Config.StarterOutfit.enabled then
        if Bridge.SetStarterOutfit(src, cid) then
            pcall(function()
                MySQL.update.await(
                    'UPDATE palm6_onboarding SET starter_outfit_granted = 1 WHERE citizenid = ?',
                    { cid })
            end)
        end
    end

    if Bridge.ResourceStarted('palm6_staff') then
        pcall(function()
            exports.palm6_staff:Log('onboarding_rules_accepted', src, nil, cid)
        end)
    end

    TriggerClientEvent('palm6_onboarding:showTour', src)
end)

-- ---------------------------------------------------------------------------
-- /rules — read-only, any time, does not touch the DB or re-trigger accept.
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('rules', function(source)
    if source == 0 then return end
    TriggerClientEvent('palm6_onboarding:showRulesReadOnly', source)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local total = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_onboarding')
        total = r and tonumber(r.n) or 0
    end)
    print(('[palm6_onboarding] online — %d citizen(s) onboarded all-time'):format(total))
end)

---Onboarded-citizen counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalAccepted = 0, starterVehicles = 0, starterOutfits = 0 }
    pcall(function()
        local r = MySQL.single.await([[
            SELECT COUNT(*) AS n,
                   COALESCE(SUM(starter_vehicle_granted), 0) AS veh,
                   COALESCE(SUM(starter_outfit_granted), 0)  AS fit
            FROM palm6_onboarding]])
        if r then
            out.totalAccepted   = tonumber(r.n) or 0
            out.starterVehicles = tonumber(r.veh) or 0
            out.starterOutfits  = tonumber(r.fit) or 0
        end
    end)
    return out
end)
