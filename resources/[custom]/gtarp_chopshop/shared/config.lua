-- ============================================================================
-- gtarp_chopshop/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
-- ============================================================================
Config = {}

Config.Debug = false

-- Hidden chop shop drop point — distinct from gtarp_gunrunning's scrapyard-
-- lot dealer spot, other side of the map so the two black markets don't
-- visually stack.
Config.DropPoint = {
    label  = 'the chop shop',
    coords = { x = 730.9, y = -3193.8, z = 5.9 },
    radius = 10.0,
}

-- Payout by GetVehicleClass() (standard GTA V class ids 0-22). Classes not
-- listed here (18 Emergency, 19 Military, 21 Train, plus anything else
-- unmapped) are refused outright — selling a stolen ambulance or army
-- vehicle isn't a chop-shop transaction, it's a different crime this
-- resource doesn't model.
Config.ClassPayout = {
    [0]  = 1200,  -- Compact
    [1]  = 1500,  -- Sedan
    [2]  = 2200,  -- SUV
    [3]  = 1800,  -- Coupe
    [4]  = 2600,  -- Muscle
    [5]  = 3200,  -- Sports Classic
    [6]  = 4500,  -- Sports
    [7]  = 8000,  -- Super
    [8]  = 900,   -- Motorcycle
    [9]  = 2000,  -- Off-Road
    [10] = 2400,  -- Industrial
    [11] = 1600,  -- Utility
    [12] = 1900,  -- Van
    [20] = 2800,  -- Commercial
}

-- Own guard, independent of gtarp_eventguard. Both /reportstolen and
-- /sellstolen are chat commands, not net events — eventguard's
-- Config.Events doesn't cover chat commands (confirmed this session,
-- gtarp_gunrunning/gtarp_ransom use the same pattern).
Config.ReportCooldownSec = 15
Config.SellCooldownSec   = 15

-- How long a /reportstolen flag stays 'active' before it auto-expires (no
-- sweep thread needed — expiry is just a WHERE clause on read, same idiom
-- gtarp_ransom's BOLO-style passive expiry uses... actually this mirrors
-- gtarp_mdt's BOLO passive expiry: `expires_at > NOW()` checked at read
-- time, nothing owed on expiry).
Config.StolenReportTTLHours = 72
