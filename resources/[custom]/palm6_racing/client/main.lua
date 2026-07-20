-- ============================================================================
-- palm6_racing/client/main.lua
--
-- Presentation only: race meet blip + organizer NPC, the countdown, the checkpoint
-- marker/detection loop, and the race HUD. Calls Game.* for every native. The
-- server owns all authority (progress order, finish, rep) — a modified client only
-- picks WHEN to claim a checkpoint, which the server re-validates by coords + order.
-- ============================================================================

local race = nil   -- { raceId, checkpoints, radius, nextIndex, total, pending, pendingAt }
local lastHud = nil

local function enabledClient() return Config and Config.Enabled == true end

local function clearRace()
    race = nil
    lastHud = nil
    Game.HideHud()
    Game.ClearRoute()
end

-- Lobby update (grid size / status).
RegisterNetEvent('palm6_racing:lobby', function(d)
    if type(d) ~= 'table' then return end
    Game.Notify({
        title = 'Racing',
        description = ('%s — %d on the grid. Host: /racego to launch.'):format(d.routeName or 'Race', d.grid and #d.grid or 1),
        type = 'inform',
    })
end)

-- Race start: countdown, then run the checkpoint loop from the first real CP.
RegisterNetEvent('palm6_racing:start', function(d)
    if type(d) ~= 'table' or type(d.checkpoints) ~= 'table' or #d.checkpoints < 2 then return end
    local cd = tonumber(d.countdown) or 5
    race = {
        raceId = d.raceId, checkpoints = d.checkpoints, radius = tonumber(d.radius) or 15.0,
        nextIndex = 2, total = #d.checkpoints, pending = false, pendingAt = 0,
    }

    CreateThread(function()
        for i = cd, 1, -1 do
            Game.Notify({ title = 'Race', description = tostring(i), type = 'inform', duration = 900 })
            Wait(1000)
        end
        Game.Notify({ title = 'Race', description = 'GO!', type = 'success', duration = 1200 })
    end)

    -- Detection loop starts AFTER the countdown so pre-GO positions never count.
    CreateThread(function()
        Wait(cd * 1000)
        if not race or race.raceId ~= d.raceId then return end
        Game.RouteTo(race.checkpoints[race.nextIndex])
        while race and race.raceId == d.raceId do
            local cp = race.checkpoints[race.nextIndex]
            if not cp then
                Game.HideHud(); lastHud = nil
                break                                          -- past the finish -> stop polling
            end
            Game.DrawCheckpoint(cp, race.radius)
            local hud = ('CP %d/%d'):format(race.nextIndex - 1, race.total - 1)
            if hud ~= lastHud then Game.ShowHud(hud); lastHud = hud end

            local pc = Game.LocalCoords()
            if pc and Game.Dist(pc, cp) <= race.radius and not race.pending then
                race.pending = true
                race.pendingAt = GetGameTimer()
                TriggerServerEvent('palm6_racing:checkpoint', { raceId = race.raceId, cpIndex = race.nextIndex })
            elseif race.pending and (GetGameTimer() - race.pendingAt) > 3000 then
                race.pending = false   -- server never acked (lag / transient reject) -> allow a retry
            end
            Wait(0)
        end
    end)
end)

-- Server confirmed a checkpoint -> advance to the next (authoritative).
RegisterNetEvent('palm6_racing:cpAck', function(d)
    if type(d) ~= 'table' or not race or race.raceId ~= d.raceId then return end
    race.nextIndex = tonumber(d.next) or race.nextIndex
    race.pending = false
    local cp = race.checkpoints[race.nextIndex]
    if cp then Game.RouteTo(cp) end
end)

RegisterNetEvent('palm6_racing:result', function(d)
    if type(d) ~= 'table' then return end
    local msg = d.finished
        and ('Finished P%d of %d — %s'):format(d.place or 0, d.fieldSize or 0, d.routeName or '')
        or  'Did not finish.'
    Game.Notify({ title = 'Race Result', description = msg, type = (d.place == 1) and 'success' or 'inform', duration = 6000 })
end)

RegisterNetEvent('palm6_racing:teardown', function()
    clearRace()
end)

-- ---------------------------------------------------------------------------
-- Race meet: blip + organizer NPC (only when enabled — prod-inert otherwise).
-- ---------------------------------------------------------------------------
local organizerPed, organizerHandle, meetBlip

local function openOrganizer()
    local routeNames = {}
    for _, r in ipairs(Config.Routes or {}) do routeNames[#routeNames + 1] = r.name end
    Game.OpenMenu('palm6_race_organizer', 'Street Racing', {
        { title = '1. Get in a car at the meet', description = 'You need to be driving to start or join.',
          icon = 'fa-solid fa-car', disabled = true },
        { title = '2. /startrace to open a race', description = 'Others /joinrace during the window; host /racego to launch.',
          icon = 'fa-solid fa-flag-checkered', disabled = true },
        { title = '3. First across the line wins rep', description = 'Climb the leaderboard — /racetop.',
          icon = 'fa-solid fa-trophy', disabled = true },
        { title = 'Routes', description = (#routeNames > 0 and table.concat(routeNames, ', ')) or 'none configured',
          icon = 'fa-solid fa-route', disabled = true },
    })
end

CreateThread(function()
    Wait(1500)   -- let Config + exports settle
    if not enabledClient() then return end
    if Config.Meet then meetBlip = Game.AddBlip(Config.Meet.coords, Config.Blip) end
    if Config.Organizer then
        organizerPed = Game.SpawnPed(Config.Organizer.model, Config.Organizer.coords, Config.Organizer.heading)
        if organizerPed then
            organizerHandle = Game.AddPedInteraction(organizerPed, Config.Organizer.coords,
                Config.Organizer.label, Config.Organizer.icon, openOrganizer)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearRace()
    Game.RemoveInteraction(organizerHandle)
    Game.DeletePed(organizerPed)
    Game.RemoveBlip(meetBlip)
end)
