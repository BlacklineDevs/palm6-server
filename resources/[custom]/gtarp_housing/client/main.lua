-- ============================================================================
-- gtarp_housing/client/main.lua
--
-- Pure logic: property blips, door-proximity interaction, buy/enter/manage
-- menus, and shell entry/exit. All natives + ox_lib UI go through Game.*
-- (bridge/cl_game.lua). To port to GTA VI, rewrite the bridge, not this file.
-- See docs/GTA6-READINESS.md.
-- ============================================================================

local props = {}   -- latest synced list (see server viewFor)
local blips = {}   -- [propId] = blip handle

-- ---------------------------------------------------------------------------
-- blips
-- ---------------------------------------------------------------------------
local function clearBlips()
    for id, h in pairs(blips) do Game.RemoveBlip(h) end
    blips = {}
end

local function rebuildBlips()
    clearBlips()
    for _, p in ipairs(props) do
        local style
        if p.relation == 'owned' then style = Config.Blips.owned
        elseif p.relation == 'keyed' then style = Config.Blips.keyed
        elseif p.relation == 'forsale' and Config.ShowForSaleBlips then style = Config.Blips.forsale end
        if style and p.door then
            blips[p.id] = Game.CreateBlip(p.door, style.sprite, style.colour, style.scale, style.label)
        end
    end
end

RegisterNetEvent('gtarp_housing:sync', function(list)
    props = list or {}
    rebuildBlips()
end)

RegisterNetEvent('gtarp_housing:teleport', function(coords)
    Game.TeleportWithFade(coords)
end)

RegisterNetEvent('gtarp_housing:openStash', function(id)
    Game.OpenStash(id)
end)

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------
local function enter(id)  TriggerServerEvent('gtarp_housing:enter', id) end
local function buy(id)    TriggerServerEvent('gtarp_housing:buy', id) end
local function sell(id)   TriggerServerEvent('gtarp_housing:sell', id) end

local function grantNearest(id)
    local sid = Game.GetNearestPlayerServerId(5.0)
    if not sid then
        Game.Notify({ title = 'Housing', description = 'No one is standing nearby.', type = 'error' })
        return
    end
    TriggerServerEvent('gtarp_housing:grantAccess', id, sid)
end

local function manageKeys(p)
    local options = {}
    for _, cid in ipairs(p.access or {}) do
        options[#options + 1] = {
            title = cid,
            description = 'Revoke this key',
            onSelect = function() TriggerServerEvent('gtarp_housing:revokeAccess', p.id, cid) end,
        }
    end
    if #options == 0 then
        Game.Notify({ title = 'Housing', description = 'No keys have been shared.', type = 'inform' })
        return
    end
    Game.ContextMenu('housing_keys', 'Manage Keys', options)
end

local function ownerMenu(p)
    local refund = math.floor((p.price or 0) * (Config.SellBackRate or 0.5))
    Game.ContextMenu('housing_owner', ('%s'):format(p.street or 'Property'), {
        { title = 'Enter', description = 'Go inside', onSelect = function() enter(p.id) end },
        { title = 'Give key to nearest player', onSelect = function() grantNearest(p.id) end },
        { title = 'Manage keys', description = 'Revoke shared keys', onSelect = function() manageKeys(p) end },
        { title = ('Sell back ($%d)'):format(refund), onSelect = function() sell(p.id) end },
    })
end

local function interact(p)
    if p.relation == 'owned' then
        ownerMenu(p)
    elseif p.relation == 'keyed' then
        enter(p.id)
    elseif p.relation == 'forsale' then
        if Game.Confirm('Buy Property', ('Buy %s for $%d?'):format(p.street or 'this property', p.price or 0)) then
            buy(p.id)
        end
    end
end

local function promptFor(p)
    if p.relation == 'owned' then return 'Press ~INPUT_PICKUP~ for home options'
    elseif p.relation == 'keyed' then return 'Press ~INPUT_PICKUP~ to enter'
    else return ('Press ~INPUT_PICKUP~ to buy ($%d)'):format(p.price or 0) end
end

-- Nearest interactable property within the interact radius, or nil.
local function nearestProp()
    local me = Game.GetPlayerCoords()
    local best, bestD = nil, (Config.InteractRadius or 2.0)
    for _, p in ipairs(props) do
        if p.door and p.relation ~= 'none' then
            local d = Game.DistanceBetween(me, p.door)
            if d <= bestD then best, bestD = p, d end
        end
    end
    return best
end

CreateThread(function()
    while true do
        local wait = 800
        local p = nearestProp()
        if p then
            wait = 0
            Game.ShowHelpThisFrame(promptFor(p))
            if Game.InteractPressed() then interact(p) end
        end
        Wait(wait)
    end
end)

-- ---------------------------------------------------------------------------
-- commands (used inside a shell, where there is no door to target)
-- ---------------------------------------------------------------------------
RegisterCommand('exithome', function() TriggerServerEvent('gtarp_housing:exit') end, false)
RegisterCommand('stash',    function() TriggerServerEvent('gtarp_housing:openStash') end, false)

-- ---------------------------------------------------------------------------
-- initial sync (retry until the server answers)
-- ---------------------------------------------------------------------------
CreateThread(function()
    while #props == 0 do
        TriggerServerEvent('gtarp_housing:requestSync')
        Wait(3000)
    end
end)
