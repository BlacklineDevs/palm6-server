-- ============================================================================
-- server_identity/config.lua — identity layer for the gtarp custom layer.
--
-- Discord application ids and webhook URLs are NOT secrets, but they ARE
-- environment-specific. Edit them here.
-- ============================================================================

Config = {}

-- Server name shown on the loading screen and in Discord rich presence.
-- EDITABLE — keep in sync with server_base/config.lua: Config.ServerName.
Config.ServerName = 'Los Santos Roleplay'

-- Loading-screen tips. The shipped loading.html shows a single static tip
-- to stay self-contained (no JS); this array is the source of truth when
-- you regenerate or template the HTML.
Config.LoadingScreenTips = {
    'Type /serverinfo in chat to check the server identity.',
    'Stay in character — use /me and /do for actions and details.',
    'New here? Read the rules pinned in the Discord before spawning in.',
    'Press F1 to open the phone once you spawn.',
    'Report issues to staff in-game with /report.',
}

-- Spawn point used by the character spawn handler.
-- EDITABLE — keep in sync with server_base/config.lua: Config.DefaultSpawn.
-- Legion Square, Los Santos.
Config.SpawnPoint = vector4(195.17, -933.77, 30.69, 144.0)

-- Discord rich presence.
-- Replace DiscordAppId with your own Discord application id from
-- https://discord.com/developers/applications. EDITABLE.
Config.DiscordAppId = '0000000000000000000'

-- Rich presence text shown under the server name in a player's Discord.
-- EDITABLE.
Config.DiscordPresenceText = 'Roleplaying in Los Santos'

-- How often (ms) to refresh Discord rich presence.
Config.DiscordPresenceRefreshMs = 60000
