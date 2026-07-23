-- ============================================================================
-- server_base/server/main.lua
--
-- Pure logic: the startup banner, connect logger, /serverinfo, and /coords.
-- All player-identity and game-native calls go through Bridge.*
-- (bridge/sv_framework.lua) so this file is engine-agnostic. To port to
-- GTA VI, rewrite the bridge, not this file. See docs/GTA6-READINESS.md.
-- ============================================================================

local function printBanner()
    local name = Config.ServerName or 'server_base'
    print('========================================')
    print(('[%s] server_base started — version 0.1.0'):format(name))
    print(('  locale=%s  debug=%s'):format(
        tostring(Config.Locale),
        tostring(Config.Debug)
    ))
    print('========================================')
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    printBanner()
    -- Allow this resource's commands to be reached by group.admin grants in
    -- custom.cfg. /coords and /p6tp are the gated commands we own here.
    ExecuteCommand('add_ace resource.' .. resource .. ' command.coords allow')
    ExecuteCommand('add_ace resource.' .. resource .. ' command.p6tp allow')
end)

AddEventHandler('playerConnecting', function(name, _setKickReason, deferrals)
    local src = source
    local ids = Bridge.GetIdentifiers(src)
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
        Bridge.ChatToPlayer(source, 'server_base', msg)
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
    local pose = Bridge.GetCoordsAndHeading(target)
    if not pose then
        print(('[server_base] /coords: no ped for player %d'):format(target))
        return
    end
    local line = ('[server_base] coords player=%d  vector4(%.2f, %.2f, %.2f, %.1f)'):format(
        target, pose.x, pose.y, pose.z, pose.w
    )
    print(line)
    if source ~= 0 then
        Bridge.ChatToPlayer(source, 'server_base', line)
    end
end, true)

-- ---------------------------------------------------------------------------
-- /p6tp — admin placement tool. Teleports to a named cop/crime world-anchor
-- (or raw coords) so an admin can confirm a "VERIFY IN-GAME" placeholder is
-- on-ground/reachable, then /coords the correction back for baking into config.
-- ACE-gated: `add_ace group.admin command.p6tp allow` in custom.cfg.
--
-- Anchors carry their CURRENT (placeholder) coords so a tour walks the exact
-- points the resources ship. Order is cop-first. Coords mirror each resource's
-- shared/config.lua as of authoring — the source of truth stays in that config;
-- this list is a dev convenience, so a drift here only misses a jump target.
-- ---------------------------------------------------------------------------
local ANCHORS = {
    -- COP / JUSTICE
    bounty      = { 434.60, -981.30, 30.71, 'palm6_bounty — wanted board @ Mission Row PD steps' },
    jail_labor  = { 1800.00, 2600.00, 46.00, 'palm6_yard — prison LABOR point (round placeholder — verify!)' },
    jail_shop   = { 1780.00, 2600.00, 46.00, 'palm6_yard — COMMISSARY (round placeholder — verify!)' },
    jail_bail   = { 1690.00, 2560.00, 45.00, 'palm6_yard — BAIL point (round placeholder — verify!)' },
    -- CRIME (the loop the cops police)
    gun_dealer  = { -477.0, -1717.0, 18.6,  'palm6_gunrunning — black-market dealer ped' },
    drug_corner = { 106.4,  -1922.6, 21.3,  'palm6_drugs — Corner Dealer (reported wall-clip)' },
    drug_buyer  = { 1980.5, 3053.0,  47.2,  'palm6_drugs — Street Buyer ped' },
}

local function anchorNames()
    local names = {}
    for k in pairs(ANCHORS) do names[#names + 1] = k end
    table.sort(names)
    return names
end

RegisterCommand('p6tp', function(source, args)
    if source == 0 then
        print('[server_base] /p6tp must be run in-game')
        return
    end
    local key = args[1]
    if not key or key == 'list' then
        Bridge.ChatToPlayer(source, 'p6tp', 'anchors: ' .. table.concat(anchorNames(), ', '))
        Bridge.ChatToPlayer(source, 'p6tp', 'usage: /p6tp <anchor>  |  /p6tp <x> <y> <z>')
        return
    end
    local x, y, z, note
    local anchor = ANCHORS[key]
    if anchor then
        x, y, z, note = anchor[1], anchor[2], anchor[3], anchor[4]
    else
        x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
        if not (x and y and z) then
            Bridge.ChatToPlayer(source, 'p6tp', ('unknown anchor %q — /p6tp list, or pass numeric x y z'):format(tostring(key)))
            return
        end
        note = ('raw coords %.2f, %.2f, %.2f'):format(x, y, z)
    end
    Bridge.ChatToPlayer(source, 'p6tp', note .. ' — /coords here to capture a fix')
    TriggerClientEvent('server_base:teleport', source, x + 0.0, y + 0.0, z + 0.0)
end, true)
