-- ============================================================================
-- gtarp_mechanic/server/main.lua
--
-- Vehicle repair invoices. Two phases: `start` validates (on-duty mechanic,
-- proximity, per-vehicle cooldown, a nearby customer who can pay) and
-- reserves the job; `complete` charges the customer and pays the mechanic
-- after the client-side repair animation. Pure logic — all framework /
-- native access via Bridge.* (§6 gate).
-- ============================================================================

local cooldowns = {}  -- [vehNetId] = unix expiry
local pending   = {}  -- [src] = { vehNetId, customer, holdUntil }

local function vehicleCoordsOk(src, netId)
    local veh = Bridge.GetVehicleFromNetId(netId)
    if not veh then return nil, nil end
    local vc = Bridge.GetVehicleCoords(veh)
    local pc = Bridge.GetCoords(src)
    if not vc or not pc then return nil, nil end
    if Bridge.Distance(pc, vc) > (Config.InteractRadius + 2.5) then return nil, nil end
    return veh, vc
end

RegisterNetEvent('gtarp_mechanic:start', function(vehNetId)
    local src = source
    if not Bridge.GetCitizenId(src) then return end
    if not Bridge.IsOnDutyMechanic(src) then
        Bridge.Notify(src, 'Mechanic', 'You need to be on duty as a mechanic.', 'error')
        return
    end

    local now = os.time()
    if (cooldowns[vehNetId] or 0) > now then
        Bridge.Notify(src, 'Mechanic', 'This vehicle was just repaired. Give it a moment.', 'error')
        return
    end

    local veh, vc = vehicleCoordsOk(src, vehNetId)
    if not veh then
        Bridge.Notify(src, 'Mechanic', 'You are too far from the vehicle.', 'error')
        return
    end

    local health = Bridge.GetVehicleHealth(veh)
    if health.engine >= Config.EngineHealthThreshold and health.body >= Config.BodyHealthThreshold then
        Bridge.Notify(src, 'Mechanic', 'This vehicle is not damaged.', 'error')
        return
    end

    local customer = Bridge.NearestOtherPlayer(src, vc, Config.CustomerSearchRadius)
    if not customer then
        Bridge.Notify(src, 'Mechanic', 'No one nearby to invoice for this repair.', 'error')
        return
    end

    -- Reserve immediately so the same vehicle can't be double-started.
    cooldowns[vehNetId] = now + Config.RepairCooldownSeconds
    pending[src] = { vehNetId = vehNetId, customer = customer, startedAt = now, holdUntil = now + 30 }

    TriggerClientEvent('gtarp_mechanic:begin', src, vehNetId)
end)

RegisterNetEvent('gtarp_mechanic:complete', function(vehNetId)
    local src = source
    local pend = pending[src]
    if not pend or pend.vehNetId ~= vehNetId then return end
    pending[src] = nil
    local now = os.time()
    if now > pend.holdUntil then return end  -- took too long / tampered
    if now - pend.startedAt < math.floor(Config.ProgressMs / 1000) then return end  -- skipped the repair animation

    if not Bridge.IsOnDutyMechanic(src) then return end
    local veh, vc = vehicleCoordsOk(src, vehNetId)
    if not veh then
        Bridge.Notify(src, 'Mechanic', 'You left the vehicle.', 'error')
        return
    end

    -- Re-validate the invoiced customer is still at the vehicle. Proximity was
    -- only checked at `start`; without re-checking, a customer who drove/walked
    -- off during the repair bar (or was never consenting) is still charged.
    local customer = pend.customer
    local cc = Bridge.GetCoords(customer)
    if not cc or Bridge.Distance(cc, vc) > Config.CustomerSearchRadius then
        Bridge.Notify(src, 'Mechanic', 'The customer is no longer around.', 'error')
        return
    end

    if not Bridge.ChargeBank(customer, Config.RepairCost, 'vehicle-repair') then
        Bridge.Notify(src, 'Mechanic', 'The customer could not afford the repair.', 'error')
        Bridge.Notify(customer, 'Mechanic', ('You need $%d in the bank for this repair.'):format(Config.RepairCost), 'error')
        return
    end
    Bridge.CreditBank(src, Config.RepairCost, 'vehicle-repair-invoice')

    TriggerClientEvent('gtarp_mechanic:applyRepair', src, vehNetId)

    local mechName = Bridge.GetPlayerName(src)
    Bridge.Notify(src, 'Mechanic', ('Repaired the vehicle. Invoiced $%d.'):format(Config.RepairCost), 'success')
    Bridge.Notify(customer, 'Mechanic', ('%s repaired your vehicle for $%d.'):format(mechName, Config.RepairCost), 'inform')
end)

RegisterNetEvent('gtarp_mechanic:cancel', function(vehNetId)
    local src = source
    local pend = pending[src]
    if pend and pend.vehNetId == vehNetId then pending[src] = nil end
end)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
