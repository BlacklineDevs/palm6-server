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

-- Never take NUI focus on top of an entity carry. Focus swallows the
-- Enter/Backspace the carry loop is waiting on, so the carry stalls: it resumes
-- as soon as the NUI closes (closeBrowser restores focus), but while it is
-- stalled the entity exists nowhere but the server's in-memory backup, which a
-- restart or a crash would have to rescue. Applies to ALL THREE focus entry
-- points, not just /propui: /maphelp and /maplog are bound to bare H and L by
-- default, so they are far more likely to be hit mid-carry than a typed command.
local function carryBlocked()
    if Entities and Entities.isCarrying and Entities.isCarrying() then
        Game.Notify('drop the entity you are carrying first', 'error')
        return true
    end
    return false
end

local function openBrowser()
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then
        Game.Notify('open the editor first (/mapedit)', 'error')
        return
    end
    if carryBlocked() then return end
    if open then return end
    open = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        groups = Config.PropGroups or {},
        peds = Config.PedGroups or {},         -- Peds tab catalog
        vehs = Config.VehGroups or {},         -- Vehicles tab catalog
        scenarios = Config.PedScenarios or {}, -- ped behaviour options
    })
    if Prefabs and Prefabs.sendKits then Prefabs.sendKits() end   -- populate Blueprint Kits
    if Scene and Scene.push then Scene.push() end                 -- populate the Scene outliner
    if Live and Live.push then Live.push() end                    -- populate the Live-map outliner
    if Entities and Entities.push then Entities.push() end         -- populate the Entities outliner
    if Perf and Perf.push then Perf.push() end                    -- populate the Performance panel
end

-- Assemble the Performance panel payload. The NUI already holds the session's
-- props + lights (via 'scene') and the live-map props (via 'live') with coords,
-- so it computes those counts and the density map itself; this supplies only
-- what it can't see — the live light / world-erase / scene-entity counts and the
-- configured budgets — so builders can watch a map against the caps that bound
-- what every client has to stream.
Perf = { push = function()
    local liveProps, liveLights, liveHides = 0, 0, 0
    if Live and Live.stats then liveProps, liveLights, liveHides = Live.stats() end
    local peds, veh = 0, 0
    if Entities and Entities.count then peds, veh = Entities.count() end
    SendNUIMessage({
        action = 'perf',
        live = { props = liveProps, lights = liveLights, hides = liveHides, peds = peds, veh = veh },
        caps = {
            liveProps  = Config.LiveMaxProps  or 6000,
            liveLights = Config.LiveMaxLights or 256,
            hides      = Config.LiveMaxHides  or 2000,
            entities   = Config.EntityMax     or 1500,
            commit     = Config.LiveMaxCommit or 1000,
        },
    })
end }

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
    if not open and carryBlocked() then return end   -- H is a bare keybind: never grab focus mid-carry
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
    if not open and carryBlocked() then return end   -- L is a bare keybind: never grab focus mid-carry
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

-- Place a ped or vehicle from the Peds/Vehicles browser at the player's aim.
-- Routes through entities.lua (same aim + place path as /matped /matveh) and
-- closes the browser so the fresh entity is visible.
RegisterNUICallback('placeEnt', function(data, cb)
    local kind = type(data) == 'table' and data.kind or nil
    local model = type(data) == 'table' and data.model or nil
    local scenario = type(data) == 'table' and data.scenario or ''
    if (kind == 'ped' or kind == 'veh') and type(model) == 'string' and model:match('^[%w_]+$') then
        TriggerEvent('palm6_mapeditor:placeEnt', kind, model, scenario)
    end
    closeBrowser()
    cb('ok')
end)

-- Stamp a blueprint kit (prefab) at the player's aim. Routes through the same
-- one-placement-path idea as spawn: validate the name, hand off to prefabs.lua,
-- and close the browser so the stamp lands where the player is looking.
RegisterNUICallback('stampPrefab', function(data, cb)
    local name = type(data) == 'table' and data.name or nil
    if type(name) == 'string' and #name > 0 and #name <= 64 then
        TriggerEvent('palm6_mapeditor:stampPrefab', name)
    end
    closeBrowser()
    cb('ok')
end)

-- Scene outliner: delete a placed prop by id (browser stays open, list refreshes)
-- or jump to it (select + teleport, then close so you can see it).
RegisterNUICallback('sceneDelete', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and MapEd and MapEd.deleteById then
        MapEd.deleteById(id)
        if Scene and Scene.push then Scene.push() end
    end
    cb('ok')
end)

-- Save the selected scene props as a new blueprint kit (prefab). Stays open so
-- the freshly-saved kit appears in the Blueprint kits view.
RegisterNUICallback('sceneSaveKit', function(data, cb)
    local name = type(data) == 'table' and data.name or nil
    local ids = type(data) == 'table' and data.ids or nil
    if type(name) == 'string' and type(ids) == 'table' and Prefabs and Prefabs.saveFromSelection then
        local clean = {}
        for _, id in ipairs(ids) do local n = tonumber(id); if n then clean[#clean + 1] = n end end
        Prefabs.saveFromSelection(name, clean)
    end
    cb('ok')
end)

RegisterNUICallback('sceneDeleteMany', function(data, cb)
    local ids = type(data) == 'table' and data.ids or nil
    if type(ids) == 'table' and MapEd and MapEd.deleteByIds then
        local clean = {}
        for _, id in ipairs(ids) do local n = tonumber(id); if n then clean[#clean + 1] = n end end
        MapEd.deleteByIds(clean)
        if Scene and Scene.push then Scene.push() end
    end
    cb('ok')
end)

RegisterNUICallback('sceneLightDelete', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and MapEd and MapEd.deleteLightById then
        MapEd.deleteLightById(id)
        if Scene and Scene.push then Scene.push() end
    end
    cb('ok')
end)

RegisterNUICallback('sceneLightGoto', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and MapEd and MapEd.gotoLightById then MapEd.gotoLightById(id) end
    closeBrowser()
    cb('ok')
end)

RegisterNUICallback('sceneGoto', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and MapEd and MapEd.gotoById then MapEd.gotoById(id) end
    closeBrowser()
    cb('ok')
end)

-- Live-map outliner actions (client/live.lua does the work; reuses audited
-- by-id server events). Delete stays open + refreshes via the live:remove
-- broadcast; grab and goto close so the player sees the result in-world.
RegisterNUICallback('liveDelete', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id then TriggerEvent('palm6_mapeditor:liveDelete', id) end
    cb('ok')
end)
RegisterNUICallback('liveDeleteMany', function(data, cb)
    local ids = type(data) == 'table' and data.ids or nil
    if type(ids) == 'table' then TriggerEvent('palm6_mapeditor:liveDeleteMany', ids) end
    cb('ok')
end)
RegisterNUICallback('liveGrab', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id then TriggerEvent('palm6_mapeditor:liveGrab', id) end
    closeBrowser()
    cb('ok')
end)
RegisterNUICallback('liveGoto', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id then TriggerEvent('palm6_mapeditor:liveGoto', id) end
    closeBrowser()
    cb('ok')
end)
-- Export the picked named map to files (server writes .lua/.json/.ymap.xml/.py).
-- Stays open — the result is files on the server + Lua on the clipboard, nothing
-- to see in-world.
RegisterNUICallback('liveExport', function(data, cb)
    local map = type(data) == 'table' and data.map or nil
    if type(map) == 'string' and Live and Live.exportMap then Live.exportMap(map) end
    cb('ok')
end)
-- Revisions / snapshots. All stay open; the server pushes a fresh revs list back.
RegisterNUICallback('liveSnapshot', function(data, cb)
    local map = type(data) == 'table' and data.map or nil
    local label = type(data) == 'table' and data.label or ''
    if type(map) == 'string' and Live and Live.snapshot then Live.snapshot(map, label) end
    cb('ok')
end)
RegisterNUICallback('liveRevList', function(data, cb)
    local map = type(data) == 'table' and data.map or nil
    if type(map) == 'string' and Live and Live.revList then Live.revList(map) end
    cb('ok')
end)
RegisterNUICallback('liveRevRestore', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and Live and Live.revRestore then Live.revRestore(id) end
    cb('ok')
end)
RegisterNUICallback('liveRevDelete', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and Live and Live.revDelete then Live.revDelete(id) end
    cb('ok')
end)

-- Merge a named map into another. Stays open; mapRenamed broadcast re-pushes.
RegisterNUICallback('liveMerge', function(data, cb)
    local fromName = type(data) == 'table' and data.from or nil
    local intoName = type(data) == 'table' and data.into or nil
    if type(fromName) == 'string' and type(intoName) == 'string' and Live and Live.mergeMap then
        Live.mergeMap(fromName, intoName)
    end
    cb('ok')
end)

-- Rename a named map (props + lights + entities). Stays open; the mapRenamed
-- broadcast re-pushes the outliner with the new name.
RegisterNUICallback('liveRename', function(data, cb)
    local oldName = type(data) == 'table' and data.old or nil
    local newName = type(data) == 'table' and data.new or nil
    if type(oldName) == 'string' and type(newName) == 'string' and Live and Live.renameMap then
        Live.renameMap(oldName, newName)
    end
    cb('ok')
end)

-- Entities outliner (peds / vehicles). Delete reuses the audited ent:remove
-- server event and stays open (the ent:remove broadcast re-pushes the list);
-- goto teleports and closes so the player lands on the entity.
RegisterNUICallback('entDelete', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and Entities and Entities.deleteById then Entities.deleteById(id) end
    cb('ok')
end)
RegisterNUICallback('entDeleteMany', function(data, cb)
    local ids = type(data) == 'table' and data.ids or nil
    if type(ids) == 'table' and Entities and Entities.deleteByIds then Entities.deleteByIds(ids) end
    cb('ok')
end)
RegisterNUICallback('entGoto', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and Entities and Entities.gotoById then Entities.gotoById(id) end
    closeBrowser()
    cb('ok')
end)
-- Grab an entity to move it: closes the browser so the carry preview is visible.
RegisterNUICallback('entGrab', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id) or nil
    if id and Entities and Entities.grabById then Entities.grabById(id) end
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
