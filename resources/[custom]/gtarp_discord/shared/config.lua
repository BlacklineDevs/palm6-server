-- ============================================================================
-- gtarp_discord/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). One resource owns every PLAYER-FACING Discord feed so
-- rate limiting, retries, and formatting live in exactly one place.
--
-- This is the hype/RP announcer, NOT the ops plumbing: gtarp_staff's
-- private audit webhook and gtarp_perf's hitch webhook stay where they are
-- (staff-only data does not belong in a resource that also posts to public
-- channels).
--
-- Each feed reads its webhook URL from a convar. Unset convar = that feed
-- is off; the boot banner names which feeds are live so a misconfigured
-- deploy is visible in one console line. Producers (flashdrop, pumpcoin,
-- clout, evidence, counterfeit) call exports.gtarp_discord:Announce(...)
-- through a soft-dependency guard, so this resource being absent or a feed
-- being off never breaks gameplay.
-- ============================================================================
Config = {}

Config.Debug = false

-- Feed registry. `convar` holds the Discord webhook URL for that feed.
-- `color` is the embed accent (decimal RGB).
Config.Feeds = {
    drops = {
        convar = 'gtarp:discord_drops',
        username = 'Palm6 Drops',
        color = 15844367,   -- gold — flashdrop releases
    },
    market = {
        convar = 'gtarp:discord_market',
        username = 'Palm6 Exchange',
        color = 5763719,    -- green — pumpcoin listings/rugs
    },
    live = {
        convar = 'gtarp:discord_live',
        username = 'Palm6 Live',
        color = 10181046,   -- purple — clout streams on air
    },
    police = {
        convar = 'gtarp:discord_police',
        username = 'LSPD Case Desk',
        color = 3447003,    -- blue — evidence case files opened
    },
    heat = {
        convar = 'gtarp:discord_heat',
        username = 'Weazel News',
        color = 15548997,   -- red — counterfeit district heat bulletins
    },
}

-- Global send pacing. Discord webhooks tolerate ~30 req/min/webhook; one
-- queue drained at SendEveryMs with a hard cap keeps every feed safely
-- under that even if all five point at the same webhook.
Config.SendEveryMs   = 2500  -- one webhook POST per drain tick
Config.MaxQueue      = 40    -- beyond this, oldest messages drop (with a console warn)
Config.Retry429Once  = true  -- respect Retry-After once, then drop the message

-- Per-feed flood clamp: a feed that fires more than this many messages in
-- a rolling minute gets its excess dropped (bugs in a producer must not
-- take down every other feed's delivery).
Config.PerFeedPerMinute = 10
