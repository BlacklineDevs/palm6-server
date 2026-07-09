-- ============================================================================
-- gtarp_smuggling/shared/config.lua — engine-agnostic tunables (Tier 1).
-- Only Pickup/Dropoffs coords are Tier 3 Los Santos values.
--
-- DESIGN INTENT — standalone multi-modal contraband smuggling runs. Grab a
-- shipment at a hidden pickup, run it across the map to an assigned drop under a
-- deadline while police (who get a dispatch ping) try to intercept, and get paid
-- DIRTY (black_money). The drop's MODE (land / sea / air) sets the risk and the
-- pay — an airfield run pays far more than a roadside drop because it needs a
-- plane and a longer exposed leg.
--
-- DELIBERATELY DISTINCT from qbx_drugs deliveries (which also does timed
-- transport). The distinctness contract, honoured here:
--   1. NO dealer coupling — a standalone hidden pickup, no door-knock, no
--      dealer-rep progression.
--   2. Pays black_money (NOT markedbills, qbx_drugs' item) — so proceeds
--      launder through gtarp_laundering and are seizable by gtarp_seizure.
--   3. MULTI-MODAL drops (land/sea/air vehicle classes) — qbx_drugs is a plain
--      ground drop; the mode split is the mechanical differentiator.
--   4. Generic "shipment" concept, NOT weed_brick/coke_brick — no overlap with
--      qbx_drugs' item set (and no new ox item to register: the run is
--      server-tracked state, not a carried item).
--   5. Real dispatch + a gtarp_evidence trail, not qbx_drugs' random ping.
-- ============================================================================
Config = {}

Config.Debug = false

Config.DirtyItem = 'black_money'   -- runs pay out dirty

-- Hidden pickup — no blip, word-of-mouth RP (like gtarp_chopshop/laundering).
-- Tier 3 placeholder (Elysian Island docks) — retune in-game.
Config.Pickup = {
    label  = 'the docks contact',
    coords = vector3(-119.0, -2489.0, 6.0),
    radius = 14.0,
}

-- Drop sites. mode is flavour + the risk/pay tier. coords are server-checked at
-- delivery. Spread across land roads, the water, and an airstrip so runs need
-- the right vehicle. Tier 3 placeholders — retune in-game.
Config.Dropoffs = {
    { id = 'sandy_road',   label = 'a Sandy Shores lay-by',  mode = 'land', coords = vector3(1470.0, 3260.0, 40.0),  payoutMin = 2200, payoutMax = 3800 },
    { id = 'paleto_lot',   label = 'the Paleto lumber lot',  mode = 'land', coords = vector3(-540.0, 5320.0, 74.0),  payoutMin = 2400, payoutMax = 4000 },
    { id = 'catfish_boat', label = 'a boat off Catfish View',mode = 'sea',  coords = vector3(3860.0, 4460.0, 1.0),   payoutMin = 4200, payoutMax = 6800 },
    { id = 'paleto_pier',  label = 'the Paleto cove buoy',   mode = 'sea',  coords = vector3(-1600.0, 5260.0, 1.0),  payoutMin = 4400, payoutMax = 7000 },
    { id = 'grapeseed_air',label = 'the Grapeseed airstrip', mode = 'air',  coords = vector3(2130.0, 4790.0, 41.0),  payoutMin = 7500, payoutMax = 11500 },
    { id = 'sandy_air',    label = 'the Sandy airfield apron',mode = 'air', coords = vector3(1720.0, 3290.0, 41.0),  payoutMin = 7000, payoutMax = 11000 },
}

-- A delivered run at/above this payout broadcasts a vague Weazel News "heat"
-- bulletin (bigger sea/air runs; small land drops stay quiet — no spam).
Config.AnnounceMinPayout = 5000

Config.DeliverRadius   = 18.0     -- how close to the drop counts as delivered
Config.RunTimeLimitSec = 900      -- 15 min to make the drop before the run dies
Config.CooldownSec     = 120      -- per-character, between starting runs

-- /smuggle, /deliver, /smugglerun are chat commands, not net events — eventguard
-- doesn't cover them; the per-character cooldown + one-active-run rule + the
-- per-citizen run lock are the guard.
Config.Evidence = {
    IncidentKeyPrefix = 'smuggling:',
    CaseTitle         = 'Contraband smuggling',
}
