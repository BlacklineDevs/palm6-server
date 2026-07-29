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

-- ---------------------------------------------------------------------------
-- The OTHER half of that wire: what a chopper PAYS for the heat they have been
-- earning. The two values above are the WRITE side (this sale makes you hotter);
-- this block is the READ side (being hot makes this sale worth less). A fence
-- moving a car for a man the whole city is hunting is taking on his risk, and
-- prices it into the buy.
--
-- SHIPS DISABLED. With Enabled = false no export is called, not one extra DB
-- round-trip is spent, and /sellstolen pays exactly Config.ClassPayout[class]
-- and prints exactly the message it prints today.
--
-- Heat is read ONLY through the frozen exports.palm6_heat:GetTier export, never
-- by querying palm6_heat_state: stored heat is settled lazily against
-- updated_at, so a direct table read reports a stale, too-HIGH tier. Soft-guard
-- (GetResourceState + pcall) so a stopped or throwing palm6_heat leaves the
-- payout at the flat class price.
--
-- ANTI-FARM: every multiplier is <= 1.0 and the code clamps anything above 1.0
-- back down, so there is no tier and no config typo that can make being hotter
-- pay BETTER. Heat here can only ever subtract. The heat this sale ADDS is
-- unchanged, so the effect does not feed itself any faster than it already did.
-- ---------------------------------------------------------------------------
Config.HeatPayout = {
    Enabled = false,
    -- Payout multiplier by palm6_heat tier. Tiers absent from this table
    -- (CLEAN, COOL) are treated as 1.0, i.e. no change.
    Mult    = { WARM = 1.00, HOT = 0.85, WANTED = 0.70 },
    Floor   = 0.50,   -- hard floor on the multiplier, whatever Mult says
}

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
