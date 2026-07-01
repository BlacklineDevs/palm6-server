-- ============================================================================
-- gtarp_housing/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA
-- natives (blips, coords, teleport/fade, help prompts) or ox_lib notify.
-- client/main.lua calls Game.* only. To port to GTA VI, rewrite THIS FILE
-- against the new natives; the proximity/interaction logic is untouched.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Game = {}

-- Local player position as {x,y,z}.
function Game.GetPlayerCoords()
    local p = GetEntityCoords(PlayerPedId())
    return { x = p.x, y = p.y, z = p.z }
end

-- Distance in metres between two {x,y,z} tables.
function Game.DistanceBetween(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

-- Create a map blip at {x,y,z}. Returns the handle.
function Game.CreateBlip(coords, sprite, colour, scale, label)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, sprite or 40)
    SetBlipColour(b, colour or 0)
    SetBlipScale(b, scale or 0.8)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or 'Property')
    EndTextCommandSetBlipName(b)
    return b
end

-- Remove a blip handle if set.
function Game.RemoveBlip(handle)
    if handle then RemoveBlip(handle) end
end

-- Teleport the player to a {x,y,z,w} point behind a fade, waiting for
-- collision to stream in. Used for entering shells and returning to the door.
function Game.TeleportWithFade(point)
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end
    DoScreenFadeOut(250)
    while not IsScreenFadedOut() do Wait(0) end
    SetEntityCoords(ped, point.x, point.y, point.z, false, false, false, false)
    SetEntityHeading(ped, point.w or 0.0)
    FreezeEntityPosition(ped, true)
    local tries = 0
    while not HasCollisionLoadedAroundEntity(ped) and tries < 200 do
        Wait(50); tries = tries + 1
    end
    FreezeEntityPosition(ped, false)
    DoScreenFadeIn(500)
end

-- Show a "press ~key~" help prompt for the current frame. Call every frame
-- while the player is in range (the logic owns the loop).
function Game.ShowHelpThisFrame(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

-- Was the interact key (E / INPUT_PICKUP) pressed this frame?
function Game.InteractPressed()
    return IsControlJustReleased(0, 38)
end

-- Notify the local player.
function Game.Notify(opts)
    lib.notify(opts)
end

-- Yes/no dialog. Returns true if confirmed.
function Game.Confirm(title, msg)
    return lib.alertDialog({
        header = title, content = msg, centered = true, cancel = true,
    }) == 'confirm'
end

-- Show a context menu. `options` is a list of { title, description, onSelect }.
function Game.ContextMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

-- Server id of the nearest other player within `maxDist` metres, or nil.
function Game.GetNearestPlayerServerId(maxDist)
    local me = PlayerPedId()
    local myPos = GetEntityCoords(me)
    local best, bestD = nil, (maxDist or 5.0)
    for _, pl in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(pl)
        if ped ~= me and ped ~= 0 then
            local d = #(myPos - GetEntityCoords(ped))
            if d < bestD then best, bestD = pl, d end
        end
    end
    return best and GetPlayerServerId(best) or nil
end

-- Open an ox_inventory stash by id.
function Game.OpenStash(id)
    exports.ox_inventory:openInventory('stash', id)
end
