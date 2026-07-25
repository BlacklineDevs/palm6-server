-- ============================================================================
-- palm6_mapeditor/server/prefabs.lua
--
-- Prefabs — named, reusable groups of props. A prefab is stored RELATIVE to the
-- group's centre (centroid), so it can be stamped anywhere and at any angle. The
-- authority + storage half; the client (client/prefabs.lua) caches the defs and
-- does the stamp placement math against the player's aim.
--
-- This is a pure building aid: it never touches the live map tables. Stamping
-- just spawns the props into the admin's session (client-side), which then flows
-- through the normal /mapcommit -> live-sync path. So there's no write-lock or
-- sync concern here — only its own palm6_mapeditor_prefabs table.
--
-- MODEL
--   prefabs[name] = { props = { { model, dx, dy, dz, rx, ry, rz }, ... } }
--   dx/dy/dz are offsets from the group centroid; rx/ry/rz are absolute euler.
--
-- NET (server -> client)
--   prefab:syncAll  (allDefs)        full cache (initial sync)
--   prefab:def      (name, def)      one prefab added/updated
--   prefab:removed  (name)           one prefab deleted
-- NET (client -> server)
--   prefab:requestSync ()            any admin -> syncAll
--   prefab:save   (name, props)      ACE — props = session snapshot (absolute)
--   prefab:delete (name)             ACE
-- ============================================================================

local PREADY = false
local prefabs = {}   -- [name] = { props = { {model,dx,dy,dz,rx,ry,rz}, ... } }

local function isAllowed(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.Ace)
end

local function pnotify(src, msg, kind)
    if src == 0 then print('[palm6_mapeditor] ' .. msg); return end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = msg, type = kind or 'inform' })
end

local function cleanName(n)
    n = (tostring(n or '')):gsub('[^%w_%-]', '')
    return n:sub(1, 48)
end

local function cleanModel(m)
    if type(m) ~= 'string' or #m == 0 or #m > 64 then return nil end
    if not m:match('^[%w_]+$') then return nil end
    return m
end

local function num(v, lo, hi, d)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return d end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function prefabCount() local n = 0; for _ in pairs(prefabs) do n = n + 1 end; return n end

local function cleanLightDef(l)
    if type(l) ~= 'table' then return nil end
    return {
        x = num(l.x, -20000.0, 20000.0, 0.0), y = num(l.y, -20000.0, 20000.0, 0.0), z = num(l.z, -2000.0, 5000.0, 0.0),
        r = math.floor(num(l.r, 0, 255, 255)), g = math.floor(num(l.g, 0, 255, 200)), b = math.floor(num(l.b, 0, 255, 140)),
        range = num(l.range, 0.5, 100.0, 8.0), intensity = num(l.intensity, 0.1, 50.0, 5.0),
        kind = (l.kind == 'spot') and 'spot' or 'point',
    }
end

-- Build a relative prefab def (props AND lights) from an absolute session
-- snapshot: centre everything on the group centroid so a stamp can drop it
-- anywhere. Returns nil if nothing valid. Loops are input-bounded (not valid-
-- count-bounded) so a garbage payload can't stall the tick.
local function buildDef(props, lights)
    local clean = {}
    local limit = math.min(#props, Config.PrefabMaxProps)
    for i = 1, limit do
        local p = props[i]
        local model = type(p) == 'table' and cleanModel(p.model) or nil
        if model then
            clean[#clean + 1] = {
                model = model,
                x = num(p.x, -20000.0, 20000.0, 0.0), y = num(p.y, -20000.0, 20000.0, 0.0), z = num(p.z, -2000.0, 5000.0, 0.0),
                rx = num(p.rx, -360.0, 360.0, 0.0), ry = num(p.ry, -360.0, 360.0, 0.0), rz = num(p.rz, -360.0, 360.0, 0.0),
            }
        end
    end
    local cleanL = {}
    lights = type(lights) == 'table' and lights or {}
    local llimit = math.min(#lights, Config.LiveMaxLights)
    for i = 1, llimit do
        local l = cleanLightDef(lights[i])
        if l then cleanL[#cleanL + 1] = l end
    end
    if #clean == 0 and #cleanL == 0 then return nil end
    -- Anchor on the props' centroid (the visual body); fall back to lights if a
    -- prefab is lights-only.
    local base = (#clean > 0) and clean or cleanL
    local cx, cy, cz = 0.0, 0.0, 0.0
    for _, p in ipairs(base) do cx = cx + p.x; cy = cy + p.y; cz = cz + p.z end
    local n = #base
    cx, cy, cz = cx / n, cy / n, cz / n
    local outP = {}
    for _, p in ipairs(clean) do
        outP[#outP + 1] = { model = p.model, dx = p.x - cx, dy = p.y - cy, dz = p.z - cz, rx = p.rx, ry = p.ry, rz = p.rz }
    end
    local outL = {}
    for _, l in ipairs(cleanL) do
        outL[#outL + 1] = { dx = l.x - cx, dy = l.y - cy, dz = l.z - cz, r = l.r, g = l.g, b = l.b, range = l.range, intensity = l.intensity, kind = l.kind }
    end
    return { props = outP, lights = outL }
end

CreateThread(function()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_mapeditor_prefabs` (
                `name`       VARCHAR(48) NOT NULL,
                `data`       MEDIUMTEXT  NOT NULL,
                `created_by` VARCHAR(96) DEFAULT NULL,
                `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        local rows = MySQL.query.await('SELECT name, data FROM palm6_mapeditor_prefabs') or {}
        for _, row in ipairs(rows) do
            local dok, def = pcall(json.decode, row.data)
            if dok and type(def) == 'table' and type(def.props) == 'table' then prefabs[row.name] = def end
        end
        local n = prefabCount()
        print(('[palm6_mapeditor] prefabs ready — %d loaded'):format(n))
    end)
    if ok then
        PREADY = true
        -- Push to connected ADMINS only (prefabs are an admin building tool, not
        -- world content players need). Covers admins who asked before the DB was
        -- ready; on-demand/late-join admins pull via prefab:requestSync.
        for _, pid in ipairs(GetPlayers()) do
            local s = tonumber(pid)
            if s and isAllowed(s) then TriggerClientEvent('palm6_mapeditor:prefab:syncAll', s, prefabs) end
        end
    else
        print(('[palm6_mapeditor] FATAL: could not create palm6_mapeditor_prefabs (%s).'):format(tostring(err)))
    end
end)

RegisterNetEvent('palm6_mapeditor:prefab:requestSync', function()
    -- Admin-only: prefabs are a building tool, so there's no reason to serialise
    -- the whole cache to a non-admin (also closes a cheap-request/big-response
    -- amplification vector).
    if not isAllowed(source) then return end
    TriggerClientEvent('palm6_mapeditor:prefab:syncAll', source, prefabs)
end)

RegisterNetEvent('palm6_mapeditor:prefab:save', function(name, props, lights)
    local src = source
    if not isAllowed(src) then pnotify(src, 'not authorized (needs admin)', 'error'); return end
    if not PREADY then pnotify(src, 'prefab DB not ready yet', 'error'); return end
    name = cleanName(name)
    if name == '' then pnotify(src, 'give the prefab a name (letters/numbers)', 'error'); return end
    if type(props) ~= 'table' then props = {} end
    if #props == 0 and (type(lights) ~= 'table' or #lights == 0) then pnotify(src, 'nothing in your session to save', 'error'); return end
    if not prefabs[name] and prefabCount() >= Config.PrefabMaxCount then
        pnotify(src, ('prefab limit reached (%d)'):format(Config.PrefabMaxCount), 'error'); return
    end
    local def = buildDef(props, lights)
    if not def then pnotify(src, 'no valid props/lights to save', 'error'); return end
    local who = (GetPlayerName(src) or ('src' .. src)):sub(1, 96)
    local wrote = pcall(function()
        MySQL.query.await([[
            INSERT INTO palm6_mapeditor_prefabs (name, data, created_by) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE data = VALUES(data), created_by = VALUES(created_by)
        ]], { name, json.encode(def), who })
    end)
    if not wrote then pnotify(src, 'DB write failed', 'error'); return end
    prefabs[name] = def
    TriggerClientEvent('palm6_mapeditor:prefab:def', -1, name, def)
    pnotify(src, ('saved prefab "%s" (%d props, %d lights)'):format(name, #def.props, #def.lights), 'success')
    print(('[palm6_mapeditor] %s saved prefab "%s" (%d props, %d lights)'):format(who, name, #def.props, #def.lights))
end)

RegisterNetEvent('palm6_mapeditor:prefab:delete', function(name)
    local src = source
    if not isAllowed(src) then pnotify(src, 'not authorized (needs admin)', 'error'); return end
    name = cleanName(name)
    if name == '' or not prefabs[name] then pnotify(src, 'no prefab by that name', 'error'); return end
    local ok = pcall(function() MySQL.query.await('DELETE FROM palm6_mapeditor_prefabs WHERE name = ?', { name }) end)
    if not ok then pnotify(src, 'DB delete failed', 'error'); return end
    prefabs[name] = nil
    TriggerClientEvent('palm6_mapeditor:prefab:removed', -1, name)
    pnotify(src, ('deleted prefab "%s"'):format(name), 'success')
end)
