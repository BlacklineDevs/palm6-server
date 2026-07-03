-- ============================================================================
-- gtarp_evidence/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all native access.
-- No direct natives or framework UI calls here (§6 gate). Server is authoritative on the
-- on-duty gate and proximity — this is UI + prompts.
-- ============================================================================

CreateThread(function()
    while true do
        local coords = Game.GetPlayerCoords()
        local wait = 1000

        if Game.DistanceBetween(coords, Config.LockerCoords) <= Config.InteractRadius then
            wait = 0
            Game.ShowHelpThisFrame('Press ~INPUT_PICKUP~ to open the evidence locker')
            if Game.InteractPressed() then
                TriggerServerEvent('gtarp_evidence:requestOpenLocker')
            end
        end

        Wait(wait)
    end
end)

RegisterNetEvent('gtarp_evidence:openLocker', function(stashId)
    Game.OpenStash(stashId)
end)

RegisterNetEvent('gtarp_evidence:showLog', function(content)
    Game.ShowLogDialog('Evidence Log', content)
end)
