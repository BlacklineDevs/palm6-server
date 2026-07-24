-- ============================================================================
-- palm6_mapeditor/client/live.lua  —  live map streaming (client half)
--
-- Spawns the server's authoritative live props on THIS client and keeps them in
-- sync. These are a SEPARATE registry from the personal editing session
-- (client/main.lua's `placed`) on purpose: live props are view-only mirrors of
-- the DB — not selectable, not in the undo stack, not touched by the tuned
-- per-frame edit loop. That keeps the two concerns from tangling.
--
-- WORKFLOW
--   build a session (the normal editor) -> /mapcommit <map> publishes it to the
--   DB, it streams to every player and persists across restarts. /maplist shows
--   maps + counts, /maplivedel removes the live prop you aim at, /mapwipe <map>
--   clears a whole map. Commit APPENDS, so /mapcommit <sameMap> grows a map.
--
-- COMMANDS
--   /mapcommit [map]   publish your current session to a live map (default: default)
--   /maplist           list live maps and their prop counts
--   /maplivedel        remove the LIVE prop you're aiming at (everywhere)
--   /mapwipe <map>     delete an entire live map (everywhere)
--   /mapworlderase     erase the vanilla world prop you aim at, for everyone (persisted)
--   /mapworldrestore   restore the nearest persisted world-erase (everywhere)
-- ============================================================================

local liveObjs = {}    -- [id] = { obj, model, x, y, z, rx, ry, rz }
local liveHides = {}   -- [id] = { x, y, z, radius, model }  (world-prop erases)
local spawning = {}    -- [id] = true while a spawn for this id is mid-model-load
local syncGen = 0      -- bumped on every full re-sync; in-flight spawns of an
                       -- older gen abort so two full syncs can't fight (leak)

local function despawn(id)
    local r = liveObjs[id]
    if not r then return end
    Game.DeleteObject(r.obj)
    liveObjs[id] = nil
end

local function despawnAll()
    for id in pairs(liveObjs) do Game.DeleteObject(liveObjs[id].obj) end
    liveObjs = {}
end

local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

-- Spawn one live prop from a server record. Idempotent AND yield-safe: the model
-- load inside Game.SpawnObject yields, so we (a) skip if the id is already live
-- or already being spawned (kills the double-sync duplicate/leak), and (b) after
-- the load, drop the object if a newer full re-sync has superseded us (gen). A
-- record with non-numeric coords is skipped, not allowed to throw the batch.
local function spawn(rec, gen)
    if type(rec) ~= 'table' or not rec.id or type(rec.model) ~= 'string' then return end
    if not (finite(rec.x) and finite(rec.y) and finite(rec.z)) then return end
    if liveObjs[rec.id] or spawning[rec.id] then return end
    spawning[rec.id] = true
    local obj = Game.SpawnObject(rec.model, rec.x, rec.y, rec.z)   -- yields on model load
    spawning[rec.id] = nil
    if not obj then return end            -- bad/removed model — skip, don't crash the batch
    if (gen and gen ~= syncGen) or liveObjs[rec.id] then Game.DeleteObject(obj); return end
    Game.SetObjectTransform(obj, rec.x, rec.y, rec.z, rec.rx or 0.0, rec.ry or 0.0, rec.rz or 0.0)
    liveObjs[rec.id] = { obj = obj, model = rec.model, x = rec.x, y = rec.y, z = rec.z, rx = rec.rx, ry = rec.ry, rz = rec.rz }
end

-- ---- server -> client ------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:add', function(rec) spawn(rec) end)

-- A batch. `full` means "this is the authoritative complete set" (initial sync /
-- reconnect) so we clear what we had first; otherwise it's an incremental commit
-- we just add. Spawned in a thread that yields every few props so loading many
-- models never freezes the client for a frame.
RegisterNetEvent('palm6_mapeditor:live:addBatch', function(list, full)
    if type(list) ~= 'table' then return end
    local myGen
    if full then
        -- Reset atomically BEFORE any yield: bump the generation and clear the
        -- world in this tick. Any older full batch still spawning will see the
        -- new gen and abort, so two syncs can't interleave into duplicates.
        syncGen = syncGen + 1
        myGen = syncGen
        despawnAll()
    end
    CreateThread(function()
        for i = 1, #list do
            if full and myGen ~= syncGen then return end   -- superseded by a newer full sync
            spawn(list[i], full and myGen or nil)
            if i % 15 == 0 then Wait(0) end
        end
    end)
end)

RegisterNetEvent('palm6_mapeditor:live:remove', function(id) despawn(tonumber(id)) end)

RegisterNetEvent('palm6_mapeditor:live:removeBatch', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do despawn(tonumber(id)) end
end)

-- ---- world-erase streaming -------------------------------------------------
local function applyHide(rec)
    if type(rec) ~= 'table' or not rec.id or type(rec.model) ~= 'number' then return end
    if not (finite(rec.x) and finite(rec.y) and finite(rec.z)) then return end
    if liveHides[rec.id] then return end   -- already applied (idempotent re-sync)
    Game.HideModelAt(rec.x, rec.y, rec.z, rec.radius or 1.0, rec.model)
    liveHides[rec.id] = { x = rec.x, y = rec.y, z = rec.z, radius = rec.radius or 1.0, model = rec.model }
end

local function unHide(id)
    local h = liveHides[id]
    if not h then return end
    Game.RestoreModelAt(h.x, h.y, h.z, h.radius, h.model)
    liveHides[id] = nil
end

RegisterNetEvent('palm6_mapeditor:live:hide', function(rec) applyHide(rec) end)
RegisterNetEvent('palm6_mapeditor:live:hideBatch', function(list, full)
    if type(list) ~= 'table' then return end
    if full then for id in pairs(liveHides) do unHide(id) end end
    for i = 1, #list do applyHide(list[i]) end
end)
RegisterNetEvent('palm6_mapeditor:live:unhide', function(id) unHide(tonumber(id)) end)

-- ---- initial sync ----------------------------------------------------------
-- Ask for the live map on start (covers a fresh join AND a resource restart on
-- either side). The server also pushes to everyone the moment its DB finishes
-- loading, so a client that asked before the DB was ready still gets the props.
CreateThread(function()
    Wait(2000)
    TriggerServerEvent('palm6_mapeditor:live:requestSync')
end)

-- ---- commands (writes are ACE-checked server-side) -------------------------
RegisterCommand('mapcommit', function(_, args)
    local snap = MapEd.snapshot and MapEd.snapshot() or {}
    if #snap == 0 then Game.Notify('nothing in your session to commit', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:live:commit', args[1], snap)
    Game.Notify(('publishing %d prop(s) to "%s"...'):format(#snap, args[1] or Config.LiveDefaultMap), 'inform')
end, false)

-- Server confirms the rows are persisted -> drop the personal session copies so
-- the returning LIVE props don't render on top of them. We wait for this ack
-- (rather than clearing optimistically) so a rejected commit never loses a
-- session. The broadcast that spawns the live copies is fired just before this.
RegisterNetEvent('palm6_mapeditor:live:committed', function()
    if MapEd.clearSession then MapEd.clearSession() end
end)

RegisterCommand('maplist', function() TriggerServerEvent('palm6_mapeditor:live:list') end, false)

RegisterCommand('mapwipe', function(_, args)
    if not args[1] then Game.Notify('usage: /mapwipe <map>', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:live:wipeMap', args[1])
end, false)

-- Aim at a LIVE prop and remove it everywhere. Matches the raycast-hit entity
-- handle back to a live id; if the crosshair isn't on a live prop, says so.
RegisterCommand('maplivedel', function()
    local ent = Game.RaycastEntity(30.0)
    if ent == 0 then Game.Notify('aim at a live prop to remove', 'error'); return end
    for id, r in pairs(liveObjs) do
        if r.obj == ent then TriggerServerEvent('palm6_mapeditor:live:removeOne', id); return end
    end
    Game.Notify('that is not a live prop (use /materase for world props)', 'error')
end, false)

-- Erase the vanilla world prop you aim at, FOR EVERYONE (persisted). Unlike
-- /materase (personal, session-local), this streams to all players and future
-- joiners so a carved-out spot for a custom build is consistent server-wide.
RegisterCommand('mapworlderase', function()
    local ent, model, x, y, z = Game.RaycastEntity(30.0)
    if ent == 0 or model == 0 then Game.Notify('aim at a world prop to erase', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:live:eraseWorld', x, y, z, 1.0, model)
end, false)

-- Restore the nearest persisted world-erase to where you aim (undo, everywhere).
RegisterCommand('mapworldrestore', function()
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    local best, bestD
    for id, h in pairs(liveHides) do
        local d = (h.x - x) ^ 2 + (h.y - y) ^ 2 + (h.z - z) ^ 2
        if not bestD or d < bestD then bestD, best = d, id end
    end
    if not best then Game.Notify('no world-erases to restore', 'inform'); return end
    TriggerServerEvent('palm6_mapeditor:live:restoreWorld', best)
end, false)

-- Live props are our own client objects and world-erases are raw client world
-- state; undo both on stop so a resource restart never leaves orphaned handles
-- or permanently-hidden vanilla props (the client re-applies them on next sync).
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    despawnAll()
    for id in pairs(liveHides) do
        local h = liveHides[id]
        Game.RestoreModelAt(h.x, h.y, h.z, h.radius, h.model)
    end
    liveHides = {}
end)
