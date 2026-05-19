-- Fires when a Qbox character finishes loading after selection.
-- Verified against Qbox-project/qbx_core: client/character.lua triggers
-- TriggerEvent('QBCore:Client:OnPlayerLoaded') after a successful load.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    if not Config.Welcome.enabled then return end
    lib.notify({
        title = Config.Welcome.title or Config.ServerName,
        description = Config.Welcome.description,
        type = Config.Welcome.type or 'inform',
    })
end)
