local function printBanner()
    local name = Config.ServerName or 'server_base'
    print('========================================')
    print(('[%s] server_base started — version 0.1.0'):format(name))
    print('========================================')
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    printBanner()
end)

RegisterCommand('serverinfo', function(source)
    local msg = ('%s — locale=%s debug=%s'):format(
        Config.ServerName,
        tostring(Config.Locale),
        tostring(Config.Debug)
    )
    if source == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', source, {
            args = { 'server_base', msg },
        })
    end
end, false)
