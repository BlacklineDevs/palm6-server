-- ============================================================================
-- gtarp_eventguard/server/main.lua
--
-- Ratelimits the events listed in Config.Events. Wraps the existing
-- handler chain by registering ourselves first; when a player exceeds the
-- budget we log to event_violations and drop the event. After
-- Config.KickThreshold breaches in a session, the player is kicked.
-- ============================================================================

local Counts     = {}  -- [eventName][src] = { calls = {ts...}, breaches = 0 }
local Violations = {}  -- [src] = total breaches this session

local function now() return os.time() end

local function bucket(eventName, src)
    Counts[eventName] = Counts[eventName] or {}
    Counts[eventName][src] = Counts[eventName][src] or { calls = {}, breaches = 0 }
    return Counts[eventName][src]
end

local function prune(b, window)
    local t = now()
    local i = 1
    while i <= #b.calls do
        if b.calls[i] < (t - window) then
            table.remove(b.calls, i)
        else
            i = i + 1
        end
    end
end

local function record(src, eventName, reason)
    Violations[src] = (Violations[src] or 0) + 1
    local detail = ('event=%s reason=%s breaches_session=%d'):format(
        eventName, reason, Violations[src])
    print(('[gtarp_eventguard] VIOLATION src=%d %s'):format(src, detail))

    MySQL.insert.await(
        "INSERT INTO event_violations (player_src, identifier, event_name, reason, created_at) VALUES (?,?,?,?, NOW())",
        { src, (GetPlayerIdentifiers(src) or {})[1] or '', eventName, reason }
    )

    pcall(function()
        exports.gtarp_staff:Log('eventguard', 0, src, detail)
    end)

    if Violations[src] >= (Config.KickThreshold or 3) then
        DropPlayer(src, 'kicked by eventguard: repeated event violations')
    end
end

-- Wrap one event with the ratelimit. Returns the wrapper handler.
local function guard(eventName, budget)
    AddEventHandler(eventName, function(...)
        local src = source
        if not src or src == 0 then return end  -- skip server-emitted
        local b = bucket(eventName, src)
        prune(b, budget.window_seconds)
        if #b.calls >= budget.calls then
            record(src, eventName, ('over budget %d/%ds'):format(
                budget.calls, budget.window_seconds))
            CancelEvent()
            return
        end
        b.calls[#b.calls + 1] = now()

        -- Cheap amount-validation for money-shaped events.
        local args = { ... }
        if eventName == 'QBCore:Server:UpdateMoney' then
            local amount = tonumber(args[2])
            if amount and math.abs(amount) > (Config.MaxClientMoneyDelta or 5000) then
                record(src, eventName, ('amount=%d > max %d'):format(
                    amount, Config.MaxClientMoneyDelta))
                CancelEvent()
                return
            end
        end
    end)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local n = 0
    for name, budget in pairs(Config.Events) do
        guard(name, budget)
        n = n + 1
    end
    print(('[gtarp_eventguard] guarding %d events; kick threshold=%d'):format(
        n, Config.KickThreshold or 3))
end)

AddEventHandler('playerDropped', function()
    local src = source
    Violations[src] = nil
    for name, t in pairs(Counts) do t[src] = nil end
end)

exports('GetViolations', function(src) return Violations[src] or 0 end)
