-- ============================================================================
-- qbx_economy_overrides/config.lua
--
-- Single source of truth for the gtarp money supply: paycheck cadence,
-- currency symbol, and per-grade society payroll defaults. These values
-- override what the recipe-deployed qbx_core/qbx_management read by being
-- published as convars on resource start.
-- ============================================================================

Config = {}

-- ---------------------------------------------------------------------------
-- Paychecks
-- ---------------------------------------------------------------------------

-- Cadence (minutes between paychecks). 7m is a small-server default that
-- keeps lower-paid jobs viable without flooding the economy.
Config.PaycheckIntervalMinutes = 7

-- Paychecks only fire for on-duty players. Off-duty workers get nothing.
Config.PaycheckOnDutyOnly = true

-- Minimum and maximum bounds applied to any single paycheck. Defence in
-- depth against bad config in downstream job resources.
Config.PaycheckBounds = {
    min = 0,
    max = 5000,
}

-- ---------------------------------------------------------------------------
-- Currency
-- ---------------------------------------------------------------------------

Config.CurrencySymbol = '$'
Config.CurrencyCode   = 'USD'

-- ---------------------------------------------------------------------------
-- Society / society-account defaults for new jobs
-- ---------------------------------------------------------------------------
-- Each grade ladder is monotonically non-decreasing. Numbers are deliberately
-- conservative for a 48-slot server; downstream phase 3 / 4 / 5 configs may
-- override per-job.
Config.JobPaychecks = {
    unemployed = { [0] = 0 },
    trucker    = { [0] = 200, [1] = 280, [2] = 360 },
    taxi       = { [0] = 220, [1] = 300, [2] = 380 },
    garbage    = { [0] = 200, [1] = 280, [2] = 360 },
    mechanic   = { [0] = 250, [1] = 350, [2] = 480, [3] = 620 },
    police     = { [0] = 350, [1] = 480, [2] = 620, [3] = 780, [4] = 940 },
    ambulance  = { [0] = 350, [1] = 480, [2] = 620, [3] = 780, [4] = 940 },
}
