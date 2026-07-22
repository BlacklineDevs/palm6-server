-- ============================================================================
-- palm6_season/shared/config.lua
--
-- Tunables for the read-only season scoreboard: ladder registry, row limits,
-- rate limits, the admin ace name, and the OFF-by-default Discord tie-in.
-- No secrets, no framework calls. server/main.lua holds the SQL keyed by the
-- same ladder names listed here, so this file is the single list a reviewer
-- reads to know exactly what boards exist.
-- ============================================================================

Config = {}

Config.Debug          = false

Config.TopN           = 10      -- default rows returned by /seasontop
Config.MaxTopN        = 25      -- hard ceiling a caller (or the cache) may request
Config.SeasonCacheSec = 15      -- GetCurrentSeason() cache TTL (seconds)
Config.QueryCacheSec  = 30      -- per-ladder result cache TTL (rate-limit relief)
Config.CmdCooldownSec = 5       -- per-player cooldown on /season and /seasontop

-- Ace gating the admin season-control commands (/seasonopen, /seasonclose).
-- A human grants this after review, e.g. add_ace group.admin command.season allow.
Config.AdminAce       = 'command.season'

-- Auto-open a default season at boot if none is active, so the ladders and
-- rewards are live out-of-box (no admin /seasonopen required for the system to
-- do anything). Names the auto-opened season Config.DefaultSeasonName.
Config.AutoOpenDefaultSeason = true
Config.DefaultSeasonName     = 'Season 1'

-- Season-close prize ladder. When a season closes, the archived top finishers
-- of each ladder earn a CLAIMABLE clean-cash reward (banked on /seasonclaim,
-- so it is offline-safe and can never double-pay). Amounts are per finishing
-- position [1]=winner. Citizen ladders pay the person; gang ladders pay the
-- gang's #1-ranked member (leader) on their behalf. Set Rewards = {} to disable.
Config.Rewards        = { [1] = 50000, [2] = 20000, [3] = 10000 }

-- Optional Discord tie-in. OFF by default and never a hard dependency: with
-- DiscordEnable = false nothing is ever posted. DiscordFeed reuses an EXISTING
-- palm6_discord feed key ('live') so no edit to palm6_discord is required.
Config.DiscordEnable  = false
Config.DiscordFeed    = 'live'

-- Ladder registry. key -> { title, subject }. subject is 'gang' or 'citizen'.
-- The matching SQL builder for each key lives in server/main.lua.
-- noPrize ladders are DISPLAY-ONLY (leaderboard bragging rights, no cash prize).
-- 'rep' is noPrize because gang rep is minted per turf-takeover and is therefore
-- farmable by two gangs trading zones; paying it a prize would turn that farm
-- into a clean-cash exploit. Turf HELD is the paying gang ladder instead — it is
-- zero-sum (one owner per zone) and contested, so it can't be co-farmed.
Config.Ladders = {
    rep   = { title = 'Top Crews (reputation)', subject = 'gang',    noPrize = true },
    turf  = { title = 'Turf Held',              subject = 'gang'    },
    drugs = { title = 'Drug Empire',            subject = 'citizen' },
    dirty = { title = 'Dirtiest Hustler',       subject = 'citizen' },
    pulse = { title = 'City Pulse (most active)', subject = 'citizen' },
    -- Most Wanted: durable police attention from palm6_heat (GetTop). noPrize —
    -- heat is added on every crime, so a clean-cash prize would be a farm (same
    -- reason 'rep' pays nothing). Bragging rights only. Empty if palm6_heat off.
    wanted = { title = 'Most Wanted', subject = 'citizen', noPrize = true },
}

-- Deterministic display / archive order (string-keyed tables are unordered).
Config.LadderOrder = { 'rep', 'turf', 'drugs', 'dirty', 'pulse', 'wanted' }
