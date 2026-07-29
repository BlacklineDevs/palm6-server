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

    -- HEAT PREMIUM (palm6_heat GetTier). The state contract amount today is a
    -- pure function of WARRANT COUNT, so the man the whole city is hunting and
    -- the man with one stale unpaid citation are worth the same $500. This adds
    -- a premium for durable police attention, so the most wanted really are
    -- worth the most.
    --
    -- SHIPS DISABLED. With Enabled = false no export is called, not one extra DB
    -- round-trip is spent per sweep, every contract amount is exactly what it is
    -- today, and every write the sync performs is byte-for-byte the write it
    -- performs today. The one statement that is not character-identical is the
    -- existing-contract lookup, which now also SELECTs the `status` column so the
    -- sync can skip a pointless premium read on an already-claimed contract. It
    -- matches the same rows and no write depends on it while the flag is off.
    --
    -- Read ONLY through the frozen exports.palm6_heat:GetTier export, never by
    -- querying palm6_heat_state: stored heat is settled lazily against
    -- updated_at, so a direct table read would price a citizen who cooled off
    -- hours ago as still WANTED. Soft-guard (GetResourceState + pcall) so a
    -- stopped or throwing palm6_heat leaves every contract at its base amount.
    --
    -- /capture's settle + boot-reconcile payout path is NOT touched by this.
    -- The only thing that changes is which number the sync writes into a
    -- still-ACTIVE contract's amount column, and the sync's UPDATE is guarded to
    -- status='active' while this is on precisely so a decaying premium can never
    -- rewrite an already-claimed row that reconcileUnsettled might re-pay from.
    --
    -- WHERE THE PRICE FREEZES: at CLAIM, not at quote. A hunter who reads
    -- /bounties is reading the amount as of that instant; while the contract is
    -- still active the sync keeps re-pricing it every SweepSec against the
    -- target's DECAYED tier, and /capture pays the amount it reads at capture
    -- time. So a target who lays low between the board being read and the
    -- capture is genuinely worth less by then, and the hunter is paid the lower
    -- figure. That is the intended economics (the premium is a bounty on CURRENT
    -- police attention, not a promise), but it is a price that moves, so
    -- /bounties prints the rule alongside the list whenever this flag is on
    -- rather than letting the number change in silence.
    --
    -- ANTI-FARM. The obvious reverse-farm is "get hot on purpose, have a friend
    -- capture me, split the city's money". Four things bound it, and none of
    -- them are new code:
    --   1. A state contract only ever exists against a LIVE warrant, which a
    --      player cannot issue to themselves: an officer or one of the four
    --      SystemIssuers above has to put it there. Heat alone mints nothing:
    --      heatPremium is only ever called from inside the loop over live
    --      warrant rows.
    --   2. The premium is ADDITIVE to an amount the warrant table already
    --      justified, is >= 0, and is clamped to Cap below, so the worst case is
    --      a known, bounded number an operator can read off this file.
    --   3. The sync looks for an existing state row with status IN
    --      ('active','claimed'), so once a citizen's state contract is claimed
    --      it is never re-opened. The premium is collectable at most ONCE per
    --      citizen. (Pre-existing behaviour, observed and deliberately left
    --      alone, because it is the hard bound this whole effect rests on.)
    --   4. The premium is re-read from the DECAYED tier on every sweep, so
    --      holding it requires continuing to commit crime, which now costs the
    --      target real money at the street buyer and the chop shop.
    -- The grief direction is closed by construction: this reads the TARGET's own
    -- heat, and nothing in the crime layer lets one player add heat to another.
    HeatBonus = {
        Enabled = false,
        -- Added to the warrant-count amount, by palm6_heat tier. Tiers absent
        -- from this table (CLEAN, COOL) add nothing.
        PerTier = { WARM = 0, HOT = 400, WANTED = 1200 },
        -- Hard ceiling on the ADDED amount, whatever PerTier says.
        --
        -- SIZING THE FAUCET: read the second number, not the first. The most a
        -- state contract's STORED amount can reach is Config.State.Cap + this
        -- = 5000 + 1200 = $6200. That is NOT the worst-case MINT. /capture
        -- multiplies the stored amount by the palm6_pulse "bounty" modifier at
        -- PAYOUT time (the GetActiveModifier block in cmdCapture), so the
        -- largest city-funded payout a single capture can produce is:
        --
        --   shipped Bounty Surge window (palm6_pulse Config.Windows
        --   .bounty_surge.modifier = 1.75):  6200 * 1.75 = $10,850
        --   structural ceiling (palm6_pulse Config.MaxModifier = 2.0, the cap
        --   GetActiveModifier clamps to): 6200 * 2.00 = $12,400
        --
        -- Today, with this premium off, those same two numbers are $8,750 and
        -- $10,000. So flipping Enabled = true raises the worst-case single mint
        -- by $2,100 (shipped) / $2,400 (ceiling), not by $1,200. Size the faucet
        -- off $12,400.
        Cap     = 1200,
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
