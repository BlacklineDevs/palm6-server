-- ============================================================================
-- server_identity/client/main.lua
--
-- Pure logic: Discord-presence refresh cadence + the post-selection spawn
-- placement. All natives and framework events go through Game.*
-- (bridge/cl_game.lua), so this file is engine-agnostic. To port to GTA VI,
-- rewrite the bridge, not this file. See docs/GTA6-READINESS.md.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Discord rich presence
-- ---------------------------------------------------------------------------
local function applyDiscordPresence()
    local appId = Config.DiscordAppId
    if not appId or appId == '' or appId == '0000000000000000000' then
        return
    end
    Game.ApplyDiscordPresence(
        appId,
        ('%s — %s'):format(Config.ServerName, Config.DiscordPresenceText)
    )
end

CreateThread(function()
    while true do
        applyDiscordPresence()
        Wait(Config.DiscordPresenceRefreshMs or 60000)
    end
end)

-- ---------------------------------------------------------------------------
-- Post-selection spawn placement
--
-- IMPORTANT: the framework — not this resource — owns character selection and
-- the initial spawn (see the bridge for the framework-specific verification).
-- We treat the loaded event strictly as the "a character was actively
-- selected and is now in the world" signal: we never spawn before it, and we
-- only reposition the already-spawned character to the server's canonical
-- spawn point (Game.PlaceAtSpawn handles the fade so the move is seamless).
-- The one-shot guard stops a re-teleport if a downstream resource re-emits
-- the loaded event within the same session.
-- ---------------------------------------------------------------------------
local hasPlacedSpawn = false

Game.OnPlayerLoaded(function()
    if hasPlacedSpawn then return end
    hasPlacedSpawn = true
    if Config.SpawnPoint then
        Game.PlaceAtSpawn(Config.SpawnPoint)
    end
end)

-- When the player logs back out to the character-select screen, re-arm the
-- guard so the next slot they choose is placed at the spawn point again.
Game.OnPlayerLoggedOut(function()
    hasPlacedSpawn = false
end)
