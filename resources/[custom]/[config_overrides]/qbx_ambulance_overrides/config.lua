-- ============================================================================
-- qbx_ambulance_overrides/config.lua
--
-- Configures the recipe-deployed qbx_ambulancejob. Single Pillbox Hill
-- hospital is enough for a 48-slot server.
-- ============================================================================

Config = {}

Config.JobName = 'ambulance'

-- Grades 0..4. Pay sourced from qbx_economy_overrides.JobPaychecks.ambulance.
Config.Grades = {
    [0] = { name = 'Trainee',   isboss = false },
    [1] = { name = 'Paramedic', isboss = false },
    [2] = { name = 'EMT',       isboss = false },
    [3] = { name = 'Doctor',    isboss = false },
    [4] = { name = 'Chief',     isboss = true  },
}

Config.Hospitals = {
    {
        label = 'Pillbox Hill Medical',
        coords = vector3(307.7, -1433.4, 29.9),
        radius = 3.0,
    },
}

Config.DutyToggle = {
    label = 'Pillbox Hill — Duty',
    coords = vector3(311.5, -1432.0, 30.0),
    radius = 1.0,
}

-- Timers (seconds).
Config.Timers = {
    revive_seconds        = 8,
    death_respawn_seconds = 300,   -- 5 minutes
    bleedout_seconds      = 600,   -- 10 minutes
}

-- Allowed loadout for EMS (items must exist in ox_inventory).
Config.LoadoutAllowed = {
    'bandage',
    'medikit',
    'painkillers',
    'adrenaline',
    'defibrillator',
    'radio',
    'firstaid',
}

-- Ambulance motor pool.
Config.VehicleAllowed = {
    'ambulance',
}
