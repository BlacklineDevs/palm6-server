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
local custCooldowns = {}  -- [citizenid] = unix expiry, per-customer invoice throttle
local offers    = {}  -- [customerSrc] = { mech, vehNetId, amount, expiry } awaiting accept

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

    -- Per-customer throttle. The vehicle cooldown is keyed per netId, so a fresh
    -- damaged-vehicle netId would otherwise be a brand-new charge each time. Gate
    -- on the customer's citizenid so they can't be invoiced repeatedly in a row.
    local ccid = Bridge.GetCitizenId(customer)
    if ccid and (custCooldowns[ccid] or 0) > now then
        Bridge.Notify(src, 'Mechanic', 'This customer was just invoiced.', 'error')
        return
    end

    -- The customer must accept the charge. Offer the invoice and wait for their
    -- client to confirm via ox_lib alertDialog; the charge/credit and repair run
    -- only from gtarp_mechanic:acceptInvoice below (re-validated there).
    offers[customer] = { mech = src, vehNetId = vehNetId, amount = Config.RepairCost, expiry = now + 30 }
    TriggerClientEvent('gtarp_mechanic:confirmInvoice', customer, src, Config.RepairCost)
    Bridge.Notify(src, 'Mechanic', 'Invoice sent to the customer for approval.', 'inform')
end)

-- The customer accepted the invoice from gtarp_mechanic:confirmInvoice. This is
-- the ONLY place the charge/credit runs — re-validate the offer, the mechanic's
-- duty + proximity, the customer's proximity + throttle, and balance server-side.
RegisterNetEvent('gtarp_mechanic:acceptInvoice', function()
    local customer = source
    local offer = offers[customer]
    if not offer then return end
    offers[customer] = nil

    local now = os.time()
    if now > offer.expiry then return end

    local mech = offer.mech
    if not Bridge.IsOnDutyMechanic(mech) then return end

    local veh, vc = vehicleCoordsOk(mech, offer.vehNetId)
    if not veh then return end

    local cc = Bridge.GetCoords(customer)
    if not cc or Bridge.Distance(cc, vc) > Config.CustomerSearchRadius then return end

    local ccid = Bridge.GetCitizenId(customer)
    if ccid and (custCooldowns[ccid] or 0) > now then return end

    if not Bridge.ChargeBank(customer, offer.amount, 'vehicle-repair') then
        Bridge.Notify(mech, 'Mechanic', 'The customer could not afford the repair.', 'error')
        Bridge.Notify(customer, 'Mechanic', ('You need $%d in the bank for this repair.'):format(offer.amount), 'error')
        return
    end
    Bridge.CreditBank(mech, offer.amount, 'vehicle-repair-invoice')
    if ccid then custCooldowns[ccid] = now + Config.RepairCooldownSeconds end

    TriggerClientEvent('gtarp_mechanic:applyRepair', mech, offer.vehNetId)

    local mechName = Bridge.GetPlayerName(mech)
    Bridge.Notify(mech, 'Mechanic', ('Repaired the vehicle. Invoiced $%d.'):format(offer.amount), 'success')
    Bridge.Notify(customer, 'Mechanic', ('%s repaired your vehicle for $%d.'):format(mechName, offer.amount), 'inform')
end)

RegisterNetEvent('gtarp_mechanic:cancel', function(vehNetId)
    local src = source
    local pend = pending[src]
    if pend and pend.vehNetId == vehNetId then pending[src] = nil end
end)

AddEventHandler('playerDropped', function()
    local ccid = Bridge.GetCitizenId(source)
    if ccid then custCooldowns[ccid] = nil end
    offers[source] = nil
    pending[source] = nil
end)
