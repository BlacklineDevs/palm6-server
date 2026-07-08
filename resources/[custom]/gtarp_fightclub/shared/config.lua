-- ============================================================================
-- gtarp_fightclub/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). An underground bare-knuckle ring: two citizens queue up
-- at the ring, a match opens a betting window, spectators wager cash on
-- either fighter, then the fight runs unarmed and server-monitored until a
-- knockout, a forfeit (leaving the ring / drawing a weapon / disconnect),
-- or a timeout draw. Payouts are a parimutuel pool split among winning
-- bettors, minus a house rake, plus a purse cut straight to the winner.
-- ============================================================================
Config = {}

Config.Debug = false

-- The ring. Queueing and fighting both require being here (server-checked
-- against real coords, never client-trusted). Placeholder Tier-3 coords
-- (see docs/GTA6-READINESS.md) — retune once a real MLO/prop is picked.
Config.Ring = {
    coords = { x = 1198.0, y = -3130.0, z = 5.05 },  -- Elysian Island backlot
    radius = 15.0,
    label = 'the fight ring (Elysian Island)',
}

-- Queueing. Two citizens present at the ring are auto-paired the instant a
-- second one joins — signing up IS the consent (gtarp_bounty's /postbounty
-- precedent: no separate accept step to abuse or stall on).
Config.Queue = {
    JoinCooldownSec = 10,
    MaxWaitSec      = 300,   -- auto-drop from the queue if nobody else joins
}

-- Betting window. Spectators only — fighters cannot bet on their own match
-- (checked server-side against both fighters' citizenids).
Config.Betting = {
    WindowSec = 60,
    MinBet    = 50,
    MaxBet    = 5000,
    RakePct   = 0.10,   -- house cut of the total pool — an economy sink
}

-- The fight itself. Server-monitored, never client-trusted: health,
-- position, and current weapon are all read off the live synced peds
-- (same technique gtarp_bounty's /capture uses).
Config.Fight = {
    -- GTA ped health is on a 100-200 scale (100 = dead/laststand, 200 =
    -- full, see qbx_medical's SetEntityMaxHealth(ped, 200)). 110 means the
    -- fighter is solidly knocked out — a notch more decisive than
    -- gtarp_bounty's 120 "beaten down" capture threshold.
    KOHealth        = 110,
    MaxDurationSec  = 180,   -- no KO by then = timeout draw, full refund
    WinnerPursePct  = 0.15,  -- cut of the pool paid straight to the winner
    PollSec         = 2,     -- sweep cadence for betting->live transitions + fight monitoring
    RequireUnarmed  = true,  -- drawing any weapon is an instant forfeit
}

-- Per-source command cooldowns (seconds) — chat-command spam guard, distinct
-- from the queue/betting rules above.
Config.RateLimits = {
    fcjoin    = 3,
    fcleave   = 2,
    fcbet     = 2,
    fcmatches = 2,
}
