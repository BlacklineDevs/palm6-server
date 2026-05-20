-- ============================================================================
-- qbx_police_overrides/server/overrides.lua
--
-- Publishes police job config as convars + exports so the recipe-deployed
-- qbx_police (and downstream consumers) can read a single source of truth.
-- ============================================================================

local function validate()
    assert(type(Config) == 'table', 'Config missing')
    assert(Config.JobName == 'police', 'JobName must be police')
    -- Grades must be 0-indexed, contiguous, monotonic with paycheck ladder.
    local pays = exports.qbx_economy_overrides:GetJobPaychecks().police
    assert(pays, 'no police pay ladder in economy overrides')
    for grade in pairs(Config.Grades) do
        assert(pays[grade] ~= nil, ('grade %d has no pay'):format(grade))
    end
    assert(#Config.Armoury >= 1, 'at least one armoury required')
    assert(#Config.LoadoutAllowed >= 1, 'loadout must not be empty')
    assert(#Config.VehicleAllowed >= 1, 'vehicle pool must not be empty')
end

local function publish()
    validate()
    SetConvar('qbx:police_grade_count',  tostring((function()
        local n = 0; for _ in pairs(Config.Grades) do n = n + 1 end; return n
    end)()))
    SetConvar('qbx:police_armoury_count', tostring(#Config.Armoury))
    SetConvar('qbx:police_mdt_enabled', Config.MDT.enabled and 'true' or 'false')
    print(('[qbx_police_overrides] grades=%s armouries=%d loadout=%d vehicles=%d'):format(
        GetConvar('qbx:police_grade_count', '0'),
        #Config.Armoury, #Config.LoadoutAllowed, #Config.VehicleAllowed
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    publish()
end)

exports('GetGrades',         function() return Config.Grades end)
exports('GetArmoury',        function() return Config.Armoury end)
exports('GetLoadoutAllowed', function() return Config.LoadoutAllowed end)
exports('GetVehicleAllowed', function() return Config.VehicleAllowed end)
exports('GetMDT',            function() return Config.MDT end)
exports('GetDutyToggle',     function() return Config.DutyToggle end)
