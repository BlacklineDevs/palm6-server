-- ============================================================================
-- gtarp_courier/client/main.lua
--
-- Manages the on-route blip + arrival detection for an accepted delivery.
-- Posting / listing is done via the server-side /courier command and the
-- gtarp_courier:post net event.
-- ============================================================================

local activeId = nil
local activeBlip = nil
local activeDropoff = nil

local function clearActive()
    if activeBlip then RemoveBlip(activeBlip) end
    activeBlip, activeId, activeDropoff = nil, nil, nil
end

RegisterNetEvent('gtarp_courier:onAccepted', function(payload)
    clearActive()
    activeId = payload.id
    activeDropoff = payload.dropoff
    local b = AddBlipForCoord(payload.dropoff.x, payload.dropoff.y, payload.dropoff.z)
    SetBlipSprite(b, 1)
    SetBlipColour(b, Config.DeliveryBlipColor or 5)
    SetBlipScale(b, 0.9)
    SetBlipAsShortRange(b, false)
    SetBlipRoute(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Delivery: ' .. tostring(payload.label or 'Package'))
    EndTextCommandSetBlipName(b)
    activeBlip = b

    lib.notify({
        title = 'Courier',
        description = ('Delivery #%d accepted. Follow the GPS to the dropoff.'):format(payload.id),
        type = 'success',
    })
end)

CreateThread(function()
    while true do
        if activeId and activeDropoff then
            local ped = PlayerPedId()
            local p = GetEntityCoords(ped)
            local d = #(vector3(p.x, p.y, p.z) - vector3(activeDropoff.x, activeDropoff.y, activeDropoff.z))
            if d <= (Config.DeliveryRadiusMeters or 8.0) then
                local id = activeId
                clearActive()
                TriggerServerEvent('gtarp_courier:complete', id)
            end
            Wait(1500)
        else
            Wait(2500)
        end
    end
end)

-- Simple chat helper to post a delivery from the player's current position
-- to a marked waypoint. Server-side validation handles bounds / escrow.
RegisterCommand('courierpost', function(_, args)
    local bounty = tonumber(args[1])
    if not bounty then
        lib.notify({ title = 'Courier', description = 'Usage: /courierpost <bounty>', type = 'error' })
        return
    end

    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then
        lib.notify({ title = 'Courier', description = 'Set a map waypoint for the dropoff first.', type = 'error' })
        return
    end
    local d = GetBlipInfoIdCoord(wp)
    local pickup = GetEntityCoords(PlayerPedId())
    TriggerServerEvent('gtarp_courier:post', {
        bounty = bounty,
        pickup = { x = pickup.x, y = pickup.y, z = pickup.z },
        dropoff = { x = d.x, y = d.y, z = d.z },
        label = table.concat(args, ' ', 2):sub(1, 60),
    })
end, false)
