-- ============================================================================
-- gtarp_bounty/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to VI). The wanted board: the city auto-posts a state contract on every
-- citizen carrying an active `gtarp_mdt_warrants` warrant (read-only —
-- this resource never writes to gtarp_mdt's tables, only SELECTs them, the
-- same house pattern gtarp_pumpcoin/gtarp_clout/gtarp_flashdrop use to read
-- gtarp_turf). Any citizen can also post a private cash contract on another
-- citizen, escrowed up front. A hunter claims by actually beating the
-- target down and getting close enough to slap the cuffs on — a name+amount
-- board, not a GPS tracker.
-- ============================================================================
Config = {}

Config.Debug = false

-- The Bounty Board — a bail-bonds-style desk. /postbounty, /cancelbounty,
-- and /bounties all work from anywhere; only POSTING a private contract
-- requires being at the board (server-checked against the poster's real
-- coords). Placeholder Tier-3 coords (see docs/GTA6-READINESS.md) — retune
-- once a real MLO/prop is picked.
Config.Board = {
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    coords = { x = 434.60, y = -981.30, z = 30.71 },  -- Mission Row Police Station front entrance, on the sidewalk steps
    radius = 12.0,
    label = 'Bail Bonds Bounty Board',
}

-- State contracts — funded by the city, not debited from any player.
-- Re-synced on a sweep against gtarp_mdt's live warrant table.
Config.State = {
    Enabled        = true,
    SweepSec       = 180,    -- how often the sync runs
    RequireMdt     = true,   -- if gtarp_mdt isn't running, state contracts just don't post
    BaseAmount     = 500,    -- flat reward for a single active warrant
    PerWarrantExtra = 250,   -- + this much per warrant beyond the first
    Cap            = 5000,   -- hard ceiling regardless of warrant count
}

-- Private contracts — posted by a citizen, escrowed from their bank at
-- post time, refundable (minus a non-refundable posting fee) on cancel.
Config.Private = {
    MinAmount        = 100,
    MaxAmount         = 10000,
    ReasonMin         = 5,
    ReasonMax         = 140,
    TtlHours          = 24,     -- unclaimed contracts auto-expire and refund
    CancelFeePct      = 0.10,   -- kept on cancel — discourages post/cancel spam
    MaxOpenPerCitizen = 3,      -- open (active) contracts a citizen may post at once
    PostCooldownSec   = 30,
    ListLimit         = 10,
}

-- Claiming ("capture"). The hunter must be close AND the target must
-- actually be beaten down — both read server-side, never client-trusted.
Config.Capture = {
    Radius           = 3.0,   -- metres between hunter and target
    -- GTA ped health is on a 100-200 scale (100 = dead/laststand, 200 =
    -- full, see qbx_medical's `SetEntityMaxHealth(ped, 200)`). 120 means
    -- the target has ~20% effective HP left — solidly beaten down but
    -- short of triggering laststand/death themselves.
    HealthThreshold  = 120,
    CooldownSec      = 10,    -- per-hunter cooldown between capture attempts
}

-- Per-source command cooldowns (seconds) — distinct from the capture/post
-- cooldowns above, these just stop chat-command spam.
Config.RateLimits = {
    postbounty   = 3,
    cancelbounty = 3,
    bounties     = 2,
    capture      = 2,
}
