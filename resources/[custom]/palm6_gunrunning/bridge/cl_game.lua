-- ============================================================================
-- palm6_gunrunning/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA natives,
-- ox_target, or ox_lib UI. client/main.lua calls Game.* only, so the dealer
-- (ped, blip, menu) ports to GTA VI by rewriting THIS FILE. The client is
-- presentation-only: buying fires a server event that re-runs all authority
-- (proximity, price, charge, grant), so nothing here is security-sensitive.
-- Mirrors palm6_lottery/bridge/cl_game.lua (the proven kiosk template).
-- ============================================================================

Game = {}

local hasTarget = GetResourceState('ox_target') == 'started'
local INTERACT_RADIUS = 2.5

-- Permanent short-range map blip.
function Game.AddBlip(coords, opts)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, opts.sprite)
    SetBlipColour(blip, opts.color)
    SetBlipScale(blip, opts.scale)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(opts.label)
    EndTextCommandSetBlipName(blip)
    return blip
end

function Game.RemoveBlip(handle)
    if handle and DoesBlipExist(handle) then RemoveBlip(handle) end
end

-- Spawn a frozen, invincible, non-reactive NPC. Returns the ped handle or nil.
function Game.SpawnPed(model, coords, heading)
    local hash = joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(50) end
    if not HasModelLoaded(hash) then return nil end
    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, heading or 0.0, false, true)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetModelAsNoLongerNeeded(hash)
    return ped
end

function Game.DeletePed(ped)
    if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
end

-- Interaction on a ped: ox_target entity eye when present, else a marker + E
-- prompt (poll only while inside the radius). Returns an opaque handle.
function Game.AddPedInteraction(ped, coords, label, icon, onSelect)
    if hasTarget and ped then
        exports.ox_target:addLocalEntity(ped, {
            {
                name = 'palm6_gunrunning_dealer',
                icon = icon or 'fa-solid fa-gun',
                label = label,
                onSelect = onSelect,
                distance = INTERACT_RADIUS,
            },
        })
        return { kind = 'target', ped = ped }
    end

    local point = lib.points.new({
        coords = vector3(coords.x, coords.y, coords.z),
        distance = 12.0,
    })
    function point:nearby()
        if self.currentDistance < INTERACT_RADIUS then
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
    if handle.kind == 'target' and handle.ped then
        pcall(function() exports.ox_target:removeLocalEntity(handle.ped) end)
    elseif handle.kind == 'point' and handle.point and handle.point.remove then
        handle.point:remove()
    end
end

-- ox_lib context menu. options = { { title, description, icon, onSelect=fn }, ... }.
function Game.OpenMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

-- Notify the local player. opts = { title, description, type }.
function Game.Notify(opts)
    lib.notify(opts)
end
