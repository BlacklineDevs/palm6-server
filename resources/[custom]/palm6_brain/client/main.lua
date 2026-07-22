-- ============================================================================
-- palm6_brain/client/main.lua — Phase 0 ambient spawner (client-side, local peds).
--
-- One slow loop: for every scene, if the player is within SpawnDist and it isn't
-- populated yet, spawn its peds (ground-snapped, on a scenario); once the player
-- is past DespawnDist, delete them. Non-networked peds → each client populates
-- around itself, no OneSync, no sync cost. Everything is torn down on resource stop.
-- ============================================================================

local spawned = {}   -- sceneIndex -> { peds = { pedHandle, ... } }
-- Master "resource is active" flag. Set at load from the gate (so BOTH the scene
-- loop and the named-NPC loop see a stable value with no start-order race);
-- cleared on resource stop.
local running = (Config.Enabled == true)

local function dbg(msg) if Config.Debug then print('[palm6_brain] ' .. msg) end end

local function pick(t) return t[math.random(#t)] end

local function loadModel(model)
    local hash = (type(model) == 'number') and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do Wait(50); waited = waited + 50 end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- Snap a spawn point to the real ground height so an imprecise config z (or uneven
-- terrain) never leaves a ped floating or buried. Falls back to the given z if the
-- ground probe misses (e.g. the tile hasn't streamed — rare at SpawnDist range).
local function groundZ(x, y, z)
    local ok, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 3.0, false)
    return ok and gz or z
end

local function pedCount()
    local n = 0
    for _, s in pairs(spawned) do n = n + #s.peds end
    return n
end

local function spawnScene(i, scene)
    if spawned[i] then return end
    local peds = {}
    for _ = 1, (scene.count or 4) do
        if pedCount() + #peds >= Config.MaxPeds then break end   -- global pool guard
        local ang  = math.random() * math.pi * 2.0
        local dist = math.random() * (scene.radius or 10.0)
        local px = scene.x + math.cos(ang) * dist
        local py = scene.y + math.sin(ang) * dist
        local pz = groundZ(px, py, scene.z)
        local hash = loadModel(pick(scene.models or Config.ModelPool))
        if hash then
            local ped = CreatePed(4, hash, px, py, pz, math.random(0, 359) + 0.0, false, true)
            if ped and ped ~= 0 then
                SetEntityAsMissionEntity(ped, true, true)   -- engine won't cull it as ambient
                SetPedCanRagdollFromPlayerImpact(ped, true)
                -- Reactive peds flee danger; non-reactive stay locked to the scenario.
                SetBlockingOfNonTemporaryEvents(ped, not Config.Reactive)
                TaskStartScenarioInPlace(ped, pick(scene.scenarios or Config.ScenarioPool), 0, true)
                peds[#peds + 1] = ped
            end
            SetModelAsNoLongerNeeded(hash)
        end
    end
    spawned[i] = { peds = peds }
    dbg(('scene %s: spawned %d'):format(scene.label or i, #peds))
end

local function despawnScene(i)
    local s = spawned[i]
    if not s then return end
    for _, ped in ipairs(s.peds) do
        if DoesEntityExist(ped) then DeletePed(ped) end
    end
    spawned[i] = nil
    dbg('scene ' .. tostring(i) .. ': despawned')
end

local function clearAll()
    for i in pairs(spawned) do despawnScene(i) end
end

CreateThread(function()
    if not Config.Enabled then return end   -- dark-ship: nothing spawns while off
    running = true
    while running do
        local ped = PlayerPedId()
        local pc = (ped ~= 0) and GetEntityCoords(ped) or nil
        if pc then
            for i, scene in ipairs(Config.Scenes) do
                local d = #(pc - vector3(scene.x + 0.0, scene.y + 0.0, scene.z + 0.0))
                if d <= Config.SpawnDist and not spawned[i] then
                    spawnScene(i, scene)
                elseif d > Config.DespawnDist and spawned[i] then
                    despawnScene(i)
                end
            end
        end
        Wait(Config.TickMs or 2000)
    end
end)

-- ---------------------------------------------------------------------------
-- PHASE 1 — named NPCs you can talk to (stub brain; real LLM wires in server-side)
-- ---------------------------------------------------------------------------
local named = {}     -- id -> ped
local speech = {}    -- ped -> { text = , expire = }  (floating reply bubbles)
local speechThread = false

local function drawText3D(x, y, z, text)
    SetDrawOrigin(x + 0.0, y + 0.0, z + 0.0, 0)
    SetTextScale(0.34, 0.34)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

local function startSpeechThread()
    if speechThread then return end
    speechThread = true
    CreateThread(function()
        while speechThread do
            local now = GetGameTimer()
            local any = false
            for ped, b in pairs(speech) do
                if not DoesEntityExist(ped) or now > b.expire then
                    speech[ped] = nil
                else
                    any = true
                    local c = GetEntityCoords(ped)
                    drawText3D(c.x, c.y, c.z + 1.1, b.text)
                end
            end
            if not any then speechThread = false break end
            Wait(0)
        end
    end)
end

local function sayBubble(ped, text)
    if not (ped and DoesEntityExist(ped)) then return end
    speech[ped] = { text = text, expire = GetGameTimer() + math.floor((Config.BubbleSeconds or 7.0) * 1000) }
    startSpeechThread()
end

-- Server pushed an NPC's reply (stub canned line now; LLM later — same path).
RegisterNetEvent('palm6_brain:reply', function(npcId, text)
    local ped = named[npcId]
    if ped then sayBubble(ped, text) end
end)

-- ── World-state snapshot ────────────────────────────────────────────────────
-- Gathered client-side (the client owns the game clock, weather, and knows who's
-- rendered nearby) and sent along with the player's line so the NPC can answer
-- "what time is it / what day / what's the weather / anyone around". This is FLAVOR
-- only — a spoofed value just makes an NPC say the wrong time, no security impact,
-- so it's trusted as-is on the server. Kept tiny to stay cheap in the LLM context.
local DAYS = { [0]='Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday' }
local MONTHS = { [0]='January','February','March','April','May','June','July',
                 'August','September','October','November','December' }

-- Map the standard GTA weather hashes to plain-English labels. Built once at load
-- (joaat of each name) so we can reverse-lookup GetPrevWeatherTypeHashName().
local WEATHER_LABEL = {}
do
    local m = {
        EXTRASUNNY = 'clear and hot', CLEAR = 'clear', NEUTRAL = 'clear',
        CLOUDS = 'cloudy', OVERCAST = 'overcast', SMOG = 'smoggy', FOGGY = 'foggy',
        RAIN = 'raining', CLEARING = 'clearing up', THUNDER = 'a thunderstorm',
        SNOW = 'snowing', SNOWLIGHT = 'snowing', BLIZZARD = 'a blizzard', XMAS = 'snowy',
        HALLOWEEN = 'eerie',
    }
    for name, label in pairs(m) do WEATHER_LABEL[joaat(name)] = label end
end

local function weatherLabel()
    local ok, hash = pcall(GetPrevWeatherTypeHashName)
    if ok and hash then return WEATHER_LABEL[hash] end
    return nil
end

-- Rough "people around": real players rendered within 60m of me (excludes self).
local function nearbyPlayers()
    local me = PlayerPedId()
    local mc = GetEntityCoords(me)
    local n = 0
    for _, pl in ipairs(GetActivePlayers()) do
        local pped = GetPlayerPed(pl)
        if pped ~= me and DoesEntityExist(pped) and #(GetEntityCoords(pped) - mc) < 60.0 then
            n = n + 1
        end
    end
    return n
end

local function worldContext()
    return {
        h    = GetClockHours(),
        m    = GetClockMinutes(),
        day  = DAYS[GetClockDayOfWeek()] or nil,
        dom  = GetClockDayOfMonth(),
        mon  = MONTHS[GetClockMonth()] or nil,
        wx   = weatherLabel(),
        near = nearbyPlayers(),
    }
end

local function openDialogue(npc, ped)
    local input = lib.inputDialog(('Talk to %s'):format(npc.name or 'NPC'), {
        { type = 'input', label = 'Say something', required = true, max = 200 },
    })
    if not input or not input[1] then return end
    -- still close enough?
    local p = PlayerPedId()
    if #(GetEntityCoords(p) - GetEntityCoords(ped)) > (Config.TalkRange or 3.0) + 1.0 then
        return
    end
    TriggerServerEvent('palm6_brain:say', npc.id, input[1], worldContext())
end

local hasTarget = GetResourceState('ox_target') == 'started'

local function spawnNamed(npc)
    if named[npc.id] then return end
    if pedCount() >= Config.MaxPeds then return end
    local hash = loadModel(npc.model)
    if not hash then return end
    local pz = groundZ(npc.x, npc.y, npc.z)
    local ped = CreatePed(4, hash, npc.x + 0.0, npc.y + 0.0, pz, (npc.heading or 0.0) + 0.0, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)  -- named NPCs stay put, don't wander off
    FreezeEntityPosition(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    TaskStartScenarioInPlace(ped, pick(npc.scenarios or Config.ScenarioPool), 0, true)
    named[npc.id] = ped
    if hasTarget then
        exports.ox_target:addLocalEntity(ped, { {
            name = 'palm6_brain_talk_' .. npc.id,
            icon = 'fa-solid fa-comment',
            label = ('Talk to %s'):format(npc.name or 'NPC'),
            distance = Config.TalkRange or 3.0,
            onSelect = function() openDialogue(npc, ped) end,
        } })
    end
    dbg('named spawned: ' .. npc.id)
end

local function despawnNamed(id)
    local ped = named[id]
    if not ped then return end
    if hasTarget and DoesEntityExist(ped) then pcall(function() exports.ox_target:removeLocalEntity(ped) end) end
    if DoesEntityExist(ped) then DeletePed(ped) end
    speech[ped] = nil
    named[id] = nil
end

-- Fold named-NPC materialisation into the same distance loop as scenes.
CreateThread(function()
    if not (Config.Enabled and Config.NamedEnabled) then return end
    while running ~= false do
        local ped = PlayerPedId()
        local pc = (ped ~= 0) and GetEntityCoords(ped) or nil
        if pc then
            for _, npc in ipairs(Config.NamedNpcs or {}) do
                local d = #(pc - vector3(npc.x + 0.0, npc.y + 0.0, npc.z + 0.0))
                if d <= Config.SpawnDist and not named[npc.id] then
                    spawnNamed(npc)
                elseif d > Config.DespawnDist and named[npc.id] then
                    despawnNamed(npc.id)
                end
            end
        end
        Wait(Config.TickMs or 2000)
    end
end)

-- /brainscene [label...] — prints a paste-ready scene block for wherever you're
-- standing, so ambient spots are captured from real positions, never guessed.
-- Add the printed line to Config.Scenes and redeploy. Coord-printer only (harmless).
RegisterCommand('brainscene', function(_src, args)
    local ped = PlayerPedId()
    if ped == 0 then return end
    local c = GetEntityCoords(ped)
    local label = (args[1] and table.concat(args, ' ')) or 'New scene'
    local line = ("    { label = '%s', x = %.1f, y = %.1f, z = %.1f, count = 6, radius = 12.0 },")
        :format(label:gsub("'", ""), c.x, c.y, c.z)
    print('[palm6_brain] paste into Config.Scenes:')
    print(line)
    if lib and lib.notify then
        lib.notify({ title = 'palm6_brain', description = 'Scene coords printed to F8 console.', type = 'inform' })
    end
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    running = false
    speechThread = false
    clearAll()                                   -- scene peds
    for id in pairs(named) do despawnNamed(id) end  -- named peds + their ox_target zones
end)
