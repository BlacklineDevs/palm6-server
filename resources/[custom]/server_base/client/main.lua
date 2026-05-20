-- qbx_core fires QBCore:Client:OnPlayerLoaded only AFTER the player has
-- actively selected a character in the multichar UI and that character has
-- spawned (verified in qbx_core client/character.lua). Hooking it here means
-- the welcome shows once selection is complete, never before it.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    if not Config.Welcome.enabled then return end
    lib.notify({
        title = Config.Welcome.title or Config.ServerName,
        description = Config.Welcome.description,
        type = Config.Welcome.type or 'inform',
    })
end)
