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

-- LLM CALL METER + BACKOFF (server/main.lua `BrainMeter`, read by every GLM call
-- site). Counters are ALWAYS on and surface in /brainstatus; the backoff is what
-- stops a dead/revoked/rate-limited GLM key being POSTed to every 60s forever.
--   BackoffAfter   = consecutive TRANSPORT failures before a lane pauses. Set 0 to
--                    disable the pause and keep only the counters. Only a non-200 /
--                    nil-body counts here: a 200 that carried an empty or unparseable
--                    answer is metered as `wasted` and deliberately does NOT count,
--                    because the 'dialogue' lane is shared by every ped in the city
--                    and is reachable from a player-triggered event.
--   BackoffSeconds = how long a paused lane stays paused. A single success clears
--                    it early and logs the recovery.
-- BackoffSeconds is math.floor'd on ingest (it is printed with %d).
Config.LlmMeter = { BackoffAfter = 3, BackoffSeconds = 300 }

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

-- ===========================================================================
-- SOCIAL LAYER ("INTEL+") — talk to any ped, personas, reputation, witness,
-- gossip, snitch, alibi — every mechanic the INTEL script has, but LLM-voiced
-- (GLM, not canned pools) and fused with our autonomous AI Director. This is the
-- shared FOUNDATION config the social modules read: server/social.lua exposes the
-- `Social` global (personas + reputation + event seam + dialogue context) and the
-- feature modules (witness/gossip/snitch/alibi/talk-to-any-ped/UI) hang off it.
-- Dark by default (Config.Social.Enabled).
-- ===========================================================================
Config.Social = {
    Enabled = true,    -- LIVE: talk-to-any-ped + personas + reputation ON; witness/gossip/snitch inert until crime events fire.

    -- PERSONALITY ARCHETYPES — shape how a ped talks + reacts. `desc` is fed to the
    -- LLM; the numeric traits (0..1) let scripted mechanics reason about a ped
    -- (higher refusal = less likely to comply; higher provoke = angers faster;
    -- higher bribe = more corruptible). Superset of INTEL's six.
    Archetypes = {
        coward     = { desc = 'timid and easily frightened; avoids confrontation and folds under pressure', refusal = 0.70, provoke = 0.20, bribe = 0.80 },
        compliant  = { desc = 'cooperative and non-confrontational; tends to go along to get along',        refusal = 0.30, provoke = 0.50, bribe = 0.60 },
        brave      = { desc = "stands their ground and won't be intimidated; calls your bluff",              refusal = 0.55, provoke = 0.70, bribe = 0.30 },
        aggressive = { desc = 'hostile and quick to anger; escalates fast and takes offence easily',         refusal = 0.60, provoke = 0.90, bribe = 0.25 },
        cunning    = { desc = 'sly and calculating; always angling for advantage and reading you',           refusal = 0.40, provoke = 0.40, bribe = 0.55 },
        stoic      = { desc = 'calm, terse and unreadable; hard to move in any direction',                   refusal = 0.50, provoke = 0.30, bribe = 0.40 },
    },
    DefaultArchetype = 'compliant',

    -- SESSION MOODS — a lighter, shorter-lived colour on top of the archetype.
    Moods = { 'friendly', 'neutral', 'grumpy', 'distracted', 'curious' },

    -- REPUTATION — per player, -10..+10, nine tiers. Actions (not chatter) move it;
    -- tier gates dialogue tone + prices. Fed to the LLM so an NPC treats a trusted
    -- regular differently from a known menace.
    RepMin = -10, RepMax = 10,
    RepTiers = {   -- upper bound (inclusive) -> tier label, ascending
        { max = -7, label = 'hated' },   { max = -4, label = 'feared' },
        { max = -1, label = 'distrusted' }, { max = 1, label = 'neutral' },
        { max = 4,  label = 'liked' },    { max = 7, label = 'trusted' },
        { max = 10, label = 'revered' },
    },
    -- Reputation deltas per action (INTEL: help +4, bribe +3, threat -1, rob -6).
    RepDelta = { help = 4, bribe = 3, gift = 2, tip = 1, threat = -1, rob = -6, attack = -4, kill = -8 },

    -- WITNESS — a ped within visual (or, for gunshots, audio) range remembers a
    -- crime for this long. Consumed by server/witness.lua.
    WitnessVisualRange = 50.0, WitnessAudioRange = 100.0, WitnessMemorySec = 86400,

    -- GOSSIP — witnessed info spreads to nearby peds, losing fidelity each hop
    -- (100% -> ... -> drops below MinFidelity and stops). server/gossip.lua.
    GossipRange = 15.0, GossipDecayPerHop = 0.2, GossipMinFidelity = 0.2,

    -- SNITCH — a witness with an informant streak reports to police dispatch; a
    -- disguise (mask) reduces the odds. server/snitch.lua -> Bridge.AlertPolice.
    SnitchBaseChance = 0.5, SnitchMaskReduction = 0.6,

    -- TALK-TO-ANY-PED — interaction distance for the "talk" prompt on any ped.
    TalkRange = 2.5,

    -- CRIME REPORT TRUST BOUND - how far a client-claimed crime position may sit
    -- from where the SERVER says the reporting player actually is before the report
    -- is REJECTED (server/crimewatch.lua re-derives the position; it never rewrites
    -- the claim). The client only reports crimes within its own NEAR_CRIME bound of
    -- 45.0m (client/crimewatch.lua), so 50.0 leaves ~5m over that bound. That 5m is
    -- slack for SERVER-POSITION LAG, not for distance error: the client already
    -- measured the distance itself and passed, but the server re-reads the reporter's
    -- ped a round trip later. It is ample for the common case (knifing a ped a few
    -- metres away leaves ~48m of headroom) and it can pinch on the far edge of the
    -- 45m bound while the reporter is moving fast - a drive-by at 40 m/s covers 5m in
    -- ~125ms, so a legitimate long-range report CAN be dropped. Rejections are
    -- counted and printed in /brainstatus, so that shows up instead of vanishing.
    -- Raising this widens the forged-blip window; lowering it drops more real reports.
    CrimeClaimMaxM = 50.0,

    -- CRIME SCAN CADENCE (client/crimewatch.lua) - the detector walks the ped pool
    -- on a timer. ScanMs is the "hot" cadence used while the player is shooting, in
    -- melee, or has just been detected committing something; IdleMs is the cheaper
    -- cadence used the rest of the time. Detection is never MISSED by the slower
    -- cadence (the engine's damage flag persists until we clear it), only delayed by
    -- at most IdleMs. Set IdleMs = ScanMs to restore the old fixed 500ms cadence.
    CrimeScanMs = 500, CrimeScanIdleMs = 1000,
}

-- ===========================================================================
-- POLICE RECORD BUS - are brain's dispatches real 911s, or just blips?
--
-- THE GAP THIS CLOSES. Bridge.AlertPolice is a PRIVATE fan-out: it pushes a blip
-- + notify straight to on-duty officers over the palm6_brain:dispatch client
-- event, and it never touches police:server:policeAlert, the shared 911 bus that
-- palm6_mdt (the /calls log) and palm6_witnesses (incidents) listen on. So today,
-- with this resource LIVE, an AI-Director crime or a snitch report is a blip on an
-- officer's map and nothing else: no /calls row, no incident, no trace once the
-- blip expires. "The 911 log" is not the 911 log.
--
-- WHILE Enabled = false NOTHING CHANGES. The private fan-out is untouched either
-- way; this flag only decides whether the dispatch is ALSO put on the record.
--
-- ONE ASSUMPTION UNDERPINS THE SUSPECT PATH, NAMED HERE BEFORE THE BULLETS THAT
-- REST ON IT. Every consumer below decides what to do by testing `source` inside
-- the handler against the repo's shared server-raise predicate: a raise from
-- inside the server VM surfaces as nil, <= 0, or 65535, never a real player id
-- (palm6_eventguard/server/main.lua guard(); palm6_mdt/bridge/sv_framework.lua,
-- grep `local fromNet`; palm6_witnesses/server/main.lua, grep `local
-- isServerCall`). That predicate is a CONVENTION OF THIS TREE, not something
-- this tree can prove: qbx_core and qbx_police live on the game box.
--
-- The evidence for it, and why palm6_brain is not the file that has to settle it:
-- SEVEN in-repo resources already raise this event in the byte-identical shape
-- palm6_brain uses - TriggerEvent('police:server:policeAlert', text, nil, src)
-- out of their own bridge/sv_framework.lua (business, counterfeit, drugs,
-- laundering, protection, smuggling, and palm6_witnesses itself; grep the event
-- name). Those ship live today, and palm6_witnesses' heat-suppression branch is
-- built on the predicate holding for exactly them. palm6_brain's raise is an
-- EIGHTH caller of an existing convention, not a new one, and it inherits
-- whatever the other seven already do in production - including the yielding
-- insert, which is why bridge/sv_framework.lua's recordDispatch routes from a
-- detached CreateThread. palm6_onboarding/bridge/sv_framework.lua refuses to
-- assert the same predicate for QBCore:Server:OnPlayerLoaded, and that is not a
-- contradiction: that event is raised by qbx_core, which is not in this tree and
-- has zero in-repo precedent, whereas this one is raised BY this tree seven times
-- over. Same predicate, different amounts of evidence, so different confidence.
--
-- WHAT Enabled = true DOES, per path (each claim checked against the consumer as
-- it stands in this tree today, ASSUMING the predicate above holds):
--
--   SUSPECT PATH - a dispatch that names a real, still-connected player (the
--   snitch path: a ped saw a player commit a crime).
--     • palm6_mdt writes a palm6_mdt_calls row stamped `citizen <cid>` with NO
--       `(unverified)` suffix, because a server-side raise is trusted provenance.
--       Its coords come from the SUSPECT'S live ped at raise time, not from the
--       coords passed to Bridge.AlertPolice.
--     • palm6_witnesses opens a witness incident against that player: NPC
--       witnesses are seeded and the incident persists. THIS IS THE LIVE
--       GAMEPLAY CHANGE - a player enters the witness system because of
--       something an NPC "perceived".
--     • palm6_heat scores NOTHING. A server-side raise sets that resource's
--       `emitterOwnsHeat`, which suppresses the charge on the assumption the
--       emitting resource owns its own AddHeat wire. palm6_brain deliberately
--       does not add one: letting AI perception move a player's durable heat is
--       its own decision, not a side effect of this flag.
--     • palm6_eventguard does not budget it. Its 40/60s police:server:policeAlert
--       budget counts CLIENT raises only; this is a server raise, which its
--       guard() returns early on (grep `server-emitted`).
--     • qbx_police is expected to render its own 911 notify for it, so officers
--       would get the brain blip AND the qbx ping for one event. Two pings, one
--       crime. UNVERIFIED FROM THIS REPO: qbx_police lives on the game box, not
--       here, so confirm the double ping in-game before deciding it is fine.
--
--   IF THE PREDICATE DOES NOT HOLD - i.e. `source` is inherited from the calling
--   chain rather than reset, so the snitch path's raise carries the reporting
--   client's id - three of those five bullets invert, and they invert for the
--   other seven raisers at the same time:
--     • palm6_mdt sees fromNet = true, stamps the row `(unverified)`, and drops
--       it outright if its Config.Calls.RequireServerProvenance is on.
--     • palm6_witnesses sees isServerCall = false, so emitterOwnsHeat is false
--       and palm6_heat IS charged.
--     • palm6_eventguard sees a real player id, so brain's dispatches count
--       against that player's own 40/60s police:server:policeAlert drop_only
--       budget and can CancelEvent() a subsequent real 911 from them.
--   THE ONE-LINE EXPERIMENT THAT SETTLES IT: print(tonumber(source)) at the top
--   of palm6_mdt's police:server:policeAlert handler, then trigger any drug sale
--   (palm6_drugs raises it exactly like this). Do that before flipping this flag
--   if the inverted column matters to you.
--
--   NO-SUSPECT PATH - an AI-Director crime (an NPC did it; there is no player to
--   attribute it to), or a suspect who has since disconnected. That bus cannot
--   carry it: police:server:policeAlert derives everything from a player source.
--   These go to exports.palm6_mdt:LogCall instead - the additive 911-log entry
--   palm6_tips already uses - so they show up in /calls and touch no player, no
--   incident and no heat.
--   WHERE THOSE COORDS COME FROM DIFFERS BY CALLER, and the difference matters
--   because this row is DURABLE where the blip was ephemeral:
--     • AI-Director crime: server-authored. director.lua reads sceneCoordSv,
--       built from Config.Scenes in this file. Nothing client-supplied.
--     • Disconnected-suspect fallback (snitch path): the CLIENT'S CLAIMED crime
--       position, passed through by server/crimewatch.lua, which deliberately
--       rejects rather than rewrites a bad claim. It is bounded, not trusted:
--       the claim must be within CrimeClaimMaxM (50m default) of the reporter's
--       SERVER-derived ped position. So a player can nudge a /calls row up to
--       50m off, and unlike the blip it does not expire. Bounded and logged, but
--       do not read the row as a server-surveyed position.
--
-- DEFAULT OFF because the witness-incident half is a live gameplay change nobody
-- asked for. /brainstatus prints the routing counters in BOTH states, so you can
-- see how many dispatches a flip WOULD ATTEMPT. Attempted, not recorded: each
-- sink has its own gates after this point (palm6_mdt Config.Calls.Enabled /
-- RequireServerProvenance / PerSourceCdSec; palm6_witnesses' per-source rate
-- limit, IncidentCooldownSec and MinWitnesses), so the counter is an upper bound
-- on the rows a flip would produce, not a preview of them.
-- ===========================================================================
Config.PoliceBus = {
    -- false = dispatches stay private blips (current, shipped behaviour).
    Enabled = false,

    -- src_label written on the LogCall rows for the no-suspect path, so an
    -- officer reading /calls can tell an AI dispatch from a real one. The column
    -- is VARCHAR(64) in palm6_mdt; keep it short.
    CallLabel = 'palm6_brain (AI dispatch)',
}
