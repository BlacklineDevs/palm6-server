-- ============================================================================
-- palm6_mapeditor/server/live.lua
--
-- Persistence + live networked sync. This is what turns the editor from a
-- personal, client-local session tool into a real server tool: committed props
-- live in MySQL, stream to EVERY connected player, and survive a restart.
-- server/main.lua still owns file export (Lua/JSON/ymap); this file owns the DB
-- and the authoritative live prop set. Self-creates its ONE table at boot
-- (CREATE TABLE IF NOT EXISTS — CI never touches the DB, the palm6_heat/ems
-- pattern), so a fault here can never reach any other resource's data.
--
-- MODEL
--   A "map" is a named set of rows in palm6_mapeditor_props. Every row in the
--   table is LIVE — if it's in the DB, all players see it. There is no draft
--   state: /mapcommit INSERTS rows (append, so a map grows over sessions),
--   /maplivedel deletes one, /mapwipe deletes a whole map. This deliberately
--   avoids a fragile "check-out then edit" round-trip that could lose data.
--
-- AUTHORITY
--   The server is the source of truth. It holds live[id] = {map,model,...} in
--   memory (a mirror of the DB) and is the only writer. Clients never send a
--   prop id they invented; they send placements (model + coords), the server
--   assigns ids. Model names and coords are re-validated server-side before any
--   insert — the client is never trusted, exactly like every other write path.
--
-- NET (server -> client)
--   live:add       {id,model,x,y,z,rx,ry,rz}    spawn one
--   live:addBatch  ({list}, full)               initial sync (full) / commit
--   live:remove    id                           despawn one
--   live:removeBatch {ids}                       despawn many (map wipe)
-- NET (client -> server)
--   live:requestSync ()                          any player -> full addBatch
--   live:commit      (map, {placements})         ACE
--   live:removeOne   (id)                         ACE
--   live:wipeMap     (map)                        ACE
--   live:list        ()                           ACE -> summary notify
-- ============================================================================

local READY = false       -- flips true once the tables are confirmed present
local live = {}           -- [id] = { id, map, model, x, y, z, rx, ry, rz }
local hides = {}          -- [id] = { id, x, y, z, radius, model }  (world-prop erases)
local lights = {}         -- [id] = { id, map, x, y, z, r, g, b, range, intensity, kind }

-- Writes are admin-only (same ACE the /mapedit command is gated on); reads
-- (requestSync) are open so every player sees the built map. src 0 = console.
local function isAllowed(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.Ace)
end

local function notify(src, msg, kind)
    if src == 0 then print('[palm6_mapeditor] ' .. msg); return end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = msg, type = kind or 'inform' })
end

-- ---------------------------------------------------------------------------
-- Sanitisers — the client is untrusted. A model name must match the SAME
-- strict [A-Za-z0-9_] rule the client spawner enforces (so nothing that lands
-- in the DB could ever break a generated Lua/ymap export or be dofile-injected).
-- ---------------------------------------------------------------------------
local function cleanModel(m)
    if type(m) ~= 'string' then return nil end
    if #m == 0 or #m > 64 then return nil end
    if not m:match('^[%w_]+$') then return nil end
    return m
end

local function cleanMap(m)
    m = (tostring(m or '')):gsub('[^%w_%-]', '')
    if m == '' then m = Config.LiveDefaultMap end
    return m:sub(1, 64)
end

-- Finite number clamped to [lo,hi], else default (rejects NaN/inf/garbage).
local function num(v, lo, hi, d)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return d end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- A client placement -> a validated row (no id yet), or nil if the model is bad.
-- Coords are clamped to a generous world envelope; rotation to +/-360.
local function cleanPlacement(p)
    if type(p) ~= 'table' then return nil end
    local model = cleanModel(p.model)
    if not model then return nil end
    return {
        model = model,
        x = num(p.x, -20000.0, 20000.0, 0.0),
        y = num(p.y, -20000.0, 20000.0, 0.0),
        z = num(p.z, -2000.0, 5000.0, 0.0),
        rx = num(p.rx, -360.0, 360.0, 0.0),
        ry = num(p.ry, -360.0, 360.0, 0.0),
        rz = num(p.rz, -360.0, 360.0, 0.0),
    }
end

local function mapCount(map)
    local n = 0
    for _, r in pairs(live) do if r.map == map then n = n + 1 end end
    return n
end

-- Strip the row down to exactly the fields the client spawner needs.
local function wire(r)
    return { id = r.id, model = r.model, x = r.x, y = r.y, z = r.z, rx = r.rx, ry = r.ry, rz = r.rz }
end

local function wireHide(h)
    return { id = h.id, x = h.x, y = h.y, z = h.z, radius = h.radius, model = h.model }
end

-- A model HASH (uint32) as sent from the client's GetEntityModel. FiveM Lua
-- returns model hashes as a SIGNED int32, so any hash with the high bit set
-- arrives negative — fold it back into the uint32 range before storing, or
-- /mapworlderase silently rejects ~half of all vanilla props.
local function cleanHash(m)
    m = math.floor(tonumber(m) or 0)
    m = m % 0x100000000          -- signed int32 -> uint32 (Lua % is always >= 0 here)
    if m == 0 then return nil end
    return m
end

local function fullHideBatch()
    local out = {}; for _, h in pairs(hides) do out[#out + 1] = wireHide(h) end; return out
end

local function wireLight(l)
    return { id = l.id, x = l.x, y = l.y, z = l.z, r = l.r, g = l.g, b = l.b, range = l.range, intensity = l.intensity, kind = l.kind }
end
local function fullLightBatch()
    local out = {}; for _, l in pairs(lights) do out[#out + 1] = wireLight(l) end; return out
end

-- Validate a client light def -> a clean row (no id), or nil. Colour bytes are
-- clamped ints; range/intensity/coords clamped; kind restricted to point|spot.
local function cleanLight(l)
    if type(l) ~= 'table' then return nil end
    local kind = (l.kind == 'spot') and 'spot' or 'point'
    return {
        x = num(l.x, -20000.0, 20000.0, 0.0), y = num(l.y, -20000.0, 20000.0, 0.0), z = num(l.z, -2000.0, 5000.0, 0.0),
        r = math.floor(num(l.r, 0, 255, 255)), g = math.floor(num(l.g, 0, 255, 200)), b = math.floor(num(l.b, 0, 255, 140)),
        range = num(l.range, 0.5, 100.0, 8.0), intensity = num(l.intensity, 0.1, 50.0, 5.0), kind = kind,
    }
end
local function lightCount() local n = 0; for _ in pairs(lights) do n = n + 1 end; return n end

-- Every DB-mutating handler yields at MySQL.*.await, so on the single main
-- thread two of them CAN interleave (a /mapwipe deleting rows a concurrent
-- /mapcommit is inserting, or two commits both reading a stale per-map count and
-- blowing past the cap). This lock serialises the write sections so each one
-- sees a settled `live`/`hides` and the DB and the in-memory mirror can never
-- diverge. Reads (requestSync/list) don't take it — a slightly stale read is
-- harmless. fn runs under pcall; the lock is always released.
local writeBusy = false
local function withWriteLock(fn)
    local waited = 0
    while writeBusy do
        Wait(5); waited = waited + 1
        if waited > 600 then return false end   -- ~3s ceiling: never deadlock a handler
    end
    writeBusy = true
    local ok, err = pcall(fn)
    writeBusy = false
    if not ok then print('[palm6_mapeditor] write-lock body error: ' .. tostring(err)) end
    return ok
end

-- ---------------------------------------------------------------------------
-- Boot: self-create the table, then hydrate `live` from it. Guarded and
-- idempotent; the surface stays inert (READY=false) until the table is
-- confirmed, so a commit racing a slow DB can never hit a missing table.
-- ---------------------------------------------------------------------------
CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_mapeditor_props` (
                `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `map`        VARCHAR(64)  NOT NULL DEFAULT 'default',
                `model`      VARCHAR(64)  NOT NULL,
                `x`          DOUBLE       NOT NULL,
                `y`          DOUBLE       NOT NULL,
                `z`          DOUBLE       NOT NULL,
                `rx`         DOUBLE       NOT NULL DEFAULT 0,
                `ry`         DOUBLE       NOT NULL DEFAULT 0,
                `rz`         DOUBLE       NOT NULL DEFAULT 0,
                `created_by` VARCHAR(96)  DEFAULT NULL,
                `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_map` (`map`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_mapeditor_hides` (
                `id`         INT UNSIGNED    NOT NULL AUTO_INCREMENT,
                `x`          DOUBLE          NOT NULL,
                `y`          DOUBLE          NOT NULL,
                `z`          DOUBLE          NOT NULL,
                `radius`     DOUBLE          NOT NULL DEFAULT 1,
                `model`      BIGINT UNSIGNED NOT NULL,
                `created_by` VARCHAR(96)     DEFAULT NULL,
                `created_at` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        local rows = MySQL.query.await('SELECT id, map, model, x, y, z, rx, ry, rz FROM palm6_mapeditor_props') or {}
        for _, row in ipairs(rows) do
            live[row.id] = {
                id = row.id, map = row.map, model = row.model,
                x = row.x + 0.0, y = row.y + 0.0, z = row.z + 0.0,
                rx = row.rx + 0.0, ry = row.ry + 0.0, rz = row.rz + 0.0,
            }
        end
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_mapeditor_lights` (
                `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `map`        VARCHAR(64)  NOT NULL DEFAULT 'default',
                `x`          DOUBLE       NOT NULL,
                `y`          DOUBLE       NOT NULL,
                `z`          DOUBLE       NOT NULL,
                `r`          SMALLINT     NOT NULL DEFAULT 255,
                `g`          SMALLINT     NOT NULL DEFAULT 200,
                `b`          SMALLINT     NOT NULL DEFAULT 140,
                `range`      DOUBLE       NOT NULL DEFAULT 8,
                `intensity`  DOUBLE       NOT NULL DEFAULT 5,
                `kind`       VARCHAR(8)   NOT NULL DEFAULT 'point',
                `created_by` VARCHAR(96)  DEFAULT NULL,
                `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_map` (`map`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        local hrows = MySQL.query.await('SELECT id, x, y, z, radius, model FROM palm6_mapeditor_hides') or {}
        for _, row in ipairs(hrows) do
            hides[row.id] = { id = row.id, x = row.x + 0.0, y = row.y + 0.0, z = row.z + 0.0, radius = row.radius + 0.0, model = math.floor(row.model) }
        end
        local lrows = MySQL.query.await('SELECT id, map, x, y, z, r, g, b, `range`, intensity, kind FROM palm6_mapeditor_lights') or {}
        for _, row in ipairs(lrows) do
            lights[row.id] = { id = row.id, map = row.map, x = row.x + 0.0, y = row.y + 0.0, z = row.z + 0.0,
                r = math.floor(row.r), g = math.floor(row.g), b = math.floor(row.b),
                range = row.range + 0.0, intensity = row.intensity + 0.0, kind = row.kind or 'point' }
        end
        local n = 0; for _ in pairs(live) do n = n + 1 end
        local hn = 0; for _ in pairs(hides) do hn = hn + 1 end
        local ln = lightCount()
        print(('[palm6_mapeditor] live map ready — %d prop(s), %d world-erase(s), %d light(s) loaded'):format(n, hn, ln))
    end)
    if ok then
        READY = true
        -- Any client that started before the DB was ready and already asked for
        -- a sync got an empty set; push the real set now they exist.
        TriggerClientEvent('palm6_mapeditor:live:addBatch', -1, (function()
            local out = {}; for _, r in pairs(live) do out[#out + 1] = wire(r) end; return out
        end)(), true)
        TriggerClientEvent('palm6_mapeditor:live:hideBatch', -1, fullHideBatch(), true)
        TriggerClientEvent('palm6_mapeditor:live:lightBatch', -1, fullLightBatch(), true)
    else
        print(('[palm6_mapeditor] FATAL: could not create palm6_mapeditor_props (%s). Live map is inert until the DB is reachable.'):format(tostring(err)))
    end
end)

-- ---------------------------------------------------------------------------
-- Sync: any player asking for the current live map gets the full set. Open to
-- everyone (not ACE) — this is how normal players see what admins have built.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:requestSync', function()
    local src = source
    local out = {}
    for _, r in pairs(live) do out[#out + 1] = wire(r) end
    TriggerClientEvent('palm6_mapeditor:live:addBatch', src, out, true)      -- full=true
    TriggerClientEvent('palm6_mapeditor:live:hideBatch', src, fullHideBatch(), true)
    TriggerClientEvent('palm6_mapeditor:live:lightBatch', src, fullLightBatch(), true)
end)

-- ---------------------------------------------------------------------------
-- Commit: publish a personal session to a live map. Inserts each valid
-- placement, assigns real ids, mirrors into `live`, and broadcasts the new
-- props to EVERY client. Append semantics — commit the same map again to grow
-- it. Bounded by Config.LiveMaxCommit (per call) and Config.LiveMaxProps (total
-- per map) so a runaway client can't flood the DB or every player's object pool.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:commit', function(map, placements, lightDefs)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    if not READY then notify(src, 'live map DB not ready yet', 'error'); return end
    if type(placements) ~= 'table' then placements = {} end
    if type(lightDefs) ~= 'table' then lightDefs = {} end
    if #placements == 0 and #lightDefs == 0 then notify(src, 'nothing to commit', 'error'); return end

    map = cleanMap(map)
    local who = (GetPlayerName(src) or ('src' .. src)):sub(1, 96)
    local added, addedLights, rejected, full = {}, {}, 0, false
    -- Locked: read the per-map count, insert props + lights, and mirror into the
    -- in-memory sets as one atomic section, so caps hold and no concurrent
    -- wipe/commit interleaves.
    local acquired = withWriteLock(function()
        local room = Config.LiveMaxProps - mapCount(map)
        if room <= 0 and #placements > 0 then full = true; return end
        for i = 1, #placements do
            if #added >= Config.LiveMaxCommit or #added >= room then break end
            local p = cleanPlacement(placements[i])
            if not p then
                rejected = rejected + 1
            else
                local id
                local wrote = pcall(function()
                    id = MySQL.insert.await(
                        'INSERT INTO palm6_mapeditor_props (map, model, x, y, z, rx, ry, rz, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                        { map, p.model, p.x, p.y, p.z, p.rx, p.ry, p.rz, who })
                end)
                if wrote and id then
                    p.id, p.map = id, map
                    live[id] = p
                    added[#added + 1] = wire(p)
                else
                    rejected = rejected + 1
                end
            end
        end
        -- Lights, bounded by the global light cap.
        local lroom = Config.LiveMaxLights - lightCount()
        for i = 1, #lightDefs do
            if #addedLights >= lroom then break end
            local l = cleanLight(lightDefs[i])
            if l then
                local id
                local wrote = pcall(function()
                    id = MySQL.insert.await(
                        'INSERT INTO palm6_mapeditor_lights (map, x, y, z, r, g, b, `range`, intensity, kind, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                        { map, l.x, l.y, l.z, l.r, l.g, l.b, l.range, l.intensity, l.kind, who })
                end)
                if wrote and id then
                    l.id, l.map = id, map
                    lights[id] = l
                    addedLights[#addedLights + 1] = wireLight(l)
                end
            end
        end
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if full then notify(src, ('map "%s" is full (%d cap)'):format(map, Config.LiveMaxProps), 'error'); return end

    if #added > 0 then TriggerClientEvent('palm6_mapeditor:live:addBatch', -1, added, false) end
    if #addedLights > 0 then TriggerClientEvent('palm6_mapeditor:live:lightBatch', -1, addedLights, false) end
    if #added > 0 or #addedLights > 0 then
        -- Ack the committer so it clears its session ONLY now that rows are
        -- actually persisted (a rejected/failed commit sends no ack, so the
        -- admin never loses an unsaved session to a transient DB hiccup).
        TriggerClientEvent('palm6_mapeditor:live:committed', src)
    end
    local msg = ('committed %d prop(s) + %d light(s) to "%s"'):format(#added, #addedLights, map)
    if rejected > 0 then msg = msg .. (' (%d rejected)'):format(rejected) end
    notify(src, msg, (#added > 0 or #addedLights > 0) and 'success' or 'error')
    print(('[palm6_mapeditor] %s committed %d prop(s), %d light(s) to map "%s"'):format(who, #added, #addedLights, map))
end)

-- ---------------------------------------------------------------------------
-- Remove one live prop (the client raycast a live object and sent its id).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:removeOne', function(id)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not live[id] then notify(src, 'no live prop with that id', 'error'); return end
    local dberr = false
    local acquired = withWriteLock(function()
        if not live[id] then return end   -- vanished while we waited for the lock
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_props WHERE id = ?', { id }) end) then
            dberr = true; return
        end
        live[id] = nil
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if dberr then notify(src, 'DB delete failed', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:live:remove', -1, id)
    notify(src, 'removed live prop', 'success')
end)

-- Grab one live prop back into the caller's editing session so a committed prop
-- can be repositioned/adjusted (the only way to EDIT a live prop). Under the
-- lock: delete the row, drop it from `live`, despawn it for everyone, then hand
-- the prop's data to the grabber to spawn as a normal editable session prop. Only
-- one prop leaves the live set per grab, so the window where it's "checked out"
-- is tiny and per-prop — never the fragile whole-map checkout.
RegisterNetEvent('palm6_mapeditor:live:grabProp', function(id)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not live[id] then notify(src, 'no live prop with that id', 'error'); return end
    local grabbed, dberr = nil, false
    local acquired = withWriteLock(function()
        local r = live[id]
        if not r then return end   -- taken by someone else while we waited
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_props WHERE id = ?', { id }) end) then
            dberr = true; return
        end
        grabbed = { model = r.model, x = r.x, y = r.y, z = r.z, rx = r.rx, ry = r.ry, rz = r.rz }
        live[id] = nil
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if dberr then notify(src, 'DB error', 'error'); return end
    if not grabbed then notify(src, 'prop no longer live', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:live:remove', -1, id)           -- despawn for everyone
    TriggerClientEvent('palm6_mapeditor:live:grabbed', src, grabbed)    -- into the grabber's session
    notify(src, 'grabbed prop into your session — edit it, then /mapcommit to republish', 'success')
end)

-- Remove one live light (the client picked it by aim and sent its id).
RegisterNetEvent('palm6_mapeditor:live:removeLightOne', function(id)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not lights[id] then notify(src, 'no live light with that id', 'error'); return end
    local dberr = false
    local acquired = withWriteLock(function()
        if not lights[id] then return end
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_lights WHERE id = ?', { id }) end) then
            dberr = true; return
        end
        lights[id] = nil
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if dberr then notify(src, 'DB delete failed', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:live:lightRemove', -1, id)
    notify(src, 'removed live light', 'success')
end)

-- ---------------------------------------------------------------------------
-- Wipe a whole map (delete every row for that map, despawn everywhere).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:wipeMap', function(map)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    map = cleanMap(map)
    local ids, lids, dberr = {}, {}, false
    -- Locked: DELETE props + lights for this map, then re-scan the in-memory sets
    -- so any row a concurrent commit inserted mid-delete is removed from memory
    -- too (no orphan). The lock prevents that interleave; the post-delete rescan
    -- is the belt-and-braces that keeps memory == DB regardless.
    local acquired = withWriteLock(function()
        local ok1 = pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_props WHERE map = ?', { map }) end)
        local ok2 = pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_lights WHERE map = ?', { map }) end)
        if not (ok1 and ok2) then dberr = true; return end
        for id, r in pairs(live) do if r.map == map then ids[#ids + 1] = id; live[id] = nil end end
        for id, l in pairs(lights) do if l.map == map then lids[#lids + 1] = id; lights[id] = nil end end
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if dberr then notify(src, 'DB delete failed', 'error'); return end
    if #ids == 0 and #lids == 0 then notify(src, ('map "%s" is already empty'):format(map), 'inform'); return end
    if #ids > 0 then TriggerClientEvent('palm6_mapeditor:live:removeBatch', -1, ids) end
    if #lids > 0 then TriggerClientEvent('palm6_mapeditor:live:lightRemoveBatch', -1, lids) end
    notify(src, ('wiped map "%s" (%d prop(s), %d light(s))'):format(map, #ids, #lids), 'success')
    print(('[palm6_mapeditor] %s wiped live map "%s" (%d prop(s), %d light(s))'):format(GetPlayerName(src) or src, map, #ids, #lids))
end)

-- ---------------------------------------------------------------------------
-- List: per-map counts, back to the requester as a single notify.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:list', function()
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    local counts = {}
    for _, r in pairs(live) do counts[r.map] = (counts[r.map] or 0) + 1 end
    local names = {}
    for m in pairs(counts) do names[#names + 1] = m end
    table.sort(names)
    if #names == 0 then notify(src, 'no live maps yet — build a session and /mapcommit', 'inform'); return end
    local lines = {}
    for _, m in ipairs(names) do lines[#lines + 1] = ('%s — %d'):format(m, counts[m]) end
    local hn = 0; for _ in pairs(hides) do hn = hn + 1 end
    notify(src, ('live maps:\n%s\n(world-erases: %d · lights: %d)'):format(table.concat(lines, '\n'), hn, lightCount()), 'inform')
end)

-- ---------------------------------------------------------------------------
-- World-erase sync. /materase is a personal, client-local suppression of a
-- vanilla map prop (session/undo-local); /mapworlderase makes it REAL: the hide
-- is stored and replayed on every client (and every future joiner), so admins
-- can carve out vanilla geometry to drop custom builds in and everyone sees it.
-- A model here is a HASH (world props aren't spawned by us, so we never have a
-- name) — kept numeric and range-checked.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_mapeditor:live:eraseWorld', function(x, y, z, radius, model)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    if not READY then notify(src, 'live map DB not ready yet', 'error'); return end
    local hash = cleanHash(model)
    if not hash then notify(src, 'invalid world prop', 'error'); return end
    local h = {
        x = num(x, -20000.0, 20000.0, 0.0), y = num(y, -20000.0, 20000.0, 0.0), z = num(z, -2000.0, 5000.0, 0.0),
        radius = num(radius, 0.1, 50.0, 1.0), model = hash,
    }
    local who = (GetPlayerName(src) or ('src' .. src)):sub(1, 96)
    local capped = false
    local acquired = withWriteLock(function()
        local hc = 0; for _ in pairs(hides) do hc = hc + 1 end
        if hc >= Config.LiveMaxHides then capped = true; return end
        local id
        if not pcall(function()
            id = MySQL.insert.await(
                'INSERT INTO palm6_mapeditor_hides (x, y, z, radius, model, created_by) VALUES (?, ?, ?, ?, ?, ?)',
                { h.x, h.y, h.z, h.radius, h.model, who })
        end) then return end
        if id then h.id = id; hides[id] = h end
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if capped then notify(src, ('world-erase cap reached (%d)'):format(Config.LiveMaxHides), 'error'); return end
    if not h.id then notify(src, 'DB write failed', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:live:hide', -1, wireHide(h))
    notify(src, 'world prop erased for everyone (/mapworldrestore to undo)', 'success')
end)

-- Restore a persisted world-erase. The client sends the id it matched by aim.
RegisterNetEvent('palm6_mapeditor:live:restoreWorld', function(id)
    local src = source
    if not isAllowed(src) then notify(src, 'not authorized (needs admin)', 'error'); return end
    id = tonumber(id)
    if not id or not hides[id] then notify(src, 'no world-erase with that id', 'error'); return end
    local dberr = false
    local acquired = withWriteLock(function()
        if not hides[id] then return end   -- vanished while we waited for the lock
        if not pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_hides WHERE id = ?', { id }) end) then
            dberr = true; return
        end
        hides[id] = nil
    end)
    if not acquired then notify(src, 'editor busy — try again', 'error'); return end
    if dberr then notify(src, 'DB delete failed', 'error'); return end
    TriggerClientEvent('palm6_mapeditor:live:unhide', -1, id)
    notify(src, 'world prop restored for everyone', 'success')
end)
