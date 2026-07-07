-- ============================================================================
-- gtarp_legal/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). The civilian counterweight to the police paperwork
-- stack: /record shows what the city has on you, /expunge petitions to
-- seal an old booking. Gives the recipe's defined-but-inert `lawyer`
-- job its first real mechanic — lawyers can pull a client's record and
-- file on their behalf (the recipe's /paylawyer finally has work to
-- pay for).
-- ============================================================================
Config = {}

Config.Debug = false

-- The job the recipe defines with no mechanics behind it.
Config.LawyerJob = 'lawyer'

-- Where petitions are filed (server-checked against the filer's real
-- coords): the Rockford Hills courthouse.
Config.Courthouse = {
    coords = { x = -544.67, y = -204.44, z = 38.65 },
    radius = 25.0,
    label = 'the courthouse',
}

Config.Expunge = {
    Fee            = 2500,   -- charged to the FILER at filing; court costs, kept on denial
    MinBookingAgeH = 168,    -- booking must be at least this old (7 days)
    ProcessingSec  = 600,    -- petition resolves this long after filing
    SweepSec       = 60,     -- how often the resolver sweep runs
}

-- Per-source command cooldowns (seconds).
Config.RateLimits = {
    record  = 3,
    expunge = 10,
}
