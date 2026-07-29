-- ============================================================================
-- palm6_replay/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
--
-- The city black-box. Every client keeps a rolling 90-second telemetry ring
-- (4 Hz compact frames — position, heading, speed, weapon, stance flags).
-- When an incident fires server-side (shots, downed player, robbery), the
-- server pulls the rings of everyone in radius and persists a scene snippet.
-- Detectives stand at the scene and replay it as translucent ghost peds.
--
-- Telemetry-only by design: NO Rockstar Editor, NO recording natives, NO
-- video/clips (qbx_smallresources already owns /record — see README).
-- ============================================================================
Config = {}

Config.Debug = false

-- ---------------------------------------------------------------------------
-- Recording (the client-side ring buffer)
-- ---------------------------------------------------------------------------
Config.Recording = {
    Enabled       = true,
    FrameHz       = 4,     -- samples per second. 4 Hz is smooth enough to
                           -- interpolate and cheap enough to forget about.
    BufferSeconds = 90,    -- rolling window each client keeps in memory.
                           -- FrameHz * BufferSeconds = ring size (360 frames,
                           -- a few KB — never leaves the client unless the
                           -- server asks for it).
}

-- ---------------------------------------------------------------------------
-- Incident capture (server-side; these are the anti-flood caps — see README)
-- ---------------------------------------------------------------------------
Config.Incident = {
    Radius               = 60.0,  -- players within this range of the incident
                                  -- get their buffers pulled.
    MaxParticipants      = 10,    -- hard cap per scene (nearest first).
    MaxFrames            = 400,   -- hard cap on frames accepted per player
                                  -- (ring size + slack; anything bigger is
                                  -- a tampered client and gets dropped).
    MaxFrameDistance     = 1500.0,-- frames farther than this from the incident
                                  -- are discarded (a 90 s ring can legitimately
                                  -- include a drive-through, not a teleport).
    UploadWindowSeconds  = 12,    -- clients must answer the buffer request
                                  -- within this window or the scene persists
                                  -- without them.
    DedupeSeconds        = 45,    -- no second scene of the same type...
    DedupeRadius         = 40.0,  -- ...within this range of a live one — one
                                  -- firefight = one scene, not thirty.
    GlobalPerMinuteCap   = 6,     -- absolute ceiling on new scenes per minute,
                                  -- whatever the trigger mix.

    -- Upload corroboration (anti-forgery — see server/main.lua). Frames are
    -- client-authored; these knobs govern how they are checked against the
    -- server's OWN observations before being persisted as evidence.
    CorroborationTolerance = 50.0,-- max metres between the server's own read of a
                                  -- participant at invite time and the newest frame
                                  -- of their uploaded ring (both sampled at ~the
                                  -- same instant). Beyond this the ring's positions
                                  -- were shifted client-side → upload rejected.
                                  -- Generous enough for highway speed + latency.
    ShotAnnotateWindowMs   = 1500,-- when the SERVER observed this player deal weapon
                                  -- damage, the uploaded frame nearest that moment
                                  -- (within this window) gets FLAG_SHOOT forced on
                                  -- even if the client stripped it.
}

-- ---------------------------------------------------------------------------
-- Incident triggers
-- ---------------------------------------------------------------------------
Config.Triggers = {
    -- Server-observed weapon damage (someone actually got hit). The most
    -- trustworthy trigger — fires from the server's own damage event, not a
    -- client claim.
    WeaponDamage = true,

    -- A player went down (baseevents death report). Client-originated, so it
    -- only ever flags a scene — it never pays, grants, or charges anything.
    PlayerDowned = true,

    -- Client "shots fired" report (shots that hit nothing still matter for
    -- first-shooter disputes). Client-originated: the server uses ITS OWN
    -- read of the shooter's position, never the client's claim, and
    -- rate-limits hard (below).
    ShotsFired         = true,
    ShotsFiredCooldown = 60,   -- seconds between accepted reports per player.

    -- Auto-flag scenes when other palm6 resources fire their incident events.
    -- Consumed read-only — palm6_replay never modifies those resources.
    -- Remove an entry to detach; add entries to flag more systems.
    --
    -- TRUST BOUNDARY (fixed 2026-07-28): this listed 'palm6_robbery:start', the
    -- raw CLIENT-triggerable net event palm6_robbery/client/main.lua fires the
    -- moment a player walks up to an ATM - before ANY of the server's start gates
    -- (police count, weapon, per-ATM cooldown, proximity) have run. Any modified
    -- client could therefore mint replay scenes at will, for robberies that were
    -- rejected or never happened. The correct signal is 'palm6_robbery:started',
    -- which palm6_robbery/server/main.lua raises with TriggerEvent ONLY after
    -- every gate passed (grep `TriggerEvent('palm6_robbery:started'`).
    -- palm6_witnesses already had this right: its shared/config.lua
    -- Config.Hooks.palm6Robbery entry, and the comment above the
    -- AddEventHandler for it in server/main.lua (grep `palm6Robbery.event`),
    -- document the same reasoning. Cited by symbol, not line number - the line
    -- numbers in both files have drifted since this comment was written.
    --
    -- Names listed here are subscribed through Bridge.OnForeignNetEvent, which
    -- FAILS CLOSED: every entry is an AddEventHandler unless it carries an
    -- explicit `clientRaised = true`, so adding a name here can never quietly
    -- open it to the network. Only set clientRaised on an event the owning
    -- resource's own CLIENT raises with TriggerServerEvent (that name is already
    -- open, so a second handler adds no surface) - and never on a ':started'
    -- style signal, which is server-raised after gates by convention.
    AutoFlagEvents = {
        { event = 'palm6_robbery:started', type = 'robbery', label = 'Robbery in progress' },
    },
}

-- ---------------------------------------------------------------------------
-- Storage / retention
-- ---------------------------------------------------------------------------
Config.Retention = {
    Days            = 7,    -- scenes expire after this many days.
    MaxStoredScenes = 300,  -- absolute cap; oldest scenes pruned past this.
}

-- ---------------------------------------------------------------------------
-- Access — who can reconstruct scenes
-- ---------------------------------------------------------------------------
Config.Access = {
    Jobs   = { 'police' },  -- on-duty members of these jobs may use the
                            -- replay commands. Add 'sheriff', 'detective',
                            -- etc. to match your job set.
    OnDuty = true,

    -- Optional: also require an inventory item (a "forensic scanner").
    -- Set to an ox_inventory item name (e.g. 'replay_scanner') AFTER you add
    -- that item to your ox_inventory data — see README. nil = job gate only.
    RequiredItem = nil,
}

-- ---------------------------------------------------------------------------
-- Scene review / playback
-- ---------------------------------------------------------------------------
Config.Playback = {
    SceneQueryRadius = 75.0,  -- /replayscenes lists scenes within this range.
    StartRadius      = 60.0,  -- /replay <id> requires standing this close to
                              -- the scene (server-checked): you reconstruct
                              -- AT the crime scene, not from the precinct.
    SceneListLimit   = 10,    -- how many nearby scenes /replayscenes shows.
    CommandCooldown  = 5,     -- seconds between replay commands per officer.

    GhostAlpha       = 150,   -- translucency of the re-enactment peds.
    FallbackPedModel = 'mp_m_freemode_01',  -- used when a recorded model
                                            -- fails to load. GTA V model name
                                            -- — Tier 3, re-author for VI.
    DefaultSpeed     = 1.0,
    Speeds           = { 0.25, 0.5, 1.0, 2.0 },  -- cycled with the speed keys.
    ScrubSeconds     = 5.0,   -- how far one scrub key-press jumps.
    LoopPlayback     = true,  -- restart from the top when the scene ends.
}

-- ---------------------------------------------------------------------------
-- Bodycam (officer-initiated snippets for case files)
-- ---------------------------------------------------------------------------
Config.Bodycam = {
    Enabled         = true,
    Radius          = 30.0,  -- tighter capture than an incident scene.
    CooldownSeconds = 60,    -- per officer.
}

-- ---------------------------------------------------------------------------
-- palm6_evidence integration (optional, auto-degrading)
-- ---------------------------------------------------------------------------
-- /replayattach writes a REPLAY EXHIBIT row into the palm6_evidence log
-- table (sql/0012_evidence.sql) so scene snippets show up in /evidence as
-- exhibits. Guarded — if palm6_evidence's table is absent the attach still
-- records against the scene and tells the officer it is standalone.
Config.EvidenceIntegration = true
