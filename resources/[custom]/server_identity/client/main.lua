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
-- Spawn handler — places the character at Config.SpawnPoint on load
-- ---------------------------------------------------------------------------
local function spawnAtConfigPoint()
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end

    local p = Config.SpawnPoint
    if not p then return end

    -- Block frame draw while we relocate, then fade in.
    DoScreenFadeOut(250)
    while not IsScreenFadedOut() do Wait(0) end

    SetEntityCoords(ped, p.x, p.y, p.z, false, false, false, false)
    SetEntityHeading(ped, p.w)
    FreezeEntityPosition(ped, true)

    -- Wait for the world around us to stream in before unfreezing.
    local tries = 0
    while not HasCollisionLoadedAroundEntity(ped) and tries < 200 do
        Wait(50)
        tries = tries + 1
    end

    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(500)

    -- Tell FXServer we are done with the loading screen on this client.
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
end

-- qbx_core fires QBCore:Client:OnPlayerLoaded after character selection.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    spawnAtConfigPoint()
end)
