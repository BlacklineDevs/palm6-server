-- ============================================================================
-- gtarp_turf/server/main.lua
--
-- Gang turf control — the Phase 6 roadmap "faction reputation tracker"
-- candidate. Two phases like gtarp_robbery: `requestTag` validates (in a
-- gang, proximity, not already yours) and reserves; `complete` flips
-- ownership after the client-side tag animation. Reputation = turf count,
-- shown via /turf. Pure logic — all framework/native access via Bridge.*
-- (§6 gate). Our own `gtarp_turf` SQL stays here (Section 3 of
-- docs/GTA6-READINESS.md).
-- ============================================================================

local zones   = {}  -- [id] = { label, coords, owner_gang, captured_by, captured_at }
local pending = {}  -- [src] = { zoneId, gangName, holdUntil }

local function ensureZones()
    for _, z in ipairs(Config.Zones) do
        pcall(function()
            MySQL.insert.await(
                'INSERT IGNORE INTO gtarp_turf (zone_id) VALUES (?)', { z.id })
        end)
    end
end

local function loadZones()
    zones = {}
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM gtarp_turf') or {}
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
        TriggerClientEvent('gtarp_turf:syncZones', tonumber(src), data)
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ensureZones()
    loadZones()
    print(('[gtarp_turf] loaded %d turf zone(s)'):format(#Config.Zones))
end)

RegisterNetEvent('gtarp_turf:requestSync', function()
    TriggerClientEvent('gtarp_turf:syncZones', source, publicZones())
end)

RegisterNetEvent('gtarp_turf:requestTag', function(zoneId)
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

    pending[src] = { zoneId = zoneId, gangName = gang.name, holdUntil = os.time() + 30 }
    TriggerClientEvent('gtarp_turf:begin', src, { zoneId = zoneId, label = z.label })
end)

RegisterNetEvent('gtarp_turf:complete', function(zoneId)
    local src = source
    local pend = pending[src]
    if not pend or pend.zoneId ~= zoneId then return end
    pending[src] = nil
    if os.time() > pend.holdUntil then return end

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
    z.owner_gang = gang.name
    z.captured_by = cid
    pcall(function()
        MySQL.update.await(
            'UPDATE gtarp_turf SET owner_gang = ?, captured_by = ?, captured_at = NOW() WHERE zone_id = ?',
            { gang.name, cid, zoneId })
    end)

    Bridge.Notify(src, 'Turf', ('%s tagged for %s.'):format(z.label, gang.name), 'success')
    syncAll()
end)

RegisterNetEvent('gtarp_turf:cancel', function(zoneId)
    local src = source
    local pend = pending[src]
    if pend and pend.zoneId == zoneId then pending[src] = nil end
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
    TriggerClientEvent('gtarp_turf:showLog', src, table.concat(lines, '\n'))
end, false)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
