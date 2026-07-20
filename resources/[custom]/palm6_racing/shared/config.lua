-- ============================================================================
-- palm6_racing/shared/config.lua — Palm6 Street Racing SHARED data + constants.
-- DATA ONLY: zero behavior/events/threads. Loads in BOTH realms. Reached from
-- server/client as the plain `Config` global (single-resource, not cross-export).
--
-- Phase 0 = REP-ONLY sprint races (no money -> money-safe by construction). Entry
-- stakes + parimutuel spectator betting land in Phase 1 (reusing palm6_fightclub's
-- money engine). Ships DARK: Config.Enabled=false -> prod-inert, nothing spawns.
-- ============================================================================
Config = {}

-- HARD prod gate. Every entry point checks this; ships false = prod-inert (no
-- organizer NPC, no blips, /startrace refuses). Flip true only to feel-test.
Config.Enabled = false

Config.Debug = false

-- Meet point — organizer NPC + map blip + the "at the meet" gate for /startrace.
-- PLACEHOLDER coords (VERIFY IN-GAME — use /racecp at a good open spot, same as the
-- fight-ring lesson). A parking lot / industrial area reads best for a race meet.
Config.Meet = {
    coords = { x = 1174.0, y = -1352.0, z = 34.8 },   -- placeholder (near Davis, open lot)
    radius = 40.0,
    label  = 'the street-race meet',
}

Config.Organizer = {
    model   = 'a_m_y_gay_02',
    coords  = { x = 1174.0, y = -1352.0, z = 34.8 },
    heading = 90.0,
    label   = 'Talk to the race organizer',
    icon    = 'fa-solid fa-flag-checkered',
}

Config.Blip = { sprite = 315, color = 5, scale = 0.9, label = 'Street Racing' }

-- Lobby lifecycle (seconds).
Config.Lobby = {
    JoinWindowSec = 45,   -- after /startrace, others may /joinrace for this long
    CountdownSec  = 5,    -- grid countdown before GO
    MinRacers     = 1,    -- 1 = solo time-trial allowed; raise to 2 to force a real field
    MaxRacers     = 8,
}

-- Anti-cheat + race rules.
Config.Race = {
    CheckpointRadius = 15.0,   -- pass distance (m) — generous so it is forgiving at speed
    MinCheckpointSec = 1.0,    -- reject a checkpoint hit sooner than this after the last (teleport/skip guard)
    DnfTimeoutSec    = 420,    -- race force-ends (all unfinished = DNF) after this
    PollMs           = 250,    -- client checkpoint-proximity poll cadence
}

-- Progression (rep is DISPLAY/LADDER only in Phase 0 — no cash, so nothing to farm
-- into money). Rank bands drive the HUD badge + leaderboard tier.
Config.Rep = {
    RepPerWin        = 50,
    RepPerPodium     = 20,   -- 2nd/3rd
    RepPerFinish     = 5,    -- finished but off the podium
    DailyRepCap      = 12,   -- rolling-24h rep-granting finishes per driver
    SoloRepFactor    = 0.25, -- solo time-trials pay a fraction (no real opponent)
    RankThresholds   = { 250, 700, 1500, 3000, 5500 },
}

-- Routes: ordered checkpoint lists. checkpoints[1] = the grid/start, checkpoints[#]
-- = the finish. `class` is advisory in Phase 0 (not enforced). Build real routes with
-- /racecp (admin) — it prints each coord as a ready-to-paste checkpoint line, so you
-- drive the route once and paste the result here. These two are PLACEHOLDERS.
Config.Routes = {
    {
        id = 'davis_sprint', name = 'Davis Sprint', class = 'any',
        checkpoints = {
            { x = 1174.0, y = -1352.0, z = 34.8 },   -- start / grid
            { x = 1108.0, y = -1697.0, z = 36.0 },
            { x = 826.0,  y = -1770.0, z = 30.0 },
            { x = 466.0,  y = -1758.0, z = 29.0 },    -- finish
        },
    },
    {
        id = 'dock_dash', name = 'Dock Dash', class = 'any',
        checkpoints = {
            { x = 1174.0, y = -1352.0, z = 34.8 },   -- start / grid
            { x = 1400.0, y = -1600.0, z = 60.0 },
            { x = 1200.0, y = -2000.0, z = 40.0 },
            { x = 900.0,  y = -2400.0, z = 28.0 },    -- finish
        },
    },
}
