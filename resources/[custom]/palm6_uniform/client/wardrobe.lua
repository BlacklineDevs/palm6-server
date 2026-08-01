-- ============================================================================
-- palm6_uniform/client/wardrobe.lua
--
-- THE WALK-UP WARDROBE AT THE POLICE STATION. This is the primary interface to
-- this resource; the chat commands are the fallback.
--
-- Pure logic. Every native, every ox_target call and every ox_lib menu call
-- goes through Game.* (bridge/cl_game.lua). Nothing in this file decides which
-- uniform anybody may wear: the server builds the entire menu, row by row,
-- including every greyed-out row and the plain-English reason it is greyed
-- out, and this file draws it.
--
-- THE TWO RULES THIS FILE IS WRITTEN TO, because breaking either of them is
-- what wasted the last two sessions:
--
--   1. THE MENU IS NEVER BLANK. Not when nothing has been captured, not when
--      the player is not police, not when the server fails to answer. A blank
--      menu is indistinguishable from a broken resource.
--
--   2. A CLICK IS NEVER SILENT. Every selectable row either changes something
--      on screen or produces a notify saying why it did not.
-- ============================================================================

local MENU_ID         = 'palm6_uniform_wardrobe'
local MENU_RANKS_ID   = 'palm6_uniform_wardrobe_ranks'
local MENU_VARIANT_ID = 'palm6_uniform_wardrobe_variant'

-- The live interaction handle (an ox_target zone, or an ox_lib point). Held so
-- a re-push from the server replaces it rather than stacking a second one.
local handle = nil

-- Debounce for the "where is the wardrobe" request. Both spawn signals fire on
-- a join within moments of each other and the server's own limit on that event
-- is deliberately silent, so asking twice would simply lose the second ask.
local REQUEST_DEBOUNCE_MS = 10000
local lastRequestAt = -REQUEST_DEBOUNCE_MS

-- Forward declarations. These three call each other in a cycle (root menu ->
-- rank submenu -> variant submenu, and the root is reachable again from the
-- back arrow), so they are declared as locals up here rather than left as
-- globals, which in a FiveM resource would leak into every script in it.
local openMenu, openCaptureRanks, openCaptureVariants

-- ---------------------------------------------------------------------------
-- Draw one server-built row list as an ox_lib context menu.
--
-- `rows` come off the wire, so every field is treated as untrusted shape (not
-- untrusted CONTENT - the server wrote it) and defaulted rather than allowed to
-- blow up mid-render and leave nothing on screen.
-- ---------------------------------------------------------------------------
local function renderRows(menu)
    local options = {}

    for i = 1, #menu.rows do
        local r = menu.rows[i]
        if type(r) == 'table' and type(r.title) == 'string' then
            local disabled = (r.disabled == true) or (r.action == 'note') or (r.action == nil)
            options[#options + 1] = {
                title       = r.title,
                description = type(r.description) == 'string' and r.description or nil,
                icon        = type(r.icon) == 'string' and r.icon or nil,
                disabled    = disabled,
                onSelect    = (not disabled) and function()
                    if r.action == 'capture_menu' then
                        -- Handled entirely client side: it opens a submenu
                        -- built from data the server already sent. Nothing is
                        -- stored until a rank AND a variant have been picked.
                        openCaptureRanks(menu)
                    else
                        TriggerServerEvent('palm6_uniform:menuAction', r.action, r.arg)
                    end
                end or nil,
            }
        end
    end

    -- A footer the server cannot write, because it is client-realm truth:
    -- which interaction route actually got built on THIS client, and the
    -- command fallback. Also the last line of defence against an empty menu.
    options[#options + 1] = {
        title       = 'How you got here',
        description = ('Interaction: %s. If this menu ever fails, /uniform and /uniformoff do the same two things from anywhere.')
            :format(Game.TargetState()),
        icon        = 'fas fa-circle-question',
        disabled    = true,
    }

    Game.OpenMenu(MENU_ID, menu.title or 'Station Wardrobe', options)
end

-- ---------------------------------------------------------------------------
-- CAPTURE, step 1 of 2: which rank?
--
-- The rank names come from the server, which read them out of
-- qbx_police_overrides' own grade roster. No rank name and no grade number is
-- authored here, and the server re-validates the grade when the capture lands.
-- ---------------------------------------------------------------------------
openCaptureRanks = function(menu)
    local cap = menu.capture
    if type(cap) ~= 'table' or type(cap.grades) ~= 'table' or #cap.grades == 0 then
        Game.OpenMenu(MENU_RANKS_ID, 'Save a uniform', {
            {
                title       = 'No rank list came back from the server.',
                description = 'That is a fault, not an empty list: the ranks are read from qbx_police_overrides. Nothing was saved. Check the server console for palm6_uniform lines.',
                icon        = 'fas fa-triangle-exclamation',
                disabled    = true,
            },
        }, MENU_ID)
        Game.Notify('The rank list did not arrive, so nothing was saved.', 'error')
        return
    end

    local options = {}
    for i = 1, #cap.grades do
        local g = cap.grades[i]
        local level = tonumber(g.level)
        local name  = type(g.name) == 'string' and g.name or ('grade ' .. tostring(level))
        if level then
            options[#options + 1] = {
                title       = ('Save as the %s uniform'):format(name),
                description = ('Applies to grade %d AND EVERY GRADE ABOVE IT, until a higher rank gets its own capture. So one save at the lowest rank dresses the whole department.'):format(level),
                icon        = 'fas fa-user-shield',
                onSelect    = function() openCaptureVariants(menu, level, name) end,
            }
        end
    end

    if not cap.rosterKnown then
        options[#options + 1] = {
            title       = 'Rank names could not be read.',
            description = 'qbx_police_overrides did not answer with its grade roster, so the list above is bare grade numbers rather than invented rank names. Saving still works.',
            icon        = 'fas fa-circle-info',
            disabled    = true,
        }
    end

    Game.OpenMenu(MENU_RANKS_ID, 'Save a uniform: which rank?', options, MENU_ID)
end

-- ---------------------------------------------------------------------------
-- CAPTURE, step 2 of 2: which conditions?
--
-- The variants come from the server too, built from Config.Seasons and
-- Config.Weathers so the menu cannot offer a bucket the validator will reject.
-- Picking one sends the capture. That is the last click; there is no text box
-- anywhere in this flow, and the label is composed server-side from the rank
-- name and the variant.
-- ---------------------------------------------------------------------------
openCaptureVariants = function(menu, level, rankName)
    local variants = menu.capture and menu.capture.variants
    if type(variants) ~= 'table' or #variants == 0 then
        Game.OpenMenu(MENU_VARIANT_ID, 'Save a uniform', {
            {
                title       = 'No condition list came back from the server.',
                description = 'Nothing was saved. This list is built from Config.Seasons and Config.Weathers on the server; an empty one means the resource is misconfigured.',
                icon        = 'fas fa-triangle-exclamation',
                disabled    = true,
            },
        }, MENU_RANKS_ID)
        Game.Notify('The condition list did not arrive, so nothing was saved.', 'error')
        return
    end

    local options = {}
    for i = 1, #variants do
        local v = variants[i]
        if type(v) == 'table' and type(v.season) == 'string' and type(v.weather) == 'string' then
            options[#options + 1] = {
                title       = type(v.title) == 'string' and v.title or ('%s / %s'):format(v.season, v.weather),
                description = ('Stored as season "%s", weather "%s" for %s. Whatever you have on right now is photographed the moment you click this.')
                    :format(v.season, v.weather, rankName),
                icon        = 'fas fa-cloud-sun',
                onSelect    = function()
                    TriggerServerEvent('palm6_uniform:menuAction', 'capture', level, v.season, v.weather)
                end,
            }
        end
    end

    Game.OpenMenu(MENU_VARIANT_ID, ('%s: which conditions?'):format(rankName), options, MENU_RANKS_ID)
end

-- ---------------------------------------------------------------------------
-- OPEN. Ask the server what this player may wear, then draw it.
-- ---------------------------------------------------------------------------
openMenu = function()
    if not Game.MenuAvailable() then
        -- ox_lib is a declared dependency, so this should be impossible. It is
        -- checked anyway because the alternative is pressing E at a wardrobe
        -- and getting absolutely nothing, which is the failure this whole file
        -- exists to remove.
        Game.Notify('This client has no ox_lib menu, so the wardrobe cannot open. /uniform puts your uniform on and /uniformoff takes it off.', 'error')
        Game.Chat('the wardrobe menu needs ox_lib and it is not available on this client. Use /uniform and /uniformoff.')
        return
    end

    local menu = Game.FetchMenu()
    if type(menu) ~= 'table' or type(menu.rows) ~= 'table' then
        -- NOT an empty wardrobe. A wardrobe that could not ask.
        Game.OpenMenu(MENU_ID, 'Station Wardrobe', {
            {
                title       = 'The server did not answer.',
                description = 'The wardrobe asked which uniforms you are allowed to wear and got nothing back. That is a server-side fault, not an empty wardrobe: an empty one says so in words. Check the server console for palm6_uniform lines, then try again.',
                icon        = 'fas fa-triangle-exclamation',
                disabled    = true,
            },
        })
        Game.Notify('The wardrobe could not reach the server. Nothing was changed.', 'error')
        return
    end

    renderRows(menu)
end

-- ---------------------------------------------------------------------------
-- WHERE THE WARDROBE IS. The server sends it; this file never computes one.
--
-- The position is read on the server from qbx_police_overrides' own duty-toggle
-- contract (see bridge/sv_framework.lua Bridge.GetStationPoint). That export is
-- server realm only, which is why it arrives over an event instead of being
-- read here.
--
-- `point` arriving as `false` means the server tried and could not work one
-- out, and `why` says which of the sources failed. That case is REPORTED, not
-- swallowed: a wardrobe nobody told you about and a wardrobe that is not there
-- look the same from where the player is standing.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:wardrobePoint', function(point, why)
    if not Config.Enabled or not Config.Wardrobe.Enabled then return end

    Game.RemoveWardrobe(handle)
    handle = nil

    if type(point) ~= 'table' then
        Game.Chat(('the station wardrobe could not be placed: %s. /uniform and /uniformoff still work from anywhere.')
            :format(tostring(why)))
        return
    end

    handle = Game.CreateWardrobe(
        MENU_ID,
        point,
        tonumber(point.radius) or Config.Wardrobe.MinRadius,
        type(point.label) == 'string' and point.label or Config.Wardrobe.Label,
        type(point.icon) == 'string' and point.icon or Config.Wardrobe.Icon,
        openMenu)

    if not handle then
        Game.Chat('the station wardrobe could not be created: this client has neither ox_target nor ox_lib points. /uniform and /uniformoff still work.')
    end
end)

-- Ask the server where the wardrobe is: once when this resource starts, and
-- again on every spawn, because a client that joined before the server pushed
-- the point would otherwise never hear about it.
local function requestPoint()
    if not Config.Enabled or not Config.Wardrobe.Enabled then return end
    local t = Game.Now()
    if (t - lastRequestAt) < REQUEST_DEBOUNCE_MS then return end
    lastRequestAt = t
    TriggerServerEvent('palm6_uniform:wardrobeRequest')
end

CreateThread(function()
    if not Config.Enabled or not Config.Wardrobe.Enabled then return end
    -- A short settle before the first ask. The server answers a request from
    -- any live client, so this does not have to wait for a ped.
    Game.Wait(2000)
    requestPoint()
end)

Game.OnPlayerSpawned(requestPoint)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- An ox_target zone outlives the script that made it, so a restart without
    -- this leaves a dead eye at the station that opens nothing.
    Game.RemoveWardrobe(handle)
    handle = nil
end)
