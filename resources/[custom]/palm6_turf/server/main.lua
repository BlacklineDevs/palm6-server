-- ============================================================================
-- palm6_turf/server/main.lua
--
-- Gang turf control — the Phase 6 roadmap "faction reputation tracker"
-- candidate. Two phases like palm6_robbery: `requestTag` validates (in a
-- gang, proximity, not already yours) and reserves; `complete` flips
-- ownership after the client-side tag animation. Reputation = turf count,
-- shown via /turf. Pure logic — all framework/native access via Bridge.*
-- (§6 gate). Our own `palm6_turf` SQL stays here (Section 3 of
-- docs/GTA6-READINESS.md).
-- ============================================================================

local zones   = {}  -- [id] = { label, coords, owner_gang, captured_by, captured_at }
local pending = {}  -- [src] = { zoneId, gangName, holdUntil }

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner
local bootReady   = false  -- flipped once the boot seed+load has actually populated `zones`

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- CREATE ... IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- palm6_turf table. Every query here is pcall-wrapped, so the failure is
-- SILENT and the resource looks perfectly healthy: loadZones falls back to
-- Config, so the boot banner still prints the right zone count and the blips
-- still appear. Every zone just reads as unowned forever and every capture is
-- discarded on the next restart, so turf ownership (and palm6_protection's
-- collections on top of it) quietly stops persisting. On the live box (0013 +
-- 0051 already applied by hand) these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0013_turf.sql. NOT included: sql/0049's
-- identity reset, which is a data UPDATE rather than schema and is owned by
-- palm6_dbmigrate (it re-runs it every boot).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- The table THIS resource owns and can answer for. Only these feed SchemaReady.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_turf` (
    zone_id VARCHAR(50) NOT NULL PRIMARY KEY,
    owner_gang VARCHAR(50) DEFAULT NULL,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP NULL DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists, so folding it into SchemaReady would make a healthy
    -- MySQL box print `schema MISSING` on every boot and train operators to
    -- ignore the banner. Same split as palm6_courier and palm6_mdt.
    --
    -- Copied VERBATIM from sql/0051_turf_rep_at.sql. It is repeated here (it
    -- also lives in palm6_dbmigrate) because dbmigrate and this resource boot
    -- on independent threads: whichever runs second is a no-op and neither can
    -- lose the race. Without rep_at, loadZones reads nil and the anti-farm
    -- cooldown falls back to 0, which is the pre-0051 in-memory behaviour.
    local alters = {
        [[
ALTER TABLE `palm6_turf`
    ADD COLUMN IF NOT EXISTS `rep_at` BIGINT NOT NULL DEFAULT 0
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_turf] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_turf] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function ensureZones()
    for _, z in ipairs(Config.Zones) do
        pcall(function()
            MySQL.insert.await(
                'INSERT IGNORE INTO palm6_turf (zone_id) VALUES (?)', { z.id })
        end)
    end
end

local function loadZones()
    zones = {}
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM palm6_turf') or {}
    end)
    local byId = {}
    if ok then
        for _, r in ipairs(rows) do byId[r.zone_id] = r end
    end
    for _, z in ipairs(Config.Zones) do
        local row = byId[z.id] or {}
        zones[z.id] = {
            id = z.id, label = z.label, coords = z.coords,
            owner_gang = row.owner_gang, captured_by = row.captured_by,
            rep_at = tonumber(row.rep_at) or 0,   -- persisted anti-farm cooldown
        }
    end
end

local function publicZones()
    local out = {}
    for id, z in pairs(zones) do
        out[id] = { id = z.id, label = z.label, coords = z.coords, owner_gang = z.owner_gang }
    end
    return out
end

local function syncAll()
    local data = publicZones()
    for _, src in ipairs(GetPlayers()) do
        TriggerClientEvent('palm6_turf:syncZones', tonumber(src), data)
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The whole boot sequence runs on this thread because ensureSchema has to
    -- Wait for oxmysql's connection before it can issue any query, and neither
    -- ensureZones nor loadZones may run before the table is guaranteed to
    -- exist. That Wait is why bootReady exists: until the load lands, `zones`
    -- is EMPTY, and an ungated tag request would silently no-op on a nil zone
    -- instead of telling the player why. The final syncAll repairs any client
    -- that asked for a sync during the window and got an empty set.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It is the only line that can report the fresh-box
        -- case: loadZones falls back to Config, so the "loaded N zone(s)" line
        -- below prints the same number whether or not the table exists.
        if not SchemaReady then
            print('^1[palm6_turf] schema MISSING - turf ownership does NOT persist on this box.^0')
        end
        ensureZones()
        loadZones()
        bootReady = true
        print(('[palm6_turf] loaded %d turf zone(s)'):format(#Config.Zones))
        syncAll()
    end)
end)

RegisterNetEvent('palm6_turf:requestSync', function()
    TriggerClientEvent('palm6_turf:syncZones', source, publicZones())
end)

RegisterNetEvent('palm6_turf:requestTag', function(zoneId)
    local src = source
    if not Bridge.GetCitizenId(src) then return end
    -- `zones` is empty until the boot load lands (~3s after resource start,
    -- because ensureSchema has to wait for oxmysql). Without this gate the
    -- nil-zone check below would refuse the tag with NO message at all.
    if not bootReady then
        Bridge.Notify(src, 'Turf', 'Turf is still loading. Try again in a moment.', 'error')
        return
    end
    local z = zones[zoneId]
    if not z then return end

    local gang = Bridge.GetGang(src)
    if not gang then
        Bridge.Notify(src, 'Turf', 'You need to be in a gang to tag turf.', 'error')
        return
    end
    if z.owner_gang == gang.name then
        Bridge.Notify(src, 'Turf', 'Your gang already holds this turf.', 'error')
        return
    end

    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, z.coords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Turf', 'You are too far from this turf.', 'error')
        return
    end

    pending[src] = { zoneId = zoneId, gangName = gang.name, startedAt = os.time(), holdUntil = os.time() + 30 }
    TriggerClientEvent('palm6_turf:begin', src, { zoneId = zoneId, label = z.label })
end)

RegisterNetEvent('palm6_turf:complete', function(zoneId)
    local src = source
    local pend = pending[src]
    if not pend or pend.zoneId ~= zoneId then return end
    pending[src] = nil
    local now = os.time()
    if now > pend.holdUntil then return end
    if now - pend.startedAt < math.floor(Config.TagProgressMs / 1000) then return end  -- skipped the tag animation

    local z = zones[zoneId]
    if not z then return end
    local gang = Bridge.GetGang(src)
    if not gang or gang.name ~= pend.gangName then return end

    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, z.coords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Turf', 'You left the turf.', 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src)
    local prevOwner = z.owner_gang   -- capture before the flip for takeover check

    -- Reputation for a GENUINE takeover: the zone was held by a DIFFERENT
    -- player-run gang, and this zone hasn't minted rep within RepCooldownSec.
    -- The cooldown is PERSISTED in palm6_turf.rep_at so a server restart can't
    -- reset it (an in-memory version let a reboot re-enable an instant mint).
    -- Claiming unowned turf grants nothing. Rep is a DISPLAY-ONLY prestige stat:
    -- it does NOT pay a season prize (palm6_season rep ladder is noPrize), so it
    -- cannot be farmed for cash by two gangs trading zones. AddRep is soft/pcall.
    local mintRep = Config.RepPerCapture and Config.RepPerCapture > 0 and gang.id
        and prevOwner and prevOwner ~= 'none' and prevOwner ~= gang.name
        and (now - (tonumber(z.rep_at) or 0)) >= (Config.RepCooldownSec or 600)

    z.owner_gang = gang.name
    z.captured_by = cid
    if mintRep then z.rep_at = now end
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_turf SET owner_gang = ?, captured_by = ?, captured_at = NOW()'
            .. (mintRep and ', rep_at = ?' or '') .. ' WHERE zone_id = ?',
            mintRep and { gang.name, cid, now, zoneId } or { gang.name, cid, zoneId })
    end)

    if mintRep then
        pcall(function()
            exports.palm6_gangs:AddRep(gang.id, Config.RepPerCapture, 'turf_takeover')
        end)
    end

    Bridge.Notify(src, 'Turf', ('%s tagged for %s.'):format(z.label, gang.name), 'success')
    syncAll()
end)

RegisterNetEvent('palm6_turf:cancel', function(zoneId)
    local src = source
    local pend = pending[src]
    if pend and pend.zoneId == zoneId then pending[src] = nil end
end)

-- Cascade a gang rename onto turf ownership. Turf keys owner_gang on the MUTABLE
-- gang NAME (both the DB rows and the in-memory `zones` cache), so a /gang rename
-- that does not rewrite it silently orphans the gang's territory: live
-- comparisons (z.owner_gang == gang.name) stop matching, palm6_protection can no
-- longer collect on its own turf, season turf standings drop to 0, and — worst —
-- dbmigrate 0049 (runs every boot) permanently NULLs any turf whose owner_gang is
-- not a current palm6_gangs.name, so the renamed gang loses all turf on the next
-- restart. palm6_gangs calls this from its rename success path. Idempotent and
-- guarded; returns the number of DB rows rewritten (0 if the gang held no turf).
exports('RenameOwner', function(oldName, newName)
    if type(oldName) ~= 'string' or type(newName) ~= 'string' then return 0 end
    if oldName == '' or newName == '' or oldName == newName then return 0 end
    local updated = 0
    pcall(function()
        updated = MySQL.update.await(
            'UPDATE palm6_turf SET owner_gang = ? WHERE owner_gang = ?', { newName, oldName }) or 0
    end)
    -- Rewrite the in-memory cache so live name comparisons match without a reload.
    local touched = false
    for _, z in pairs(zones) do
        if z.owner_gang == oldName then z.owner_gang = newName; touched = true end
    end
    if touched then syncAll() end
    return updated
end)

RegisterCommand('turf', function(src)
    local counts = {}
    for _, z in pairs(zones) do
        if z.owner_gang then
            counts[z.owner_gang] = (counts[z.owner_gang] or 0) + 1
        end
    end

    local board = {}
    for gang, count in pairs(counts) do board[#board + 1] = { gang = gang, count = count } end
    table.sort(board, function(a, b) return a.count > b.count end)

    local lines = {}
    for i, entry in ipairs(board) do
        lines[#lines + 1] = ('%d. **%s** — %d turf'):format(i, entry.gang, entry.count)
    end
    for _, z in pairs(zones) do
        if not z.owner_gang then
            lines[#lines + 1] = ('_%s — unclaimed_'):format(z.label)
        end
    end

    if #lines == 0 then lines[1] = 'No turf claimed yet.' end
    TriggerClientEvent('palm6_turf:showLog', src, table.concat(lines, '\n'))
end, false)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
