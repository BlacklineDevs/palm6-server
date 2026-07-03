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
        { src, Bridge.GetPrimaryIdentifier(src), eventName, reason }
    )

    pcall(function()
        exports.gtarp_staff:Log('eventguard', 0, src, detail)
    end)

    if Violations[src] >= (Config.KickThreshold or 3) then
        Bridge.Kick(src, 'kicked by eventguard: repeated event violations')
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
    end)
end

-- onResourceStart can fire more than once for this resource's own name in
-- some boot sequences (observed: guards silently double-registering,
-- halving every rate-limit budget and doubling violation counts — false
-- kicks after as few as 2 real breaches). Guard registration is not safe
-- to run twice in the same VM, so make it idempotent regardless of how
-- many times the event fires.
local guardsRegistered = false

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if guardsRegistered then return end
    guardsRegistered = true

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
