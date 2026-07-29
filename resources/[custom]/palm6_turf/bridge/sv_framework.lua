-- ============================================================================
-- palm6_turf/bridge/sv_framework.lua
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

-- { id, name, label } for the source's PLAYER-RUN gang (palm6_gangs), or nil.
-- Turf keys on the player-run gang layer (not qbx's static PlayerData.gang) so
-- ownership, /ganginfo "turf held", the season ladder, and gang reputation all
-- share ONE gang identity (palm6_gangs.name/id). Soft dependency — pcall-guarded
-- so turf degrades gracefully (no tagging) if palm6_gangs isn't running.
function Bridge.GetGang(src)
    local cid = Bridge.GetCitizenId(src)
    if not cid then return nil end
    local ok, g = pcall(function() return exports.palm6_gangs:GetGang(cid) end)
    if not ok or not g or not g.name then return nil end
    return { id = g.id, name = g.name, label = g.tag or g.name }
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

-- Online server ids as numbers. Used by the contest engine to RE-DERIVE who is
-- standing in a zone: the server walks this list and reads each ped's position
-- with GetCoords above. A client never reports its own position or presence.
-- Same shape as palm6_gangs' bridge.
function Bridge.GetOnlinePlayers()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do out[#out + 1] = tonumber(sid) end
    return out
end
