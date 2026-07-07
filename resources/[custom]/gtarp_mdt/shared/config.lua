-- ============================================================================
-- gtarp_mdt/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to VI). The MDT is the police-side READER for the systems the city
-- already runs: gtarp_evidence case files surface here, BOLOs and written
-- reports are filed here. qbx_police_overrides published the MDT contract
-- (Config.MDT via its GetMDT export) with no implementation behind it —
-- this resource is that implementation, and it honours GetMDT() values
-- when the override resource is running.
-- ============================================================================
Config = {}

Config.Debug = false

-- The item an officer must be carrying to use any MDT command. Already in
-- qbx_police_overrides' LoadoutAllowed and sold at the armoury shop —
-- until this resource existed, nothing consumed it.
Config.TabletItem = 'mdt_tablet'

-- Fallbacks for the qbx_police_overrides GetMDT() contract, used only when
-- that resource is not running. Keys mirror its Config.MDT exactly.
Config.MDTDefaults = {
    enabled = true,
    bolo_default_duration_minutes = 60,
    report_min_chars = 20,
}

-- BOLO text bounds (chars).
Config.Bolo = {
    MinChars = 5,
    MaxChars = 140,
    ListLimit = 8,     -- /bolos shows at most this many active entries
}

-- Case browsing.
Config.Cases = {
    ListLimit = 10,    -- /mdtcases shows at most this many open cases
    EntryLines = 5,    -- /mdtcase shows at most this many recent entries
    EntryTrim = 100,   -- each entry line trimmed to this many chars
}

-- Report body upper bound (lower bound comes from the GetMDT contract).
Config.ReportMaxChars = 1000

-- Warrants + bookings (v0.2.0). The recipe's qbx_police owns the
-- PHYSICAL side (/cuff /jail) — this is the paper trail on top of it.
Config.Warrants = {
    ReasonMinChars = 5,
    ReasonMaxChars = 200,
    ListLimit      = 8,
    ChargesMin     = 5,     -- /book charges text bounds
    ChargesMax     = 500,
}

-- Per-source command cooldowns (seconds).
Config.RateLimits = {
    mdt          = 2,
    bolo         = 10,
    bolos        = 2,
    boloclear    = 2,
    mdtcases     = 2,
    mdtcase      = 2,
    mdtreport    = 10,
    warrant      = 10,
    warrants     = 2,
    warrantclear = 2,
    book         = 10,
}
