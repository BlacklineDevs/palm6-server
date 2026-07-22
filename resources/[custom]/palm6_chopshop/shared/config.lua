-- ============================================================================
-- palm6_chopshop/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
-- ============================================================================
Config = {}

Config.Debug = false

-- Hidden chop shop drop point — distinct from palm6_gunrunning's scrapyard-
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

-- Persistent police attention (palm6_heat) added to the seller on a completed
-- sale. Fencing a car is a crime; fencing one that was reported STOLEN is hotter
-- than dumping your own. Keyed to the character, so it follows them after they
-- log (drives the /heat board, season Most-Wanted, dispatch priority). Soft-dep
-- — a no-op if palm6_heat is stopped. Mirrors palm6_heat Config.Suggested.chopshop.
Config.HeatOnSale      = 10  -- base heat for any chop-shop sale
Config.HeatStolenBonus = 6   -- extra when the plate had a live stolen report

-- Own guard, independent of palm6_eventguard. Both /reportstolen and
-- /sellstolen are chat commands, not net events — eventguard's
-- Config.Events doesn't cover chat commands (confirmed this session,
-- palm6_gunrunning/palm6_ransom use the same pattern).
Config.ReportCooldownSec = 15
Config.SellCooldownSec   = 15

-- How long a /reportstolen flag stays 'active' before it auto-expires (no
-- sweep thread needed — expiry is just a WHERE clause on read, same idiom
-- palm6_ransom's BOLO-style passive expiry uses... actually this mirrors
-- palm6_mdt's BOLO passive expiry: `expires_at > NOW()` checked at read
-- time, nothing owed on expiry).
Config.StolenReportTTLHours = 72
