-- ============================================================================
-- palm6_brain/server/netped.lua — NETWORKED SERVER-OWNED PEDS (foundation).
--
-- The roadmap's "hard part". Unlike the client-local movers (client/main.lua),
-- these peds are SERVER-CREATED + OneSync-networked, so EVERY player sees the SAME
-- ped at the same place — the prerequisite for crime/money NPCs a player can
-- actually rob or interact with (a client-local ped exists on one machine only and
-- can never be a shared target).
--
-- THE OWNERSHIP PROBLEM + THE FIX. A networked ped "thinks" only on the client
-- that currently OWNS it; OneSync migrates ownership to the nearest player, and
-- tasks set by the old owner DROP on migration. So we never task the ped from the
-- server. Instead the server writes the ped's GOAL into a REPLICATED state bag
-- (`p6netgoal`); whichever client owns the ped reads that bag and applies the
-- task, and re-applies it when it becomes the owner (client/netped.lua). The task
-- therefore survives migration.
--
-- FOUNDATION SCOPE. This slice proves that mechanism with manual, ACE-restricted
-- test commands. Director / crime / money integration comes AFTER the plumbing is
-- validated in-game. Dark by default (Config.NetPed.Enabled); fully isolated from
-- the live client-local mover system (touches none of it).
--
-- ⚠️ UNVERIFIED LOCALLY: server-created networked peds + ownership migration only
-- manifest at runtime with real clients — this cannot be tested without the live
-- server. See TO-VALIDATE at the bottom. Ships behind its gate for exactly that
-- reason: David walks it, we iterate.
-- ============================================================================

local function cfg() return Config.NetPed or {} end
local function enabled() return cfg().Enabled == true end

local netPeds = {}   -- id -> { ped = <server entity handle> }
local counter = 0

-- Create a server-owned networked ped and stamp its goal into a REPLICATED state
-- bag so any client (including a future owner after migration) can read it.
-- Returns id, ped or nil. `goal` = { verb = 'wander'|'goTo'|'idle', x?,y?,z? }.
local function spawn(model, x, y, z, heading, goal)
    local hash = joaat(model or cfg().Model or 'a_m_y_business_01')
    -- Server-side CreatePed under OneSync: isNetwork=true, bScriptHostPed=true.
    local ped = CreatePed(4, hash, x + 0.0, y + 0.0, z + 0.0, (heading or 0.0) + 0.0, true, true)
    if not ped or ped == 0 then return nil end
    -- Defer the state-bag write one tick so the entity is fully registered/
    -- replicated before the goal lands (belt-and-suspenders against a race where a
    -- client hasn't seen the entity yet).
    Wait(0)
    if DoesEntityExist(ped) then
        Entity(ped).state:set('p6netgoal', goal or { verb = 'wander' }, true)  -- replicated
    end
    counter = counter + 1
    local id = ('net_%d'):format(counter)
    netPeds[id] = { ped = ped }
    return id, ped
end

-- Update an existing test ped's goal (re-writing the replicated bag → the owner
-- re-tasks it). Applies to the most-recent ped, or all, for the test commands.
local function setGoalAll(goal)
    local n = 0
    for _, np in pairs(netPeds) do
        if np.ped and DoesEntityExist(np.ped) then
            Entity(np.ped).state:set('p6netgoal', goal, true)
            n = n + 1
        end
    end
    return n
end

local function clearAll()
    local n = 0
    for id, np in pairs(netPeds) do
        if np.ped and DoesEntityExist(np.ped) then DeleteEntity(np.ped); n = n + 1 end
        netPeds[id] = nil
    end
    return n
end

-- scene label -> coords (for /netpedgoto), server-side.
local function sceneCoord(label)
    for _, s in ipairs(Config.Scenes or {}) do
        if s.label == label then return { x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0 } end
    end
    return nil
end

-- ── TEST COMMANDS (ACE-restricted) ──────────────────────────────────────────

-- /netpedtest — spawn a networked ped ~2m from you with a wander goal. Every
-- player near you should see the SAME ped; it should wander and keep wandering as
-- players walk past it (ownership migrates, task re-asserts).
RegisterCommand('netpedtest', function(src)
    if not enabled() then return print('[palm6_brain:netped] Config.NetPed.Enabled is false — flip it + redeploy.') end
    if src == 0 then return print('[palm6_brain:netped] run this in-game (needs your position).') end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)                -- server-side under OneSync
    local h = GetEntityHeading(ped)
    local id, np = spawn(cfg().Model, c.x + 2.0, c.y + 2.0, c.z, h, { verb = 'wander' })
    local msg = id and ('spawned networked ped %s (net %s) — should wander for everyone'):format(id, np and NetworkGetNetworkIdFromEntity(np) or '?')
        or 'spawn FAILED (check server console / model)'
    print('[palm6_brain:netped] ' .. msg)
    TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 }, args = { 'netped', msg } })
end, true)

-- /netpedgoto <scene label> — retarget all test peds to walk to a scene. Walk
-- alongside one to watch it path AND survive ownership migration mid-walk.
RegisterCommand('netpedgoto', function(src, args)
    if not enabled() then return end
    local label = args[1] and table.concat(args, ' ') or nil
    local dst = label and sceneCoord(label)
    if not dst then
        local msg = 'usage: /netpedgoto <scene label> (known: ' ..
            (function() local t = {} for _, s in ipairs(Config.Scenes or {}) do t[#t+1] = s.label end return table.concat(t, ', ') end)() .. ')'
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { color = { 230, 180, 120 }, args = { 'netped', msg } }) else print(msg) end
        return
    end
    local n = setGoalAll({ verb = 'goTo', x = dst.x, y = dst.y, z = dst.z })
    local msg = ('sent %d networked ped(s) -> %s'):format(n, label)
    print('[palm6_brain:netped] ' .. msg)
    if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 }, args = { 'netped', msg } }) end
end, true)

-- /netpedclear — delete all test peds.
RegisterCommand('netpedclear', function(src)
    local n = clearAll()
    local msg = ('cleared %d networked ped(s)'):format(n)
    print('[palm6_brain:netped] ' .. msg)
    if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 }, args = { 'netped', msg } }) end
end, true)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)

-- ── TO-VALIDATE IN-GAME (this is the point of the foundation) ────────────────
-- 1. /netpedtest → does the ped appear for ALL nearby players (not just you)?
-- 2. Does it wander, and KEEP wandering as players walk past it (ownership
--    migrates — the client re-assert loop must re-task it for the new owner)?
-- 3. /netpedgoto <scene> → does it path there, and survive migration mid-walk?
-- 4. /netpedclear → does it delete for everyone?
-- 5. With NOBODY near at spawn, does the server cull it? (If so, we add a routing
--    bucket / SetEntityDistanceCullingRadius in the next slice.)
-- Once these hold, the Director drives these (assign goals → set p6netgoal) and
-- crime/money can target them as shared entities.
