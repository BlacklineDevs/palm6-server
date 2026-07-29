-- ============================================================================
-- palm6_turf/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all native access.
-- No direct natives / ox_lib here (§6 gate). Server is authoritative on the
-- gang gate, proximity, and ownership flip — this is UI + prompts + blips.
-- ============================================================================

local zones = {}
local blips = {}

local function requestSync()
    TriggerServerEvent('palm6_turf:requestSync')
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

-- Request the sync a beat after load. Firing it during the join/connect race
-- (the instant OnPlayerLoaded fires, or immediately on client resource start)
-- reaches the server before the client is marked net-safe, so the server drops
-- it as "palm6_turf:requestSync was not safe for net" and the blips do not sync.
-- The short wait lets the session settle. Covers both a fresh join (OnPlayerLoaded)
-- and a resource restart while already in-game (the standalone thread).
local function requestSyncSoon()
    CreateThread(function()
        Wait(2000)
        requestSync()
    end)
end

Game.OnPlayerLoaded(requestSyncSoon)
requestSyncSoon()  -- covers resource restarts while already in-game

RegisterNetEvent('palm6_turf:syncZones', function(data)
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
                -- With the conflict flag ON, an owned zone no longer promises an
                -- instant claim, so the prompt names the current holder instead.
                -- It deliberately does NOT say "contest": the client has no view
                -- of the player's own gang, so it cannot tell a rival's turf
                -- from your own, and promising a contest on turf your gang
                -- already holds is a lie the server immediately contradicts
                -- ("Your gang already holds this turf"). "Tag" is true in every
                -- case, because the tag action is what the button does; the
                -- server alone decides what the tag then means.
                --
                -- 'none' is the unowned sentinel the server treats as
                -- unclaimed (server/main.lua only opens a contest when
                -- owner_gang is neither nil nor 'none'), so it must fall to the
                -- unclaimed wording here too rather than read "held by none".
                -- Unowned zones, and the entire disabled path, keep the original
                -- wording exactly. Cosmetic only: the server decides everything.
                if Config.Conflict and Config.Conflict.Enabled
                    and z.owner_gang and z.owner_gang ~= 'none' then
                    Game.ShowHelpThisFrame(('Press ~INPUT_PICKUP~ to tag %s (held by %s)')
                        :format(z.label, z.owner_gang))
                else
                    Game.ShowHelpThisFrame(('Press ~INPUT_PICKUP~ to tag %s for your gang'):format(z.label))
                end
                if Game.InteractPressed() then
                    TriggerServerEvent('palm6_turf:requestTag', id)
                end
            end
        end
        Wait(wait)
    end
end)

RegisterNetEvent('palm6_turf:begin', function(payload)
    local ok = Game.ProgressBar('Tagging ' .. payload.label .. '...', Config.TagProgressMs)
    if ok then
        TriggerServerEvent('palm6_turf:complete', payload.zoneId)
    else
        TriggerServerEvent('palm6_turf:cancel', payload.zoneId)
    end
end)

RegisterNetEvent('palm6_turf:showLog', function(content)
    Game.ShowLogDialog('Turf Standings', content)
end)
