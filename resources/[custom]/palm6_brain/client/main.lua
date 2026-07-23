-- ============================================================================
-- palm6_brain/client/main.lua — Phase 0 ambient spawner (client-side, local peds).
--
-- One slow loop: for every scene, if the player is within SpawnDist and it isn't
-- populated yet, spawn its peds (ground-snapped, on a scenario); once the player
-- is past DespawnDist, delete them. Non-networked peds → each client populates
-- around itself, no OneSync, no sync cost. Everything is torn down on resource stop.
-- ============================================================================

local spawned = {}   -- sceneIndex -> { peds = { pedHandle, ... } }
local movers  = {}   -- moverId -> { ped, taskKey, move }  (Phase 2b Director-driven extras)
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
    for _ in pairs(movers) do n = n + 1 end   -- Director movers share the pool guard
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

-- ===========================================================================
-- PHASE 2b — CLIENT EXECUTOR: actuate the Director's goals on MOVER peds.
--
-- Movers (Config.Movers) are anonymous CLIENT-LOCAL peds. Each client
-- materialises its own copy near a mover's home scene and applies whatever goal
-- the server Director broadcast for that mover id. Because they are local &
-- anonymous, slight per-client desync is invisible and there is zero OneSync
-- cost. Named NPCs are NEVER driven here (they are stationary anchors and the
-- Director cannot even issue them a goal).
--
-- Every locomotion task carries a TIMEOUT + STUCK-detection + ARRIVAL check, and
-- every failure path falls back to wander — a mover can never hang on a broken
-- navmesh path (the roadmap's "every compound action needs a timeout + fallback").
-- Goals also self-expire client-side (goal.expiresAt is real epoch, same clock as
-- the server), so a missed clear-broadcast still degrades a mover back to ambient
-- wander. Materialisation is gated on Config.Director.Enabled, so the whole
-- system is inert until the Director is lit — dark-ship like everything else.
-- ===========================================================================
local moverGoal = {}    -- moverId -> { verb, target, amount, expiresAt }  (latest broadcast)
local moverIds  = {}    -- set of valid mover ids (defensive filter on the broadcast)
for _, m in ipairs(Config.Movers or {}) do if m.id then moverIds[m.id] = true end end

-- scene label -> anchor coords; goTo/queueAt targets and mover homes resolve here.
local sceneCoord = {}
for _, s in ipairs(Config.Scenes or {}) do
    if s.label then sceneCoord[s.label] = vector3(s.x + 0.0, s.y + 0.0, s.z + 0.0) end
end

-- Director broadcast sink: store/clear the latest goal for a mover. Ignores any
-- id that is not a mover (named anchors, junk) and any malformed payload.
RegisterNetEvent('palm6_brain:goal', function(npcId, goal)
    if not moverIds[npcId] then return end
    if goal == false or goal == nil then
        moverGoal[npcId] = nil
    elseif type(goal) == 'table' and type(goal.verb) == 'string' then
        -- Stamp a MONOTONIC client deadline from the server-side DURATION
        -- (expiresAt - issuedAt is a difference of two SERVER epochs, so it's
        -- clock-independent) plus our own GetGameTimer(). Never compare our
        -- wall-clock to a server epoch — a mis-set client clock would otherwise
        -- expire goals instantly or never (audit M2).
        local dur = (tonumber(goal.expiresAt) or 0) - (tonumber(goal.issuedAt) or 0)
        if dur <= 0 then dur = 120 end   -- fallback if the fields are missing
        goal._deadline = GetGameTimer() + dur * 1000
        moverGoal[npcId] = goal
    end
end)

-- Police dispatch renderer. The server sends palm6_brain:dispatch ONLY to on-duty
-- officers (see bridge/sv_framework.lua), so only cops ever see this. Draws a
-- temporary routed blip + a 911 notify, matching palm6_robbery's dispatch look;
-- the blip auto-removes after its TTL. Purely visual — no gameplay effect.
local dispatchBlips = {}   -- active dispatch blips, so onResourceStop can clear them (audit L2)
RegisterNetEvent('palm6_brain:dispatch', function(d)
    if type(d) ~= 'table' or type(d.coords) ~= 'table' then return end
    local b = AddBlipForCoord(d.coords.x + 0.0, d.coords.y + 0.0, d.coords.z + 0.0)
    SetBlipSprite(b, d.sprite or 161)
    SetBlipColour(b, d.colour or 1)
    SetBlipScale(b, d.scale or 1.2)
    SetBlipAsShortRange(b, false)
    SetBlipRoute(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(d.label or 'Dispatch')
    EndTextCommandSetBlipName(b)
    dispatchBlips[b] = true
    if lib and lib.notify then
        lib.notify({ title = '911 Dispatch', description = d.label or 'Reported incident', type = 'inform' })
    end
    SetTimeout((d.duration or 90) * 1000, function()
        if DoesBlipExist(b) then RemoveBlip(b) end
        dispatchBlips[b] = nil
    end)
end)

-- Start the ped task for a goal verb. Locomotion verbs record a `move` monitor;
-- everything else is a one-shot task. Unknown/ungated verbs fall through to a
-- safe idle so no verb is ever unhandled.
local function startTask(mv, ped, goal, verb)
    ClearPedTasks(ped)
    mv.move = nil
    if verb == 'goTo' or verb == 'queueAt' or verb == 'orderAt' then
        -- all three walk to a place; queueAt/orderAt linger there as a customer
        local dst = goal and goal.target and sceneCoord[goal.target]
        if dst then
            TaskFollowNavMeshToCoord(ped, dst.x, dst.y, dst.z, 1.0, 20000, 1.5, false, 0.0)
            mv.move = { dst = dst, deadline = GetGameTimer() + 20000,
                        lastPos = GetEntityCoords(ped), lastMoveAt = GetGameTimer(),
                        after = (verb == 'goTo') and 'idle' or 'queue' }
        else
            TaskWanderStandard(ped, 10.0, 10)   -- unknown place -> just wander
        end
    elseif verb == 'talkTo' or verb == 'buyFrom' then
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 2000)   -- client-local flavour of "talk"/"buy"
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_MOBILE', 0, true)
    elseif verb == 'wander' then
        TaskWanderStandard(ped, 10.0, 10)
    elseif verb == 'rob' or verb == 'attack' or verb == 'deal' then
        -- Theater only: face the player and hold an agitated stance. The REAL
        -- signal is the 911 dispatch the server fires; the ped never actually
        -- fights (keeps it non-janky and safe). Inert until CrimeEnabled is on.
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 1500)
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    else   -- idle / flee / complyWithPolice / anything else -> stand and idle
        TaskStartScenarioInPlace(ped, pick(Config.ScenarioPool), 0, true)
    end
end

-- Monitor an in-progress move: arrive -> settle into a scenario; stuck or timed
-- out -> abandon to wander. Never retries a broken path (avoids task thrash).
local function monitorMove(mv, ped)
    local m = mv.move
    if not m then return end
    local pos = GetEntityCoords(ped)
    local now = GetGameTimer()
    if #(pos - m.dst) < 2.0 then                       -- arrived
        ClearPedTasks(ped)
        TaskStartScenarioInPlace(ped,
            m.after == 'queue' and 'WORLD_HUMAN_STAND_IMPATIENT' or pick(Config.ScenarioPool), 0, true)
        mv.move = nil
        return
    end
    if #(pos - m.lastPos) > 1.0 then m.lastPos = pos; m.lastMoveAt = now end
    if now > m.deadline or (now - m.lastMoveAt) > 6000 then   -- timeout or stuck
        ClearPedTasks(ped)
        TaskWanderStandard(ped, 10.0, 10)
        mv.move = nil
    end
end

-- Drive one materialised mover for a tick: expire stale goal, (re)start the task
-- when the goal changes, otherwise keep monitoring an active move.
local function driveMover(id, mv)
    local ped = mv.ped
    if not (ped and DoesEntityExist(ped)) then return end
    local goal = moverGoal[id]
    if goal and goal._deadline and GetGameTimer() >= goal._deadline then
        moverGoal[id] = nil; goal = nil                -- monotonic client-side self-degrade (M2)
    end
    local verb = (goal and goal.verb) or 'wander'      -- ambient wander when ungoaled
    local key = verb .. '|' .. tostring(goal and goal.target or '')
    if mv.taskKey ~= key then
        startTask(mv, ped, goal, verb)
        mv.taskKey = key
    else
        monitorMove(mv, ped)
    end
end

local function spawnMover(m, home)
    if pedCount() >= Config.MaxPeds then return end
    local hash = loadModel(m.model or pick(Config.ModelPool))
    if not hash then return end
    local ang = math.random() * math.pi * 2.0
    local px = home.x + math.cos(ang) * 3.0
    local py = home.y + math.sin(ang) * 3.0
    local pz = groundZ(px, py, home.z)
    local ped = CreatePed(4, hash, px, py, pz, math.random(0, 359) + 0.0, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, false)   -- must accept tasks / react to the world
    SetPedCanRagdollFromPlayerImpact(ped, true)
    TaskWanderStandard(ped, 10.0, 10)             -- ambient default until a goal drives it
    movers[m.id] = { ped = ped, taskKey = 'wander|', move = nil }
    dbg('mover spawned: ' .. m.id)
end

local function despawnMover(id)
    local mv = movers[id]
    if not mv then return end
    if mv.ped and DoesEntityExist(mv.ped) then DeletePed(mv.ped) end
    movers[id] = nil
    -- keep moverGoal[id]: it re-applies on re-materialise (subject to its TTL)
end

-- Materialise a mover when the player nears its HOME; despawn it by distance from
-- the player to the mover's CURRENT position (not its home) so a mover sent to a
-- far scene isn't culled mid-walk while the player is watching/following it — it
-- only despawns once it's genuinely out of the player's view radius. Gated on
-- Config.Director.Enabled so nothing spawns until the Director is lit. 1s cadence:
-- responsive enough for arrival/stuck, still cheap.
CreateThread(function()
    if not (Config.Enabled and Config.Director and Config.Director.Enabled) then return end
    while running ~= false do
        local pped = PlayerPedId()
        local pc = (pped ~= 0) and GetEntityCoords(pped) or nil
        if pc then
            for _, m in ipairs(Config.Movers or {}) do
                local home = m.home and sceneCoord[m.home]
                local mv = movers[m.id]
                if not mv then
                    if home and #(pc - home) <= Config.SpawnDist then spawnMover(m, home) end
                else
                    local ped = mv.ped
                    local mpos = (ped and DoesEntityExist(ped)) and GetEntityCoords(ped) or nil
                    if not mpos or #(pc - mpos) > Config.DespawnDist then
                        despawnMover(m.id)
                    else
                        driveMover(m.id, mv)
                    end
                end
            end
        end
        Wait(1000)
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
    for id in pairs(movers) do despawnMover(id) end -- Director mover peds
    for b in pairs(dispatchBlips) do                -- dispatch blips (audit L2)
        if DoesBlipExist(b) then RemoveBlip(b) end
        dispatchBlips[b] = nil
    end
end)
