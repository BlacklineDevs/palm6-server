-- ============================================================================
-- gtarp_mechanic/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA
-- natives or ox_lib UI. client/main.lua calls Game.* only, so the proximity
-- / prompt / repair logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Game = {}

-- Local player position as {x,y,z}.
function Game.GetPlayerCoords()
    local p = GetEntityCoords(PlayerPedId())
    return { x = p.x, y = p.y, z = p.z }
end

-- Distance in metres between two coord tables (accepts vector3 too).
function Game.DistanceBetween(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

-- Nearest vehicle to `coords` within `radius`, or nil. Excludes the
-- vehicle the local player is currently driving/riding in, if any.
function Game.GetClosestVehicle(coords, radius)
    local veh = GetClosestVehicle(coords.x, coords.y, coords.z, radius, 0, 70)
    if not veh or veh == 0 then return nil end
    return veh
end

-- {engine, body} health for a vehicle. Native max is ~1000.0 for both.
function Game.GetVehicleHealth(veh)
    return {
        engine = GetVehicleEngineHealth(veh),
        body = GetVehicleBodyHealth(veh),
    }
end

-- Network id for a vehicle entity, for sending to the server.
function Game.GetVehicleNetId(veh)
    return NetworkGetNetworkIdFromEntity(veh)
end

-- Resolve a networked vehicle entity from its net id, or nil.
function Game.GetVehicleFromNetId(netId)
    if not NetworkDoesEntityExistWithNetworkId(netId) then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 then return nil end
    return veh
end

-- Show a "press ~key~" help prompt for the current frame.
function Game.ShowHelpThisFrame(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

-- Was the interact key (E / INPUT_PICKUP) pressed this frame?
function Game.InteractPressed()
    return IsControlJustReleased(0, 38)
end

-- Run a cancellable progress bar for `ms`. Returns true if completed.
function Game.ProgressBar(label, ms)
    return lib.progressBar({
        duration = ms,
        label = label,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })
end

-- Fully repair a vehicle's engine, body, and visible deformation. The repair
-- runs on the mechanic's client for a vehicle they may not own (the customer,
-- if seated, is the network owner), so request control first — otherwise the
-- SetVehicle* writes don't sync and the customer is charged for a car that
-- stays broken.
function Game.RepairVehicle(veh)
    if not NetworkHasControlOfEntity(veh) then
        NetworkRequestControlOfEntity(veh)
        local deadline = GetGameTimer() + 1000
        while not NetworkHasControlOfEntity(veh) and GetGameTimer() < deadline do
            Wait(0)
        end
    end
    SetVehicleFixed(veh)
    SetVehicleDeformationFixed(veh)
    SetVehicleUndriveable(veh, false)
    SetVehicleEngineHealth(veh, 1000.0)
    SetVehicleBodyHealth(veh, 1000.0)
end

-- Notify the local player.
function Game.Notify(opts)
    lib.notify(opts)
end
