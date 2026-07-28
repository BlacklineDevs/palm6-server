-- ============================================================================
-- palm6_whitelist_jobs/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that knows
-- about player identifiers, the qbx_core / QBCore setjob API, the job-update
-- event name, or ox_lib notifications.
--
-- Core logic (server/main.lua) calls Bridge.* and nothing else. To port
-- this resource to a different framework (or to GTA VI), rewrite THIS FILE.
-- The whitelist roster matching, staff override, and enforcement decision
-- are untouched.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

-- All identifiers for a server source as an index-iterable list.
function Bridge.GetIdentifiers(src)
    local list = GetPlayerIdentifiers(src) or {}
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

-- Set a player's job, preferring the qbx_core player API and falling back
-- to the QBCore event. Returns true if the qbx path succeeded.
function Bridge.SetJob(src, job, grade)
    local ok = pcall(function()
        local player = exports.qbx_core:GetPlayer(src)
        if player and player.Functions and player.Functions.SetJob then
            player.Functions.SetJob(job, grade or 0)
        end
    end)
    if not ok then
        TriggerEvent('QBCore:Server:SetJob', src, job, grade or 0)
    end
    return ok
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'error',
    })
end

-- Register a callback fired when a player's job changes. The callback
-- receives (src, jobName). This hides the framework's job-update event name.
--
-- AddEventHandler, NOT RegisterNetEvent: qbx_core raises
-- QBCore:Server:OnJobUpdate server-side with TriggerEvent, so AddEventHandler is
-- sufficient to receive it. RegisterNetEvent would additionally make the name
-- network-addressable for EVERY listener on the box, letting a modified client
-- announce an arbitrary job change and drive this whitelist enforcement path
-- with fabricated arguments.
--
-- The swap is behaviour-neutral: RegisterNetEvent(name, cb) is just
-- RegisterNetEvent(name) + AddEventHandler(name, cb), so the handler and the
-- value of `source` inside it are identical either way. What is NOT true (an
-- earlier version of this comment claimed it) is that a server-side
-- TriggerEvent "inherits the triggering context's source". This repo's own
-- shared server-raise predicate says the opposite: a raise from inside the
-- server VM surfaces as nil, <= 0, or 65535 - see palm6_eventguard/server/main.lua
-- guard(), palm6_mdt/bridge/sv_framework.lua Bridge.OnPoliceAlert (grep
-- `local fromNet`) and palm6_witnesses/server/main.lua's
-- police:server:policeAlert handler (grep `local isServerCall`). Cited by symbol,
-- not line number: those files have drifted twice already. So `source` here must
-- be treated as unreliable, which is why the explicit first argument wins below.
function Bridge.OnJobChanged(handler)
    AddEventHandler('QBCore:Server:OnJobUpdate', function(evtSrc, jobInfo)
        -- Prefer the EXPLICIT first argument - qbx_core passes the affected
        -- player's server id there, and enforcement (server/main.lua:59 ->
        -- enforce(src, ...)) rolls back a job against whatever id it is handed.
        -- Fall back to the ambient `source` only when the argument is missing or
        -- is not a plausible player id, so a fork with a different signature
        -- degrades to the old behaviour instead of enforcing against a
        -- non-player.
        local src = tonumber(evtSrc)
        if not src or src <= 0 or src == 65535 then src = source end
        handler(src, jobInfo and jobInfo.name or nil)
    end)
end
