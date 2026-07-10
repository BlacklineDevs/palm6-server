-- ============================================================================
-- gtarp_protection/shared/config.lua — engine-agnostic tunables (Tier 1).
-- Only Businesses[].coords are Tier 3 Los Santos values.
--
-- DESIGN INTENT — turf finally pays. gtarp_turf ships zone control as PURE
-- REPUTATION; its own README defers "material reward for holding turf" to v2.
-- This resource IS that v2 layer: a gang that controls a turf zone can lean on
-- the businesses inside it for protection money. Lose the turf, lose the
-- income — so holding ground becomes economically real for the first time.
--
-- Protection money is DIRTY (`black_money`) — it's a shakedown, not a
-- paycheck — so it feeds gtarp_laundering the same way gtarp_numbers winnings
-- do. NEVER counterfeit_cash (gtarp_counterfeit's fake-money lane), NEVER the
-- unregistered markedbills.
--
-- Turf ownership is read live from the gtarp_turf table via the established
-- soft cross-read (Bridge.GetZoneOwner) — gtarp_turf is a SOFT dependency; if
-- it isn't running, no zone has an owner and nothing can be collected.
-- ============================================================================
Config = {}

Config.Debug = false

Config.Payout = 'black_money'    -- dirty protection money (needs laundering)

-- Businesses. Each sits in a turf zone (zone id must match gtarp_turf's
-- Config.Zones ids). A gang may only shake down a business whose zone its gang
-- currently controls. Coords reuse gtarp_turf's already-validated zone points
-- (Tier 3 placeholders — retune to actual storefronts in-game).
Config.Businesses = {
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'ls_liquor',  label = 'Legion Square Liquor', zone = 'legion_square', coords = vector3(25.7, -1347.3, 29.49),      radius = 14.0 },   -- 24/7, Innocence Blvd, Strawberry (S of Legion Sq)
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'gs_grocery', label = 'Grove Street Grocery', zone = 'grove_street',  coords = vector3(-48.52, -1757.51, 29.42),   radius = 14.0 },   -- 24/7, Grove St, Davis
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'mp_deli',    label = 'Mirror Park Deli',     zone = 'mirror_park',   coords = vector3(1163.87, -323.86, 69.21),   radius = 14.0 },   -- Rob's Liquor, East Vinewood / Mirror Park border
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'vw_pawn',    label = 'Vinewood Pawn',        zone = 'vinewood',      coords = vector3(373.87, 325.9, 103.57),     radius = 14.0 },   -- 24/7, Clinton Ave, Downtown Vinewood
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'ss_diner',   label = 'Sandy Shores Diner',   zone = 'sandy_shores',  coords = vector3(1961.48, 3740.57, 32.34),   radius = 14.0 },   -- 24/7, Alhambra Dr, Sandy Shores
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    { id = 'pb_market',  label = 'Paleto Market',        zone = 'paleto_bay',    coords = vector3(1727.99, 6416.66, 35.04),   radius = 14.0 },   -- 24/7, Great Ocean Hwy, Paleto Bay
}

-- Payout per shakedown (dirty dollars), rolled in this range.
Config.PayoutMin = 800
Config.PayoutMax = 2000

-- A business is "paid up" for this long after a shakedown — gang-agnostic (the
-- business already paid its protection this cycle, whoever collected).
Config.CollectIntervalSec = 1800   -- 30 minutes per business

-- Chance the business quietly calls it in → native police alert + an extortion
-- evidence case.
Config.ReportChance = 0.20

-- /shakedown and /rackets are chat commands, not net events — so (like
-- gtarp_chopshop/laundering/numbers) eventguard's Config.Events doesn't cover
-- them; the per-character CooldownSec + the per-business interval + the
-- per-business collect lock are the guard.
Config.CooldownSec = 5             -- per-character, between /shakedown attempts

Config.Evidence = {
    IncidentKeyPrefix = 'extortion:',
    CaseTitle         = 'Extortion / protection racket',
}
