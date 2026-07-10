-- ============================================================================
-- gtarp_mechanic/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all native access.
-- No direct natives / ox_lib here (§6 gate). Server is authoritative on the
-- job gate, cooldown, and payment — this loop is an opportunistic prompt.
-- ============================================================================

local function isDamaged(veh)
    local h = Game.GetVehicleHealth(veh)
    return h.engine < Config.EngineHealthThreshold or h.body < Config.BodyHealthThreshold
end

CreateThread(function()
    while true do
        local coords = Game.GetPlayerCoords()
        local veh = Game.GetClosestVehicle(coords, Config.InteractRadius)
        local wait = 750

        if veh and isDamaged(veh) then
            wait = 0
            Game.ShowHelpThisFrame(('Press ~INPUT_PICKUP~ to repair this vehicle ($%d, invoiced to nearest player)'):format(Config.RepairCost))
            if Game.InteractPressed() then
                TriggerServerEvent('gtarp_mechanic:start', Game.GetVehicleNetId(veh))
            end
        end

        Wait(wait)
    end
end)

RegisterNetEvent('gtarp_mechanic:begin', function(vehNetId)
    local ok = Game.ProgressBar('Repairing vehicle...', Config.ProgressMs)
    if ok then
        TriggerServerEvent('gtarp_mechanic:complete', vehNetId)
    else
        TriggerServerEvent('gtarp_mechanic:cancel', vehNetId)
    end
end)

RegisterNetEvent('gtarp_mechanic:applyRepair', function(vehNetId)
    local veh = Game.GetVehicleFromNetId(vehNetId)
    if veh then Game.RepairVehicle(veh) end
end)

-- The server offered a repair invoice. Ask the customer to accept before any
-- charge; only a positive dialog fires the accept back to the server.
RegisterNetEvent('gtarp_mechanic:confirmInvoice', function(_mechSrc, amount)
    if Game.ConfirmDialog('Repair Invoice',
        ('A mechanic wants to charge $%d to repair your vehicle. Accept?'):format(amount)) then
        TriggerServerEvent('gtarp_mechanic:acceptInvoice')
    end
end)
