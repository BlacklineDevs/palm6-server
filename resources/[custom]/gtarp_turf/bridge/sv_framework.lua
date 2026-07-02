-- ============================================================================
-- gtarp_turf/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that touches
-- qbx_core (gang data) or server-side natives. The turf-tagging rules
-- (gang gate, proximity, ownership flip) live in server/main.lua and call
-- Bridge.* only. To port to GTA VI, rewrite THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData then return nil end
    return p.PlayerData.citizenid
end

-- { name, grade } for the source's current gang, or nil if they have none
-- ('none' is qbx_core's default — treated as "no gang").
function Bridge.GetGang(src)
    local p = getPlayer(src)
    local gang = p and p.PlayerData and p.PlayerData.gang
    if not gang or gang.name == 'none' then return nil end
    return { name = gang.name, label = gang.label or gang.name }
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Current coords of a player's ped as {x,y,z}, or nil.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

-- Distance in metres between two coord tables (accepts vector3 too).
function Bridge.Distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end
