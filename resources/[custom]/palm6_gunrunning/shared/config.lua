-- ============================================================================
-- palm6_gunrunning/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
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

-- Rate limit — own guard, independent of palm6_eventguard. /buyweapon is a
-- chat command, not a net event, so eventguard's Config.Events doesn't cover
-- it (confirmed this session: eventguard only guards RegisterNetEvent
-- handlers). The one real net event this resource DOES register — a second
-- handler on the recipe's `evidence:server:CreateCasing` — gets its own
-- eventguard budget instead (see palm6_eventguard/config.lua).
Config.BuyCooldownSec = 10

-- Serial prefix so a dealer-sold weapon's metadata.serial is recognizably
-- "GR-" at a glance in an evidence bag description — same readability idea
-- as palm6_counterfeit's "CF-" wad serials.
Config.SerialPrefix = 'GR'

-- Persistent police attention (palm6_heat) added to the BUYER on a completed
-- purchase — acquiring an untraceable black-market weapon is a crime. Keyed to
-- the character so it follows them after they log (drives /heat, season
-- Most-Wanted, dispatch priority). Soft-dep — a no-op if palm6_heat is stopped.
-- Mirrors palm6_heat Config.Suggested.gun_deal.
--
-- FLAT PER PURCHASE IS DELIBERATE, and this note exists so nobody "fixes" it
-- into being amount-proportional the way palm6_laundering's had to be. That one
-- was broken because a launder RUN takes a variable $500..$25,000, so a flat
-- charge scored a whole-haul dump exactly as quietly as a pocket-change wash,
-- which made the fewest, largest runs the cheapest way to move dirty money. A
-- buy here grants exactly ONE weapon (server/main.lua) and cannot be batched,
-- so run size is not a dial the player can turn: six guns cost six times the
-- heat no matter how they are bought. The crime being scored is possession of
-- an untraceable weapon, not the size of the transaction, so price is correctly
-- not a factor.
Config.HeatOnBuy = 10

-- Discoverable dealer NPC at the drop point (presentation only — the buy still
-- re-runs the full server authority: proximity, price, charge, grant). Anchored
-- to Config.DropPoint.coords so the ped IS the proximity zone. Was command-only
-- with no blip/ped, so a new player had no way to find (or learn of) the black
-- market — mirrors the palm6_lottery / palm6_insurance clerk pattern.
-- VERIFY IN-GAME: ped on-ground + heading faces the approach; retune if floating.
Config.Dealer = {
    model   = 'g_m_m_armboss_01',       -- arms-dealer vibe
    heading = 160.0,
    label   = 'Talk to the dealer',
    icon    = 'fa-solid fa-gun',
    blip    = { sprite = 110, color = 1, scale = 0.7, label = 'Scrapyard' },
}
