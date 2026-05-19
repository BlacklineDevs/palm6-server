local function printBanner()
    local name = Config.ServerName or 'server_base'
    print('========================================')
    print(('[%s] server_base started — version 0.1.0'):format(name))
    print(('  locale=%s  debug=%s  spawn_by_identity=%s'):format(
        tostring(Config.Locale),
        tostring(Config.Debug),
        tostring(Config.SpawnHandledByIdentity)
    ))
    print('========================================')
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    printBanner()
    -- Allow this resource's commands to be reached by group.admin grants in
    -- custom.cfg. /coords is the gated command we own here.
    ExecuteCommand('add_ace resource.' .. resource .. ' command.coords allow')
end)

AddEventHandler('playerConnecting', function(name, _setKickReason, deferrals)
    local src = source
    local ids = GetPlayerIdentifiers(src) or {}
    print(('[server_base] connecting: name=%q src=%d identifiers=%d'):format(
        tostring(name), src, #ids
    ))
    if Config.Debug then
        for _, id in ipairs(ids) do
            print(('  id: %s'):format(id))
        end
    end
    if deferrals and deferrals.done then
        deferrals.done()
    end
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

-- /coords [id] — print a player's coordinates server-side. ACE-gated:
-- grant `command.coords` to group.admin in custom.cfg.
RegisterCommand('coords', function(source, args)
    local target = tonumber(args[1]) or source
    if target == 0 then
        print('[server_base] /coords must be run with a player id from console')
        return
    end
    local ped = GetPlayerPed(target)
    if not ped or ped == 0 then
        print(('[server_base] /coords: no ped for player %d'):format(target))
        return
    end
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local line = ('[server_base] coords player=%d  vector4(%.2f, %.2f, %.2f, %.1f)'):format(
        target, pos.x, pos.y, pos.z, heading
    )
    print(line)
    if source ~= 0 then
        TriggerClientEvent('chat:addMessage', source, {
            args = { 'server_base', line },
        })
    end
end, true)
