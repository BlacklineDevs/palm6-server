-- ===========================================================================
-- palm6_pulse — configuration (Tier-1 tunables)
-- ===========================================================================
-- The "live city director": every TickSeconds it looks at how many players are
-- online and what they're doing, then opens the single best-fitting Pulse Window
-- (a ~15-min, city-wide, transparent payout modifier) and announces it. Pulse
-- NEVER grants money/items directly except the gated participation reward — it
-- publishes a capped scalar other resources read at grant time.
-- ===========================================================================

Config = {}

Config.Debug = false

-- Cadence / population gating -------------------------------------------------
Config.TickSeconds     = 60    -- how often the director evaluates
Config.WindowSeconds   = 900   -- how long a Pulse Window stays open (15 min)
Config.CooldownSeconds = 1200  -- quiet gap between windows (20 min)
-- TODO(David): tune MinOnline for a 48-slot server. Below this, the director
-- stays quiet (a window firing to an empty city is the exact failure we avoid).
Config.MinOnline       = 4

-- Modifier safety ------------------------------------------------------------
Config.MaxModifier     = 2.0   -- hard ceiling on any published multiplier

-- Participation reward (NOT a purchase — a flat, once-per-window grant) --------
-- TODO(David): points have NO cash value (they feed the season scoreboard).
Config.PointsPerCheckin = 10
Config.StreakBonusPoints = 2    -- extra points per current-streak level, capped
Config.StreakBonusCap    = 20   -- max streak bonus points per check-in
Config.StreakGraceWindows = 1   -- windows you may miss and still keep your streak
-- TODO(David): CashTip defaults to 0 (points-only). If >0, a flat, hard-capped
-- clean-cash tip is paid once per window via the SAME atomic check-in gate, so it
-- can never be double-collected. Confirm if you want any cash faucet at all.
Config.CashTip = 0

-- Announce -------------------------------------------------------------------
Config.Toast = true             -- server-wide in-game toast on window open
-- Discord: set `set palm6:discord_pulse_webhook "..."` in server.cfg (never git).
Config.DiscordConvar = 'palm6:discord_pulse_webhook'
-- cityfeed narration is GATED OFF until the bot side adds a 'pulse' event type
-- (cross-repo change in the bot). Do NOT enable until then.
Config.EmitCityfeed = false

-- Window catalog -------------------------------------------------------------
-- weight   : base selection weight among eligible windows
-- minOnline: this window only becomes eligible at/above this online count
-- domain   : the modifier bus key consumers read via GetActiveModifier(domain)
-- modifier : the published multiplier while the window is open
-- Selection is population-aware: eligibility + weight, then weighted-random.
Config.Windows = {
    boomtown = {
        label = 'Boomtown', domain = 'grind', modifier = 1.6, weight = 5, minOnline = Config.MinOnline,
        blurb = 'Legal hauls are paying big — fishing, mining and hunting are booming across the city.',
    },
    hot_exchange = {
        label = 'Hot Exchange', domain = 'market', modifier = 1.75, weight = 4, minOnline = Config.MinOnline,
        blurb = 'The Commodity Exchange is spiking — one good is selling hot right now.',
        -- picks a random Config.MarketCommodities entry as the target sub-key
    },
    bounty_surge = {
        label = 'Bounty Surge', domain = 'bounty', modifier = 1.75, weight = 3, minOnline = Config.MinOnline,
        blurb = 'Skip-tracers are cashing in — posted bounty payouts are surging.',
    },
    -- Only windows whose domain has a LIVE consumer are listed here, so pulse
    -- never announces a boost that does nothing. Live consumers:
    --   grind  -> palm6_grind sell (Boomtown)
    --   market -> palm6_market currentPrice (Hot Exchange)
    --   bounty -> palm6_bounty capture payout (Bounty Surge)
    -- TODO(David): crackdown (police) and turf_war (gang) are DEFERRED — the game
    -- has no cop arrest-reward (police are salaried) and turf reputation is a zone
    -- COUNT (no numeric rep grant to boost). Re-enable each here once it has a real
    -- consumer (e.g. a per-arrest reward, or a numeric gang-rep grant on turf
    -- capture that reads GetActiveModifier('gang')).
    -- crackdown = { label = 'Crackdown', domain = 'police', modifier = 1.6, weight = 3, minOnline = Config.MinOnline + 2,
    --     blurb = 'The brass ordered a crackdown — arrests and citations pay extra while it lasts.' },
    -- turf_war  = { label = 'Turf War', domain = 'gang', modifier = 1.6, weight = 4, minOnline = Config.MinOnline + 1,
    --     blurb = 'Tensions are high — turf and rep gains are amplified across the sets.' },
}

-- Commodities Hot Exchange may spike (must match palm6_market commodity keys).
-- TODO(David): keep in sync with palm6_market Config commodities if you add more.
Config.MarketCommodities = { 'raw_fish', 'raw_ore', 'raw_meat', 'animal_pelt' }
