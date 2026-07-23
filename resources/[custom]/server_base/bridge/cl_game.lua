-- ============================================================================
-- server_base/bridge/cl_game.lua
--
-- Framework + game adapter (client). The ONLY file in this resource that
-- knows the framework's player-loaded event name or calls ox_lib notify.
--
-- Core logic (client/main.lua) calls Game.* and nothing else. To port to
-- GTA VI, rewrite THIS FILE against the new framework's loaded event and the
-- new notification API. The welcome decision stays in the logic.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Game = {}

-- Register a callback fired once the player's character is loaded and in the
-- world. Hides the framework's loaded-event name.
--
-- qbx_core fires QBCore:Client:OnPlayerLoaded only AFTER the player has
-- actively selected a character in the multichar UI and that character has
-- spawned (verified in qbx_core client/character.lua), so the welcome shown
-- by the logic never fires before selection completes.
function Game.OnPlayerLoaded(handler)
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', handler)
end

-- Notify the local player.
function Game.Notify(opts)
    lib.notify(opts)
end

-- Teleport the local player to a point, loading the collision around the
-- destination first so they don't fall through an unstreamed map. Used only by
-- the admin /p6tp placement tool (verifying "VERIFY IN-GAME" anchors). Freezes
-- the ped while collision streams in, then releases and drops them onto ground.
function Game.Teleport(x, y, z)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityCoords(ped, x + 0.0, y + 0.0, z + 0.0, false, false, false, false)
    local tries = 0
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    while not HasCollisionLoadedAroundEntity(ped) and tries < 250 do
        RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
        Wait(10)
        tries = tries + 1
    end
    -- Settle onto the ground if a valid Z is found near the requested height.
    local found, groundZ = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 0.0, false)
    if found then
        SetEntityCoords(ped, x + 0.0, y + 0.0, groundZ + 0.0, false, false, false, false)
    end
    FreezeEntityPosition(ped, false)
    lib.notify({
        title = 'Placement',
        description = ('Teleported to %.2f, %.2f, %.2f'):format(x, y, z),
        type = 'inform',
    })
end
