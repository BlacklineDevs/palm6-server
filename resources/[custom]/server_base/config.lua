-- ============================================================================
-- server_base/config.lua — shared config for the gtarp base resource.
--
-- Edit the values below for your server. Keep secrets OUT of this file.
-- ============================================================================

Config = {}

-- Public-facing server name. EDITABLE.
Config.ServerName = 'Los Santos Roleplay'

-- ox_lib locale key.
Config.Locale = 'en'

-- Verbose logging. Leave false in production.
Config.Debug = false

-- Welcome notification shown on character load.
Config.Welcome = {
    enabled = true,
    title = Config.ServerName,
    description = 'Welcome to the city. Have fun and stay in character.',
    type = 'inform',
}

-- Default spawn point — Legion Square, Los Santos. Source of truth for
-- the custom layer. server_identity reads an aligned value from its own
-- config; keep them consistent.
Config.DefaultSpawn = vector4(195.17, -933.77, 30.69, 144.0)

-- When true, server_base defers spawning to server_identity.
Config.SpawnHandledByIdentity = true
