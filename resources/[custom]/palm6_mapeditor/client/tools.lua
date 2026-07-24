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
    for i = 0, rows - 1 do
        for j = 0, cols - 1 do
            if not (i == 0 and j == 0) then   -- (0,0) is the existing selection
                MapEd.spawnAt(r.model, r.x + i * sp, r.y + j * sp, r.z, r.rx, r.ry, r.rz)
                n = n + 1
            end
        end
    end
    Game.Notify(('grid spawned %d (%dx%d @ %.1f)'):format(n, rows, cols, sp), 'success')
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
    Game.SetFreeze(r.obj, true)
    MapEd.setGizmo(false)
    if not ok then Game.Notify('object_gizmo not started', 'error') return end
    local x, y, z, rx, ry, rz = Game.GetObjectTransform(r.obj)
    r.x, r.y, r.z, r.rx, r.ry, r.rz = x, y, z, rx, ry, rz
    Game.Notify('gizmo applied')
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
