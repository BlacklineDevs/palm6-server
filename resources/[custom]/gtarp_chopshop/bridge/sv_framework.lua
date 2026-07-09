-- ============================================================================
-- gtarp_chopshop/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side game natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
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
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Credit `amount` to bank (normal payout path, player online).
function Bridge.CreditBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('bank', amount, reason)
    return true
end

-- Credit bank by citizenid, online or offline (same offline-safe pattern
-- gtarp_ransom/gtarp_gunrunning use for refunds) — used here on a failed
-- sale rollback, never a normal payout.
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            p.Functions.AddMoney('bank', amount, reason)
            return true
        end
    end
    local ok = pcall(function()
        MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
            { amount, citizenid }
        )
    end)
    return ok
end

-- Caller position as {x,y,z}, or nil.
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

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end

-- The vehicle entity this player is currently the DRIVER of, or nil. Driver-
-- only (not a passenger) so a rideshare passenger can't chop the driver's
-- car out from under them.
function Bridge.GetDrivenVehicle(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end -- driver seat only
    return veh
end

-- Real plate text off the vehicle entity itself (server-authoritative —
-- never trust a client-supplied plate string), trimmed of the fixed-width
-- padding GetVehicleNumberPlateText pads with.
function Bridge.GetVehiclePlate(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    return plate and plate:gsub('%s+$', '') or nil
end

function Bridge.GetVehicleClass(vehicle)
    return GetVehicleClass(vehicle)
end

-- Deletes the vehicle entity ("chopped") and every ped/prop it's towing is
-- left alone — only the vehicle itself.
function Bridge.DeleteVehicle(vehicle)
    if not DoesEntityExist(vehicle) then return end
    SetEntityAsMissionEntity(vehicle, true, true)
    DeleteEntity(vehicle)
end
