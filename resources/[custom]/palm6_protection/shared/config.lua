-- ============================================================================
-- palm6_protection/shared/config.lua — engine-agnostic tunables (Tier 1).
-- Only Businesses[].coords are Tier 3 Los Santos values.
--
-- DESIGN INTENT — turf finally pays. palm6_turf ships zone control as PURE
-- REPUTATION; its own README defers "material reward for holding turf" to v2.
-- This resource IS that v2 layer: a gang that controls a turf zone can lean on
-- the businesses inside it for protection money. Lose the turf, lose the
-- income — so holding ground becomes economically real for the first time.
--
-- Protection money is DIRTY (`black_money`) — it's a shakedown, not a
-- paycheck — so it feeds palm6_laundering the same way palm6_numbers winnings
-- do. NEVER counterfeit_cash (palm6_counterfeit's fake-money lane), NEVER the
-- unregistered markedbills.
--
-- Turf ownership is read live from the palm6_turf table via the established
-- soft cross-read (Bridge.GetZoneOwner) — palm6_turf is a SOFT dependency; if
-- it isn't running, no zone has an owner and nothing can be collected.
-- ============================================================================
Config = {}

Config.Debug = false

Config.Payout = 'black_money'    -- dirty protection money (needs laundering)

-- Businesses. Each sits in a turf zone (zone id must match palm6_turf's
-- Config.Zones ids). A gang may only shake down a business whose zone its gang
-- currently controls. Coords reuse palm6_turf's already-validated zone points
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

-- Persistent police attention (palm6_heat) added to the collector on a
-- successful shakedown — extortion is a gang crime, and one the business
-- reported (native alert + evidence) runs hotter. Keyed to the character so it
-- follows them after they log. Soft-dep — a no-op if palm6_heat is stopped.
Config.HeatOnShakedown  = 6
Config.HeatFlaggedBonus = 6

-- /shakedown and /rackets are chat commands, not net events — so (like
-- palm6_chopshop/laundering/numbers) eventguard's Config.Events doesn't cover
-- them; the per-character CooldownSec + the per-business interval + the
-- per-business collect lock are the guard.
Config.CooldownSec = 5             -- per-character, between /shakedown attempts

Config.Evidence = {
    IncidentKeyPrefix = 'extortion:',
    CaseTitle         = 'Extortion / protection racket',
}

-- ---------------------------------------------------------------------------
-- OWNED-BUSINESS EXTORTION (Phase 1 seam -> palm6_business). DARK by default.
-- When true, a gang controlling a turf zone can also shake down a PLAYER-OWNED
-- palm6_business storefront that sits in that zone, draining its REAL pooled
-- account (bounded, never minted) instead of the hardcoded mint above. When
-- false, the owned-business resolver short-circuits nil on its first line, so
-- /shakedown and /rackets behave byte-identically to today. Effectively also
-- needs palm6_business Config.Phase1Enabled (an owned business with no placed
-- storefront has nothing to stand at). See docs/superpowers/specs/
-- 2026-07-20-palm6-protection-extort-owned-design.md.
-- ---------------------------------------------------------------------------
Config.ExtortOwned = false

-- Local mirror of palm6_turf Config.Zones centers — KEEP IN SYNC with palm6_turf.
-- Used only to resolve which turf zone a player-placed storefront sits in (turf
-- exposes no point->zone lookup and its zones are 3m interaction points). A
-- storefront belongs to the nearest zone whose center is within OwnedZoneRadius;
-- ownership itself is still read live via Bridge.GetZoneOwner (the DB cross-read).
Config.Zones = {
    { id = 'legion_square', coords = vector3(195.17, -933.77, 30.69) },
    { id = 'grove_street',  coords = vector3(-47.30, -1757.40, 29.42) },
    { id = 'mirror_park',   coords = vector3(1163.10, -322.90, 69.20) },
    { id = 'vinewood',      coords = vector3(-1222.10, -906.90, 12.33) },
    { id = 'sandy_shores',  coords = vector3(1961.30, 3740.30, 32.34) },
    { id = 'paleto_bay',    coords = vector3(1728.66, 6414.16, 35.04) },
}

-- A storefront within this distance of a zone center is "in" that zone (nearest
-- wins). Wide enough to cover a neighborhood, since turf zones are single points.
Config.OwnedZoneRadius = 200.0

-- How close the collector must stand to the storefront to shake it (mirrors the
-- hardcoded businesses' per-entry radius).
Config.OwnedRadius = 14.0

-- Max fraction of a business's account a single shakedown can take — it stings but
-- never wipes the register (>= 1 - OwnedCutPct always remains). The actual take is
-- min(random(PayoutMin..PayoutMax), floor(balance * OwnedCutPct)).
Config.OwnedCutPct = 0.15
