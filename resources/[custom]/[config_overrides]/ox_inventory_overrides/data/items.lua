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
}
