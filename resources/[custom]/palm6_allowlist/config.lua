-- ============================================================================
-- palm6_allowlist/config.lua
--
-- The allowlist has two independent sources:
--   1. Discord roles — queried via Discord bot API. Read role ids from
--      Config.AllowedRoles. Bot token comes from a convar — NEVER hardcode.
--   2. DB allowlist — rows in the `allowlist` table (sql/0009_allowlist.sql).
--      Used for manual additions or for players without Discord linked.
--
-- A join is approved if EITHER source matches.
--
-- Relationship to txAdmin's native whitelist (audited 2026-07-03): txAdmin
-- ships guildRoles and approvedLicense whitelist modes, but runs exactly ONE
-- mode at a time — it cannot express this resource's "role OR license"
-- either-match, and it has no palm6_staff deny-logging. This resource
-- intentionally supersedes it: keep txAdmin's whitelist mode set to
-- `disabled` (its default) or joins get double-gated.
-- ============================================================================

Config = {}

-- Convar names (set in txAdmin secret store):
--   set palm6:discord_bot_token  "..."
--   set palm6:discord_guild_id   "..."
Config.BotTokenConvar = 'palm6:discord_bot_token'
Config.GuildIdConvar  = 'palm6:discord_guild_id'

-- Discord role ids permitted to join. A join is admitted if the linked Discord
-- member holds ANY of these roles (requires the bot token + guild id convars set
-- below — the boot banner in server/main.lua reports whether they are).
--
-- This set MIRRORS the roles the allowlist DB-sync already grants play to
-- (sync-horizon-allowlist.py / Task HorizonAllowlistSync, guild 1522465866837393418):
-- the sync writes an `allowlist` DB row for holders of these roles every ~10 min,
-- which is the CURRENT admit path. Populating AllowedRoles + setting the two
-- convars below turns on the REAL-TIME role check (no 10-min lag) as a parallel
-- admit path — it does not remove the DB path.
--
-- NB: the Founding Tester role (1528644816890630166) is deliberately NOT here.
-- Per /beta a founding reservation does NOT bypass whitelist ("approval is still
-- required before play"), so holding the founding role must not by itself grant
-- play; a founding tester is admitted only once they complete the whitelist and
-- receive @Whitelisted (below).
Config.AllowedRoles = {
    ['1524863821725040941'] = 'admin',
    ['1524863824002420829'] = 'moderator',
    ['1524863825877405757'] = 'whitelisted',
    ['1524863833166975009'] = 'member',
    ['1522473509547282584'] = 'customer',
    ['1522473510725750906'] = 'investor',
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
