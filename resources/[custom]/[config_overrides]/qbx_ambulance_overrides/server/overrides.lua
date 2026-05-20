-- ============================================================================
-- qbx_ambulance_overrides/server/overrides.lua
-- ============================================================================

local function validate()
    assert(type(Config) == 'table', 'Config missing')
    assert(Config.JobName == 'ambulance', 'JobName must be ambulance')
    local pays = exports.qbx_economy_overrides:GetJobPaychecks().ambulance
    assert(pays, 'no ambulance pay ladder in economy overrides')
    for grade in pairs(Config.Grades) do
        assert(pays[grade] ~= nil, ('grade %d has no pay'):format(grade))
    end
    assert(#Config.Hospitals >= 1, 'at least one hospital required')
    assert(Config.Timers.revive_seconds > 0, 'revive timer must be positive')
    assert(Config.Timers.death_respawn_seconds > Config.Timers.revive_seconds,
        'death respawn must exceed revive timer')
end

local function publish()
    validate()
    SetConvar('qbx:ambulance_grade_count', tostring((function()
        local n = 0; for _ in pairs(Config.Grades) do n = n + 1 end; return n
    end)()))
    SetConvar('qbx:ambulance_revive_seconds', tostring(Config.Timers.revive_seconds))
    SetConvar('qbx:ambulance_death_seconds',  tostring(Config.Timers.death_respawn_seconds))
    print(('[qbx_ambulance_overrides] grades=%s hospitals=%d revive=%ds death=%ds'):format(
        GetConvar('qbx:ambulance_grade_count', '0'),
        #Config.Hospitals,
        Config.Timers.revive_seconds,
        Config.Timers.death_respawn_seconds
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    publish()
end)

exports('GetGrades',         function() return Config.Grades end)
exports('GetHospitals',      function() return Config.Hospitals end)
exports('GetDutyToggle',     function() return Config.DutyToggle end)
exports('GetTimers',         function() return Config.Timers end)
exports('GetLoadoutAllowed', function() return Config.LoadoutAllowed end)
exports('GetVehicleAllowed', function() return Config.VehicleAllowed end)
