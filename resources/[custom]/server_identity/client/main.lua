-- ---------------------------------------------------------------------------
-- Discord rich presence
-- ---------------------------------------------------------------------------
local function applyDiscordPresence()
    if not Config.DiscordAppId or Config.DiscordAppId == '' then return end
    SetDiscordAppId(Config.DiscordAppId)
    SetRichPresence(('%s — %s'):format(Config.ServerName, Config.DiscordPresenceText))
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
-- IMPORTANT: qbx_core — not this resource — owns character selection and the
-- initial spawn. Verified against
-- github.com/Qbox-project/qbx_core/blob/main/client/character.lua:
--   1. Once the session starts, qbx_core calls
--      exports.spawnmanager:setAutoSpawn(false) so the engine does NOT auto-
--      spawn a ped, then runs chooseCharacter(), which presents the multichar
--      UI via lib.showContext('qbx_core_multichar_characters').
--   2. When the player actively picks a slot, qbx_core loads that character
--      (qbx_core:server:loadCharacter) and spawns the ped
--      (exports.spawnmanager:spawnPlayer at the last location / default spawn),
--      and only THEN fires QBCore:Client:OnPlayerLoaded.
--
-- The previous version of this file teleported the ped on every
-- OnPlayerLoaded with no guard, which slammed whichever character qbx_core
-- spawned to a fixed point and made it look like the player was auto-spawned
-- into a slot rather than choosing one. We now treat OnPlayerLoaded strictly
-- as the "a character was actively selected and is now in the world" signal:
-- we never spawn before it, and we only reposition the already-spawned
-- character to the server's canonical spawn point, behind a fade so the move
-- is seamless. The one-shot guard stops a re-teleport if a downstream
-- resource re-emits OnPlayerLoaded within the same session.
-- ---------------------------------------------------------------------------
local hasPlacedSpawn = false

local function placeAtSpawnPoint()
    local p = Config.SpawnPoint
    if not p then return end

    local ped = PlayerPedId()
    if not ped or ped == 0 then return end

    DoScreenFadeOut(250)
    -- Wait(0) yield: blocking until the engine reports the fade is complete.
    while not IsScreenFadedOut() do Wait(0) end

    SetEntityCoords(ped, p.x, p.y, p.z, false, false, false, false)
    SetEntityHeading(ped, p.w)
    FreezeEntityPosition(ped, true)

    local tries = 0
    while not HasCollisionLoadedAroundEntity(ped) and tries < 200 do
        Wait(50)
        tries = tries + 1
    end

    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(500)

    -- server_identity owns the loading screen; tear it down once the selected
    -- character is actually in the world. Idempotent with the manifest's
    -- auto-shutdown.
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    if hasPlacedSpawn then return end
    hasPlacedSpawn = true
    placeAtSpawnPoint()
end)

-- When the player logs back out to the character-select screen, re-arm the
-- guard so the next slot they choose is placed at the spawn point again.
-- Event verified in qbx_core (client/character.lua: 'qbx_core:client:playerLoggedOut').
AddEventHandler('qbx_core:client:playerLoggedOut', function()
    hasPlacedSpawn = false
end)
