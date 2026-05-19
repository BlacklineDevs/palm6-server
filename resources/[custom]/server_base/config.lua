-- ============================================================================
-- server_base/config.lua — shared config for the gtarp base resource.
--
-- Edit the values below for your server. Keep secrets OUT of this file —
-- secrets live in txAdmin convars and never in version control.
-- ============================================================================

Config = {}

-- Public-facing server name. EDITABLE — change to your own brand.
Config.ServerName = 'Los Santos Roleplay'

-- ox_lib locale key. Must be a locale you've shipped in resources that use it.
Config.Locale = 'en'

-- Verbose server/client logging. Leave false in production.
Config.Debug = false

-- Welcome notification shown on character load.
Config.Welcome = {
    enabled = true,
    title = Config.ServerName,
    description = 'Welcome to the city. Have fun and stay in character.',
    type = 'inform',
}

-- Default spawn point — Legion Square, Los Santos.
-- This is the source-of-truth spawn coordinate for the custom layer.
-- server_identity reads an aligned value from its own config; keep them
-- consistent if you move spawn.
Config.DefaultSpawn = vector4(195.17, -933.77, 30.69, 144.0)

-- When true, server_base defers spawning logic to the server_identity
-- resource and does not place the player itself. Flip to false if you
-- remove server_identity and want to take over spawning here.
Config.SpawnHandledByIdentity = true
