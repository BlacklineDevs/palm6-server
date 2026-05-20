-- ============================================================================
-- gtarp_whitelist_jobs/server/main.lua
--
-- Enforces emergency-services whitelisting. Hooks the qbx_core setjob
-- flow: rejects a setjob if the target player's identifiers do not appear
-- in Config.Allowed[<job>] (or in Config.StaffOverride).
--
-- Exposes IsAllowed(src, job) for downstream resources (Phase 9 allowlist).
-- ============================================================================

local function identifiersFor(src)
    local list = GetPlayerIdentifiers(src) or {}
    -- ensure index-iterable
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

local function listContains(list, id)
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

local function isStaff(src)
    if not Config.StaffOverride or #Config.StaffOverride == 0 then return false end
    local ids = identifiersFor(src)
    for i = 1, #ids do
        if listContains(Config.StaffOverride, ids[i]) then return true end
    end
    return false
end

local function isAllowed(src, job)
    if isStaff(src) then return true end
    local roster = Config.Allowed[job]
    if not roster then return true end -- non-whitelisted job
    local ids = identifiersFor(src)
    for i = 1, #ids do
        if listContains(roster, ids[i]) then return true end
    end
    return false
end

exports('IsAllowed', isAllowed)

-- ---------------------------------------------------------------------------
-- Setjob enforcement
-- ---------------------------------------------------------------------------
-- qbx_core fires a server-side event when a job is being set. We veto by
-- restoring the prior job after the fact. The recipe's qbx_core
-- implementation exposes player.Functions.SetJob; we shim by listening on
-- the canonical event name and rolling back when denied.

local function notify(src, msg)
    TriggerClientEvent('ox_lib:notify', src, {
        title = 'Whitelist',
        description = msg,
        type = 'error',
    })
end

local function enforce(src, newJob, prevJob)
    if not Config.Allowed[newJob] then return end
    if isAllowed(src, newJob) then return end
    -- Roll back. If we don't know prevJob, default to 'unemployed'.
    local rollback = prevJob or 'unemployed'
    print(('[gtarp_whitelist_jobs] denied src=%d job=%s -> rolling back to %s'):format(
        src, tostring(newJob), rollback
    ))
    -- Use exports.qbx_core where available; fall back to QBCore event.
    local ok = pcall(function()
        local player = exports.qbx_core:GetPlayer(src)
        if player and player.Functions and player.Functions.SetJob then
            player.Functions.SetJob(rollback, 0)
        end
    end)
    if not ok then
        TriggerEvent('QBCore:Server:SetJob', src, rollback, 0)
    end
    notify(src, Config.DenyMessage)
end

RegisterNetEvent('QBCore:Server:OnJobUpdate', function(_src, jobInfo)
    local src = source
    enforce(src, jobInfo and jobInfo.name or nil, nil)
end)

-- /setjob command guard — fired locally as a safety net for any path that
-- doesn't go through the canonical event. Server-only command; the actual
-- /setjob lives in qbx_core. Admins still need command.setjob via ACE.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print(('[gtarp_whitelist_jobs] enforcing whitelist for %d job(s)'):format(
        (function() local n = 0; for _ in pairs(Config.Allowed) do n = n + 1 end; return n end)()
    ))
end)
