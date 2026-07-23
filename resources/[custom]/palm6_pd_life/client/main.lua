-- ============================================================================
-- palm6_pd_life/client/main.lua
--
-- The living PBPD station. Merges NTeam's plaza scene (Config.Scene) with the
-- interior room posts extracted from the MLO furniture (Config.Rooms) and
-- materialises the whole thing only while a player is near the building,
-- despawning past the outer ring. Each ped runs its intended scenario (seated at
-- a desk / bench, standing with a clipboard, etc.) at the exact spot + heading.
-- A post whose ambient NPC has been relieved by a real officer (Phase B) is
-- suppressed until released. All natives go through Game.* (bridge).
-- ============================================================================

local spawned = {}       -- array of { ped, post, room, kind }
local built = false
local heldPosts = {}     -- post id -> true (a player is manning it; NPC suppressed)

local function pick(list)
    return list[math.random(#list)]
end

-- One flat list of every post: plaza ambient + interior rooms.
local function allPosts()
    local list = {}
    for _, e in ipairs(Config.Scene or {}) do
        list[#list + 1] = { scen = e.scen, ped = e.ped, coords = e.coords, kind = 'ambient' }
    end
    for _, e in ipairs(Config.Rooms or {}) do
        list[#list + 1] = { scen = e.scen, ped = e.ped, coords = e.coords, kind = e.kind, room = e.room, post = e.post }
    end
    return list
end

local function spawnPost(e)
    local models = Config.Peds[e.ped] or Config.Peds.civ
    local ped = Game.SpawnScenarioPed(pick(models), e.coords.x, e.coords.y, e.coords.z, e.coords.w, e.scen, true)
    if ped then
        spawned[#spawned + 1] = { ped = ped, post = e.post, room = e.room, kind = e.kind }
    end
end

local function buildScene()
    if built then return end
    built = true
    for _, e in ipairs(allPosts()) do
        if not (e.post and heldPosts[e.post]) then   -- skip posts a player is manning
            spawnPost(e)
        end
        Wait(0)   -- yield between model loads
    end
end

local function clearScene()
    for _, s in ipairs(spawned) do
        Game.DeletePed(s.ped)
    end
    spawned = {}
    built = false
end

-- Despawn the single NPC manning a given post (when a player relieves it).
local function despawnByPost(postId)
    for i = #spawned, 1, -1 do
        if spawned[i].post == postId then
            Game.DeletePed(spawned[i].ped)
            table.remove(spawned, i)
        end
    end
end

-- Respawn the ambient NPC for a post that was just released.
local function respawnPost(postId)
    if not built then return end
    for _, e in ipairs(Config.Rooms or {}) do
        if e.post == postId then
            spawnPost({ scen = e.scen, ped = e.ped, coords = e.coords, kind = e.kind, room = e.room, post = e.post })
            return
        end
    end
end

-- Server tells everyone a post is now held (relieve NPC) or released (restore).
RegisterNetEvent('palm6_pd_life:postState', function(postId, held)
    heldPosts[postId] = held or nil
    if held then despawnByPost(postId) else respawnPost(postId) end
end)

-- Pre-cull NPCs for already-held posts when we first load in.
RegisterNetEvent('palm6_pd_life:heldSnapshot', function(held)
    for _, postId in ipairs(held or {}) do
        heldPosts[postId] = true
        despawnByPost(postId)
    end
end)

-- Proximity gate: build when a player nears the station, cull when they leave.
CreateThread(function()
    local st = Config.Station
    TriggerServerEvent('palm6_pd_life:requestHeld')
    while true do
        local dist = Game.DistToStation(st.center.x, st.center.y, st.center.z)
        if not built and dist <= st.spawnDist then
            buildScene()
        elseif built and dist > st.despawnDist then
            clearScene()
        end
        Wait(1500)
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearScene()
end)

-- Dev helpers (placement now comes from the MLO, so /pdnpc is retired).
if Config.DevPlacement then
    RegisterCommand('pdnpcclear', function()
        clearScene()
        Game.Chat('[pd_life]', 'scene cleared')
    end, false)
    RegisterCommand('pdnpccount', function()
        local byRoom = {}
        for _, s in ipairs(spawned) do
            local k = s.room or s.kind or 'plaza'
            byRoom[k] = (byRoom[k] or 0) + 1
        end
        local parts = {}
        for k, v in pairs(byRoom) do parts[#parts + 1] = ('%s:%d'):format(k, v) end
        Game.Chat('[pd_life]', ('%d NPCs live (%s)'):format(#spawned, table.concat(parts, ' ')))
    end, false)
end
