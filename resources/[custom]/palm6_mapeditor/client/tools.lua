-- ============================================================================
-- palm6_mapeditor/client/tools.lua  —  pro tools
--
-- World eraser (suppress vanilla map props), mass grid spawn, per-prop toggles.
-- Uses the MapEd API from client/main.lua. Natives via Game.* (bridge).
-- ============================================================================

local hides = {}   -- { {x,y,z,r,model}, ... } for restore/undo

-- --- world eraser ----------------------------------------------------------
RegisterCommand('materase', function()
    if not MapEd.isEditing() then return end
    local ent, model, x, y, z = Game.RaycastEntity(30.0)
    if ent == 0 or model == 0 then Game.Notify('aim at a world prop to erase', 'error') return end
    Game.HideModelAt(x, y, z, 1.0, model)
    hides[#hides + 1] = { x = x, y = y, z = z, r = 1.0, model = model }
    Game.Notify('erased world prop (/materaseundo to restore)', 'success')
end, false)

RegisterCommand('materaseundo', function()
    local h = table.remove(hides)
    if not h then Game.Notify('nothing to restore') return end
    Game.RestoreModelAt(h.x, h.y, h.z, h.r, h.model)
    Game.Notify('restored world prop')
end, false)

-- Model-hides are raw client world-state that outlive the resource — restore
-- them all on stop so a dev restart never leaves vanilla props permanently gone.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, h in ipairs(hides) do Game.RestoreModelAt(h.x, h.y, h.z, h.r, h.model) end
    hides = {}
end)

-- --- mass grid spawn -------------------------------------------------------
-- /matgrid <rows> <cols> <spacing> — grid of the selected object's model,
-- starting at the selection, using its rotation. One batch.
RegisterCommand('matgrid', function(_, args)
    local r = MapEd.selected()
    if not r then Game.Notify('select a prop first (/matpick)', 'error') return end
    local rows = math.max(1, math.min(20, tonumber(args[1]) or 3))
    local cols = math.max(1, math.min(20, tonumber(args[2]) or 3))
    local sp = tonumber(args[3]) or 2.0
    local n = 0
    MapEd.batch(function()
        for i = 0, rows - 1 do
            for j = 0, cols - 1 do
                if not (i == 0 and j == 0) then   -- (0,0) is the existing selection
                    MapEd.spawnAt(r.model, r.x + i * sp, r.y + j * sp, r.z, r.rx, r.ry, r.rz, true)
                    n = n + 1
                end
            end
        end
    end)
    Game.Notify(('grid spawned %d (%dx%d @ %.1f) — one /matundo'):format(n, rows, cols, sp), 'success')
end, false)

-- --- visual gizmo (object_gizmo) -------------------------------------------
-- /matgizmo — grab the selected object with translate/rotate/scale handles
-- (W/R/S, Q world/local, LAlt ground, Enter confirm). Syncs the record back.
RegisterCommand('matgizmo', function()
    local r = MapEd.selected()
    if not r then Game.Notify('select a prop first (/matpick)', 'error') return end
    MapEd.setGizmo(true)
    Game.SetFreeze(r.obj, false)      -- the gizmo moves via SetEntityMatrix
    local ok = Game.UseGizmo(r.obj)   -- blocks until Enter; editor loop stands down
    Game.SetFreeze(r.obj, r.frozen ~= false)   -- restore the prop's own freeze state
    MapEd.setGizmo(false)
    if not ok then Game.Notify('gizmo unavailable / errored', 'error') return end
    local x, y, z, rx, ry, rz = Game.GetObjectTransform(r.obj)
    r.x, r.y, r.z, r.rx, r.ry, r.rz = x, y, z, rx, ry, rz
    Game.Notify('gizmo applied')
end, false)

-- --- random scatter --------------------------------------------------------
-- /matscatter <count> <radius> — scatter N copies of the selected model in a
-- radius around it with random yaw. One undo group.
RegisterCommand('matscatter', function(_, args)
    local r = MapEd.selected()
    if not r then Game.Notify('select a prop first (/matpick)', 'error') return end
    local count = math.max(1, math.min(200, math.floor(tonumber(args[1]) or 10)))
    local rad = math.max(0.5, tonumber(args[2]) or 8.0)
    MapEd.batch(function()
        for _ = 1, count do
            local a, d = math.random() * math.pi * 2, math.sqrt(math.random()) * rad
            MapEd.spawnAt(r.model, r.x + math.cos(a) * d, r.y + math.sin(a) * d, r.z,
                r.rx, r.ry, math.random() * 360.0, true)
        end
    end)
    Game.Notify(('scattered %d in %.1fm — one /matundo'):format(count, rad), 'success')
end, false)

-- --- per-prop utilities -----------------------------------------------------
RegisterCommand('matcopy', function()
    local r = MapEd.selected(); if not r then return end
    Game.SetClipboard(('vector4(%.3f, %.3f, %.3f, %.1f)'):format(r.x, r.y, r.z, r.rz))
    Game.Notify('coords copied to clipboard', 'success')
end, false)
RegisterCommand('mattp', function()
    local r = MapEd.selected(); if not r then return end
    Game.TeleportPlayer(r.x, r.y, r.z)
end, false)

-- --- area delete -----------------------------------------------------------
-- /matareadel <radius> — delete every placed prop within <radius> of where you
-- aim. Targets our own placements (not vanilla world props — use /materase for
-- those). One notify with the count.
RegisterCommand('matareadel', function(_, args)
    if not MapEd.isEditing() then return end
    local rad = math.max(0.5, tonumber(args[1]) or 5.0)
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then Game.Notify('aim somewhere', 'error') return end
    local n = MapEd.deleteInRadius(x, y, z, rad)
    Game.Notify(('deleted %d props within %.1fm'):format(n, rad), n > 0 and 'success' or 'inform')
end, false)

-- --- per-prop toggles ------------------------------------------------------
RegisterCommand('matfreeze', function()
    local r = MapEd.selected(); if not r then return end
    r.frozen = not (r.frozen ~= false)   -- default true -> toggle
    Game.SetFreeze(r.obj, r.frozen)
    Game.Notify('freeze: ' .. tostring(r.frozen))
end, false)

RegisterCommand('matcollision', function()
    local r = MapEd.selected(); if not r then return end
    r.collision = not (r.collision ~= false)
    Game.SetCollision(r.obj, r.collision)
    Game.Notify('collision: ' .. tostring(r.collision))
end, false)
