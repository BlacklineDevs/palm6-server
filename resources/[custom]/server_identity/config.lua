-- ============================================================================
-- server_identity/config.lua - identity layer config.
-- Loadscreen copy (tips, rules, socials, staff, music) lives in html/config.js.
-- ============================================================================

Config = {}

Config.ServerName = 'Palm6'

-- Keep in sync with server_base/config.lua: Config.DefaultSpawn.
Config.SpawnPoint = vector4(195.17, -933.77, 30.69, 144.0)

-- Replace with your Discord application id from
-- https://discord.com/developers/applications.
Config.DiscordAppId = '0000000000000000000'
Config.DiscordPresenceText = 'Roleplaying in Palm6 Bay'
Config.DiscordPresenceRefreshMs = 60000
