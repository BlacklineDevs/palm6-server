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
--   /mapcommit [map]   publish your session — props AND lights — to a live map
--   /maplist           list live maps and their prop/erase/light counts
--   /mapexportlive <m> export a whole live map to Lua/JSON/CodeWalker ymap.xml
--   /maplivedel        remove the LIVE prop you're aiming at (everywhere)
--   /maplivegrab       grab the LIVE prop you aim at back into your session to edit it
--   /maplightdel       remove the LIVE light nearest your aim (everywhere)
--   /mapwipe <map>     delete an entire live map — props + lights (everywhere)
--   /mapworlderase     erase the vanilla world prop you aim at, for everyone (persisted)
--   /mapworldrestore   restore the nearest persisted world-erase (everywhere)
-- ============================================================================

local liveObjs = {}    -- [id] = { obj, model, x, y, z, rx, ry, rz }
local liveHides = {}   -- [id] = { x, y, z, radius, model }  (world-prop erases)
local spawning = {}    -- [id] = true while a spawn for this id is mid-model-load
local canceled = {}    -- [id] = true if removed WHILE its spawn was mid-load
local syncGen = 0      -- bumped on every full re-sync; in-flight spawns of an
                       -- older gen abort so two full syncs can't fight (leak)
local stopping = false

local function despawn(id)
    if spawning[id] then canceled[id] = true end   -- cancel an in-flight spawn (no DB row will exist)
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
    canceled[rec.id] = nil
    local obj = Game.SpawnObject(rec.model, rec.x, rec.y, rec.z)   -- yields on model load
    spawning[rec.id] = nil
    if not obj then canceled[rec.id] = nil; return end   -- bad/removed model — skip, don't crash the batch
    -- Drop it if it was removed mid-load (canceled), superseded by a newer full
    -- sync (gen), already spawned, or the resource is stopping.
    if canceled[rec.id] or stopping or (gen and gen ~= syncGen) or liveObjs[rec.id] then
        Game.DeleteObject(obj); canceled[rec.id] = nil; return
    end
    Game.SetObjectTransform(obj, rec.x, rec.y, rec.z, rec.rx or 0.0, rec.ry or 0.0, rec.rz or 0.0)
    liveObjs[rec.id] = { obj = obj, model = rec.model, map = rec.map, x = rec.x, y = rec.y, z = rec.z, rx = rec.rx, ry = rec.ry, rz = rec.rz }
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
        -- Clear `spawning` too so the new gen re-attempts ids still mid-load from
        -- an older sync (else they'd be skipped then dropped → lost this session).
        syncGen = syncGen + 1
        myGen = syncGen
        despawnAll()
        spawning = {}
    end
    CreateThread(function()
        for i = 1, #list do
            if full and myGen ~= syncGen then return end   -- superseded by a newer full sync
            spawn(list[i], full and myGen or nil)
            if i % 15 == 0 then Wait(0) end
        end
    end)
end)

RegisterNetEvent('palm6_mapeditor:live:remove', function(id) despawn(tonumber(id)); if Live then Live.push() end end)

RegisterNetEvent('palm6_mapeditor:live:removeBatch', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do despawn(tonumber(id)) end
    if Live then Live.push() end
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

-- Server sent this map's revision list -> hand it to the NUI revisions view.
RegisterNetEvent('palm6_mapeditor:live:revs', function(map, list)
    SendNUIMessage({ action = 'revs', map = map, revs = list or {} })
end)

-- Server renamed a map: relabel the streamed props in place (no respawn) so the
-- outliner map-picker reflects the new name, then re-push the outliner.
RegisterNetEvent('palm6_mapeditor:live:mapRenamed', function(oldName, newName)
    if type(oldName) ~= 'string' or type(newName) ~= 'string' then return end
    for _, r in pairs(liveObjs) do if r.map == oldName then r.map = newName end end
    if Live and Live.push then Live.push() end
end)

-- ---- live lights -----------------------------------------------------------
-- Lights aren't entities; they're redrawn every frame. Unlike lights.lua (the
-- admin's session lights, drawn only while editing), these are streamed and
-- drawn for EVERY player, always. A single always-on loop draws them all,
-- distance-culled so far-away lights cost nothing.
local liveLights = {}   -- [id] = { x,y,z, r,g,b, range, intensity, kind }

local function applyLight(rec)
    if type(rec) ~= 'table' or not rec.id then return end
    if not (finite(rec.x) and finite(rec.y) and finite(rec.z)) then return end
    liveLights[rec.id] = {
        x = rec.x, y = rec.y, z = rec.z,
        r = rec.r or 255, g = rec.g or 200, b = rec.b or 140,
        range = rec.range or 8.0, intensity = rec.intensity or 5.0, kind = rec.kind or 'point',
    }
end

RegisterNetEvent('palm6_mapeditor:live:light', function(rec) applyLight(rec) end)
RegisterNetEvent('palm6_mapeditor:live:lightBatch', function(list, full)
    if type(list) ~= 'table' then return end
    if full then liveLights = {} end
    for i = 1, #list do applyLight(list[i]) end
end)
RegisterNetEvent('palm6_mapeditor:live:lightRemove', function(id) if id then liveLights[tonumber(id)] = nil end end)
RegisterNetEvent('palm6_mapeditor:live:lightRemoveBatch', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do liveLights[tonumber(id)] = nil end
end)

CreateThread(function()
    local D2 = Config.LiveLightDist * Config.LiveLightDist
    while true do
        local any = next(liveLights) ~= nil
        if any then
            local px, py, pz = Game.PlayerPos()   -- once per frame, not per light
            for _, l in pairs(liveLights) do
                if (l.x - px) ^ 2 + (l.y - py) ^ 2 + (l.z - pz) ^ 2 <= D2 then
                    if l.kind == 'spot' then
                        Game.DrawSpot(l.x, l.y, l.z, 0.0, 0.0, -1.0, l.r, l.g, l.b, l.range, l.intensity, 8.0, 1.0)
                    else
                        Game.DrawPointLight(l.x, l.y, l.z, l.r, l.g, l.b, l.range, l.intensity)
                    end
                end
            end
        end
        Wait(any and 0 or 500)   -- only run every frame when there ARE live lights
    end
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
    local lsnap = (MapEd.getLights and MapEd.getLights()) or {}
    if #snap == 0 and #lsnap == 0 then Game.Notify('nothing in your session to commit', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:live:commit', args[1], snap, lsnap)
    Game.Notify(('publishing %d prop(s) + %d light(s) to "%s"...'):format(#snap, #lsnap, args[1] or Config.LiveDefaultMap), 'inform')
end, false)

-- Server confirms the rows are persisted -> drop the personal session copies
-- (props AND lights) so the returning LIVE copies don't render on top of them.
-- We wait for this ack (rather than clearing optimistically) so a rejected
-- commit never loses a session. The broadcast that respawns them fires first.
RegisterNetEvent('palm6_mapeditor:live:committed', function()
    if MapEd.clearSession then MapEd.clearSession() end
    if MapEd.clearLights then MapEd.clearLights() end
end)

-- Aim at a live light and remove it everywhere. Matches the nearest live light
-- to the aim point (lights aren't entities, so there's nothing to raycast).
RegisterCommand('maplightdel', function()
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    local best, bestD
    for id, l in pairs(liveLights) do
        local d = (l.x - x) ^ 2 + (l.y - y) ^ 2 + (l.z - z) ^ 2
        if not bestD or d < bestD then bestD, best = d, id end
    end
    if not best then Game.Notify('no live lights nearby', 'inform'); return end
    TriggerServerEvent('palm6_mapeditor:live:removeLightOne', best)
end, false)

RegisterCommand('maplist', function() TriggerServerEvent('palm6_mapeditor:live:list') end, false)

-- Export the accumulated LIVE map (built across sessions) to Lua/JSON/ymap.xml.
-- The server returns the map's prop ids; we build the files from the matching
-- live objects (real entities -> accurate ymap quaternions), then save them.
RegisterCommand('mapexportlive', function(_, args)
    if not args[1] then Game.Notify('usage: /mapexportlive <mapname>', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:live:exportRequest', args[1])
end, false)

RegisterNetEvent('palm6_mapeditor:live:exportIds', function(mapName, ids)
    if type(ids) ~= 'table' or #ids == 0 then Game.Notify('live map "' .. tostring(mapName) .. '" has no props', 'error'); return end
    if not (MapEd and MapEd.buildExports) then return end
    local want = {}
    for _, id in ipairs(ids) do want[tonumber(id)] = true end
    local recs = {}
    for id, r in pairs(liveObjs) do if want[id] then recs[#recs + 1] = r end end
    if #recs == 0 then Game.Notify('live map not streamed in yet — move nearer / retry', 'error'); return end
    local ents = (Entities and Entities.exportList) and Entities.exportList(mapName) or {}
    local lua, js, ymap, py = MapEd.buildExports(recs, {}, mapName, ents)
    Game.SetClipboard(lua)
    TriggerServerEvent('palm6_mapeditor:save', mapName, lua, js, ymap, py)
    Game.Notify(('exporting live map "%s" — %d props, %d entities (.lua/.json/.ymap.xml/.py)'):format(mapName, #recs, #ents), 'inform')
end)

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

-- Aim at a LIVE prop and GRAB it into your session to reposition/adjust it (the
-- only way to edit a committed prop). The server removes it from the live map for
-- everyone and hands it back as a normal editable prop; /mapcommit republishes.
RegisterCommand('maplivegrab', function()
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then Game.Notify('open the editor first (/mapedit)', 'error'); return end
    local ent = Game.RaycastEntity(30.0)
    if ent == 0 then Game.Notify('aim at a live prop to grab', 'error'); return end
    for id, r in pairs(liveObjs) do
        if r.obj == ent then TriggerServerEvent('palm6_mapeditor:live:grabProp', id); return end
    end
    Game.Notify('that is not a live prop', 'error')
end, false)

-- ---- Live-map outliner (NUI) ----------------------------------------------
-- liveObjs already holds the FULL committed set (the sync streams every live
-- prop), so the outliner is built client-side — no server enumeration needed.
-- Actions reuse the audited by-id server events (removeOne / grabProp).
Live = {}
function Live.push()
    local list = {}
    for id, r in pairs(liveObjs) do
        list[#list + 1] = { id = id, model = r.model, map = r.map, x = r.x, y = r.y, z = r.z }
    end
    SendNUIMessage({ action = 'live', props = list })
end

-- Export a named live map to files from the NUI (same path as /mapexportlive):
-- ask the server for the map's prop ids, then live:exportIds builds + saves.
function Live.exportMap(name)
    if type(name) ~= 'string' or name == '' then return end
    TriggerServerEvent('palm6_mapeditor:live:exportRequest', name)
end

-- Revisions / snapshots (server owns the palm6_mapeditor_revisions table).
function Live.snapshot(map, label)
    if type(map) == 'string' and map ~= '' then TriggerServerEvent('palm6_mapeditor:live:snapshot', map, label or '') end
end
function Live.revList(map)
    if type(map) == 'string' and map ~= '' then TriggerServerEvent('palm6_mapeditor:live:revList', map) end
end
function Live.revRestore(id) local n = tonumber(id); if n then TriggerServerEvent('palm6_mapeditor:live:revRestore', n) end end
function Live.revDelete(id) local n = tonumber(id); if n then TriggerServerEvent('palm6_mapeditor:live:revDelete', n) end end

-- Rename a live map (props + lights via live.lua, entities via entities.lua).
function Live.renameMap(oldName, newName)
    if type(oldName) ~= 'string' or type(newName) ~= 'string' then return end
    if oldName == '' or newName == '' or oldName == newName then return end
    TriggerServerEvent('palm6_mapeditor:live:renameMap', oldName, newName)
    TriggerServerEvent('palm6_mapeditor:ent:renameMap', oldName, newName)
end

-- Merge one live map into another (relabels props/lights/entities from -> into).
function Live.mergeMap(fromName, intoName)
    if type(fromName) ~= 'string' or type(intoName) ~= 'string' then return end
    if fromName == '' or intoName == '' or fromName == intoName then return end
    TriggerServerEvent('palm6_mapeditor:live:mergeMap', fromName, intoName)
    TriggerServerEvent('palm6_mapeditor:ent:renameMap', fromName, intoName)   -- entity UPDATE allows any target
end

-- Counts for the Performance panel: props / lights / world-erases currently on
-- the live (committed) map. liveObjs/liveLights/liveHides mirror the full sets
-- the server streams, so these are accurate for every player, not just admins.
function Live.stats()
    local props, lights, hides = 0, 0, 0
    for _ in pairs(liveObjs) do props = props + 1 end
    for _ in pairs(liveLights) do lights = lights + 1 end
    for _ in pairs(liveHides) do hides = hides + 1 end
    return props, lights, hides
end

AddEventHandler('palm6_mapeditor:liveGoto', function(id)
    local r = liveObjs[id]
    if r then Game.TeleportPlayer(r.x, r.y, r.z); Game.Notify('jumped to ' .. tostring(r.model), 'inform') end
end)
AddEventHandler('palm6_mapeditor:liveGrab', function(id)
    if liveObjs[id] then TriggerServerEvent('palm6_mapeditor:live:grabProp', id) end
end)
AddEventHandler('palm6_mapeditor:liveDelete', function(id)
    if liveObjs[id] then TriggerServerEvent('palm6_mapeditor:live:removeOne', id) end
end)
AddEventHandler('palm6_mapeditor:liveDeleteMany', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n and liveObjs[n] then TriggerServerEvent('palm6_mapeditor:live:removeOne', n) end
    end
end)

-- The server confirmed the grab (already despawned the live copy for everyone via
-- live:remove); spawn it into the personal session, selected, ready to edit.
RegisterNetEvent('palm6_mapeditor:live:grabbed', function(rec)
    if type(rec) ~= 'table' or type(rec.model) ~= 'string' then return end
    if MapEd and MapEd.spawnAt then
        MapEd.spawnAt(rec.model, rec.x, rec.y, rec.z, rec.rx or 0.0, rec.ry or 0.0, rec.rz or 0.0)
        Game.Notify('grabbed — reposition it, then /mapcommit', 'inform')
    end
end)

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
    stopping = true   -- in-flight spawns self-delete instead of leaking on restart
    despawnAll()
    for id in pairs(liveHides) do
        local h = liveHides[id]
        Game.RestoreModelAt(h.x, h.y, h.z, h.radius, h.model)
    end
    liveHides = {}
end)
