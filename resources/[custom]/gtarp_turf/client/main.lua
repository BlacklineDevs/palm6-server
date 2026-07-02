-- ============================================================================
-- gtarp_turf/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all native access.
-- No direct natives / ox_lib here (§6 gate). Server is authoritative on the
-- gang gate, proximity, and ownership flip — this is UI + prompts + blips.
-- ============================================================================

local zones = {}
local blips = {}

local function requestSync()
    TriggerServerEvent('gtarp_turf:requestSync')
end

local function refreshBlips()
    for _, b in pairs(blips) do Game.RemoveBlip(b) end
    blips = {}
    for id, z in pairs(zones) do
        local colour = z.owner_gang and Config.ClaimedColour or Config.UnclaimedColour
        local label = z.owner_gang and ('%s (%s)'):format(z.label, z.owner_gang) or ('%s (unclaimed)'):format(z.label)
        blips[id] = Game.SetZoneBlip(z.coords, label, colour, Config.BlipSprite, Config.BlipScale)
    end
end

Game.OnPlayerLoaded(requestSync)
CreateThread(requestSync)  -- covers resource restarts while already in-game

RegisterNetEvent('gtarp_turf:syncZones', function(data)
    zones = data or {}
    refreshBlips()
end)

CreateThread(function()
    while true do
        local wait = 750
        local coords = Game.GetPlayerCoords()
        for id, z in pairs(zones) do
            if Game.DistanceBetween(coords, z.coords) <= Config.InteractRadius then
                wait = 0
                Game.ShowHelpThisFrame(('Press ~INPUT_PICKUP~ to tag %s for your gang'):format(z.label))
                if Game.InteractPressed() then
                    TriggerServerEvent('gtarp_turf:requestTag', id)
                end
            end
        end
        Wait(wait)
    end
end)

RegisterNetEvent('gtarp_turf:begin', function(payload)
    local ok = Game.ProgressBar('Tagging ' .. payload.label .. '...', Config.TagProgressMs)
    if ok then
        TriggerServerEvent('gtarp_turf:complete', payload.zoneId)
    else
        TriggerServerEvent('gtarp_turf:cancel', payload.zoneId)
    end
end)

RegisterNetEvent('gtarp_turf:showLog', function(content)
    Game.ShowLogDialog('Turf Standings', content)
end)
