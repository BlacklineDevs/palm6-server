-- ============================================================================
-- gtarp_robbery/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that touches
-- qbx_core (money, job data), ox_inventory, or server-side natives. The
-- robbery rules (cooldowns, timers, rewards, the police gate) live in
-- server/main.lua and call Bridge.* only. To port to GTA VI, rewrite THIS
-- FILE. See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
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

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Pay the player `amount` in cash. Returns true if applied.
function Bridge.AddCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('cash', amount, reason)
    return true
end

-- Current coords of a player's ped as {x,y,z}, or nil. Anti-abuse proximity.
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

-- Is this player's ped currently holding a weapon (not unarmed)? Best-effort
-- server-side check for Config.RequireWeapon. Unlike GetEntityCoords,
-- GetSelectedPedWeapon is not reliably a server native across builds — it may
-- return a stale value or error — so the call is guarded: a failure fails open
-- (treated as armed) rather than crashing the whole start handler and breaking
-- robberies for everyone. Enforcement is therefore advisory, not a hard gate.
function Bridge.IsArmed(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local ok, weapon = pcall(GetSelectedPedWeapon, ped)
    if not ok then return true end
    return weapon ~= `WEAPON_UNARMED`
end

-- List of server ids of on-duty police.
local function onDutyPolice()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        local p = getPlayer(sid)
        local job = p and p.PlayerData and p.PlayerData.job
        if job and job.name == 'police' and job.onduty then
            out[#out + 1] = sid
        end
    end
    return out
end

-- How many police are on duty right now.
function Bridge.CountOnDutyPolice()
    return #onDutyPolice()
end

-- Send a dispatch alert (blip + notify) to every on-duty officer. `coords` is
-- {x,y,z}. The client renders it via our own gtarp_robbery:dispatch event.
function Bridge.AlertPolice(coords, label, durationSeconds, sprite, colour, scale)
    for _, sid in ipairs(onDutyPolice()) do
        TriggerClientEvent('gtarp_robbery:dispatch', sid, {
            coords = coords, label = label, duration = durationSeconds,
            sprite = sprite, colour = colour, scale = scale,
        })
    end
end
