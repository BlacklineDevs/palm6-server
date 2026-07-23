-- ============================================================================
-- palm6_pd_life/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file that calls GTA natives. client/main.lua
-- calls Game.* and nothing else, so this ports to GTA VI by rewriting THIS file.
-- ============================================================================

Game = {}

-- Load a model with a bounded wait; returns the hash or nil on timeout.
local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 300 do
        RequestModel(hash)
        Wait(10)
        tries = tries + 1
    end
    return HasModelLoaded(hash) and hash or nil
end

-- Spawn a stationary scene ped running a scenario. Client-LOCAL (each client owns
-- its own copy, non-networked) so the scene is free of server sync cost. The ped
-- ignores the player and gunfire (SetBlockingOfNonTemporaryEvents) so it stays in
-- character, can't be killed/dragged, and (if freeze) is pinned in place.
function Game.SpawnScenarioPed(model, x, y, z, heading, scenario, freeze)
    local hash = loadModel(model)
    if not hash then return nil end
    -- Spawn at the exact given Z (per-zone flat-floor value). No ground-snap:
    -- GetGroundZFor_3dCoord mis-fired on the multi-floor interior (dropped
    -- mezzanine peds to the lobby). Config Z values are the real floor per zone.
    local ped = CreatePed(4, hash, x + 0.0, y + 0.0, z + 0.0, heading + 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end
    SetEntityAsMissionEntity(ped, true, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedCanBeTargetted(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedConfigFlag(ped, 32, false)   -- CPED_CONFIG_FLAG_CanBeDraggedOut off
    SetPedConfigFlag(ped, 208, true)   -- disable writhe
    if scenario and scenario ~= '' then
        if freeze then
            TaskStartScenarioInPlace(ped, scenario, 0, true)
        else
            TaskStartScenarioAtPosition(ped, scenario, x + 0.0, y + 0.0, z + 0.0, heading + 0.0, 0, true, true)
        end
    end
    if freeze then FreezeEntityPosition(ped, true) end
    return ped
end

function Game.DeletePed(ped)
    if ped and DoesEntityExist(ped) then
        SetEntityAsMissionEntity(ped, true, true)
        DeletePed(ped)
    end
end

-- Local player pose for the /pdnpc placement tool.
function Game.PlayerPose()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    return c.x, c.y, c.z, GetEntityHeading(ped)
end

function Game.Notify(msg)
    if lib and lib.notify then
        lib.notify({ title = 'PD Life', description = msg, type = 'inform' })
    end
end

-- Echo a line into the chat box (used to surface a placed NPC's baked coord).
function Game.Chat(tag, line)
    TriggerEvent('chat:addMessage', { args = { tag, line } })
end
