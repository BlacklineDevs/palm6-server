-- ============================================================================
-- server_identity/config.lua — identity layer config.
-- ============================================================================

Config = {}

Config.ServerName = 'Los Santos Roleplay'

Config.LoadingScreenTips = {
    'Type /serverinfo in chat to check the server identity.',
    'Stay in character — use /me and /do for actions and details.',
    'New here? Read the rules pinned in the Discord before spawning in.',
    'Press F1 to open the phone once you spawn.',
    'Report issues to staff in-game with /report.',
}

-- Keep in sync with server_base/config.lua: Config.DefaultSpawn.
Config.SpawnPoint = vector4(195.17, -933.77, 30.69, 144.0)

-- Replace with your Discord application id from
-- https://discord.com/developers/applications.
Config.DiscordAppId = '0000000000000000000'
Config.DiscordPresenceText = 'Roleplaying in Los Santos'
Config.DiscordPresenceRefreshMs = 60000
