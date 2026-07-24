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
-- ============================================================================

local liveObjs = {}   -- [id] = { obj, model, x, y, z, rx, ry, rz }

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

-- Spawn (or respawn) one live prop from a server record. Idempotent on id: a
-- re-sync or a duplicate add replaces the existing handle rather than leaking it.
local function spawn(rec)
    if type(rec) ~= 'table' or not rec.id or type(rec.model) ~= 'string' then return end
    if liveObjs[rec.id] then despawn(rec.id) end
    local obj = Game.SpawnObject(rec.model, rec.x, rec.y, rec.z)
    if not obj then return end            -- bad/removed model — skip, don't crash the batch
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
    CreateThread(function()
        if full then despawnAll() end
        for i = 1, #list do
            spawn(list[i])
            if i % 15 == 0 then Wait(0) end
        end
    end)
end)

RegisterNetEvent('palm6_mapeditor:live:remove', function(id) despawn(tonumber(id)) end)

RegisterNetEvent('palm6_mapeditor:live:removeBatch', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do despawn(tonumber(id)) end
end)

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

-- Live props are our own client objects; delete them on stop so a resource
-- restart never leaves orphaned handles floating in the world.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then despawnAll() end
end)
