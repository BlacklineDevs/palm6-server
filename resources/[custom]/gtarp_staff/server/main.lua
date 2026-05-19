-- ============================================================================
-- gtarp_staff/server/main.lua
--
-- Implements the staff-command set, logs every invocation to audit_log,
-- and fans out to a Discord webhook (URL via convar). All commands are
-- ACE-restricted; ACEs are granted in custom.cfg.
-- ============================================================================

local function actorName(src)
    if src == 0 then return 'console' end
    local name = GetPlayerName(src) or ('player:%d'):format(src)
    return name
end

local function actorIdentifier(src)
    if src == 0 then return 'console' end
    local ids = GetPlayerIdentifiers(src) or {}
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'license:' then return ids[i] end
    end
    return ids[1] or ('src:%d'):format(src)
end

local function log(action, actorSrc, targetSrc, detail)
    local actor_name = actorName(actorSrc)
    local actor_id   = actorIdentifier(actorSrc)
    local target_name = targetSrc and actorName(targetSrc) or nil
    local target_id   = targetSrc and actorIdentifier(targetSrc) or nil

    MySQL.insert.await(
        "INSERT INTO audit_log (action, actor_name, actor_identifier, target_name, target_identifier, detail, created_at) VALUES (?,?,?,?,?,?, NOW())",
        { action, actor_name, actor_id, target_name, target_id, detail or '' }
    )

    local url = GetConvar(Config.WebhookConvar, '')
    if url == '' then return end
    local payload = json.encode({
        embeds = { {
            title = ('staff: %s'):format(action),
            description = ('actor=%s target=%s detail=%s'):format(
                actor_name, tostring(target_name or '-'), detail or '-'),
            color = 5814783, -- dark blue
        } },
        username = 'gtarp-staff',
    })
    PerformHttpRequest(url, function(status)
        if status >= 400 then
            print(('[gtarp_staff] webhook %s -> HTTP %d'):format(action, status))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

local function notify(src, title, msg, t)
    if src == 0 then print(('[%s] %s'):format(title, msg)); return end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

local function targetCoordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- ---------------------------------------------------------------------------
-- Command implementations
-- ---------------------------------------------------------------------------

local Handlers = {}

function Handlers.tp(src, args)
    local target = tonumber(args[1])
    if not target then return notify(src, 'Staff', 'usage: /tp <id>', 'error') end
    local c = targetCoordsOf(target)
    if not c then return notify(src, 'Staff', 'no such player', 'error') end
    if src == 0 then log('tp', 0, target, 'console teleport'); return end
    SetEntityCoords(GetPlayerPed(src), c.x, c.y, c.z, false, false, false, false)
    log('tp', src, target, ('to %.1f,%.1f,%.1f'):format(c.x, c.y, c.z))
end

Handlers.goto = Handlers.tp

function Handlers.tpm(src)
    if src == 0 then return notify(src, 'Staff', 'tpm requires in-game', 'error') end
    TriggerClientEvent('gtarp_staff:tpm', src)
    log('tpm', src, nil, 'to waypoint')
end

function Handlers.bring(src, args)
    if src == 0 then return notify(src, 'Staff', 'bring requires in-game', 'error') end
    local target = tonumber(args[1])
    if not target then return notify(src, 'Staff', 'usage: /bring <id>', 'error') end
    local me = targetCoordsOf(src)
    if not me then return end
    SetEntityCoords(GetPlayerPed(target), me.x, me.y, me.z, false, false, false, false)
    log('bring', src, target, ('to %.1f,%.1f,%.1f'):format(me.x, me.y, me.z))
end

function Handlers.revive(src, args)
    local target = tonumber(args[1]) or src
    if target == 0 then return notify(src, 'Staff', 'usage: /revive <id>', 'error') end
    TriggerClientEvent('hospital:client:Revive', target)
    log('revive', src, target, '')
end

function Handlers.heal(src, args)
    local target = tonumber(args[1]) or src
    if target == 0 then return notify(src, 'Staff', 'usage: /heal <id>', 'error') end
    local ped = GetPlayerPed(target)
    if ped and ped ~= 0 then
        SetEntityHealth(ped, 200)
        log('heal', src, target, 'health=200')
    end
end

-- ---------------------------------------------------------------------------
-- Register all commands from Config.Commands
-- ---------------------------------------------------------------------------

local function register()
    for _, entry in ipairs(Config.Commands) do
        local fn = Handlers[entry.command]
        if not fn then
            print(('[gtarp_staff] no handler for /%s'):format(entry.command))
        else
            RegisterCommand(entry.command, function(src, args)
                fn(src, args)
            end, true) -- restricted by ACE
        end
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    register()
    print(('[gtarp_staff] registered %d staff commands; webhook=%s'):format(
        #Config.Commands,
        GetConvar(Config.WebhookConvar, '') ~= '' and 'set' or 'unset'
    ))
end)

-- Public export so other phases (e.g. allowlist denials, eventguard kicks)
-- can write to the same audit log.
exports('Log', log)
