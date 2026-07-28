-- ============================================================================
-- palm6_mapeditor/server/entities.lua
--
-- Scene entities — peds and vehicles placed into the world, persisted, and
-- streamed to every player (client-local frozen entities, same idea as props).
-- A deliberately SELF-CONTAINED subsystem: it owns only palm6_mapeditor_entities
-- and never touches the prop/light/hide tables or the live.lua commit/wipe paths,
-- so adding it can't regress the already-audited live map. It reuses the same
-- hardened patterns: a write-lock serialising DB mutators, strict validation of
-- every client field, and per-successful-delete memory reconciliation.
--
-- MODEL
--   ents[id] = { id, map, kind('ped'|'veh'), model, x, y, z, heading, extra }
--   extra = the ped scenario name (or '' ); unused for vehicles.
--
-- NET (server -> client)
--   ent:add / ent:addBatch(list, full) / ent:remove / ent:removeBatch
--   ent:mapRenamed (old, new)  relabel streamed entities after a rename/merge
-- NET (client -> server)
--   ent:requestSync ()                                   (open — world content)
--   ent:place (kind, model, x,y,z, heading, extra, map)  ACE
--   ent:remove (id)                                      ACE
--   ent:wipeMap (map)                                    ACE
--   ent:list ()                                          ACE
-- ============================================================================

local EREADY = false
local ents = {}          -- [id] = { id, map, kind, model, x, y, z, heading, extra }
local grabbedPending = {} -- [src] = { {map,kind,model,x,y,z,heading,extra}, ... } carried entities
                          -- awaiting re-place; restored if the grabber disconnects mid-carry.
-- Forward declaration: defined below (after the grab), but ent:place needs it to
-- undo a carry whose re-place this handler refuses.
local restorePending

local function isAllowed(src) return src == 0 or IsPlayerAceAllowed(src, Config.Ace) end

local function enotify(src, msg, kind)
    if src == 0 then print('[palm6_mapeditor] ' .. msg); return end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = msg, type = kind or 'inform' })
end

-- ---- write-lock (its own; serialises this subsystem's DB mutators) ----------
local writeBusy = false
local function withWriteLock(fn)
    local waited = 0
    while writeBusy do
        Wait(5); waited = waited + 1
        if waited > 600 then return false end
    end
    writeBusy = true
    local ok, err = pcall(fn)
    writeBusy = false
    if not ok then print('[palm6_mapeditor] entities write-lock error: ' .. tostring(err)) end
    return ok
end

-- ---- validation ------------------------------------------------------------
local function cleanModel(m)
    if type(m) ~= 'string' or #m == 0 or #m > 64 then return nil end
    if not m:match('^[%w_]+$') then return nil end
    return m
end
local function cleanMap(m)
    m = (tostring(m or '')):gsub('[^%w_%-]', '')
    if m == '' then m = Config.LiveDefaultMap end
    return m:sub(1, 64)
end
local function cleanKind(k) return (k == 'veh') and 'veh' or (k == 'ped') and 'ped' or nil end
-- Scenario / extra: a conservative token (natives take a fixed name), else ''.
local function cleanExtra(e)
    e = (tostring(e or '')):gsub('[^%w_]', '')
    return e:sub(1, 48)
end
local function num(v, lo, hi, d)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return d end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
local function entCount() local n = 0; for _ in pairs(ents) do n = n + 1 end; return n end

local function wire(e)
    return { id = e.id, map = e.map, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading, extra = e.extra }
end
local function fullBatch()
    local out = {}; for _, e in pairs(ents) do out[#out + 1] = wire(e) end; return out
end

-- ---- boot ------------------------------------------------------------------
CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_mapeditor_entities` (
                `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `map`        VARCHAR(64)  NOT NULL DEFAULT 'default',
                `kind`       VARCHAR(8)   NOT NULL,
                `model`      VARCHAR(64)  NOT NULL,
                `x`          DOUBLE       NOT NULL,
                `y`          DOUBLE       NOT NULL,
                `z`          DOUBLE       NOT NULL,
                `heading`    DOUBLE       NOT NULL DEFAULT 0,
                `extra`      VARCHAR(48)  DEFAULT NULL,
                `created_by` VARCHAR(96)  DEFAULT NULL,
                `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_map` (`map`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        local rows = MySQL.query.await('SELECT id, map, kind, model, x, y, z, heading, extra FROM palm6_mapeditor_entities') or {}
        for _, r in ipairs(rows) do
            ents[r.id] = { id = r.id, map = r.map, kind = r.kind, model = r.model,
                x = r.x + 0.0, y = r.y + 0.0, z = r.z + 0.0, heading = (r.heading or 0.0) + 0.0, extra = r.extra or '' }
        end
        print(('[palm6_mapeditor] scene entities ready — %d loaded'):format(entCount()))
    end)
    if ok then
        EREADY = true
        TriggerClientEvent('palm6_mapeditor:ent:addBatch', -1, fullBatch(), true)
    else
        print(('[palm6_mapeditor] FATAL: could not create palm6_mapeditor_entities (%s).'):format(tostring(err)))
    end
end)

-- ---- sync (open — scene entities are world content everyone sees) ----------
RegisterNetEvent('palm6_mapeditor:ent:requestSync', function()
    TriggerClientEvent('palm6_mapeditor:ent:addBatch', source, fullBatch(), true)
end)

-- ---- place -----------------------------------------------------------------
-- A carry ends by re-placing through this handler, and the client clears its
-- `carrying` flag unconditionally the moment it fires. So if we REFUSE the place
-- (ACE revoked mid-carry, DB not ready, cap reached, write-lock timeout, failed
-- INSERT) the client is free but grabbedPending[src] still holds the backup, and
-- the grab guard below would then refuse every future grab with "already
-- carrying" for the rest of that session, with no in-game way out. Put the
-- entity back where it was grabbed instead: the row returns, everyone sees it
-- respawn, and the pending slot is released.
local function refusePlace(src, msg)
    enotify(src, msg, 'error')
    local pend = grabbedPending[src]
    if not (pend and #pend > 0) then return end
    if restorePending(src, 'refused place', false) then
        enotify(src, 'the entity you were carrying was put back where you grabbed it', 'inform')
    else
        -- Restore itself failed (write-lock timeout), so the backup is still held
        -- and the next grab will still be refused. Say so rather than leaving the
        -- admin to guess: retrying any place runs this rescue again.
        enotify(src, 'could not put your carried entity back yet, it is still held - try placing again', 'error')
    end
end

RegisterNetEvent('palm6_mapeditor:ent:place', function(kind, model, x, y, z, heading, extra, map)
    local src = source
    if not isAllowed(src) then refusePlace(src, 'not authorized (needs admin)'); return end
    if not EREADY then refusePlace(src, 'entity DB not ready yet'); return end
    kind = cleanKind(kind)
    model = cleanModel(model)
    if not kind or not model then enotify(src, 'invalid entity kind/model', 'error'); return end
    local e = {
        map = cleanMap(map), kind = kind, model = model,
        x = num(x, -20000.0, 20000.0, 0.0), y = num(y, -20000.0, 20000.0, 0.0), z = num(z, -2000.0, 5000.0, 0.0),
        heading = num(heading, 0.0, 360.0, 0.0), extra = (kind == 'ped') and cleanExtra(extra) or '',
    }
    local who = (GetPlayerName(src) or ('src' .. src)):sub(1, 96)
    local capped = false
    local acquired = withWriteLock(function()
        if entCount() >= Config.EntityMax then capped = true; return end
        local id
        if not pcall(function()
            id = MySQL.insert.await(
                'INSERT INTO palm6_mapeditor_entities (map, kind, model, x, y, z, heading, extra, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                { e.map, e.kind, e.model, e.x, e.y, e.z, e.heading, e.extra, who })
        end) then return end
        if id then
            e.id = id; ents[id] = e
            -- A carry resolves by re-placing the SAME entity (drop = new coords,
            -- cancel = the original ones), so a successful insert of a matching
            -- kind/model/map/extra IS that carry finishing: retire the backup here,
            -- inside the lock, against the row we just wrote. The old
            -- ent:grabResolved net event did this from the CLIENT with no lock and
            -- no validation, and nil'd the whole list, so anyone could wipe another
            -- grab's only surviving copy by firing it.
            -- NOT a per-carry token, so be precise about what this does and does
            -- not guarantee: an UNRELATED place of the same kind/model/map/extra
            -- (e.g. /matped <same model> on the same work map) produces an
            -- identical tuple and would retire the backup too. It cannot lose the
            -- entity (the row it matched against is a real, just-written copy of
            -- it), only leave it at the wrong coords. The client closes that window
            -- by refusing /matped, /matveh and the NUI placeEnt while a carry is
            -- up (client/entities.lua placeGate).
            local pend = grabbedPending[src]
            if pend then
                for i = #pend, 1, -1 do
                    local g = pend[i]
                    if g.kind == e.kind and g.model == e.model and g.map == e.map and g.extra == e.extra then
                        table.remove(pend, i); break
                    end
                end
                if #pend == 0 then grabbedPending[src] = nil end
            end
        end
    end)
    if not acquired then refusePlace(src, 'editor busy — try again'); return end
    if capped then refusePlace(src, ('scene-entity cap reached (%d)'):format(Config.EntityMax)); return end
    if not e.id then refusePlace(src, 'DB write failed'); return end
    TriggerClientEvent('palm6_mapeditor:ent:add', -1, wire(e))
    enotify(src, ('placed %s "%s" on "%s"'):format(kind, model, e.map), 'success')
end)

-- ---- remove one ------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:ent:remove', function(id)
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not ents[id] then enotify(src, 'no scene entity with that id', 'error'); return end
    local dberr = false
    local acquired = withWriteLock(function()
        if not ents[id] then return end
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_entities WHERE id = ?', { id }) end) then
            dberr = true; return
        end
        ents[id] = nil
    end)
    if not acquired then enotify(src, 'editor busy — try again', 'error'); return end
    if dberr then enotify(src, 'DB delete failed', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:ent:remove', -1, id)
    enotify(src, 'removed scene entity', 'success')
end)

-- ---- grab (move) one entity ------------------------------------------------
-- Remove the entity from the world (delete row + despawn for everyone) and hand
-- its data back to the grabber, who carries it to a new spot and re-places it
-- via ent:place. Mirrors live.lua's prop grab: a per-player backup restores the
-- entity if the grabber disconnects mid-carry, so a move can never lose it.
RegisterNetEvent('palm6_mapeditor:ent:grab', function(id)
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not ents[id] then enotify(src, 'no scene entity with that id', 'error'); return end
    local grabbed, dberr, already = nil, false, false
    local acquired = withWriteLock(function()
        -- One carry at a time. The client only ever carries one entity (the carry
        -- loop refuses to start a second), and the backup below is what makes a
        -- grab non-destructive, so a second grab must be refused BEFORE its delete,
        -- not merged into the same pending list where a single resolution would
        -- discard it. Checked inside the lock because withWriteLock can yield.
        if grabbedPending[src] and #grabbedPending[src] > 0 then already = true; return end
        local e = ents[id]
        if not e then return end
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_entities WHERE id = ?', { id }) end) then dberr = true; return end
        grabbed = { map = e.map, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading, extra = e.extra }
        ents[id] = nil
        grabbedPending[src] = { grabbed }
    end)
    if not acquired then enotify(src, 'editor busy — try again', 'error'); return end
    if already then enotify(src, 'you are already carrying an entity, drop it first', 'error'); return end
    if dberr then enotify(src, 'DB error', 'error'); return end
    if not grabbed then enotify(src, 'entity no longer exists', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:ent:remove', -1, id)          -- despawn everywhere
    TriggerClientEvent('palm6_mapeditor:ent:grabbed', src, grabbed)   -- into the grabber's carry
    enotify(src, 'grabbed — move it, [Enter] to drop / [Backspace] to cancel', 'success')
end)

-- Re-insert one player's carried entities and drop the backup. The grab DELETES
-- the row up front, so this table is the only copy until the carry is re-placed.
--
-- `inline` is the TEARDOWN path (onResourceStop) and it must not yield even once.
-- withWriteLock can Wait() up to ~3s, and MySQL.insert.await IS Citizen.Await:
-- under lua54 that yield propagates out through pcall and out of the
-- onResourceStop handler, which teardown never schedules again, so the handler
-- would suspend on the FIRST row and abandon every entity after it plus every
-- other player's pending grabs. The inline path therefore uses the non-await call
-- form, which only hands the query to oxmysql (a separate, still-running
-- resource) and returns, and skips the ents[] mirror + broadcast entirely: the
-- boot hydrate rebuilds both from these rows. Mirrors the identical rescue in
-- server/live.lua for grabbed props.
restorePending = function(src, why, inline)
    local pend = grabbedPending[src]
    grabbedPending[src] = nil
    if not pend or #pend == 0 then return end
    if inline then
        local queued = 0
        for _, e in ipairs(pend) do
            local ok = pcall(function()
                MySQL.insert('INSERT INTO palm6_mapeditor_entities (map, kind, model, x, y, z, heading, extra, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    { e.map, e.kind, e.model, e.x, e.y, e.z, e.heading, e.extra, 'grab-restore' })
            end)
            if ok then queued = queued + 1 end
        end
        print(('[palm6_mapeditor] queued %d/%d carried scene entit(ies) for restore after a %s'):format(queued, #pend, why))
        return
    end
    local restored = 0
    withWriteLock(function()
        for _, e in ipairs(pend) do
            local id
            if pcall(function()
                id = MySQL.insert.await('INSERT INTO palm6_mapeditor_entities (map, kind, model, x, y, z, heading, extra, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    { e.map, e.kind, e.model, e.x, e.y, e.z, e.heading, e.extra, 'grab-restore' })
            end) and id then
                ents[id] = { id = id, map = e.map, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading, extra = e.extra }
                TriggerClientEvent('palm6_mapeditor:ent:add', -1, wire(ents[id]))
                restored = restored + 1
            end
        end
        if restored > 0 then print(('[palm6_mapeditor] restored %d carried scene entit(ies) after a %s'):format(restored, why)) end
    end)
    -- The backup is cleared up front, but withWriteLock returns false WITHOUT
    -- running the body when it times out (~3s of contention). Dropping `pend` in
    -- that case would destroy the only remaining copy of the entity, so put it
    -- back and let the next refused place / disconnect / resource stop retry it.
    if restored == 0 then grabbedPending[src] = pend end
    return restored > 0
end

-- Restore any entities a player was carrying if they disconnect before dropping,
-- so a grab is non-destructive. Cleared by a matching ent:place on a normal finish.
AddEventHandler('playerDropped', function()
    restorePending(source, 'disconnect', false)
end)

-- The OTHER abandonment, and the one a deploy causes: the resource stopping under
-- the carrier. The row is already deleted and grabbedPending is plain memory, so
-- without this a restart while an admin carries an entity destroys it permanently.
-- Inline and strictly non-yielding (no Wait, no write-lock, no MySQL .await,
-- which is Citizen.Await): teardown will not schedule us again, so ANY yield here
-- abandons every row after the first. restorePending's inline path
-- fire-and-forgets each INSERT so all of them leave this VM before we return.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- Clearing the current key inside pairs() is explicitly allowed in Lua, and
    -- restorePending nils exactly the key it is handed.
    for src in pairs(grabbedPending) do restorePending(src, 'resource stop', true) end
end)

-- ---- wipe a map's entities -------------------------------------------------
RegisterNetEvent('palm6_mapeditor:ent:wipeMap', function(map)
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    map = cleanMap(map)
    local ids, dberr = {}, false
    local acquired = withWriteLock(function()
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_entities WHERE map = ?', { map }) end) then
            dberr = true; return
        end
        for id, e in pairs(ents) do if e.map == map then ids[#ids + 1] = id; ents[id] = nil end end
    end)
    if not acquired then enotify(src, 'editor busy — try again', 'error'); return end
    if dberr then enotify(src, 'DB delete failed', 'error'); return end
    if #ids == 0 then enotify(src, ('no scene entities on "%s"'):format(map), 'inform'); return end
    TriggerClientEvent('palm6_mapeditor:ent:removeBatch', -1, ids)
    enotify(src, ('wiped %d scene entit(ies) from "%s"'):format(#ids, map), 'success')
end)

-- ---- rename a map's entities (driven by live.lua's rename/merge) -----------
-- SERVER-raised only: live.lua emits palm6_mapeditor:internal:entRename after its
-- own ACE / READY / name-collision / cap guards have passed AND after its DB
-- writes reported success, and we listen with AddEventHandler (not
-- RegisterNetEvent) so no client can reach it. It used to be
-- a net event the client fired independently of live:renameMap, which meant a
-- rename the prop half REFUSED still relabelled the entity table, so the two could
-- silently disagree about which map an entity belongs to.
--
-- Silent (no notify): live.lua's renameMap owns the user-facing message. It DOES
-- broadcast, because client liveEnts DO carry a map field (client/entities.lua
-- stores map = rec.map) and Entities.exportList selects on it. Without the
-- relabel, every export after a rename or merge dropped all of that map's peds
-- and vehicles.
AddEventHandler('palm6_mapeditor:internal:entRename', function(oldName, newName)
    if not EREADY then return end
    oldName = cleanMap(oldName); newName = cleanMap(newName)
    if oldName == newName then return end
    local moved = false
    withWriteLock(function()
        if pcall(function() MySQL.query.await('UPDATE palm6_mapeditor_entities SET map = ? WHERE map = ?', { newName, oldName }) end) then
            for _, e in pairs(ents) do if e.map == oldName then e.map = newName end end
            moved = true
        end
    end)
    if moved then TriggerClientEvent('palm6_mapeditor:ent:mapRenamed', -1, oldName, newName) end
end)

-- ---- list ------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:ent:list', function()
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    local peds, vehs = 0, 0
    for _, e in pairs(ents) do if e.kind == 'ped' then peds = peds + 1 else vehs = vehs + 1 end end
    enotify(src, ('scene entities: %d peds, %d vehicles (%d total)'):format(peds, vehs, entCount()), 'inform')
end)
