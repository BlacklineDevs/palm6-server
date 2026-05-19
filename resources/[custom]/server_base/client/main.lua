-- qbx_core fires QBCore:Client:OnPlayerLoaded once the character is loaded.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    if not Config.Welcome.enabled then return end
    lib.notify({
        title = Config.Welcome.title or Config.ServerName,
        description = Config.Welcome.description,
        type = Config.Welcome.type or 'inform',
    })
end)
