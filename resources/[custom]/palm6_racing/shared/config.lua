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
-- Set to a downtown LS spot co-located with the Downtown Sprint start (real on-road
-- coord). VERIFY IN-GAME it's a sensible open spot and re-home with /racecp if you
-- want a proper car-meet lot; the Vinewood/Dike routes run out to their own areas.
Config.Meet = {
    coords = { x = -438.84, y = -657.85, z = 30.0 },   -- downtown LS (Downtown Sprint start) — VERIFY open spot
    radius = 45.0,
    label  = 'the downtown street-race meet',
}

Config.Organizer = {
    model   = 'a_m_y_gay_02',
    coords  = { x = -434.5, y = -662.5, z = 30.0 },
    heading = 55.0,
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
    CheckpointRadius  = 15.0,  -- pass distance (m), measured 2D (x,y) so a mis-set z can't wall a CP off
    MinCheckpointMs   = 900,   -- min REAL interval (ms) between checkpoint accepts — teleport/skip guard
    CheckpointEventMs = 120,   -- min interval (ms) between accepted checkpoint EVENTS per player (anti-spam)
    DnfTimeoutSec     = 420,   -- race force-ends (all unfinished = DNF) after this
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

-- Routes: ordered checkpoint lists. checkpoints[1] = the grid/start (skipped for
-- detection — drivers start physically AT the meet), checkpoints[#] = the finish.
-- `class` is advisory in Phase 0 (not enforced). Coords below are REAL, recorded-
-- in-game, confirmed-on-road points sourced from published GTA V route data (facts,
-- not code — nothing copied from GPL scripts). Detection is 2D (x,y) so the z is
-- forgiving; still VERIFY/re-home with /racecp before a serious feel-test, and note
-- the Vinewood/Dike routes run OUT from downtown to their area (longer opening leg).
Config.Routes = {
    {
        -- Downtown loop, starts right at the meet. mkr-style dense on-road points.
        id = 'downtown_sprint', name = 'Downtown Sprint', class = 'any',
        checkpoints = {
            { x = -438.84,  y = -657.85,  z = 30.09 },   -- start / grid (= meet)
            { x = -524.18,  y = -655.38,  z = 32.23 },
            { x = -769.28,  y = -651.15,  z = 28.95 },
            { x = -886.18,  y = -568.33,  z = 31.17 },
            { x = -1001.52, y = -451.68,  z = 36.33 },
            { x = -1086.61, y = -409.11,  z = 35.62 },
            { x = -1076.47, y = -387.81,  z = 36.00 },
            { x = -1035.67, y = -293.52,  z = 36.84 },   -- finish
        },
    },
    {
        -- Vinewood Hills "City Run" — winding hillside road. Runs north from the meet.
        id = 'vinewood_hills', name = 'Vinewood Hills Run', class = 'any',
        checkpoints = {
            { x = -438.84,  y = -657.85,  z = 30.0 },    -- grid (meet)
            { x = -250.249, y = 605.480,  z = 184.877 }, -- route start (hillside)
            { x = -369.290, y = 670.251,  z = 166.221 },
            { x = -547.119, y = 670.009,  z = 143.048 },
            { x = -699.318, y = 718.974,  z = 157.962 },
            { x = -593.062, y = 738.485,  z = 181.764 },
            { x = -719.461, y = 804.162,  z = 210.396 },
            { x = -782.695, y = 826.117,  z = 206.769 },
            { x = -984.096, y = 802.302,  z = 172.600 }, -- finish
        },
    },
    {
        -- East LS dike climb — Palmer-Taylor up into the Senora hills. Longest route.
        id = 'dike_climb', name = 'East LS Dike Climb', class = 'any',
        checkpoints = {
            { x = -438.84,  y = -657.85,  z = 30.0 },    -- grid (meet)
            { x = 2677.375, y = 1644.270, z = 23.635 },  -- route start (dike base)
            { x = 2539.940, y = 1587.425, z = 29.340 },
            { x = 2405.018, y = 1221.531, z = 57.106 },
            { x = 2269.277, y = 1041.760, z = 72.343 },
            { x = 2374.139, y = 927.238,  z = 106.078 },
            { x = 2446.089, y = 629.422,  z = 137.875 },
            { x = 2372.456, y = 278.359,  z = 185.163 },
            { x = 2273.311, y = 168.644,  z = 211.476 }, -- finish
        },
    },
}
