-- ============================================================================
-- gtarp_citations/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). Citations are DEBT WITH MEMORY: the recipe's
-- police:server:BillPlayer and radar fines are instant online-and-nearby
-- debits that record nothing (a target who can't pay escapes with no
-- trace). A citation is a ledger row on the citizen — online or offline —
-- payable later at city hall, and it escalates to a gtarp_mdt warrant
-- when it goes overdue. Non-payment is a story hook, not a free pass.
-- ============================================================================
Config = {}

Config.Debug = false

-- Officers must carry this to write citations (same tablet the MDT uses).
Config.TabletItem = 'mdt_tablet'

-- Where fines are paid: the city hall service desk (server-checked
-- against the payer's real coords; qbx_cityhall's own location).
Config.PayDesk = {
    coords = { x = -265.0, y = -963.6, z = 31.2 },
    radius = 20.0,
    label = 'City Hall',
}

Config.Citation = {
    MinAmount   = 25,
    MaxAmount   = 5000,
    ReasonMin   = 5,
    ReasonMax   = 140,
    DueHours    = 72,     -- real hours before an unpaid citation is overdue
    ListLimit   = 8,      -- /fines shows at most this many
}

-- Overdue escalation: unpaid past due -> gtarp_mdt warrant (soft
-- dependency — if gtarp_mdt is missing the citation just stays overdue
-- and keeps its record; nothing is forgiven silently).
Config.Escalation = {
    Enabled  = true,
    SweepSec = 300,   -- how often the overdue sweep runs
}

-- Where paid fines land (the recipe routes its instant fines to the same
-- account). Soft dependency via pcall — if the banking resource is
-- absent, payment still settles the citation.
Config.PoliceAccount = 'police'

-- Per-source command cooldowns (seconds).
Config.RateLimits = {
    cite    = 10,
    fines   = 2,
    payfine = 5,
}
