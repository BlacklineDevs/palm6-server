-- ============================================================================
-- gtarp_whitelist_jobs/server/main.lua
--
-- Enforces emergency-services whitelisting. Pure logic: roster matching,
-- staff override, and the deny/rollback decision. All framework and
-- runtime calls (identifiers, setjob, notify, job-change event) go through
-- Bridge.* (bridge/sv_framework.lua) so this file is framework-agnostic.
--
-- Exposes IsAllowed(src, job) for downstream resources (Phase 9 allowlist).
-- See docs/GTA6-READINESS.md.
-- ============================================================================

local function listContains(list, id)
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

local function isStaff(src)
    if not Config.StaffOverride or #Config.StaffOverride == 0 then return false end
    local ids = Bridge.GetIdentifiers(src)
    for i = 1, #ids do
        if listContains(Config.StaffOverride, ids[i]) then return true end
    end
    return false
end

local function isAllowed(src, job)
    if isStaff(src) then return true end
    local roster = Config.Allowed[job]
    if not roster then return true end -- non-whitelisted job
    local ids = Bridge.GetIdentifiers(src)
    for i = 1, #ids do
        if listContains(roster, ids[i]) then return true end
    end
    return false
end

exports('IsAllowed', isAllowed)

-- ---------------------------------------------------------------------------
-- Setjob enforcement
-- ---------------------------------------------------------------------------
-- When a player's job changes to a whitelisted job they are not allowed to
-- hold, roll them back to their prior job (or 'unemployed' if unknown).

local function enforce(src, newJob, prevJob)
    if not Config.Allowed[newJob] then return end
    if isAllowed(src, newJob) then return end
    local rollback = prevJob or 'unemployed'
    print(('[gtarp_whitelist_jobs] denied src=%d job=%s -> rolling back to %s'):format(
        src, tostring(newJob), rollback
    ))
    Bridge.SetJob(src, rollback, 0)
    Bridge.Notify(src, 'Whitelist', Config.DenyMessage, 'error')
end

Bridge.OnJobChanged(function(src, jobName)
    enforce(src, jobName, nil)
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print(('[gtarp_whitelist_jobs] enforcing whitelist for %d job(s)'):format(
        (function() local n = 0; for _ in pairs(Config.Allowed) do n = n + 1 end; return n end)()
    ))
end)
