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
-- *** ENABLED 2026-07-22 for the first AI-NPC feel-test: ambient life at 3 plazas
-- + 3 GLM-powered named NPCs (Big Tony/Rosa/Deak) at Legion Square. GLM convars
-- (palm6:glm_*) are set on the box; NPCs use canned lines if GLM ever fails.
-- Rollback = set false + redeploy. Coords are ground-snapped but tune in-game. ***
Config.Enabled = true

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

-- ---------------------------------------------------------------------------
-- PHASE 2b — MOVERS: the "acting population" the Director steers.
--
-- Movers are ANONYMOUS extras (no dialogue, no identity card) that the Director
-- can send between known places — the visible motion that makes the world feel
-- alive off-peak. They are distinct from NamedNpcs on purpose:
--   • NamedNpcs (Tony/Rosa/Deak) = STATIONARY conversational anchors. The
--     Director may reference them as a talkTo target but NEVER tasks them to
--     move (the validator marks them "targetable" but not "directable").
--   • Movers = DIRECTABLE. The Director assigns each one goal per tick.
--
-- `home` MUST be a Config.Scenes label (the Director only knows those places).
-- `model` is used by the client executor when it materialises the mover.
--
-- ⚠️ INERT until the client executor slice lands AND Config.Director.Enabled is
-- flipped: nothing reads this list except the Director roster, which only runs
-- when the Director gate is on. Ships as illustrative examples, dark.
-- ---------------------------------------------------------------------------
Config.Movers = {
    { id = 'mover_legion_1', model = 'a_m_y_business_01', home = 'Legion Square' },
    { id = 'mover_legion_2', model = 'a_f_y_hipster_02',  home = 'Legion Square' },
    { id = 'mover_pier_1',   model = 'a_m_y_tourist_01',  home = 'Del Perro Pier' },
    { id = 'mover_beach_1',  model = 'a_f_y_tourist_01',  home = 'Vespucci Beach' },
}

-- ===========================================================================
-- PHASE 2b — THE AI DIRECTOR (docs/AI-NPC-ROADMAP.md §Phase 2).
--
-- The Director is a low-frequency, BATCHED, server-side LLM call: once per tick
-- it looks at the whole NPC roster + world state and assigns each NPC ONE goal
-- from a CLOSED action enum. The model only ever picks a verb + typed args; the
-- Lua engine chooses whether/how to act. This is the "on-rails AI" the roadmap
-- describes: the LLM literally cannot name an action or target we didn't define,
-- because every returned action passes three validation layers
-- (shape → referential → legality) before anything happens.
--
-- 🔒 SAFETY MODEL — why this ships DARK and in DRY-RUN:
--   • Config.Director.Enabled = false  → the tick never runs (prod-inert).
--   • Config.Director.DryRun  = true   → even when the tick runs, accepted
--       actions are only LOGGED ("Tony WOULD goTo the plaza"), never executed.
--   • Config.Director.MoneyEnabled / CrimeEnabled = false → the money and crime
--       verbs still VALIDATE, but the legality layer BLOCKS them, so they can
--       never fire even if DryRun were off. These are the two capability gates
--       that guard the live economy and the police-dispatch bus. They are the
--       flips that require David's browser-walk (money) / rate-limit review
--       (crime) FIRST — see the roadmap's "Risks & hard parts".
--
-- Nothing in this block spawns a ped, moves money, or calls dispatch. It is the
-- planning spine only. Actuation (networked peds, palm6_business income,
-- Bridge.AlertPolice) lands in later, individually-gated slices.
-- ===========================================================================
Config.Director = {
    -- MASTER GATE for the whole Director tier. false = the tick loop never
    -- starts. Independent of Config.Enabled so the ambient/dialogue tiers and
    -- the Director can be lit up separately.
    Enabled = true,   -- LIVE feel-test: Director tick + mover materialization ON

    -- DRY-RUN. true = accepted actions are only LOGGED and discarded (the tick
    -- proves the LLM→validate pipeline with zero state change). false = accepted
    -- actions are COMMITTED to the server-side goal store with a TTL and
    -- broadcast to clients on `palm6_brain:goal` (npcId, goal|false) — the seam
    -- the ped-actuation slice subscribes to. NOTE: even with DryRun=false there
    -- is still NO ped movement, money, or dispatch until the client executor and
    -- the Money/Crime gates land; a committed goal with no consumer is inert.
    -- Stays true until the client executor exists AND is browser-walked.
    DryRun = false,   -- LIVE: commit goals -> movers actuate them

    -- Goal Time-To-Live = TickSeconds * this. A committed goal auto-expires after
    -- this many ticks with no refresh, so a Director outage (GLM down) can never
    -- freeze an NPC on a stale goal — it expires and the NPC falls back to the
    -- always-on Lua reflex tier (the roadmap's graceful-degradation guarantee).
    GoalTtlTicks = 2,

    -- CAPABILITY GATES. Even with DryRun off, a verb whose gate is false is
    -- BLOCKED by the legality layer. These are the two live-system guards:
    --   MoneyEnabled → verbs that would move real money (orderAt, buyFrom).
    --       ⚠️ palm6_business enforces exactly ONE bounded NPC-income faucet
    --       (owner-present, supply-gated, daily-capped). Auto-crediting an
    --       ABSENT owner would be a NEW faucet = AFK money-printer. Do NOT flip
    --       this until the economy model for off-peak income is decided and the
    --       money path is browser-walked (roadmap "Economy safety").
    --   CrimeEnabled → verbs that would call the police-dispatch bus
    --       (rob, attack, deal). Gate off until rate-limits + CountOnDutyPolice
    --       gating are wired so off-peak crime can't spam on-duty officers.
    MoneyEnabled = false,   -- HELD: real money faucet — flip only after the AFK-printer browser-walk (docs/AI-NPC-RUNBOOK.md §6)
    CrimeEnabled = true,    -- LIVE: throttled 911s to on-duty cops (audited safe; MinOnDutyPolice gates it, throttle caps rate)

    -- Seconds between Director ticks. Roadmap costs are computed at 30–60s; a
    -- slow tick is what keeps this ~free (one batched call, not per-ped).
    TickSeconds = 60,

    -- Only run a tick if at least this many real players are ON. Off-peak is the
    -- whole point, but with ZERO players there is nobody to perceive the world,
    -- so we save the call. 0 = always tick when Enabled.
    MinPlayers = 1,

    -- Max NPCs described to the model in one batched call. The batching trick
    -- (one call for ~20 NPCs) is where the 12× cost win comes from; a hard cap
    -- keeps the prompt bounded. Roster beyond this is simply not directed.
    MaxRoster = 20,

    -- Hard ceiling on any `amount` arg the model can request, BEFORE the
    -- per-verb clamp. A defensive backstop so a hallucinated 9-figure number is
    -- rejected at the shape layer, never reaching the clamp. Real economy caps
    -- live in palm6_business; this is just an outer sanity bound.
    MaxAmount = 100000,

    -- Log every accepted/blocked action to the server console each tick. This is
    -- the observability meter (David's "ship the meter before shipped" rule) —
    -- it is how we watch the Director's decisions before trusting it to actuate.
    Verbose = true,

    -- CRIME DISPATCH THROTTLE. When CrimeEnabled flips on (a later slice), a
    -- committed crime goal (rob/deal/attack) will fire a police dispatch through
    -- palm6's alert bus (Bridge.AlertPolice) — but ONLY if this throttle allows,
    -- so off-peak AI crime can never flood on-duty officers. The throttle is the
    -- guardrail the roadmap mandates ("rate-limit + CountOnDutyPolice"); it is
    -- built and battery-tested (/braincrime) BEFORE any live dispatch is wired.
    -- All limits are advisory numbers, not invariants — tune freely.
    Crime = {
        -- Never dispatch to an empty PD: require at least this many on-duty police.
        -- (An AI crime nobody can respond to is just noise.)
        MinOnDutyPolice = 1,
        -- Server-wide floor between ANY two crime dispatches (seconds).
        GlobalCooldownSec = 45,
        -- Per-location floor (seconds) — one scene can't spawn back-to-back crimes,
        -- mirroring palm6_robbery's per-ATM cooldown idiom.
        LocationCooldownSec = 180,
        -- Hard cap on crime dispatches accepted in a single Director tick.
        PerTickMax = 1,

        -- Dispatch presentation on the officer's map (blip + 911 notify). Sprite/
        -- colour/scale match palm6_robbery's dispatch look; duration is how long
        -- the blip lives. Per-verb `labels` set the 911 text; `defaultLabel` is
        -- the fallback for any crime verb without its own entry.
        Dispatch = {
            sprite = 161, colour = 1, scale = 1.2, durationSec = 90,
            defaultLabel = 'Suspicious activity reported',
            labels = {
                rob    = 'Robbery in progress',
                attack = 'Assault reported',
                deal   = 'Suspected narcotics activity',
            },
        },
    },

    -- PASSIVE INCOME WIRING. When MoneyEnabled flips on, a committed orderAt goal
    -- (a mover "shopping" at a scene) credits a player-owned business whose
    -- storefront sits within BusinessRadius of that scene, via
    -- exports.palm6_business:AccrueNpcPassive. The MONEY is already hard-bounded by
    -- palm6_business (shared daily cap + supply cost basis), so this side only
    -- needs a per-business cooldown to make income a believable TRICKLE rather than
    -- an instant cap-out. Requires BOTH gates: Config.Director.MoneyEnabled AND
    -- palm6_business Config.NpcPassiveIncome. Inert until both are on.
    Money = {
        -- Metres around a scene anchor to look for an owned storefront to credit.
        BusinessRadius = 40.0,
        -- Minimum seconds between passive credits to the SAME business — shapes the
        -- trickle. The real ceiling is palm6_business's DailyNpcIncome; this just
        -- spaces credits out so a shop doesn't cap out in minutes.
        PerBusinessCooldownSec = 300,
    },
}

-- ===========================================================================
-- NETWORKED SERVER-OWNED PEDS (the roadmap's "hard part" — FOUNDATION).
--
-- The live movers (client/main.lua) are CLIENT-LOCAL: great theater, but each
-- exists on only one machine, so a player can't directly rob/interact with one.
-- Networked peds are SERVER-CREATED + OneSync-replicated — EVERY player sees the
-- SAME ped — which is the prerequisite for crime/money NPCs players can interact
-- with. The catch is ownership: a networked ped "thinks" only on the client that
-- currently owns it, and tasks drop on ownership migration. The fix (server/
-- client netped.lua) is to store the ped's GOAL in a REPLICATED STATE BAG and
-- have whichever client owns it apply + re-assert the task.
--
-- This is a FOUNDATION: manual test commands (/netpedtest /netpedgoto /netpedclear)
-- to validate the networked+ownership+state-bag mechanism in-game BEFORE wiring
-- the Director / crime / money onto it. Dark by default; fully isolated from the
-- live client-local mover system (does not touch it).
-- ===========================================================================
Config.NetPed = {
    Enabled = true,    -- ARMED for validation: handler + re-assert loop run, but NOTHING spawns until /netpedtest (inert idle).

    Model   = 'a_m_y_business_01',   -- default test model
    WalkSpeed = 1.0,                 -- 1.0 walk, ~2.0 run (TaskFollowNavMeshToCoord)
}
