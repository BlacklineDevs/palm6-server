--[[
    client/main.lua — keybind, NUI lifecycle, RegisterNUICallback, open/close state.

    Command name: VERIFY — 'radialmenu' is the qb-ecosystem convention and matches what
    qbx_radialmenu is expected to bind live, so any third-party script calling
    ExecuteCommand('radialmenu') keeps working after cutover. Confirm against the live
    server's actual qbx_radialmenu/qbx_smallresources RegisterKeyMapping() before first
    ensure (README.md "Before First Ensure" checklist). If the live command name differs,
    rename both the RegisterCommand and RegisterKeyMapping strings below to match — do not
    keep a private name like 'palm6_radialmenu:open', since that breaks the degrade-safe
    guarantee (design spec §8 step 4).
]]

local isOpen = false

-- Leaf nodes the NUI is currently allowed to trigger, keyed by event name,
-- storing the REAL eventType/args declared in the tree - not a plain boolean
-- set. Rebuilt from the actual tree on every OpenRadial() and checked before
-- every dispatch in the 'select' callback. This exists because the NUI
-- callback endpoint (RegisterNUICallback('select')) is a plain HTTP POST a
-- modified client can hit directly, bypassing the real menu entirely.
--
-- Adversarial review (2026-08-05) found the original version of this only
-- validated the event NAME, not eventType or args - a forged POST could pair
-- a legitimate event name with `eventType:'server'` on a client-only node
-- (crossing the boundary the tree defined) or with attacker-chosen `args`.
-- Fixed by storing and dispatching the node's OWN eventType/args, looked up
-- from our own tree - `data.eventType`/`data.args` from the client payload are
-- ignored entirely.
--
-- KEYED BY PATH, NOT BY EVENT NAME. The name was the wrong key even for
-- honest clients: the qb idiom is ONE event with different positional args per
-- item, which shared/config.lua documents `args` for. Three leaves on
-- `palm6_shop:buy` with args {'bandage'} / {'water'} / {'medkit'} all collapsed
-- into a single map entry and the last one won - so clicking Bandage bought a
-- medkit, silently, with the "forged NUI callback?" diagnostic unable to fire
-- because the name genuinely was in the map. `eventType` collided the same
-- way, meaning a client leaf and a server leaf sharing a name would cross a
-- boundary the tree never declared.
--
-- The path is built from each node's position in the tree (index AND id), so
-- it is unique by construction even if two siblings somehow share an id, and
-- it is stamped onto the node itself as `nodeKey` so it travels to the NUI
-- with the tree and comes back on select. `id` alone is not enough - it is
-- only unique among SIBLINGS per shared/config.lua's schema.
local AllowedEvents = {}

--- Recursively collects every leaf node into `map`, keyed by its tree path,
--- stamping that same path onto the node as `nodeKey` on the way through.
--- @param path string the caller's path for `node` itself
local function collectEvents(node, map, path)
    if type(node) ~= 'table' then return end
    if node.event ~= nil then
        node.nodeKey = path
        map[path] = { event = node.event, eventType = node.eventType, args = node.args }
    end
    if node.items then
        for i, child in ipairs(node.items) do
            local childId = type(child.id) == 'string' and child.id or '?'
            collectEvents(child, map, ('%s/%d:%s'):format(path, i, childId))
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- Startup validation: exactly one of `items` / `event` must be set on any given node.
-- Never both, never neither. Warns per malformed node rather than hard-erroring, so one
-- bad entry in a third-party registration doesn't take down the whole menu.
-- ---------------------------------------------------------------------------------------
local function validateNode(node, path)
    if type(node) ~= 'table' then
        print(('[palm6_radialmenu] WARN: node at %s is not a table, skipping'):format(path))
        return
    end

    local hasItems = node.items ~= nil and type(node.items) == 'table' and #node.items > 0
    local hasEvent = node.event ~= nil

    if hasItems and hasEvent then
        print(('[palm6_radialmenu] WARN: node "%s" (%s) has BOTH items and event set — event will be ignored'):format(node.id or '?', path))
    elseif not hasItems and not hasEvent then
        print(('[palm6_radialmenu] WARN: node "%s" (%s) has NEITHER items nor event set — this node is dead'):format(node.id or '?', path))
    end

    if not node.id or type(node.id) ~= 'string' then
        print(('[palm6_radialmenu] WARN: node at %s is missing a string id'):format(path))
    end
    if not node.title or type(node.title) ~= 'string' then
        print(('[palm6_radialmenu] WARN: node "%s" (%s) is missing a string title'):format(node.id or '?', path))
    end
    if not node.icon or type(node.icon) ~= 'string' then
        print(('[palm6_radialmenu] WARN: node "%s" (%s) is missing a string icon'):format(node.id or '?', path))
    end

    if hasItems then
        for i, child in ipairs(node.items) do
            validateNode(child, path .. '.items[' .. i .. ']')
        end
    end
end

CreateThread(function()
    validateNode(Config.MenuTree, 'MenuTree')

    -- Both resources register the command AND the keymapping under the name
    -- `radialmenu`, and FiveM's command manager invokes every handler under a
    -- name - so with qbx_radialmenu still started, PageUp opens both menus,
    -- two owners call SetNuiFocus(true, true), and only ours ever releases it.
    -- RegisterKeyMapping also will not re-default an already-bound name, so
    -- Config.Keybind can be silently overridden on top of that.
    if Game.QbxRadialIsRunning() then
        print('[palm6_radialmenu] WARN: qbx_radialmenu is STARTED. Both resources bind the "radialmenu" ' ..
              'command/keybind and both will open. Add `stop qbx_radialmenu` before `ensure palm6_radialmenu` ' ..
              'in custom.cfg (see README.md "Before First Ensure").')
    end
end)

-- ---------------------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------------------

function OpenRadial()
    if isOpen then return end
    if not Game.CanOpenRadial() then return end

    -- collectEvents stamps `nodeKey` onto the tree it walks, so it must run
    -- BEFORE the tree is sent - the NUI echoes that key back on select.
    local tree = BuildTree()
    AllowedEvents = {}
    collectEvents(tree, AllowedEvents, 'root')
    isOpen = true
    Game.PlaySound('NAV_LEFT_RIGHT')
    SendNUIMessage({ action = 'open', tree = tree, accent = '#d6a950' })
    SetNuiFocus(true, true)
end

function CloseRadial()
    if not isOpen then return end
    isOpen = false
    AllowedEvents = {}
    SendNUIMessage({ action = 'close' })
    SetNuiFocus(false, false)
end

-- ---------------------------------------------------------------------------------------
-- Watchdog: the menu must close when the player stops being allowed to have it open.
--
-- Game.CanOpenRadial() was consulted exactly once, at open, and nothing
-- re-checked it afterwards. `palm6_radialmenu:forceClose` exists for third
-- parties to close it, but nothing repo-wide fires it and the resources that
-- would (cuffing, death) are out-of-repo and cannot know a palm6-only event
-- name - tools/audit/allowlist.js waives it in writing, which is the audit
-- recording the gap rather than the gap being covered.
--
-- Concretely: die with the menu up and the wedges sit over the death screen
-- with NUI focus held, so hold-E respawn and the ambulance controls get
-- nothing. Escape still works at every level, so it is recoverable - but a
-- player who does not know that is stuck looking at a menu during their own
-- death.
--
-- Polled rather than event-driven for the same reason forceClose has no
-- senders: there is no event we own to listen to.
CreateThread(function()
    while true do
        if isOpen and (not Game.CanOpenRadial() or Game.IsPlayerDead()) then
            CloseRadial()
        end
        Wait(isOpen and Config.StateWatchdogIntervalMs or 500)
    end
end)

RegisterCommand('radialmenu', function()
    OpenRadial()
end, false)

RegisterKeyMapping('radialmenu', 'Open Interaction Menu', 'keyboard', Config.Keybind)

-- ---------------------------------------------------------------------------------------
-- NUI callbacks
-- ---------------------------------------------------------------------------------------

RegisterNUICallback('select', function(data, cb)
    cb('ok')
    if not isOpen then return end   -- forged POST while no menu was ever open - nothing to select

    -- `data.key` is used ONLY as a lookup key into AllowedEvents, which was
    -- built from OUR tree, not the client payload. The event NAME, eventType
    -- and args all come from that lookup, never from `data` itself - a forged
    -- POST cannot cross a client/server boundary the tree didn't declare, or
    -- smuggle in its own args, even if it names a real event.
    local key = (type(data) == 'table' and type(data.key) == 'string') and data.key or nil
    local node = key and AllowedEvents[key] or nil
    CloseRadial()
    if not node then
        print(('[palm6_radialmenu] WARN: dropped select for key "%s" — not a leaf in the menu tree this client was shown (forged NUI callback?)')
            :format(tostring(key)))
        return
    end

    -- The echoed event name is a CROSS-CHECK, never the source of truth. It
    -- costs nothing and turns a NUI/Lua tree desync (which is otherwise a
    -- silently wrong action) into a logged refusal.
    if data.event ~= nil and data.event ~= node.event then
        print(('[palm6_radialmenu] WARN: dropped select for key "%s" — payload event "%s" does not match the tree\'s "%s"')
            :format(key, tostring(data.event), tostring(node.event)))
        return
    end

    Game.PlaySound('SELECT')
    if node.eventType == 'server' then
        TriggerServerEvent(node.event, table.unpack(node.args or {}))
    else
        TriggerEvent(node.event, table.unpack(node.args or {}))
    end
end)

RegisterNUICallback('close', function(_, cb)
    cb('ok')
    CloseRadial()
end)

-- Focus release happens synchronously inside the callback (not deferred by SetTimeout) —
-- by the time JS's fetch POST fires, its own close animation has already finished
-- client-side (see html/script.js), matching palm6_ui's idiom of syncing the CSS duration
-- and the JS setTimeout, just with the wait living in JS instead of Lua.

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isOpen then
        isOpen = false
        SetNuiFocus(false, false)
    end
end)

-- Force-close from other resources if needed (e.g. player gets cuffed mid-menu).
RegisterNetEvent('palm6_radialmenu:forceClose', function()
    CloseRadial()
end)

-- ---------------------------------------------------------------------------------------
-- Example leaf handlers for the shipped example tree (shared/config.lua). These are
-- intentionally minimal — real implementations belong to whichever resource owns each
-- feature (vehicle locks, emote wheel, player ID display, etc). Kept here only so the
-- shipped example tree has something to dispatch to and doesn't produce dead events.
-- ---------------------------------------------------------------------------------------

RegisterNetEvent('palm6_radialmenu:vehicleLock', function()
    Game.Notify('Vehicle lock toggled (example handler — wire to your vehicle resource).', 'inform')
end)

RegisterNetEvent('palm6_radialmenu:vehicleHood', function()
    Game.Notify('Hood toggled (example handler — wire to your vehicle resource).', 'inform')
end)

RegisterNetEvent('palm6_radialmenu:openEmoteMenu', function()
    Game.Notify('Emote menu requested (example handler — wire to your emote resource).', 'inform')
end)

RegisterNetEvent('palm6_radialmenu:showId', function()
    Game.Notify(('Your server ID: %s'):format(GetPlayerServerId(PlayerId())), 'inform')
end)
