-- ============================================================================
-- palm6_bounty/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to VI). The wanted board: the city auto-posts a state contract on every
-- citizen carrying an active `palm6_mdt_warrants` warrant (read-only —
-- this resource never writes to palm6_mdt's tables, only SELECTs them, the
-- same house pattern palm6_pumpcoin/palm6_clout/palm6_flashdrop use to read
-- palm6_turf). Any citizen can also post a private cash contract on another
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
-- Re-synced on a sweep against palm6_mdt's live warrant table.
Config.State = {
    Enabled        = true,
    SweepSec       = 180,    -- how often the sync runs
    RequireMdt     = true,   -- if palm6_mdt isn't running, state contracts just don't post
    BaseAmount     = 500,    -- flat reward for a single active warrant
    PerWarrantExtra = 250,   -- + this much per warrant beyond the first
    Cap            = 5000,   -- hard ceiling regardless of warrant count

    -- Eligibility gate. SHIPS DARK (false) - flipping it is David's call.
    -- A state contract is city-funded: /capture pays it from nowhere, with no
    -- escrow and no debit, so every auto-posted contract is a small faucet.
    -- Upstream, /warrant needs only an on-duty officer, a tablet, a valid
    -- citizen and a 5-character reason - no evidence of anything. With this ON
    -- the city only puts money on a warrant that is TRACEABLE: it either
    -- carries a real palm6_evidence case_id (the column palm6_mdt writes when
    -- an officer passes a case number) or came from the automated unpaid-
    -- citation escalation, which issues under one of the SystemIssuers below.
    -- Officer-typed warrants with no case attached still work everywhere else
    -- - they just stop minting a bounty.
    --
    -- NOTE the payout side is deliberately untouched: /capture's settle +
    -- boot-reconcile path is carefully ordered and must not be disturbed. This
    -- gate is purely about which warrants get auto-posted in the first place.
    RequireCase    = false,

    -- Every AUTOMATED warrant issuer in the stack. These are the officer_name
    -- strings passed as officerLabel to palm6_mdt:IssueWarrant by resources
    -- that issue with caseId = 0 (so case_id lands NULL and the case half of
    -- the predicate above can never match them). Each must match its source
    -- string EXACTLY or that issuer's warrants stop minting bounties the
    -- moment RequireCase is flipped on:
    --   'City Hall Collections' - palm6_citations overdue escalation
    --                             (palm6_citations/server/main.lua:233)
    --   'Court'                 - palm6_yard bail skip
    --                             (palm6_yard/shared/config.lua:94 ->
    --                              palm6_yard/server/main.lua:346)
    --   'Anonymous Tip'         - palm6_ransom kidnapping case
    --                             (palm6_ransom/server/main.lua:206)
    --   'Loan Shark'            - palm6_loanshark default
    --                             (palm6_loanshark/shared/config.lua:43 ->
    --                              palm6_loanshark/server/main.lua:54)
    -- The first draft listed only City Hall, which would have killed state
    -- bounties on bail-skips and kidnappers - the two most bounty-worthy
    -- automated warrants in the stack - the moment RequireCase went on.
    SystemIssuers  = {
        'City Hall Collections',
        'Court',
        'Anonymous Tip',
        'Loan Shark',
    },
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
