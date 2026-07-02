-- ============================================================================
-- gtarp_turf/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA
-- natives or ox_lib UI. client/main.lua calls Game.* only, so the
-- proximity / tag / blip / leaderboard logic ports to GTA VI by rewriting
-- THIS FILE. See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
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

-- Create (or replace) a zone blip. Returns the blip handle.
function Game.SetZoneBlip(coords, label, colour, sprite, scale)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, sprite or 84)
    SetBlipColour(b, colour or 0)
    SetBlipScale(b, scale or 0.8)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or 'Turf')
    EndTextCommandSetBlipName(b)
    return b
end

function Game.RemoveBlip(handle)
    if handle and DoesBlipExist(handle) then RemoveBlip(handle) end
end

-- Show a read-only text dialog (the turf leaderboard).
function Game.ShowLogDialog(title, content)
    lib.alertDialog({
        header = title,
        content = content,
        centered = true,
        cancel = false,
    })
end

-- Notify the local player.
function Game.Notify(opts)
    lib.notify(opts)
end

-- Fire `handler` once the local player's character has finished loading.
function Game.OnPlayerLoaded(handler)
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', handler)
end
