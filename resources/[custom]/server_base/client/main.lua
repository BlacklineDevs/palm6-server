local function onClientStart()
    lib.notify({
        title = Config.ServerName,
        description = Config.Welcome.message,
        type = 'inform',
    })
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if Config.Welcome.enabled then
        onClientStart()
    end
end)

-- TODO: wire the Qbox player-loaded event here once qbx_core is available.
-- Example shape (uncomment and adapt when extending):
--
--   RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
--       -- player is fully loaded; safe to set up HUD, blips, etc.
--   end)
