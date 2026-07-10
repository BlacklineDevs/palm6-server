-- ============================================================================
-- gtarp_gunrunning/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
-- ============================================================================
Config = {}

Config.Debug = false

-- Hidden dealer drop point. A scrapyard-adjacent spot, away from any recipe
-- weapon vendor's own proximity zone.
Config.DropPoint = {
    label  = 'the scrapyard lot',
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    coords = { x = -477.0, y = -1717.0, z = 18.6 },
    radius = 8.0,
}

-- Real ox_inventory/qbx weapon item names only (verified against
-- resources/[ox]/ox_inventory/data/weapons.lua) — street-level stock, not
-- military-grade, keeps this thematically a black market, not an armory.
Config.Catalog = {
    { weapon = 'WEAPON_SNSPISTOL',    label = 'SNS Pistol',    price = 2500 },
    { weapon = 'WEAPON_PISTOL',       label = 'Pistol',        price = 3200 },
    { weapon = 'WEAPON_COMBATPISTOL', label = 'Combat Pistol', price = 4500 },
    { weapon = 'WEAPON_MICROSMG',     label = 'Micro SMG',     price = 7800 },
    { weapon = 'WEAPON_SMG',          label = 'SMG',           price = 9500 },
    { weapon = 'WEAPON_PUMPSHOTGUN',  label = 'Pump Shotgun',  price = 6000 },
}

-- Rate limit — own guard, independent of gtarp_eventguard. /buyweapon is a
-- chat command, not a net event, so eventguard's Config.Events doesn't cover
-- it (confirmed this session: eventguard only guards RegisterNetEvent
-- handlers). The one real net event this resource DOES register — a second
-- handler on the recipe's `evidence:server:CreateCasing` — gets its own
-- eventguard budget instead (see gtarp_eventguard/config.lua).
Config.BuyCooldownSec = 10

-- Serial prefix so a dealer-sold weapon's metadata.serial is recognizably
-- "GR-" at a glance in an evidence bag description — same readability idea
-- as gtarp_counterfeit's "CF-" wad serials.
Config.SerialPrefix = 'GR'
