-- ============================================================================
-- gtarp_drugs/shared/config.lua — a faithful Schedule I MVP (weed only).
--
-- Engine-agnostic tunables (Tier 1, carry to GTA VI). Only the *.coords /
-- *.plots values are Tier 3 Los Santos points to retune when the VI map lands
-- (see docs/GTA6-TIER3-RETUNE.md).
--
-- DESIGN INTENT — the missing DRUG SUPPLY CHAIN, modelled on the Steam game
-- Schedule I: grow → MIX custom branded product with stacking effects +
-- quality → sell → dirty cash → launder. The downstream sinks already exist
-- (gtarp_laundering washes black_money, gtarp_evidence tracks cases); this
-- resource is the PRODUCER + the price engine.
--
-- The loop (MVP Phase 1, spec §10):
--   1. GROW   — buy a weed_seed + soil, plant a pot at a grow plot, water it
--               over wall-clock time, harvest buds. Bud metadata carries
--               {strain, quality, effects, dried}. Timers are DB-persisted and
--               resolved on interaction (restart-safe — NO client ticks).
--   2. MIX    — at the mixing station pick a base stack + one additive; the
--               SERVER resolves effects (append-if-absent, 8-cap, order kept),
--               recomputes quality + unit price via Config.Price, and writes a
--               single branded weed_product item. Saved recipes repeat.
--   3. SELL   — hand-to-hand to real players (ox_inventory trade), PLUS a
--               rate-limited NPC street-buyer that pays DIRTY cash (black_money,
--               the same item gtarp_laundering washes and gtarp_seizure takes).
--
-- SERVER AUTHORITY: the server never trusts a client-sent price, effect list,
-- quality, amount, or position. Every value is recomputed from THIS config +
-- the item's REAL ox_inventory metadata; proximity is checked against the
-- caller's ped; inputs are consumed before outputs are granted. See §12.
-- ============================================================================
Config = {}

Config.Debug = false

-- Hard caps (spec §12).
Config.MaxEffects   = 8       -- effects per product (price only ever sums 8)
Config.MaxUnitPrice = 500     -- per-unit price ceiling so a stack can't wreck the economy
Config.RegionDemand = 1.0     -- region demand modifier (dynamic demand = Phase 3)

-- ox_inventory item names this resource owns / consumes.
Config.Items = {
    seed        = 'weed_seed',      -- generic seed; strain is chosen at plant time
    soil        = 'soil',           -- consumed per plant
    wateringcan = 'wateringcan',    -- tool, never consumed
    bud         = 'weed_bud',       -- raw harvest (metadata: strain/quality/effects/dried)
    product     = 'weed_product',   -- finished branded product (metadata, see §6)
    dirty       = 'black_money',    -- dirty payout (launderable via gtarp_laundering)
}

-- ---------------------------------------------------------------------------
-- §1 Base drugs (weed strains only for the MVP). base_value feeds Config.Price;
-- default_effect seeds a fresh bud's effect list; unlock_rank gates planting
-- against the grower's drugs_progression rank.
-- ---------------------------------------------------------------------------
Config.Drugs = {
    weed_ogkush     = { label = 'OG Kush',           base_value = 38, default_effect = 'Calming',    unlock_rank = 0 },
    weed_sourdiesel = { label = 'Sour Diesel',       base_value = 40, default_effect = 'Refreshing', unlock_rank = 0 },
    weed_greencrack = { label = 'Green Crack',       base_value = 43, default_effect = 'Energizing', unlock_rank = 1 },
    weed_gdp        = { label = 'Granddaddy Purple', base_value = 44, default_effect = 'Sedating',   unlock_rank = 1 },
}

-- Deterministic strain iteration order (pairs() is unordered) for menus.
Config.StrainOrder = { 'weed_ogkush', 'weed_sourdiesel', 'weed_greencrack', 'weed_gdp' }

-- ---------------------------------------------------------------------------
-- §2 Additives → base effect (the mix system). key = ox_inventory item name.
-- Each additive appends ONE base effect if the product doesn't already carry
-- it (order preserved, 8-cap). The order-dependent transform/reaction table is
-- Phase-2 (spec §3) — MVP is append-if-absent only.
-- ---------------------------------------------------------------------------
Config.Additives = {
    cuke         = { label = 'Cuke',         effect = 'Energizing'        },
    banana       = { label = 'Banana',       effect = 'Gingeritis'        },
    paracetamol  = { label = 'Paracetamol',  effect = 'Sneaky'            },
    donut        = { label = 'Donut',        effect = 'Calorie-Dense'     },
    viagra       = { label = 'Viagra',       effect = 'Tropic Thunder'    },
    mouthwash    = { label = 'Mouth Wash',   effect = 'Balding'           },
    flu_medicine = { label = 'Flu Medicine', effect = 'Sedating'          },
    gasoline     = { label = 'Gasoline',     effect = 'Toxic'             },  -- junk effect (RP tension)
    energy_drink = { label = 'Energy Drink', effect = 'Athletic'          },  -- reuses the existing consumable item
    motor_oil    = { label = 'Motor Oil',    effect = 'Slippery'          },
    mega_bean    = { label = 'Mega Bean',    effect = 'Foggy'             },
    chili        = { label = 'Chili',        effect = 'Spicy'             },
    battery      = { label = 'Battery',      effect = 'Bright-Eyed'       },
    iodine       = { label = 'Iodine',       effect = 'Jennerising'       },
    addy         = { label = 'Addy',         effect = 'Thought-Provoking' },
    horse_semen  = { label = 'Horse Semen',  effect = 'Long-Faced'        },
}

-- Deterministic additive iteration order for menus.
Config.AdditiveOrder = {
    'cuke', 'banana', 'paracetamol', 'donut', 'viagra', 'mouthwash',
    'flu_medicine', 'gasoline', 'energy_drink', 'motor_oil', 'mega_bean',
    'chili', 'battery', 'iodine', 'addy', 'horse_semen',
}

-- ---------------------------------------------------------------------------
-- §2b Reactions — the ORDER-DEPENDENT transform layer (the signature Schedule I
-- mechanic). Reactions[additiveKey] = { [existingEffect] = newEffect, ... }.
-- When an additive is mixed into a product that ALREADY carries `existingEffect`,
-- that effect is TRANSFORMED into `newEffect` (before the additive's own base
-- effect from §2 is appended). Every matching existing effect transforms at once,
-- against the current set; because a mix applies ONE additive at a time, the
-- outcome is genuinely order-dependent (A-then-B ≠ B-then-A). Keys match
-- Config.Additives; effect strings match Config.Effects EXACTLY.
--
-- SOURCE: the real Schedule I mixing database, cross-checked 2026-07-10 against
-- the Schedule 1 Fandom wiki per-ingredient pages, the Steam "Complete Mixing
-- Database (2026)" / "How to Get Every Effect (Full Transformation Guide)"
-- guides, and the scheduleonemixer / prodigygamers transformation charts. The
-- live game patches these during early access — THIS TABLE IS THE TUNING
-- SURFACE: retune it against the current in-game mixing DB when the game updates.
-- A few Motor Oil / Mega Bean / Battery / Energy Drink rows are corroborated by
-- the calculator charts rather than a directly-quoted snippet; treat those as
-- the best-known core and verify if a row ever feels off.
-- ---------------------------------------------------------------------------
Config.Reactions = {
    cuke = {
        ['Toxic']             = 'Euphoric',
        ['Slippery']          = 'Munchies',
        ['Sneaky']            = 'Paranoia',
        ['Foggy']             = 'Cyclopean',
        ['Gingeritis']        = 'Thought-Provoking',
        ['Munchies']          = 'Athletic',
        ['Euphoric']          = 'Laxative',
    },
    banana = {
        ['Energizing']        = 'Thought-Provoking',
        ['Calming']           = 'Sneaky',
        ['Toxic']             = 'Smelly',
        ['Long-Faced']        = 'Refreshing',
        ['Cyclopean']         = 'Thought-Provoking',
        ['Disorienting']      = 'Focused',
        ['Focused']           = 'Seizure-Inducing',
        ['Paranoia']          = 'Jennerising',
        ['Smelly']            = 'Anti-Gravity',
    },
    paracetamol = {
        ['Calming']           = 'Slippery',
        ['Toxic']             = 'Tropic Thunder',
        ['Spicy']             = 'Bright-Eyed',
        ['Glowing']           = 'Toxic',
        ['Foggy']             = 'Calming',
        ['Focused']           = 'Gingeritis',
        ['Munchies']          = 'Anti-Gravity',
        ['Paranoia']          = 'Balding',
        ['Electrifying']      = 'Athletic',
        ['Energizing']        = 'Paranoia',
    },
    donut = {
        ['Calorie-Dense']     = 'Explosive',
        ['Balding']           = 'Sneaky',
        ['Anti-Gravity']      = 'Slippery',
        ['Jennerising']       = 'Gingeritis',
        ['Focused']           = 'Euphoric',
        ['Shrinking']         = 'Energizing',
        ['Munchies']          = 'Calming',
    },
    viagra = {
        ['Athletic']          = 'Sneaky',
        ['Euphoric']          = 'Bright-Eyed',
        ['Laxative']          = 'Calming',
        ['Disorienting']      = 'Toxic',
    },
    mouthwash = {
        ['Calming']           = 'Anti-Gravity',
        ['Calorie-Dense']     = 'Sneaky',
        ['Explosive']         = 'Sedating',
        ['Focused']           = 'Jennerising',
    },
    flu_medicine = {
        ['Calming']           = 'Bright-Eyed',
        ['Athletic']          = 'Munchies',
        ['Thought-Provoking'] = 'Gingeritis',
        ['Cyclopean']         = 'Foggy',
        ['Munchies']          = 'Slippery',
        ['Laxative']          = 'Euphoric',
        ['Euphoric']          = 'Toxic',
        ['Focused']           = 'Calming',
        ['Electrifying']      = 'Refreshing',
        ['Shrinking']         = 'Paranoia',
    },
    gasoline = {
        ['Energizing']        = 'Euphoric',
        ['Gingeritis']        = 'Smelly',
        ['Jennerising']       = 'Sneaky',
        ['Sneaky']            = 'Tropic Thunder',
        ['Munchies']          = 'Sedating',
        ['Euphoric']          = 'Spicy',
        ['Laxative']          = 'Foggy',
        ['Disorienting']      = 'Glowing',
        ['Paranoia']          = 'Calming',
        ['Electrifying']      = 'Disorienting',
        ['Shrinking']         = 'Focused',
    },
    energy_drink = {
        ['Sedating']          = 'Munchies',
        ['Euphoric']          = 'Energizing',
        ['Spicy']             = 'Euphoric',
        ['Glowing']           = 'Disorienting',
        ['Foggy']             = 'Laxative',
        ['Disorienting']      = 'Electrifying',
        ['Focused']           = 'Shrinking',
        ['Schizophrenic']     = 'Balding',
    },
    motor_oil = {
        ['Energizing']        = 'Munchies',
        ['Foggy']             = 'Toxic',
        ['Euphoric']          = 'Sedating',
        ['Paranoia']          = 'Anti-Gravity',
        ['Munchies']          = 'Schizophrenic',
    },
    mega_bean = {
        ['Energizing']        = 'Cyclopean',
        ['Calming']           = 'Glowing',
        ['Sneaky']            = 'Calming',
        ['Jennerising']       = 'Paranoia',
        ['Athletic']          = 'Laxative',
        ['Slippery']          = 'Toxic',
        ['Thought-Provoking'] = 'Energizing',
        ['Seizure-Inducing']  = 'Focused',
        ['Focused']           = 'Disorienting',
        ['Shrinking']         = 'Electrifying',
    },
    chili = {
        ['Athletic']          = 'Euphoric',
        ['Anti-Gravity']      = 'Tropic Thunder',
        ['Sneaky']            = 'Bright-Eyed',
        ['Munchies']          = 'Toxic',
        ['Laxative']          = 'Long-Faced',
        ['Shrinking']         = 'Refreshing',
    },
    battery = {
        ['Munchies']          = 'Tropic Thunder',
        ['Euphoric']          = 'Zombifying',
        ['Electrifying']      = 'Euphoric',
        ['Laxative']          = 'Calorie-Dense',
        ['Cyclopean']         = 'Glowing',
        ['Shrinking']         = 'Munchies',
    },
    iodine = {
        ['Calming']           = 'Balding',
        ['Toxic']             = 'Sneaky',
        ['Foggy']             = 'Paranoia',
        ['Calorie-Dense']     = 'Gingeritis',
        ['Euphoric']          = 'Seizure-Inducing',
        ['Refreshing']        = 'Thought-Provoking',
    },
    addy = {
        ['Sedating']          = 'Gingeritis',
        ['Long-Faced']        = 'Electrifying',
        ['Glowing']           = 'Refreshing',
        ['Foggy']             = 'Energizing',
        ['Explosive']         = 'Euphoric',
    },
    horse_semen = {
        ['Anti-Gravity']      = 'Calming',
        ['Gingeritis']        = 'Refreshing',
        ['Thought-Provoking'] = 'Electrifying',
        ['Seizure-Inducing']  = 'Energizing',
    },
}

-- ---------------------------------------------------------------------------
-- §3 Effects & value multipliers. The 26 positive effects carry a multiplier;
-- the 8 junk effects are 0.00 (some are RP downsides a bad mix can inflict).
-- Σ multipliers (capped at 8 effects) drives the price in §5.
-- ---------------------------------------------------------------------------
Config.Effects = {
    -- positive (26)
    ['Shrinking']         = 0.60,
    ['Zombifying']        = 0.58,
    ['Cyclopean']         = 0.56,
    ['Anti-Gravity']      = 0.54,
    ['Long-Faced']        = 0.52,
    ['Electrifying']      = 0.50,
    ['Glowing']           = 0.48,
    ['Tropic Thunder']    = 0.46,
    ['Thought-Provoking'] = 0.44,
    ['Jennerising']       = 0.42,
    ['Bright-Eyed']       = 0.40,
    ['Spicy']             = 0.38,
    ['Foggy']             = 0.36,
    ['Slippery']          = 0.34,
    ['Athletic']          = 0.32,
    ['Balding']           = 0.30,
    ['Calorie-Dense']     = 0.28,
    ['Sedating']          = 0.26,
    ['Sneaky']            = 0.24,
    ['Energizing']        = 0.22,
    ['Gingeritis']        = 0.20,
    ['Euphoric']          = 0.18,
    ['Focused']           = 0.16,
    ['Refreshing']        = 0.14,
    ['Munchies']          = 0.12,
    ['Calming']           = 0.10,
    -- junk (8) — 0.00 value, some with downsides
    ['Disorienting']      = 0.00,
    ['Explosive']         = 0.00,
    ['Laxative']          = 0.00,
    ['Paranoia']          = 0.00,
    ['Schizophrenic']     = 0.00,
    ['Seizure-Inducing']  = 0.00,
    ['Smelly']            = 0.00,
    ['Toxic']             = 0.00,
}

-- Junk effects a bad mix (or careless additive) may inflict.
Config.JunkEffects = {
    'Disorienting', 'Laxative', 'Paranoia', 'Smelly', 'Toxic',
}

-- ---------------------------------------------------------------------------
-- §4 Quality tiers. markup multiplies the price. Quality is set at GROW time
-- (grow additives / neglect), then bumped to Heavenly (tier 4) by drying fresh
-- buds on the DRYING RACK (below) — a wall-clock DB timer in drugs_processes,
-- resolved on interaction like the grow timers (sql/0040_drugs_drying.sql).
-- ---------------------------------------------------------------------------
Config.Quality = {
    [0] = { label = 'Trash',    markup = 0.60 },
    [1] = { label = 'Poor',     markup = 0.80 },
    [2] = { label = 'Standard', markup = 1.00 },
    [3] = { label = 'Premium',  markup = 1.15 },
    [4] = { label = 'Heavenly', markup = 1.30 },  -- reached by drying fresh buds on the rack
}
Config.HeavenlyTier = 4  -- the tier a dried-on-rack bud is bumped to
Config.DefaultQuality = 2  -- Standard: a plain grow with no additive

-- Grow additives (separate system — they set quality/yield/speed, NOT mix
-- effects). One may be applied at plant time; it is consumed then.
Config.GrowAdditives = {
    fertilizer = { label = 'Fertilizer', quality = 3, growMult = 1.00, yieldBonus = 0 },  -- → Premium
    speed_grow = { label = 'Speed-Grow', quality = 2, growMult = 0.50, yieldBonus = 0 },  -- → faster, Standard
    pgr        = { label = 'PGR',        quality = 1, growMult = 1.00, yieldBonus = 2 },  -- → +yield, Poor
}
Config.GrowAdditiveOrder = { 'fertilizer', 'speed_grow', 'pgr' }

-- ---------------------------------------------------------------------------
-- GROW — plots, timing, watering, yield. Wall-clock: planted_at/ready_at/
-- watered_at are DB epoch seconds resolved on interaction (restart-safe).
-- ---------------------------------------------------------------------------
Config.Grow = {
    baseGrowSeconds  = 900,    -- 15 min baseline to harvestable (speed_grow halves it)
    waterDecayPerSec = 0.15,   -- water_level (0-100) lost per second → ~1 top-up per grow
    plotRadius       = 1.5,    -- ox_target sphere radius per plot
    proximitySlack   = 3.0,    -- server proximity = plotRadius + this (anti-jitter, like gtarp_evidence)
    yieldMin         = 3,      -- buds per harvest (before pgr bonus)
    yieldMax         = 6,
    plantSeconds     = 4,      -- client progress bar to plant
    waterSeconds     = 3,      -- client progress bar to water
    harvestSeconds   = 6,      -- client progress bar to harvest
    xp               = 15,     -- drugs_progression XP per harvest
    -- Tier 3 placeholders (a Grapeseed backwoods grow field). VERIFY IN-GAME.
    plots = {
        vector3(2223.5, 5150.4, 59.8),
        vector3(2226.1, 5152.0, 59.8),
        vector3(2228.7, 5153.6, 59.8),
        vector3(2231.3, 5155.2, 59.8),
        vector3(2318.7, 5192.0, 47.0),
        vector3(2321.3, 5193.6, 47.0),
    },
}

-- ---------------------------------------------------------------------------
-- MIX — the branding station.
-- ---------------------------------------------------------------------------
Config.Mix = {
    label        = 'Mixing Station',
    radius       = 2.0,        -- ox_target sphere radius
    proximitySlack = 3.0,
    seconds      = 5,          -- client progress bar per mix
    xp           = 10,
    badChance    = 0.12,       -- server roll: a bad mix inflicts a junk effect (if room)
    brandMaxLen  = 24,         -- product name length limit (sanitized server-side)
    maxRecipes   = 30,         -- saved named recipes per grower
    -- Tier 3 placeholder (a Grand Senora trailer). VERIFY IN-GAME.
    coords = vector3(1391.2, 3605.5, 38.9),
}

-- ---------------------------------------------------------------------------
-- DRY — the drying rack. Load fresh (undried) weed_bud into a rack slot; it
-- dries over WALL-CLOCK time (a drugs_processes row, kind='dry', epoch seconds,
-- resolved on interaction exactly like the grow timers — restart-safe, NO
-- client ticks). On collect the bud is bumped to Heavenly (tier 4) and marked
-- dried=true; the existing price engine then applies the ×1.30 markup on mix/
-- sell. One drying run per rack slot; a slot's process is server-owned by its
-- starter. It needs NO new ox_inventory item — it is a world station.
-- ---------------------------------------------------------------------------
Config.Dry = {
    label          = 'Drying Rack',
    radius         = 2.0,        -- ox_target sphere radius
    proximitySlack = 3.0,        -- server proximity = radius + this (anti-jitter)
    slots          = 4,          -- independent rack slots (each = one station_id)
    baseDrySeconds = 1800,       -- 30 min wall-clock to fully dry a loaded stack
    loadSeconds    = 4,          -- client progress bar to hang buds
    collectSeconds = 4,          -- client progress bar to take them down
    xp             = 12,         -- drugs_progression XP per dried batch
    -- Tier 3 placeholder (a rack beside the Grand Senora mixing trailer). VERIFY IN-GAME.
    coords = vector3(1388.5, 3608.2, 38.9),
}

-- ---------------------------------------------------------------------------
-- SELL — the NPC street-buyer (the rate-limited faucet). Real-player sales use
-- ox_inventory hand-to-hand trade and are not brokered here.
-- ---------------------------------------------------------------------------
Config.Sell = {
    region        = 'Sandy Shores',
    label         = 'Street Buyer',
    pedModel      = 'a_m_m_hillbilly_01',
    pedHeading    = 0.0,
    radius        = 2.0,        -- ox_target sphere radius
    proximitySlack = 3.0,
    cooldownSec   = 8,          -- per-player, between sales
    dailyDirtyCap = 40000,      -- per-character NPC-faucet ceiling per calendar day (spec §12)
    xp            = 8,
    -- Tier 3 placeholder (behind the Yellow Jack, Sandy Shores). VERIFY IN-GAME.
    coords = vector3(1980.5, 3053.0, 47.2),
}

-- ---------------------------------------------------------------------------
-- Progression (drugs_progression). rank = min(maxRank, floor(xp / xpPerRank)).
-- Gates which strains can be planted (Config.Drugs.unlock_rank).
-- ---------------------------------------------------------------------------
Config.Progression = {
    xpPerRank = 100,
    maxRank   = 8,
}

-- ---------------------------------------------------------------------------
-- Heat / evidence (basic, per spec §10 — light but present). Selling in a
-- public spot warms a per-dealer heat model; a hot dealer or an unlucky
-- witness roll trips a native police alert + a gtarp_evidence case. Big
-- harvests occasionally get spotted too. Server-only accumulators, decay on a
-- sweep — no client blip (this resource has no map-blip surface).
-- ---------------------------------------------------------------------------
Config.Heat = {
    PerSale           = 6.0,
    DecayPerMin       = 4.0,
    AlertThreshold    = 50.0,
    AlertChanceMax    = 0.50,
    WitnessBaseChance = 0.03,   -- flat chance any sale is called in
    HarvestAlertChance = 0.05,  -- flat chance a harvest is spotted
    SweepSec          = 30,
}

-- gtarp_evidence v2 frozen exports. A flagged event opens/updates a case
-- bucketed to a 5-minute window so a burst shares one case.
Config.Evidence = {
    IncidentKeyPrefix = 'drugs:',
    CaseTitle         = 'Drug supply-chain activity',
}

-- ---------------------------------------------------------------------------
-- §5 Price formula (server-authoritative). Shared so server and client agree,
-- but ONLY the server's result is ever trusted for a payout.
--
--   unit_price = round( base_value
--                       × (1 + Σ effect_multipliers)   -- effects capped at 8
--                       × quality_markup
--                       × region_demand )
--
-- then clamped to [1, Config.MaxUnitPrice].
-- ---------------------------------------------------------------------------

-- Σ of the first `MaxEffects` effect multipliers (unknown/junk = 0).
function Config.EffectSum(effects)
    local sum, n = 0.0, 0
    if type(effects) == 'table' then
        for _, name in ipairs(effects) do
            n = n + 1
            if n > Config.MaxEffects then break end
            sum = sum + (Config.Effects[name] or 0.0)
        end
    end
    return sum
end

function Config.QualityMarkup(quality)
    local q = Config.Quality[quality] or Config.Quality[Config.DefaultQuality]
    return q.markup
end

function Config.QualityLabel(quality)
    local q = Config.Quality[quality] or Config.Quality[Config.DefaultQuality]
    return q.label
end

function Config.Price(baseValue, effects, quality)
    baseValue = tonumber(baseValue) or 0
    local price = baseValue * (1.0 + Config.EffectSum(effects)) * Config.QualityMarkup(quality) * Config.RegionDemand
    price = math.floor(price + 0.5)
    if price < 1 then price = 1 end
    if price > Config.MaxUnitPrice then price = Config.MaxUnitPrice end
    return price
end
