-- ============================================================================
-- palm6_mapeditor/client/prefabs.lua  —  prefab save / stamp (client half)
--
-- Caches the prefab defs the server owns and stamps them into the editor
-- session. A stamp spawns the prefab's props (stored relative to their centre)
-- at the player's aim point, rotated by an optional yaw — so you can drop a
-- whole furnished room or checkpoint in one command, then /mapcommit it live.
--
-- Prefabs are the editor's "blueprint kits": the NUI (/propui) surfaces them as
-- a pinned Blueprint Kits view (Prefabs.sendKits pushes the list; the Stamp
-- button routes back through palm6_mapeditor:stampPrefab).
--
-- COMMANDS
--   /mapprefabsave <name>        save your current session props as a prefab
--   /mapprefabstamp <name> [yaw] stamp a prefab at your aim (yaw in degrees)
--   /mapprefablist               list saved prefabs + prop counts
--   /mapprefabdel <name>         delete a prefab
-- ============================================================================

local prefabDefs = {}   -- [name] = { props = { {model,dx,dy,dz,rx,ry,rz}, ... } }

-- Push the current kit list to the NUI (name + prop/light counts). Sent on every
-- sync so the Blueprint Kits view stays current, and again when the browser opens.
local function sendKits()
    local list = {}
    for nm, def in pairs(prefabDefs) do
        list[#list + 1] = { name = nm, props = #(def.props or {}), lights = #(def.lights or {}) }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    SendNUIMessage({ action = 'kits', kits = list })
end

RegisterNetEvent('palm6_mapeditor:prefab:syncAll', function(all)
    prefabDefs = (type(all) == 'table') and all or {}
    sendKits()
end)
RegisterNetEvent('palm6_mapeditor:prefab:def', function(name, def)
    if type(name) == 'string' and type(def) == 'table' then prefabDefs[name] = def; sendKits() end
end)
RegisterNetEvent('palm6_mapeditor:prefab:removed', function(name)
    if type(name) == 'string' then prefabDefs[name] = nil; sendKits() end
end)

CreateThread(function()
    Wait(2500)
    TriggerServerEvent('palm6_mapeditor:prefab:requestSync')
end)

-- --- save ------------------------------------------------------------------
RegisterCommand('mapprefabsave', function(_, args)
    if not args[1] then Game.Notify('usage: /mapprefabsave <name>', 'error'); return end
    local snap = (MapEd and MapEd.snapshot) and MapEd.snapshot() or {}
    local lsnap = (MapEd and MapEd.getLights) and MapEd.getLights() or {}
    if #snap == 0 and #lsnap == 0 then Game.Notify('nothing in your session to save', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:prefab:save', args[1], snap, lsnap)
end, false)

-- --- stamp -----------------------------------------------------------------
-- Spawn the prefab's props at the aim point. Each prop's centre-relative offset
-- (dx,dy) is rotated by the stamp yaw, and yaw is added to its own rotation, so
-- the whole group rotates as one. Spawns as ONE undo group. Shared by the
-- /mapprefabstamp command and the NUI Stamp button.
local function stampPrefab(name, yaw)
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then Game.Notify('open the editor first (/mapedit)', 'error'); return end
    local def = name and prefabDefs[name]
    if not def or type(def.props) ~= 'table' then Game.Notify('no prefab "' .. tostring(name) .. '" (/mapprefablist)', 'error'); return end
    local ax, ay, az = Game.CameraAimPoint(60.0)
    if not ax then ax, ay, az = Game.PlayerPos() end
    yaw = tonumber(yaw) or 0.0
    local rad = math.rad(yaw)
    local cos, sin = math.cos(rad), math.sin(rad)
    local n = 0
    -- Load every model up front so the spawn loop below never yields — that keeps
    -- MapEd.batch's index range clean (one atomic /matundo) even for a big/fresh
    -- prefab, and the whole group appears at once rather than trickling in.
    local models = {}
    for _, p in ipairs(def.props) do models[#models + 1] = p.model end
    Game.PreloadModels(models)
    MapEd.batch(function()
        for _, p in ipairs(def.props) do
            local dx, dy = p.dx or 0.0, p.dy or 0.0
            local wx = ax + (dx * cos - dy * sin)
            local wy = ay + (dx * sin + dy * cos)
            local wz = az + (p.dz or 0.0)
            local rz = ((p.rz or 0.0) + yaw) % 360.0
            if MapEd.spawnAt(p.model, wx, wy, wz, p.rx or 0.0, p.ry or 0.0, rz, true) then n = n + 1 end
        end
    end)
    -- Lights aren't entities (not in the undo batch); re-add them at the same
    -- yaw-rotated offsets so a lit prefab keeps its lighting.
    local ln = 0
    for _, l in ipairs(def.lights or {}) do
        local dx, dy = l.dx or 0.0, l.dy or 0.0
        if MapEd.addLight then
            MapEd.addLight({
                x = ax + (dx * cos - dy * sin), y = ay + (dx * sin + dy * cos), z = az + (l.dz or 0.0),
                r = l.r, g = l.g, b = l.b, range = l.range, intensity = l.intensity, kind = l.kind,
            })
            ln = ln + 1
        end
    end
    Game.Notify(('stamped "%s" — %d props, %d lights (/matundo props). /mapcommit to publish'):format(name, n, ln), 'success')
end

RegisterCommand('mapprefabstamp', function(_, args) stampPrefab(args[1], args[2]) end, false)

-- NUI Stamp button routes here (nui.lua's stampPrefab callback fires this event).
AddEventHandler('palm6_mapeditor:stampPrefab', function(name) stampPrefab(name, 0.0) end)

-- Save the outliner's selected props as a new blueprint kit. The subset's
-- absolute coords go to the server, which centroid-relativises them; the server
-- then broadcasts prefab:def -> sendKits, so the kit appears in the NUI at once.
local function saveFromSelection(name, ids)
    local safe = type(name) == 'string' and name:gsub('%s+', '_'):gsub('[^%w_%-]', '') or ''
    if safe == '' then Game.Notify('name the kit (letters / numbers)', 'error'); return end
    local snap = (MapEd and MapEd.snapshotIds) and MapEd.snapshotIds(ids) or {}
    if #snap == 0 then Game.Notify('select props first', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:prefab:save', safe, snap, {})
    Game.Notify(('saving kit "%s" (%d props)...'):format(safe, #snap), 'inform')
end

-- Exposed for nui.lua: push the kit list, stamp a kit, save a selection as a kit.
Prefabs = { sendKits = sendKits, stamp = stampPrefab, saveFromSelection = saveFromSelection }

-- --- list / delete ---------------------------------------------------------
RegisterCommand('mapprefablist', function()
    local names = {}
    for nm, def in pairs(prefabDefs) do names[#names + 1] = ('%s (%dp %dl)'):format(nm, #(def.props or {}), #(def.lights or {})) end
    table.sort(names)
    if #names == 0 then Game.Notify('no prefabs yet — build props and /mapprefabsave <name>', 'inform'); return end
    Game.Notify('prefabs:\n' .. table.concat(names, '\n'), 'inform')
end, false)

RegisterCommand('mapprefabdel', function(_, args)
    if not args[1] then Game.Notify('usage: /mapprefabdel <name>', 'error'); return end
    TriggerServerEvent('palm6_mapeditor:prefab:delete', args[1])
end, false)
