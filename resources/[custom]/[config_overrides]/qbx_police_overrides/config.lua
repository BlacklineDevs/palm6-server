-- ============================================================================
-- qbx_police_overrides/config.lua
--
-- Configures the recipe-deployed qbx_police: grade roster, armoury, vehicles,
-- and MDT defaults. Mission Row is the default armoury / motor pool.
-- ============================================================================

Config = {}

Config.JobName = 'police'

-- Grades 0..4. Pay is sourced from qbx_economy_overrides.JobPaychecks.police.
Config.Grades = {
    [0] = { name = 'Cadet',      isboss = false },
    [1] = { name = 'Officer',    isboss = false },
    [2] = { name = 'Sergeant',   isboss = false },
    [3] = { name = 'Lieutenant', isboss = false },
    [4] = { name = 'Chief',      isboss = true  },
}

-- Armoury locations (each is a single use point; multiple are allowed).
Config.Armoury = {
    {
        label = 'Mission Row PD — Armoury',
        coords = vector3(461.79, -983.04, 30.69),
        radius = 1.2,
    },
}

-- Allowed loadout (item names — must exist in ox_inventory items table).
Config.LoadoutAllowed = {
    'weapon_combatpistol',
    'weapon_stungun',
    'weapon_nightstick',
    'weapon_flashlight',
    'pistol_ammo',
    'handcuffs',
    'radio',
    'armor',
    'bandage',
    'mdt_tablet',
}

-- Allowed vehicles in the motor pool (models — must be streamed by recipe).
Config.VehicleAllowed = {
    'police',
    'police2',
    'police3',
    'policeb',
    'policet',
}

-- MDT defaults
Config.MDT = {
    enabled = true,
    bolo_default_duration_minutes = 60,
    report_min_chars = 20,
}

-- Duty toggle location (single station for a 48-slot server).
Config.DutyToggle = {
    label = 'Mission Row PD — Duty',
    coords = vector3(442.32, -988.43, 30.69),
    radius = 1.0,
}
