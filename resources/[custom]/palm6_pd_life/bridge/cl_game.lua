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
-- character and can't be killed/dragged.
--
-- `seated` matters: a seated scenario (PROP_HUMAN_SEAT_*) needs the sit-down
-- animation to SETTLE the pelvis onto the chair. FreezeEntityPosition BEFORE that
-- settles pins the ped mid-stand (the "standing not sitting" + twitch/CPU glitch),
-- so seated peds are frozen only AFTER a short delay, once the sit has played.
function Game.SpawnScenarioPed(model, x, y, z, heading, scenario, seated)
    local hash = loadModel(model)
    if not hash then return nil end
    -- Spawn at the exact given Z (per-zone flat-floor value). No ground-snap:
    -- GetGroundZFor_3dCoord mis-fired on the multi-floor interior (dropped
    -- mezzanine peds to the lobby). Config Z values are the real floor per zone.
    -- Seated peds spawn at the SEAT surface, not the chair base: the furniture
    -- origin sits on the floor, but a seated pose anchors the ped's root, so
    -- spawning at floor Z drops the butt to the ground (the hunched/perched look).
    local zz = z + 0.0
    if seated then zz = zz + (Config.SeatHeight or 0.45) end
    local ped = CreatePed(4, hash, x + 0.0, y + 0.0, zz, heading + 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end
    SetEntityAsMissionEntity(ped, true, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedCanBeTargetted(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedKeepTask(ped, true)          -- hold the scenario instead of idling out
    SetPedConfigFlag(ped, 32, false)   -- CPED_CONFIG_FLAG_CanBeDraggedOut off
    SetPedConfigFlag(ped, 208, true)   -- disable writhe
    if scenario and scenario ~= '' then
        -- In-place always: the ped plays the scenario where it stands, never
        -- pathing off to hunt for a scenario prop (that hunt = the crowd churn).
        TaskStartScenarioInPlace(ped, scenario, 0, true)
    end
    if seated then
        -- Let the sit settle, then pin so it can't drift, re-heading in case the
        -- sit rotated it.
        CreateThread(function()
            Wait(1600)
            if DoesEntityExist(ped) then
                SetEntityHeading(ped, heading + 0.0)
                FreezeEntityPosition(ped, true)
            end
        end)
    else
        FreezeEntityPosition(ped, true)
    end
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

-- Distance from the local player to the station center (metres). Drives the
-- proximity gate that materialises / culls the scene.
function Game.DistToStation(cx, cy, cz)
    local p = GetEntityCoords(PlayerPedId())
    return #(vector3(p.x, p.y, p.z) - vector3(cx + 0.0, cy + 0.0, cz + 0.0))
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

-- ---------------------------------------------------------------------------
-- Duty layer (Phase B) natives. Everything the interactive post/sit/duty layer
-- touches on the client goes through these, keeping client/duty.lua native-free.
-- ---------------------------------------------------------------------------

local hasTarget = GetResourceState('ox_target') == 'started'

-- A proximity interaction at a fixed point. ox_target sphere when available,
-- else an ox_lib point with an E-prompt. Returns an opaque handle to remove.
function Game.CreateInteraction(id, coords, radius, label, icon, onSelect)
    if hasTarget then
        local zoneId = exports.ox_target:addSphereZone({
            coords = vector3(coords.x, coords.y, coords.z),
            radius = radius,
            options = {
                {
                    name = ('palm6_pd_life_%s'):format(id),
                    icon = icon or 'fas fa-user-shield',
                    label = label,
                    onSelect = onSelect,
                    distance = radius,
                },
            },
        })
        return { kind = 'target', zoneId = zoneId }
    end
    local point = lib.points.new({ coords = vector3(coords.x, coords.y, coords.z), distance = 12.0 })
    function point:nearby()
        if self.currentDistance < radius then
            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(('Press ~INPUT_PICKUP~ %s'):format(label))
            EndTextCommandDisplayHelp(0, false, true, -1)
            if IsControlJustReleased(0, 38) then onSelect() end
        end
    end
    return { kind = 'point', point = point }
end

function Game.RemoveInteraction(handle)
    if not handle then return end
    if handle.kind == 'target' and handle.zoneId then
        pcall(function() exports.ox_target:removeZone(handle.zoneId) end)
    elseif handle.kind == 'point' and handle.point and handle.point.remove then
        handle.point:remove()
    end
end

-- The local player's job name + duty flag (menu UX only; server is the gate).
function Game.PlayerJob()
    local ok, pd = pcall(function() return exports.qbx_core:GetPlayerData() end)
    local job = ok and pd and pd.job or nil
    if not job then return nil, false end
    return job.name, job.onduty == true
end

-- Seat/stand the local player at a manned post and run its scenario. Snaps to
-- the exact baked post coord+heading, then plays the scenario in place.
function Game.EnterPostPose(x, y, z, heading, scenario)
    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetEntityHeading(ped, heading + 0.0)
    Wait(50)
    if scenario and scenario ~= '' then
        TaskStartScenarioInPlace(ped, scenario, 0, true)
    end
end

function Game.ExitPostPose()
    ClearPedTasksImmediately(PlayerPedId())
end

-- Sit the local player on a targeted chair entity (generic /sit via ox_target).
function Game.SitOnEntity(entity, scenario)
    if not entity or not DoesEntityExist(entity) then return end
    local ped = PlayerPedId()
    local c = GetEntityCoords(entity)
    local h = GetEntityHeading(entity)
    ClearPedTasksImmediately(ped)
    SetEntityCoordsNoOffset(ped, c.x, c.y, c.z + 0.1, false, false, false)
    SetEntityHeading(ped, h + 180.0)   -- face away from the chair back
    Wait(50)
    TaskStartScenarioInPlace(ped, scenario or 'PROP_HUMAN_SEAT_CHAIR_MP', 0, true)
end

-- ox_target on chair MODELS so any such chair in the world is sittable.
function Game.AddSitModels(models, onSelect)
    if not hasTarget or not models or #models == 0 then return false end
    exports.ox_target:addModel(models, {
        {
            name = 'palm6_pd_life_sit',
            icon = 'fas fa-chair',
            label = 'Sit',
            distance = 1.6,
            onSelect = onSelect,
        },
    })
    return true
end

-- Remove the sit option from those models (teardown). removeModel takes the
-- models + the option name, per ox_target (see ox_inventory_overrides).
function Game.RemoveSitModels(models)
    if not hasTarget or not models then return end
    pcall(function() exports.ox_target:removeModel(models, 'palm6_pd_life_sit') end)
end
