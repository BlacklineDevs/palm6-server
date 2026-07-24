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

-- Never leave the player trapped with a cursor: if the editor is toggled off or
-- the resource stops while the browser is up, release focus.
CreateThread(function()
    while true do
        if open and MapEd and MapEd.isEditing and not MapEd.isEditing() then closeBrowser() end
        Wait(500)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and open then SetNuiFocus(false, false) end
end)
