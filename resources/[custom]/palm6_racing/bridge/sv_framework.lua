-- ============================================================================
-- palm6_racing/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls qbx_core /
-- framework exports or server-side natives. server/main.lua calls Bridge.* only, so
-- its logic ports by rewriting THIS file. Mirrors palm6_fightclub's bridge surface.
-- Phase 0 is rep-only, so there are NO money helpers here — nothing this resource
-- does can move bank cash (money lands in Phase 1 via palm6_fightclub's engine).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for boards / leaderboards.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('driver %d'):format(src)
end

function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, { title = title, description = msg, type = t or 'inform' })
end

-- Reply to a command invoker: console prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_racing] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src, { color = { 90, 160, 255 }, args = { 'Racing', line } })
        end
    end
end

-- Server source for an online character, or nil.
function Bridge.GetSourceByCitizenId(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

-- Caller position {x,y,z}, or nil. Server-side GetEntityCoords on a synced ped is
-- valid; used for the "at the meet" gate + server-side finish plausibility.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Bridge.Distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Is the player in a vehicle (as driver)? Phase 0 uses this to require a car to
-- start/join a race. Returns the vehicle net id or nil.
function Bridge.DriverVehicle(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end   -- must be the DRIVER
    return veh
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end

-- Ace check for admin-only helpers (route builder). Console (src 0) always allowed.
function Bridge.IsAdmin(src)
    if src == 0 then return true end
    return IsPlayerAceAllowed(src, 'palm6_racing.admin')
end
