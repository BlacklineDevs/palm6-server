-- ============================================================================
-- gtarp_whitelist_jobs/bridge/sv_framework.lua
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
function Bridge.OnJobChanged(handler)
    RegisterNetEvent('QBCore:Server:OnJobUpdate', function(_src, jobInfo)
        handler(source, jobInfo and jobInfo.name or nil)
    end)
end
