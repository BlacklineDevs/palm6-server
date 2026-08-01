-- ============================================================================
-- palm6_anchors/client/main.lua
--
-- The live view and the menu. Pure logic: every native and every ox_lib call
-- goes through Game.* (bridge/cl_game.lua).
--
-- THIS FILE DECIDES NOTHING. The server sends the list of points to draw and
-- builds every menu row; this file draws them, culls by distance, and sends
-- back which row was clicked. It never computes, sends or stores a coordinate:
-- the one position that matters (where the admin is standing at capture time)
-- is read on the server off the ped.
--
-- THE TWO RULES, taken from palm6_uniform because they were learned the same
-- expensive way:
--   1. THE MENU IS NEVER BLANK. Not when the registry is empty, not when the
--      admin lacks the ACE, not when the server fails to answer.
--   2. A CLICK IS NEVER SILENT. Every selectable row either changes something
--      on screen or produces a notify saying why it did not.
-- ============================================================================

local MENU_ID        = 'palm6_anchors_list'
local MENU_ANCHOR_ID = 'palm6_anchors_one'

-- Points pushed by the server: { key, x, y, z, captured }. Empty until the
-- server answers, and an empty list draws nothing rather than drawing the
-- registry's own values, because a client that has not been told is not the
-- same as a server with no anchors.
local points = {}

-- Markers off until an admin turns them on. The server owns this flag: the
-- client asks, the server checks the ACE, and the answer comes back on
-- palm6_anchors:markerState. Config.Markers.DefaultOn only seeds it.
local markersOn = Config.Markers.DefaultOn == true

-- The distance-culled subset, recomputed on a timer rather than every frame.
local visible = {}

-- When the next cull is due, in game-timer milliseconds. File scope rather than
-- a local inside the draw thread because a server push has to be able to make
-- the cull due NOW: after a capture the corrected anchor must move on screen at
-- once, not up to Config.Markers.RefreshMs later, or the admin sees his own
-- correction land in the old place and reasonably concludes it did not take.
local nextRefreshAt = 0

-- Debounce for the "send me the points" request. The two spawn signals fire
-- within moments of each other on a join, and the server's limit on that event
-- is deliberately silent, so asking twice would simply lose the second ask.
local REQUEST_DEBOUNCE_MS = 10000
local lastRequestAt = -REQUEST_DEBOUNCE_MS

local function requestPoints()
    if not Config.Enabled then return end
    local t = Game.Now()
    if (t - lastRequestAt) < REQUEST_DEBOUNCE_MS then return end
    lastRequestAt = t
    TriggerServerEvent('palm6_anchors:requestPoints')
end

-- ---------------------------------------------------------------------------
-- THE LIVE VIEW.
--
-- One thread. When markers are off it sleeps a full second and does nothing
-- else, so a player who never turns this on pays a wakeup a second and no
-- native calls at all. When they are on, the cull runs on Config.Markers
-- .RefreshMs and only the draw runs every frame.
--
-- THE CAP IS A HARD CAP. After sorting by distance, only the nearest MaxDrawn
-- are drawn. Mission Row has nine anchors inside 40m today; the cap is there so
-- that a registry three times this size cannot turn into a frame-rate incident.
-- ---------------------------------------------------------------------------
local function recomputeVisible()
    visible = {}
    if not markersOn then return end
    local pc = Game.PlayerCoords()
    if not pc then return end

    local near = {}
    for i = 1, #points do
        local p = points[i]
        local d = Game.Distance(pc, p.x, p.y, p.z)
        if d and d <= Config.Markers.Radius then
            near[#near + 1] = { p = p, d = d }
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)

    local n = math.min(#near, Config.Markers.MaxDrawn)
    for i = 1, n do
        visible[#visible + 1] = near[i]
    end
end

CreateThread(function()
    if not Config.Enabled then return end
    while true do
        if not markersOn then
            visible = {}
            nextRefreshAt = 0    -- due immediately when markers come back on
            Game.Wait(1000)
        else
            local t = Game.Now()
            if t >= nextRefreshAt then
                recomputeVisible()
                nextRefreshAt = t + Config.Markers.RefreshMs
            end
            for i = 1, #visible do
                local v = visible[i]
                local colour = v.p.captured and Config.Markers.ColourCaptured or Config.Markers.ColourConfig
                Game.DrawAnchorMarker(v.p.x, v.p.y, v.p.z, colour)
                if v.d <= Config.Markers.TextDistance then
                    Game.DrawAnchorText(v.p.x, v.p.y, v.p.z, v.p.key)
                end
            end
            Game.Wait(0)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- THE MENU
-- ---------------------------------------------------------------------------
local openList, openAnchor

-- Draw one server-built row list. Rows come off the wire, so every field is
-- treated as untrusted SHAPE (not untrusted content: the server wrote it) and
-- defaulted rather than allowed to blow up mid-render and leave nothing on
-- screen.
local function renderRows(menu, id, parentId, onAction)
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
                onSelect    = (not disabled) and function() onAction(r.action, r.arg) end or nil,
            }
        end
    end

    -- A footer the server cannot write, because it is client-realm truth.
    options[#options + 1] = {
        title       = 'How you got here',
        description = ('Markers are %s. /%s toggles them, /%s reopens this list, /anchorlist prints the whole thing to chat.')
            :format(markersOn and 'ON' or 'off', Config.MarkerCommand, Config.Command),
        icon        = 'fas fa-circle-question',
        disabled    = true,
    }

    Game.OpenMenu(id, menu.title or 'World anchors', options, parentId)
end

local function serverDidNotAnswer(id, parentId)
    Game.OpenMenu(id, 'World anchors', {
        {
            title       = 'The server did not answer.',
            description = 'This list asked the server which anchors exist and got nothing back. That is a server-side fault, not an empty registry: an empty one says so in words. Check the server console for palm6_anchors lines, then try again.',
            icon        = 'fas fa-triangle-exclamation',
            disabled    = true,
        },
    }, parentId)
    Game.Notify('The anchor list could not reach the server. Nothing was changed.', 'error')
end

-- One anchor's submenu.
openAnchor = function(key)
    if not Game.CallbacksAvailable() then
        Game.Notify(('This client has no ox_lib callbacks, so anchor details cannot be fetched. /anchorline %s prints the same thing to chat.')
            :format(tostring(key)), 'error')
        return
    end
    local menu = Game.FetchAnchorMenu(key)
    if type(menu) ~= 'table' or type(menu.rows) ~= 'table' then
        serverDidNotAnswer(MENU_ANCHOR_ID, MENU_ID)
        return
    end
    renderRows(menu, MENU_ANCHOR_ID, MENU_ID, function(action, arg)
        -- Every action here is a server decision. The client sends the anchor
        -- KEY and never a position.
        TriggerServerEvent('palm6_anchors:menuAction', action, arg)
    end)
end

openList = function()
    if not Config.Enabled then
        Game.Notify('palm6_anchors is switched off (Config.Enabled = false).', 'error')
        return
    end
    if not Game.MenuAvailable() then
        -- ox_lib is a declared dependency, so this should be impossible. It is
        -- checked anyway, because pressing a key and getting absolutely nothing
        -- is the failure this whole resource exists to remove.
        Game.Notify('This client has no ox_lib menu, so the anchor list cannot open. /anchorlist prints it to chat instead.', 'error')
        Game.Chat('the anchor menu needs ox_lib and it is not available on this client. Use /anchorlist.')
        return
    end

    -- The player's position is sent so the SERVER can sort by distance. It is
    -- used for ordering and for the "12.4m away" labels, and for nothing else:
    -- no capture and no config line is ever built from it.
    local pc = Game.PlayerCoords()
    local menu = Game.FetchMenu(pc and pc.x or nil, pc and pc.y or nil, pc and pc.z or nil)
    if type(menu) ~= 'table' or type(menu.rows) ~= 'table' then
        serverDidNotAnswer(MENU_ID, nil)
        return
    end

    renderRows(menu, MENU_ID, nil, function(action, arg)
        if action == 'anchor' then
            -- Opening a submenu YIELDS (it asks the server). ox_lib fires
            -- onSelect on its own frame, so this runs on a fresh thread rather
            -- than stalling the menu.
            CreateThread(function() openAnchor(arg) end)
        else
            TriggerServerEvent('palm6_anchors:menuAction', action, arg)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- SERVER PUSHES
-- ---------------------------------------------------------------------------

-- The point list. Replaces whatever was held; a re-push after a capture is how
-- a corrected anchor moves on screen without reopening anything.
RegisterNetEvent('palm6_anchors:points', function(list)
    if type(list) ~= 'table' then return end
    local clean = {}
    for i = 1, #list do
        local p = list[i]
        if type(p) == 'table' and type(p.key) == 'string'
           and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
            clean[#clean + 1] = {
                key = p.key,
                x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z),
                captured = p.captured == true,
            }
        end
    end
    points = clean
    -- Force the next tick to recompute rather than waiting out the refresh
    -- window, so a capture is visible immediately.
    visible = {}
    nextRefreshAt = 0
end)

-- The answer to a toggle request. The server checked the ACE; this is the only
-- thing that turns markers on.
RegisterNetEvent('palm6_anchors:markerState', function(on)
    markersOn = on == true
    visible = {}
    nextRefreshAt = 0
    Game.Notify(markersOn
        and ('Anchor markers ON. Every registered anchor within %dm is drawn with its key above it. Green means a capture is on file; amber means it is still the config value.')
            :format(math.floor(Config.Markers.Radius))
        or 'Anchor markers off.', 'inform')
end)

-- Teleport. The destination came from the server, which looked the key up in
-- the registry. This client never picked it.
RegisterNetEvent('palm6_anchors:teleport', function(x, y, z, label)
    if not Config.TeleportEnabled then return end
    if not (tonumber(x) and tonumber(y) and tonumber(z)) then return end
    local ok, grounded = Game.Teleport(tonumber(x), tonumber(y), tonumber(z))
    if not ok then
        Game.Notify('Your ped could not be moved, so the teleport did nothing.', 'error')
        return
    end
    Game.Notify(grounded
        and ('At "%s". You were dropped onto the ground under it.'):format(tostring(label))
        or  ('At "%s". NO GROUND was found under this anchor, so you are at its exact Z. That on its own is worth reporting: it usually means the anchor is inside geometry or in the air.')
            :format(tostring(label)),
        grounded and 'success' or 'warning')
end)

-- ---------------------------------------------------------------------------
-- HOW YOU OPEN IT
--
-- A command AND a keybind, both firing the same handler. The keybind is the one
-- you want while walking a station; the command is the one that still works
-- when the keybind is cleared or taken. Neither is gated here: the ACE check is
-- server-side, and a non-admin who presses the key gets a menu whose only row
-- says, by name, which permission is missing.
-- ---------------------------------------------------------------------------
Game.RegisterCommandAndKey(Config.Command, 'Anchors: nearby world anchors', Config.Keybind, function()
    -- Opening yields on a server callback, so it runs on its own thread rather
    -- than on the command dispatcher's.
    CreateThread(openList)
end)

Game.RegisterCommandAndKey(Config.MarkerCommand, 'Anchors: toggle anchor markers', nil, function()
    if not Config.Enabled then
        Game.Notify('palm6_anchors is switched off (Config.Enabled = false).', 'error')
        return
    end
    -- Ask for the OPPOSITE of what is on now. The server decides whether the
    -- answer is granted and sends the state back.
    TriggerServerEvent('palm6_anchors:toggleMarkers', not markersOn)
    if not markersOn then requestPoints() end
end)

-- ---------------------------------------------------------------------------
-- BOOT
-- ---------------------------------------------------------------------------
CreateThread(function()
    if not Config.Enabled then return end
    -- A short settle before the first ask. The server answers from any live
    -- client, so this does not have to wait for a ped.
    Game.Wait(2000)
    requestPoints()
end)

Game.OnPlayerSpawned(requestPoints)
