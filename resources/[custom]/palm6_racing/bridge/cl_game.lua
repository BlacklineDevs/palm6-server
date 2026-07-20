-- ============================================================================
-- palm6_racing/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file here that calls GTA natives / ox_target /
-- ox_lib UI. client/main.lua calls Game.* only. Presentation + local markers;
-- the server owns all race authority (progress, order, rep).
-- ============================================================================

Game = {}

local hasTarget = GetResourceState('ox_target') == 'started'

function Game.LocalCoords()
    local ped = PlayerPedId()
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Game.Dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Game.Notify(opts) lib.notify(opts) end

function Game.OpenMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

function Game.AddBlip(coords, cfg)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, cfg.sprite or 315)
    SetBlipColour(b, cfg.color or 5)
    SetBlipScale(b, cfg.scale or 0.9)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(cfg.label or 'Racing')
    EndTextCommandSetBlipName(b)
    return b
end

function Game.RemoveBlip(b) if b then RemoveBlip(b) end end

function Game.SpawnPed(model, coords, heading)
    local hash = joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local dl = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(20) end
    if not HasModelLoaded(hash) then return nil end
    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, heading or 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityAsMissionEntity(ped, true, true)
    return ped
end

function Game.DeletePed(ped)
    if ped and DoesEntityExist(ped) then SetEntityAsMissionEntity(ped, true, true); DeletePed(ped) end
end

-- ox_target eye on the organizer ped, with an ox_lib marker+E fallback if ox_target
-- is absent. Returns a handle table for cleanup.
function Game.AddPedInteraction(ped, coords, label, icon, onSelect)
    if hasTarget then
        exports.ox_target:addLocalEntity(ped, {
            { name = 'palm6_racing_organizer', icon = icon or 'fa-solid fa-flag-checkered',
              label = label or 'Race organizer', distance = 2.5, onSelect = onSelect },
        })
        return { ped = ped, target = true }
    end
    local handle = { coords = coords, onSelect = onSelect, active = true }
    CreateThread(function()
        while handle.active do
            local sleep = 1000
            local pc = Game.LocalCoords()
            if pc and Game.Dist(pc, coords) < 2.5 then
                sleep = 0
                lib.showTextUI(('[E] %s'):format(label or 'Race organizer'))
                if IsControlJustReleased(0, 38) then handle.onSelect() end
            else
                lib.hideTextUI()
            end
            Wait(sleep)
        end
        lib.hideTextUI()
    end)
    return handle
end

function Game.RemoveInteraction(handle)
    if not handle then return end
    if handle.target and handle.ped then pcall(function() exports.ox_target:removeLocalEntity(handle.ped, 'palm6_racing_organizer') end)
    else handle.active = false end
end

-- Draw a checkpoint cylinder marker at coords (call every frame while racing).
function Game.DrawCheckpoint(coords, radius)
    DrawMarker(1, coords.x, coords.y, coords.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        (radius or 15.0) * 2.0, (radius or 15.0) * 2.0, 3.0, 90, 160, 255, 120, false, false, 2, false, nil, nil, false)
end

-- Set the map GPS route to the next checkpoint (clears the prior one).
function Game.RouteTo(coords)
    SetNewWaypoint(coords.x, coords.y)
end
function Game.ClearRoute()
    -- clearing the waypoint is enough; leaving it is harmless if teardown missed.
    local wp = GetFirstBlipInfoId(8)
    if DoesBlipExist(wp) then RemoveBlip(wp) end
end

-- Lightweight race HUD line (top-center). Uses ox_lib textUI so no per-frame draw.
function Game.ShowHud(text) lib.showTextUI(text, { position = 'top-center' }) end
function Game.HideHud() lib.hideTextUI() end
