-- ============================================================================
-- ox_inventory_overrides/data/items.lua
--
-- Items we ADD to the recipe's items table. Anything already shipped by
-- ox_inventory (water, sandwich, bandage, etc.) is referenced from shops
-- without re-declaring here. Server apply step (server/apply.lua) merges
-- these into ox_inventory's runtime items table on resource start.
--
-- Each item is { name, label, weight, stack, consume?, description? }.
-- ============================================================================

ExtraItems = {
    -- Society / job-issue items referenced by phase 3 loadouts.
    handcuffs       = { label = 'Handcuffs',       weight = 200,  stack = false },
    radio           = { label = 'Radio',           weight = 250,  stack = false },
    mdt_tablet      = { label = 'MDT Tablet',      weight = 700,  stack = false },
    defibrillator   = { label = 'Defibrillator',   weight = 1500, stack = false },
    firstaid        = { label = 'First Aid Kit',   weight = 500,  stack = true  },
    painkillers     = { label = 'Painkillers',     weight = 50,   stack = true, consume = 1.0 },
    adrenaline      = { label = 'Adrenaline Shot', weight = 100,  stack = true, consume = 1.0 },
    medikit         = { label = 'Medikit',         weight = 400,  stack = true, consume = 1.0 },

    -- Civilian convenience items.
    coffee          = { label = 'Coffee',          weight = 150,  stack = true, consume = 1.0 },
    energy_drink    = { label = 'Energy Drink',    weight = 200,  stack = true, consume = 1.0 },
    snack_bar       = { label = 'Snack Bar',       weight = 50,   stack = true, consume = 1.0 },

    -- Hardware
    repair_kit      = { label = 'Repair Kit',      weight = 1200, stack = true },
    flashlight      = { label = 'Flashlight',      weight = 300,  stack = false },
    tirepack        = { label = 'Tire Pack',       weight = 2500, stack = true },

    -- Grind tools (gtarp_grind) — buyable at the Hardware Store.
    fishing_rod     = { label = 'Fishing Rod',     weight = 1000, stack = false },
    pickaxe         = { label = 'Pickaxe',         weight = 1500, stack = false },
    hunting_knife   = { label = 'Hunting Knife',   weight = 400,  stack = false },

    -- Grind yields (gtarp_grind) — sold to the matching buyer.
    raw_fish        = { label = 'Fish',            weight = 200,  stack = true },
    raw_ore         = { label = 'Ore',             weight = 300,  stack = true },
    raw_meat        = { label = 'Raw Meat',        weight = 250,  stack = true },
    animal_pelt     = { label = 'Animal Pelt',     weight = 400,  stack = true },

    -- Serialized sneakers (gtarp_flashdrop). One base item; per-pair identity
    -- (label, serial, uid) rides in metadata. Must match Config.Item in
    -- gtarp_flashdrop/shared/config.lua — that resource presence-checks this
    -- item at start and disables drops with a console error if it is missing.
    flashdrop_sneaker = { label = 'Sneakers',      weight = 800,  stack = false },

    -- Counterfeit-cash economy (gtarp_counterfeit). Must match Config.Items
    -- in gtarp_counterfeit/shared/config.lua — that resource presence-checks
    -- these at start and self-disables with a console error if any is
    -- missing. counterfeit_cash is FAKE money with a serial in metadata —
    -- distinct name and semantics from the recipe's `markedbills` (dirty
    -- REAL money); it is never launderable and never stacks.
    counterfeit_cash    = { label = 'Bundled Cash',    weight = 120,  stack = false },
    counterfeit_printer = { label = 'Compact Printer', weight = 9000, stack = false },
    counterfeit_paper   = { label = 'Linen Paper',     weight = 200,  stack = true },
    counterfeit_ink     = { label = 'Intaglio Ink',    weight = 350,  stack = true },
    marker_pen          = { label = 'Detector Pen',    weight = 30,   stack = false },

    -- Drug supply chain (gtarp_drugs). Must match Config in
    -- gtarp_drugs/shared/config.lua — that resource presence-checks these at
    -- start and self-disables with a console error if any is missing.
    -- cannabis_leaf = raw grow yield; weed_baggie = the processed, sellable
    -- street product (sold to NPCs for black_money). Distinct from qbx_drugs'
    -- weed_brick/coke_brick so the two item sets never overlap.
    cannabis_leaf       = { label = 'Cannabis Leaf',   weight = 80,   stack = true },
    weed_baggie         = { label = 'Baggie of Weed',  weight = 30,   stack = true },
}
