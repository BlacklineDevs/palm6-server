-- ============================================================================
-- palm6_brain/shared/config.lua
--
-- PHASE 0 of the AI-NPC living world (docs/AI-NPC-ROADMAP.md): curated AMBIENT
-- life, ZERO AI. Client-side, non-networked peds that populate hand-picked spots
-- so a low-population server doesn't feel dead. No economy, no dialogue, no LLM —
-- this is the substrate the later Director tier will steer.
--
-- WHY CLIENT-SIDE LOCAL PEDS: for pure ambience the research is unambiguous —
-- local (non-networked) peds cost nothing on the network, sidestep OneSync
-- ownership-migration jank entirely, and each client simply populates around
-- itself (exactly how GTA's own ambient population works). Server orchestration
-- only becomes necessary in Phase 2 (economy — a customer walking into a business
-- and paying it real money), and is deliberately NOT here yet.
-- ============================================================================
Config = {}

-- MASTER GATE. false = prod-inert: the spawn loop returns immediately, no ped is
-- ever created. Flip true (+ redeploy) for a feel-test. Mirrors the dark-ship
-- idiom used across palm6_* resources.
Config.Enabled = false

-- Debug: print each scene spawn/despawn to the client console.
Config.Debug = false

-- Distances (metres) from the player to a scene's anchor. Despawn > Spawn gives a
-- hysteresis band so peds don't flicker in/out at the boundary as you walk the edge.
Config.SpawnDist   = 90.0
Config.DespawnDist  = 120.0

-- How often the spawn/despawn check runs (ms). Ambient life is not time-critical;
-- a slow tick keeps this effectively free.
Config.TickMs = 2000

-- Hard cap on palm6_brain peds a single client renders at once. Protects the
-- ~256-entry GTA ped pool (shared with base-game ambient population) from
-- exhaustion, which would cause spawn failures elsewhere.
Config.MaxPeds = 30

-- If true, spawned peds react to danger (flee gunfire, dodge cars) instead of
-- standing frozen on their scenario — reads as more alive. If false, they stay
-- locked to their scenario animation no matter what.
Config.Reactive = true

-- Ambient civilian model pool (base-game, always present). A scene that doesn't
-- set its own `models` draws random models from here.
Config.ModelPool = {
    'a_m_y_business_01', 'a_f_y_business_02', 'a_m_m_business_01', 'a_f_m_business_02',
    'a_m_y_hipster_01',  'a_f_y_hipster_02',  'a_m_y_downtown_01', 'a_f_y_tourist_01',
    'a_m_m_tourist_01',  'a_m_y_genstreet_01','a_f_y_genhot_01',   'a_m_y_skater_01',
}

-- Idle scenario pool (stand-and-do-something animations). A scene that doesn't set
-- its own `scenarios` picks randomly from here. All are base-game scenario names.
Config.ScenarioPool = {
    'WORLD_HUMAN_STAND_MOBILE', 'WORLD_HUMAN_AA_COFFEE', 'WORLD_HUMAN_SMOKING',
    'WORLD_HUMAN_STAND_IMPATIENT', 'WORLD_HUMAN_TOURIST_MAP', 'WORLD_HUMAN_DRINKING',
    'WORLD_HUMAN_HANG_OUT_STREET', 'WORLD_HUMAN_STAND_MOBILE',
}

-- SCENES — hand-picked spots that get extra ambient life on top of GTA's default
-- population. Each is an anchor {x,y,z} plus how many peds and the radius they
-- scatter within. Per-scene `models` / `scenarios` override the pools above.
--
-- 🔶 COORDS ARE GROUND-SNAPPED at spawn (GetGroundZFor_3dCoord), so the z only has
-- to be roughly right — a ped lands on the actual ground, not floating. x/y still
-- matter. Capture a fresh spot in-game with /brainscene (prints a paste-ready
-- block below); the examples are well-known plazas but VERIFY each in-game and
-- delete any that land somewhere wrong.
Config.Scenes = {
    { label = 'Legion Square',  x = 195.0,   y = -934.0,  z = 30.7, count = 6, radius = 12.0 },
    { label = 'Del Perro Pier', x = -1850.0, y = -1235.0, z = 13.4, count = 5, radius = 14.0 },
    { label = 'Vespucci Beach', x = -1223.0, y = -1500.0, z = 4.4,  count = 5, radius = 16.0 },
}

-- ---------------------------------------------------------------------------
-- PHASE 1 — NAMED NPCs you can TALK to (docs/AI-NPC-ROADMAP.md).
-- Each is a persistent character with an identity card. Right now the reply
-- comes from a STUB brain (a canned line from `lines`) travelling the REAL
-- path — client target -> server -> client bubble — so the whole conversation
-- loop is testable now, and swapping in the LLM later is a server-only change
-- (replace the stub in server/main.lua with an HTTP call to the `cortex` sidecar;
-- the identity card + memory become the model's context). Nothing here spawns
-- while Config.Enabled is false.
--
-- `id`     stable key (memory/relationships hang off this later).
-- `role`/`personality` become the LLM system prompt in Phase 1-real.
-- `lines`  stub responses until the brain is wired.
-- Coords are ground-snapped like scenes; capture with /brainscene.
-- ---------------------------------------------------------------------------
Config.NamedEnabled = true   -- sub-gate; still requires Config.Enabled

Config.NamedNpcs = {
    {
        id = 'tony', name = 'Big Tony', model = 'a_m_m_business_01',
        x = 205.0, y = -930.0, z = 30.7, heading = 250.0,
        role = 'A street-smart downtown fixture who knows everyone and every hustle.',
        personality = 'Gruff, wry, guarded but loyal once you earn it. Talks in short lines.',
        lines = {
            "You lookin' for somethin'? I might know a guy.",
            "Slow night. Everybody's either broke or hidin'.",
            "Word travels fast around here, friend. Watch yourself.",
            "You new? Keep your head down and your ears open.",
        },
    },
    {
        id = 'rosa', name = 'Rosa', model = 'a_f_y_business_02',
        x = 190.0, y = -940.0, z = 30.7, heading = 70.0,
        role = 'Runs a coffee cart by the plaza; the unofficial info broker of the block.',
        personality = 'Warm, chatty, remembers faces and gossip. Motherly but sharp.',
        lines = {
            "Morning, hon! The usual? ...oh, you're new. Welcome to the block.",
            "You hear about the mess over on the boulevard last night? Wild.",
            "Stay outta trouble and I'll keep the coffee hot for you.",
            "Everybody talks to me eventually, sweetheart. Everybody.",
        },
    },
    {
        id = 'deak', name = 'Deak', model = 'a_m_y_downtown_01',
        x = 198.0, y = -925.0, z = 30.7, heading = 180.0,
        role = 'A corner hustler always working an angle; knows where the action is.',
        personality = 'Fast-talking, paranoid, opportunistic. Sizes you up constantly.',
        lines = {
            "Ay ay, you didn't see me, a'ight? I ain't here.",
            "You got that look. You buyin' or you badge?",
            "Everything's a transaction, homie. What you got for me?",
            "Cops been thick lately. Somethin's cookin'.",
        },
    },
}

-- Dialogue display: seconds the NPC's reply floats above their head.
Config.BubbleSeconds = 7.0
-- How close (m) you must be to keep the conversation open.
Config.TalkRange = 3.0
