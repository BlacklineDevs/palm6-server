-- ============================================================================
-- server_identity/config.lua - identity layer config.
-- Loadscreen copy (tips, rules, socials, staff, music) lives in html/config.js.
-- ============================================================================

Config = {}

Config.ServerName = 'Palm6'

-- Keep in sync with server_base/config.lua: Config.DefaultSpawn.
Config.SpawnPoint = vector4(195.17, -933.77, 30.69, 144.0)

-- Discord Rich Presence (in-game, not the loadscreen)
-- 1. Open https://discord.com/developers/applications → New Application "Palm6"
-- 2. Copy Application ID → paste below (replace the zeros)
-- 3. Optional: Rich Presence → Art Assets upload a 512×512 logo as "palm6"
-- 4. Restart server_identity / reconnect so presence refreshes
-- I cannot create this app for you (needs your Discord login).
Config.DiscordAppId = '1522468444610760774'
Config.DiscordPresenceText = 'Roleplaying in Palm6 Bay'
Config.DiscordPresenceRefreshMs = 60000
