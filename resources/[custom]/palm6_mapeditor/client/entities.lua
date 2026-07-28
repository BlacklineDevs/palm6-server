-- ============================================================================
-- palm6_mapeditor/client/entities.lua  —  scene peds / vehicles (client half)
--
-- Streams the server's persisted scene entities and spawns them locally (frozen)
-- on every player. Separate registry from props/lights, and applies the same
-- yield-safe sync the prop layer learned in audit: an in-flight id guard + a
-- sync generation, so the boot double-sync can't double-spawn or leak handles.
--
-- COMMANDS (editor must be open)
--   /matped <model> [scenario]  place a scene ped at your aim + heading
--   /matveh <model>             place a scene vehicle at your aim + heading
--   /matentdel                  remove the scene entity you're aiming at
--   /mapworkmap <name>          set the map new scene entities are placed on
--   /mapentwipe [map]           wipe a map's scene entities (default: work map)
--   /mapentlist                 count peds / vehicles
-- ============================================================================

local liveEnts = {}    -- [id] = { obj, kind, model, x, y, z, heading, extra }
local spawning = {}    -- [id] = true while mid model-load
local canceled = {}    -- [id] = true if removed WHILE its spawn was mid-load
local syncGen = 0
local stopping = false
local workMap = Config.LiveDefaultMap   -- map that /matped, /matveh place onto
-- Declared up here (not at the carry loop below) because placeGate reads it and
-- Lua locals are only visible after their declaration.
local carrying = false

local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function despawn(id)
    if spawning[id] then canceled[id] = true end   -- cancel an in-flight spawn (no DB row will exist)
    local e = liveEnts[id]
    if not e then return end
    Game.DeleteAnyEntity(e.obj)
    liveEnts[id] = nil
end
local function despawnAll()
    for id in pairs(liveEnts) do Game.DeleteAnyEntity(liveEnts[id].obj) end
    liveEnts = {}
end

-- Yield-safe spawn (model load yields): skip if already present/in-flight; after
-- the yield, drop the entity if it was removed (canceled), superseded by a newer
-- full re-sync (gen), already spawned, or the resource is stopping.
local function spawn(rec, gen)
    if type(rec) ~= 'table' or not rec.id or type(rec.model) ~= 'string' then return end
    if rec.kind ~= 'ped' and rec.kind ~= 'veh' then return end
    if not (finite(rec.x) and finite(rec.y) and finite(rec.z)) then return end
    if liveEnts[rec.id] or spawning[rec.id] then return end
    spawning[rec.id] = true
    canceled[rec.id] = nil
    local obj
    if rec.kind == 'veh' then
        obj = Game.SpawnVehicle(rec.model, rec.x, rec.y, rec.z, rec.heading or 0.0)
    else
        obj = Game.SpawnPed(rec.model, rec.x, rec.y, rec.z, rec.heading or 0.0, rec.extra)
    end
    spawning[rec.id] = nil
    if not obj then canceled[rec.id] = nil; return end
    if canceled[rec.id] or stopping or (gen and gen ~= syncGen) or liveEnts[rec.id] then
        Game.DeleteAnyEntity(obj); canceled[rec.id] = nil; return
    end
    liveEnts[rec.id] = { obj = obj, map = rec.map, kind = rec.kind, model = rec.model, x = rec.x, y = rec.y, z = rec.z, heading = rec.heading, extra = rec.extra }
end

-- ---- server -> client ------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:ent:add', function(rec) spawn(rec); if Entities then Entities.push() end end)
RegisterNetEvent('palm6_mapeditor:ent:addBatch', function(list, full)
    if type(list) ~= 'table' then return end
    local myGen
    -- Clear `spawning` on a full reset so the new generation re-attempts any ids
    -- still mid-load from an older sync (otherwise the older in-flight spawn would
    -- be skipped by the guard, then dropped by its gen check → lost for the session).
    if full then syncGen = syncGen + 1; myGen = syncGen; despawnAll(); spawning = {} end
    CreateThread(function()
        for i = 1, #list do
            if full and myGen ~= syncGen then return end
            spawn(list[i], full and myGen or nil)
            if i % 10 == 0 then Wait(0) end
        end
    end)
end)
RegisterNetEvent('palm6_mapeditor:ent:remove', function(id) despawn(tonumber(id)); if Entities then Entities.push() end end)
RegisterNetEvent('palm6_mapeditor:ent:removeBatch', function(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do despawn(tonumber(id)) end
    if Entities then Entities.push() end
end)

-- Server relabelled a map (rename or merge): update the streamed entities' map
-- tags in place. Nothing respawns, but Entities.exportList selects on this
-- field, so without the relabel every export after a rename or merge silently
-- dropped that map's peds and vehicles.
RegisterNetEvent('palm6_mapeditor:ent:mapRenamed', function(oldName, newName)
    if type(oldName) ~= 'string' or type(newName) ~= 'string' then return end
    for _, e in pairs(liveEnts) do if e.map == oldName then e.map = newName end end
end)

CreateThread(function()
    Wait(2500)
    TriggerServerEvent('palm6_mapeditor:ent:requestSync')
end)

-- ---- commands --------------------------------------------------------------
-- Gate for every USER-initiated placement (/matped, /matveh, the NUI Peds and
-- Vehicles tabs). The carry loop below does NOT go through here: it fires
-- ent:place directly, which is how a carry resolves.
-- The carry check matters because the server retires a carry's disconnect-backup
-- by matching kind/model/map/extra on the row it just inserted, with no per-carry
-- token, so placing a second entity with the same tuple onto the same work map
-- mid-carry would retire the carried one's backup against the wrong row and leave
-- the carried entity at the new coords instead of where it gets dropped.
local function placeGate()
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then Game.Notify('open the editor first (/mapedit)', 'error'); return false end
    if carrying then Game.Notify('drop the entity you are carrying first', 'error'); return false end
    return true
end

RegisterCommand('mapworkmap', function(_, args)
    if not args[1] then Game.Notify('work map: ' .. workMap, 'inform'); return end
    workMap = (tostring(args[1])):gsub('[^%w_%-]', ''):sub(1, 64)
    if workMap == '' then workMap = Config.LiveDefaultMap end
    Game.Notify('scene entities now place on map: ' .. workMap, 'success')
end, false)

RegisterCommand('matped', function(_, args)
    if not placeGate() then return end
    if not args[1] then Game.Notify('usage: /matped <model> [scenario]', 'error'); return end
    -- A vehicle model would fail in CreatePed on every client — reject early.
    if Game.ModelIsVehicle(args[1]) then Game.Notify(args[1] .. ' is a vehicle — use /matveh', 'error'); return end
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    TriggerServerEvent('palm6_mapeditor:ent:place', 'ped', args[1], x, y, z, Game.PlayerHeading(), args[2] or '', workMap)
end, false)

RegisterCommand('matveh', function(_, args)
    if not placeGate() then return end
    if not args[1] then Game.Notify('usage: /matveh <model>', 'error'); return end
    if not Game.ModelIsVehicle(args[1]) then Game.Notify(args[1] .. ' is not a vehicle model', 'error'); return end
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    TriggerServerEvent('palm6_mapeditor:ent:place', 'veh', args[1], x, y, z, Game.PlayerHeading(), '', workMap)
end, false)

-- Place a ped/vehicle chosen in the /propui Peds or Vehicles browser. Same aim +
-- place path as the commands above; kind/model already validated in nui.lua, and
-- re-checked here (a vehicle model can't spawn as a ped and vice-versa).
AddEventHandler('palm6_mapeditor:placeEnt', function(kind, model, scenario)
    if not placeGate() then return end
    if (kind ~= 'ped' and kind ~= 'veh') or type(model) ~= 'string' or not model:match('^[%w_]+$') then return end
    if kind == 'veh' and not Game.ModelIsVehicle(model) then Game.Notify(model .. ' is not a vehicle model', 'error'); return end
    if kind == 'ped' and Game.ModelIsVehicle(model) then Game.Notify(model .. ' is a vehicle — use the Vehicles tab', 'error'); return end
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    -- Scenario is a ped behaviour (server clamps it to [%w_]); vehicles ignore it.
    local extra = (kind == 'ped' and type(scenario) == 'string') and scenario or ''
    TriggerServerEvent('palm6_mapeditor:ent:place', kind, model, x, y, z, Game.PlayerHeading(), extra, workMap)
end)

-- Remove the scene entity nearest your aim. Uses nearest-to-aim (not a raycast)
-- because the editor's shapetest only intersects world+objects, NOT peds or
-- vehicles — so a raycast could never hit a scene entity.
RegisterCommand('matentdel', function()
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then x, y, z = Game.PlayerPos() end
    local best, bestD
    for id, e in pairs(liveEnts) do
        local d = (e.x - x) ^ 2 + (e.y - y) ^ 2 + (e.z - z) ^ 2
        if not bestD or d < bestD then bestD, best = d, id end
    end
    if not best then Game.Notify('no scene entities nearby', 'inform'); return end
    TriggerServerEvent('palm6_mapeditor:ent:remove', best)
end, false)

RegisterCommand('mapentwipe', function(_, args)
    TriggerServerEvent('palm6_mapeditor:ent:wipeMap', args[1] or workMap)
end, false)

RegisterCommand('mapentlist', function() TriggerServerEvent('palm6_mapeditor:ent:list') end, false)

-- Scene-entity outliner + Performance counts. liveEnts already holds the full
-- streamed set (peds + vehicles), so the /propui "Entities" view is built
-- client-side — no server enumeration. Delete reuses the audited ent:remove
-- server event; goto is a local teleport. Peds/vehicles can't be raycast, so an
-- outliner is the only precise way to jump to or remove a specific one.
Entities = {}
function Entities.count()
    local peds, veh = 0, 0
    for _, e in pairs(liveEnts) do
        if e.kind == 'veh' then veh = veh + 1 else peds = peds + 1 end
    end
    return peds, veh
end
function Entities.list()
    local out = {}
    for id, e in pairs(liveEnts) do
        out[#out + 1] = { id = id, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z }
    end
    return out
end
function Entities.push()
    SendNUIMessage({ action = 'entities', ents = Entities.list() })
end
-- Entities on a named map, for the map export (peds/vehicles as a spawn list).
function Entities.exportList(map)
    local out = {}
    for _, e in pairs(liveEnts) do
        if e.map == map then
            out[#out + 1] = { kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading or 0.0, scenario = e.extra or '' }
        end
    end
    return out
end
function Entities.deleteById(id)
    id = tonumber(id)
    if id and liveEnts[id] then TriggerServerEvent('palm6_mapeditor:ent:remove', id) end
end
-- Batch delete (outliner multi-select): loops the audited per-id remove, exactly
-- like the live-map multi-delete. Each removal broadcasts + re-pushes the list.
function Entities.deleteByIds(ids)
    if type(ids) ~= 'table' then return end
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n and liveEnts[n] then TriggerServerEvent('palm6_mapeditor:ent:remove', n) end
    end
end
function Entities.gotoById(id)
    id = tonumber(id)
    local e = id and liveEnts[id]
    if not e then return end
    Game.TeleportPlayer(e.x, e.y, e.z)
    Game.Notify('jumped to ' .. tostring(e.model), 'inform')
end
function Entities.grabById(id)
    id = tonumber(id)
    if id and liveEnts[id] then TriggerServerEvent('palm6_mapeditor:ent:grab', id) end
end

-- Carry-to-move a grabbed entity. The server already removed the original and
-- sent us its data; we spawn a LOCAL (non-networked) preview that tracks the
-- camera aim + player heading each frame, then re-place it via ent:place on
-- Enter (drop at new spot) or Backspace (restore at the original spot). Reuses
-- the mass-fill preview's control scheme; stands the editor loop down while up.
-- `carrying` is declared at the top of this file (placeGate needs it).
-- Exposed so every NUI-focus entry point can refuse to open mid-carry: NUI focus
-- steals the Enter/Backspace the carry loop needs to resolve.
function Entities.isCarrying() return carrying end
RegisterNetEvent('palm6_mapeditor:ent:grabbed', function(rec)
    -- Say so rather than returning silently: the server has already deleted the
    -- row and handed us the only copy, so a silent drop here looks exactly like
    -- the entity vanishing. (The server also refuses a second grab now, so this
    -- is the belt to that braces.)
    if carrying then Game.Notify('already carrying an entity, drop it first', 'error'); return end
    if type(rec) ~= 'table' or (rec.kind ~= 'ped' and rec.kind ~= 'veh') or type(rec.model) ~= 'string' then return end
    carrying = true
    if MapEd and MapEd.setPreview then MapEd.setPreview(true) end   -- editor loop stands down
    CreateThread(function()
        local x, y, z = Game.CameraAimPoint(40.0)
        if not x then x, y, z = Game.PlayerPos() end
        local ent = (rec.kind == 'veh') and Game.SpawnVehicle(rec.model, x, y, z, rec.heading or 0.0)
                    or Game.SpawnPed(rec.model, x, y, z, rec.heading or 0.0, rec.extra)
        local resolved = false
        while carrying do
            if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then break end   -- editor off -> restore below
            local ax, ay, az = Game.CameraAimPoint(40.0)
            if ax then x, y, z = ax, ay, az end
            local h = Game.PlayerHeading()
            if ent then Game.SetObjectTransform(ent, x, y, z, 0.0, 0.0, h) end
            Game.DrawRect2D(0.5, 0.90, 0.46, 0.065, 0, 0, 0, 170)
            Game.DrawText2D(('~w~Moving: ~b~%s'):format(rec.model), 0.5, 0.877, 0.42, 235, 235, 235, true)
            Game.DrawText2D('~g~[Enter]~w~ drop     ~r~[Backspace]~w~ cancel', 0.5, 0.905, 0.36, 200, 210, 225, true)
            DisableControlAction(0, 201, true)   -- accept (Enter)
            DisableControlAction(0, 202, true)   -- Esc (don't let it exit the editor)
            DisableControlAction(0, 177, true)   -- Backspace
            if IsDisabledControlJustPressed(0, 201) then
                TriggerServerEvent('palm6_mapeditor:ent:place', rec.kind, rec.model, x, y, z, h, rec.extra or '', rec.map)
                Game.Notify('moved ' .. tostring(rec.model), 'success')
                resolved = true; break
            elseif IsDisabledControlJustPressed(0, 202) or IsDisabledControlJustPressed(0, 177) then
                TriggerServerEvent('palm6_mapeditor:ent:place', rec.kind, rec.model, rec.x, rec.y, rec.z, rec.heading, rec.extra or '', rec.map)
                Game.Notify('move cancelled', 'inform')
                resolved = true; break
            end
            Wait(0)
        end
        if ent then Game.DeleteAnyEntity(ent) end
        -- Editor toggled off mid-carry (loop broke without a key): restore original.
        if not resolved then
            TriggerServerEvent('palm6_mapeditor:ent:place', rec.kind, rec.model, rec.x, rec.y, rec.z, rec.heading, rec.extra or '', rec.map)
        end
        -- No "I'm done" event any more. Every exit from this loop re-places the
        -- entity via ent:place, and the SERVER retires the disconnect-restore
        -- backup inside that insert's write-lock when the row it wrote matches the
        -- carried one. The old client-raised ent:grabResolved took no lock, did no
        -- validation, and nil'd the whole pending list, so a failed re-place threw
        -- away the only surviving copy of the entity.
        if MapEd and MapEd.setPreview then MapEd.setPreview(false) end
        carrying = false
    end)
end)

-- Scene entities are our own client entities; delete them on stop so a resource
-- restart never leaves orphaned peds/vehicles in the world.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stopping = true; despawnAll() end   -- stopping: in-flight spawns self-delete
end)
