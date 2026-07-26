-- ============================================================================
-- palm6_mapeditor/client/nui.lua  —  thumbnail prop-browser NUI controller
--
-- The visual counterpart to client/browser.lua's ox_lib menus: a full-screen
-- grid of the 5,295-prop catalog with live RAGE-odb thumbnails, category rail,
-- and search. /propui opens it; clicking a prop spawns it into the editor at
-- your aim and closes the browser so you can immediately position it.
--
-- The editor's live loop already stands down while a NUI is focused
-- (IsNuiFocused() in client/main.lua), so opening this never fights the edit
-- controls. This file owns ONLY NUI focus + the catalog handoff; the actual
-- spawn goes through the same palm6_mapeditor:spawn event the ox_lib browser
-- uses, so both browsers share one placement path.
--
-- COMMAND
--   /propui   toggle the thumbnail browser (must be in the editor: /mapedit)
-- ============================================================================

local open = false

local function openBrowser()
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then
        Game.Notify('open the editor first (/mapedit)', 'error')
        return
    end
    if open then return end
    open = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', groups = Config.PropGroups or {} })
end

local function closeBrowser()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterCommand('propui', function()
    if open then closeBrowser() else openBrowser() end
end, false)

-- Open the browser straight onto the Controls & Commands reference sheet. Same
-- focus handling as /propui; the page shows the help overlay on top of the grid.
local function openHelp()
    -- Silent no-op outside the editor: the default keybind is H (a common key),
    -- so it must never notify or act unless the map editor is actually open.
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then return end
    if not open then
        open = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', groups = Config.PropGroups or {}, help = true })
    else
        SendNUIMessage({ action = 'help' })
    end
end

RegisterCommand('maphelp', openHelp, false)
-- Let players bind a key (default H) to pull up the controls sheet in-world.
RegisterKeyMapping('maphelp', 'Map editor: controls & commands', 'keyboard', 'H')

-- Open the browser straight onto the Activity Log (a searchable history of every
-- action the editor reported this session). Same focus handling as /propui.
local function openLog()
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then return end
    local log = (Game.GetActivityLog and Game.GetActivityLog()) or {}
    if not open then
        open = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', groups = Config.PropGroups or {}, activity = log })
    else
        SendNUIMessage({ action = 'activity', log = log })
    end
end

RegisterCommand('maplog', openLog, false)
-- Default key L (silent outside the editor, like /maphelp).
RegisterKeyMapping('maplog', 'Map editor: activity log', 'keyboard', 'L')

-- Spawn a picked prop. The model name is validated again here (defence in depth,
-- same strict rule the spawner enforces) even though it came from our own
-- catalog, then routed through the shared spawn event. Closes so the player can
-- position the fresh prop with the editor controls.
RegisterNUICallback('spawnProp', function(data, cb)
    local model = type(data) == 'table' and data.model or nil
    if type(model) == 'string' and model:match('^[%w_]+$') then
        TriggerEvent('palm6_mapeditor:spawn', model)
    end
    closeBrowser()
    cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
    closeBrowser()
    cb('ok')
end)

-- Never leave the player trapped with a cursor. The NUI page posts 'close' on
-- Esc, but if the page fails to load or its JS throws, that path is gone — so
-- this is a guaranteed Lua-side backstop: IsRawKeyPressed reads the physical Esc
-- key even while a NUI holds keyboard focus. Also closes if the editor is somehow
-- toggled off underneath the browser.
CreateThread(function()
    local escFrames = 0
    while true do
        if open then
            if MapEd and MapEd.isEditing and not MapEd.isEditing() then
                -- Editor toggled off underneath the browser: release focus at once.
                closeBrowser()
                escFrames = 0
            elseif IsRawKeyPressed(0x1B) then                          -- VK_ESCAPE, hardware-level
                -- Normal Esc is OWNED by the page JS: it backs out an open overlay
                -- (help / activity) first, then posts 'close'. This raw-key path must
                -- NOT steal that, so it's only a dead-page panic hatch — it fires just
                -- when Esc is HELD ~0.4s, which a quick tap never reaches.
                escFrames = escFrames + 1
                if escFrames >= 25 then closeBrowser(); escFrames = 0 end
            else
                escFrames = 0
            end
            Wait(0)
        else
            escFrames = 0
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and open then SetNuiFocus(false, false) end
end)
