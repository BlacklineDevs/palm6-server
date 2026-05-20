-- ============================================================================
-- qbx_economy_overrides/server/overrides.lua
--
-- Publishes economy convars and validates bounds. Exports the JobPaychecks
-- table so downstream resources (phase 3+ job configs) can read a single
-- source of truth without duplicating numbers.
-- ============================================================================

local function setNum(key, value) SetConvar(key, tostring(value)) end
local function setStr(key, value) SetConvar(key, tostring(value)) end
local function setBool(key, value) SetConvar(key, value and 'true' or 'false') end

local function validate()
    assert(type(Config) == 'table', 'Config table missing')
    assert(Config.PaycheckIntervalMinutes and Config.PaycheckIntervalMinutes > 0,
        'PaycheckIntervalMinutes must be positive')
    assert(Config.PaycheckBounds.min >= 0, 'paycheck min must be >= 0')
    assert(Config.PaycheckBounds.max >= Config.PaycheckBounds.min,
        'paycheck max must be >= min')

    -- Monotonic non-decreasing per grade.
    for job, ladder in pairs(Config.JobPaychecks) do
        local prev = -1
        local grades = {}
        for g in pairs(ladder) do grades[#grades + 1] = g end
        table.sort(grades)
        for _, g in ipairs(grades) do
            local pay = ladder[g]
            assert(pay >= prev, ('job=%s grade=%d pay=%d not monotonic'):format(job, g, pay))
            assert(pay >= Config.PaycheckBounds.min and pay <= Config.PaycheckBounds.max,
                ('job=%s grade=%d pay=%d out of bounds'):format(job, g, pay))
            prev = pay
        end
    end
end

local function publish()
    validate()

    setNum('qbx:paycheck_interval_minutes', Config.PaycheckIntervalMinutes)
    setBool('qbx:paycheck_onduty_only',     Config.PaycheckOnDutyOnly)
    setNum('qbx:paycheck_min',              Config.PaycheckBounds.min)
    setNum('qbx:paycheck_max',              Config.PaycheckBounds.max)
    setStr('qbx:currency_symbol',           Config.CurrencySymbol)
    setStr('qbx:currency_code',             Config.CurrencyCode)

    print(('[qbx_economy_overrides] paycheck=%dm currency=%s%s jobs=%d'):format(
        Config.PaycheckIntervalMinutes,
        Config.CurrencySymbol,
        Config.CurrencyCode,
        (function() local n = 0; for _ in pairs(Config.JobPaychecks) do n = n + 1 end return n end)()
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    publish()
end)

-- Export so downstream resources can read paychecks without duplicating.
exports('GetJobPaychecks', function() return Config.JobPaychecks end)
exports('GetPaycheckInterval', function() return Config.PaycheckIntervalMinutes end)
exports('GetCurrencySymbol', function() return Config.CurrencySymbol end)
