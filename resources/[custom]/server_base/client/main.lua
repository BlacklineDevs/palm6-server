-- ============================================================================
-- server_base/client/main.lua
--
-- Pure logic: show the welcome notification once the character is loaded.
-- The framework loaded-event and the notify call go through Game.*
-- (bridge/cl_game.lua), so this file is engine-agnostic. To port to GTA VI,
-- rewrite the bridge, not this file. See docs/GTA6-READINESS.md.
--
-- The framework fires its loaded event only AFTER the player has actively
-- selected a character in the multichar UI and that character has spawned
-- (see the bridge for the framework-specific verification). Hooking it here
-- means the welcome shows once selection is complete, never before it.
-- ============================================================================

Game.OnPlayerLoaded(function()
    if not Config.Welcome.enabled then return end
    Game.Notify({
        title = Config.Welcome.title or Config.ServerName,
        description = Config.Welcome.description,
        type = Config.Welcome.type or 'inform',
    })
end)

-- Admin placement tool: the server (ace-gated /p6tp) authorises a teleport and
-- hands the destination here. The native call lives in the bridge.
RegisterNetEvent('server_base:teleport', function(x, y, z)
    Game.Teleport(x + 0.0, y + 0.0, z + 0.0)
end)
