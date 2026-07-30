-- ============================================================================
-- Unit position heartbeats for /ops/live map (W5).
-- Client posts coords while on duty; server upserts palm6_mdt_unit_positions.
-- ============================================================================

local HEARTBEAT_MS = 5000

CreateThread(function()
    while true do
        Wait(HEARTBEAT_MS)
        local ped = PlayerPedId()
        if ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            TriggerServerEvent('palm6_mdt:unitHeartbeat', {
                x = coords.x + 0.0,
                y = coords.y + 0.0,
                z = coords.z + 0.0,
                heading = GetEntityHeading(ped) + 0.0,
            })
        end
    end
end)
