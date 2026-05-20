-- ============================================================================
-- gtarp_allowlist/config.lua
--
-- The allowlist has two independent sources:
--   1. Discord roles — queried via Discord bot API. Read role ids from
--      Config.AllowedRoles. Bot token comes from a convar — NEVER hardcode.
--   2. DB allowlist — rows in the `allowlist` table (sql/0009_allowlist.sql).
--      Used for manual additions or for players without Discord linked.
--
-- A join is approved if EITHER source matches.
-- ============================================================================

Config = {}

-- Convar names (set in txAdmin secret store):
--   set gtarp:discord_bot_token  "..."
--   set gtarp:discord_guild_id   "..."
Config.BotTokenConvar = 'gtarp:discord_bot_token'
Config.GuildIdConvar  = 'gtarp:discord_guild_id'

-- Discord role ids permitted to join. Add real ids when known.
Config.AllowedRoles = {
    -- ['000000000000000000'] = 'member',
    -- ['000000000000000001'] = 'whitelist',
}

-- Role lookups are cached this many seconds.
Config.RoleCacheTtlSeconds = 60

-- Per-request timeout for the Discord API call. After this, allow OR deny
-- depending on Config.FailOpen.
Config.DiscordTimeoutMs = 4000
Config.FailOpen        = false  -- safer default for a public RP server

-- Friendly messages.
Config.DenyNoLink   = 'Your Discord must be linked in FiveM to join.'
Config.DenyNoRole   = 'You are not on the allowlist. Apply via Discord first.'
Config.DenyTimeout  = 'Allowlist check timed out. Try again in a minute.'
