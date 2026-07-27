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
RegisterNetEvent('palm6_mapeditor:ent:place', function(kind, model, x, y, z, heading, extra, map)
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    if not EREADY then enotify(src, 'entity DB not ready yet', 'error'); return end
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
        if id then e.id = id; ents[id] = e end
    end)
    if not acquired then enotify(src, 'editor busy — try again', 'error'); return end
    if capped then enotify(src, ('scene-entity cap reached (%d)'):format(Config.EntityMax), 'error'); return end
    if not e.id then enotify(src, 'DB write failed', 'error'); return end
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
    local grabbed, dberr = nil, false
    local acquired = withWriteLock(function()
        local e = ents[id]
        if not e then return end
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_entities WHERE id = ?', { id }) end) then dberr = true; return end
        grabbed = { map = e.map, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading, extra = e.extra }
        ents[id] = nil
    end)
    if not acquired then enotify(src, 'editor busy — try again', 'error'); return end
    if dberr then enotify(src, 'DB error', 'error'); return end
    if not grabbed then enotify(src, 'entity no longer exists', 'error'); return end
    grabbedPending[src] = grabbedPending[src] or {}
    grabbedPending[src][#grabbedPending[src] + 1] = grabbed
    TriggerClientEvent('palm6_mapeditor:ent:remove', -1, id)          -- despawn everywhere
    TriggerClientEvent('palm6_mapeditor:ent:grabbed', src, grabbed)   -- into the grabber's carry
    enotify(src, 'grabbed — move it, [Enter] to drop / [Backspace] to cancel', 'success')
end)

-- The client finished the carry (dropped or cancelled — either way it re-placed
-- the entity via ent:place), so drop the disconnect-restore backup.
RegisterNetEvent('palm6_mapeditor:ent:grabResolved', function()
    grabbedPending[source] = nil
end)

-- Restore any entities a player was carrying if they disconnect before dropping,
-- so a grab is non-destructive. Cleared by ent:grabResolved on a normal finish.
AddEventHandler('playerDropped', function()
    local src = source
    local pend = grabbedPending[src]; grabbedPending[src] = nil
    if not pend or #pend == 0 then return end
    withWriteLock(function()
        for _, e in ipairs(pend) do
            local id
            if pcall(function()
                id = MySQL.insert.await('INSERT INTO palm6_mapeditor_entities (map, kind, model, x, y, z, heading, extra, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    { e.map, e.kind, e.model, e.x, e.y, e.z, e.heading, e.extra, 'grab-restore' })
            end) and id then
                ents[id] = { id = id, map = e.map, kind = e.kind, model = e.model, x = e.x, y = e.y, z = e.z, heading = e.heading, extra = e.extra }
                TriggerClientEvent('palm6_mapeditor:ent:add', -1, wire(ents[id]))
            end
        end
    end)
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

-- ---- rename a map's entities (paired with live.lua's map rename) -----------
-- Silent (no notify): live.lua's renameMap owns the user-facing message; this is
-- the entity half of the same client action, keeping the entity table's map tags
-- consistent. Client liveEnts don't carry a map field, so no broadcast is needed.
RegisterNetEvent('palm6_mapeditor:ent:renameMap', function(oldName, newName)
    local src = source
    if not isAllowed(src) then return end
    if not EREADY then return end
    oldName = cleanMap(oldName); newName = cleanMap(newName)
    if oldName == newName then return end
    withWriteLock(function()
        if pcall(function() MySQL.query.await('UPDATE palm6_mapeditor_entities SET map = ? WHERE map = ?', { newName, oldName }) end) then
            for _, e in pairs(ents) do if e.map == oldName then e.map = newName end end
        end
    end)
end)

-- ---- list ------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:ent:list', function()
    local src = source
    if not isAllowed(src) then enotify(src, 'not authorized (needs admin)', 'error'); return end
    local peds, vehs = 0, 0
    for _, e in pairs(ents) do if e.kind == 'ped' then peds = peds + 1 else vehs = vehs + 1 end end
    enotify(src, ('scene entities: %d peds, %d vehicles (%d total)'):format(peds, vehs, entCount()), 'inform')
end)
