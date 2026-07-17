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
    ensureZones()
    loadZones()
    print(('[palm6_turf] loaded %d turf zone(s)'):format(#Config.Zones))
end)

RegisterNetEvent('palm6_turf:requestSync', function()
    TriggerClientEvent('palm6_turf:syncZones', source, publicZones())
end)

RegisterNetEvent('palm6_turf:requestTag', function(zoneId)
    local src = source
    if not Bridge.GetCitizenId(src) then return end
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
