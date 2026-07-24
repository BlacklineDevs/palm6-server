-- ============================================================================
-- palm6_mapeditor/client/main.lua  —  in-game map/prop editor (Phase 1 core)
--
-- Spawn props, carry them to where you aim, nudge/rotate with keys, snap to
-- surfaces, select/undo, then export every placement to Lua + JSON (ymap export
-- comes from the headless pipeline in a later phase). Reuses the proven
-- placement patterns from palm6_pd_life. Admin dev tool.
--
-- COMMANDS
--   /mapedit                 toggle the editor (you are planted; camera free)
--   /prop <model>            spawn a model at your aim point and select it
--   /matnext | /matprev      cycle the quick-prop catalog (spawns + selects)
--   /matpick                 select the object nearest your aim
--   /matrot <rx> <ry> <rz>   set exact rotation on the selected object
--   /matdel                  delete the selected object
--   /mapclear                delete everything placed
--   /mapexport               copy all placements (Lua + JSON) + save to file
-- LIVE (with something selected):
--   Hold Left-Click  carry to aim     Arrows  move    Shift+Up/Down  height
--   Q / E  rotate (yaw)               Space   snap to surface        Esc  exit
-- ============================================================================

local editing = false
local placed = {}            -- { { obj, model, x, y, z, rx, ry, rz }, ... }
local sel = nil              -- index into placed of the selected object
local catNames, catIdx, propIdx = {}, 1, 0

for name in pairs(Config.QuickProps) do catNames[#catNames + 1] = name end
table.sort(catNames)

local function curCat() return catNames[((catIdx - 1) % #catNames) + 1] end
local function selRec() return sel and placed[sel] or nil end

local function selectLast() sel = #placed > 0 and #placed or nil end

local function spawnProp(model, x, y, z)
    local obj = Game.SpawnObject(model, x, y, z)
    if not obj then Game.Notify('bad model: ' .. tostring(model), 'error') return end
    placed[#placed + 1] = { obj = obj, model = model, x = x, y = y, z = z, rx = 0.0, ry = 0.0, rz = 0.0 }
    selectLast()
    if sel then
        -- deselect visual on others, highlight the new one
        for i, r in ipairs(placed) do Game.SetObjectAlpha(r.obj, i == sel and 200 or nil) end
    end
end

local function spawnAtAim(model)
    local x, y, z = Game.CameraAimPoint(30.0)
    if not x then x, y, z = Game.PlayerPos() end
    spawnProp(model, x, y, z)
end

local function applyTransform(r)
    Game.SetObjectTransform(r.obj, r.x, r.y, r.z, r.rx, r.ry, r.rz)
end

local function deleteSelected()
    local r = selRec()
    if not r then return end
    Game.DeleteObject(r.obj)
    table.remove(placed, sel)
    selectLast()
    if sel then Game.SetObjectAlpha(placed[sel].obj, 200) end
end

local function clearAll()
    for _, r in ipairs(placed) do Game.DeleteObject(r.obj) end
    placed = {}; sel = nil
end

-- ---- export ---------------------------------------------------------------
local function buildLua()
    local out = { 'local objects = {' }
    for _, r in ipairs(placed) do
        out[#out + 1] = ("    { model = `%s`, coords = vector3(%.3f, %.3f, %.3f), rot = vector3(%.2f, %.2f, %.2f) },")
            :format(r.model, r.x, r.y, r.z, r.rx, r.ry, r.rz)
    end
    out[#out + 1] = '}'
    return table.concat(out, '\n')
end

local function buildJson()
    local items = {}
    for _, r in ipairs(placed) do
        items[#items + 1] = { model = r.model, x = r.x, y = r.y, z = r.z, rx = r.rx, ry = r.ry, rz = r.rz }
    end
    return json.encode(items)
end

RegisterCommand('mapexport', function()
    if #placed == 0 then Game.Notify('nothing placed', 'error') return end
    local lua, js = buildLua(), buildJson()
    Game.SetClipboard(lua)
    TriggerServerEvent('palm6_mapeditor:save', lua, js)
    Game.Notify(('exported %d objects (Lua on clipboard, saved to file)'):format(#placed), 'success')
    Game.Chat('[mapeditor]', ('exported %d objects'):format(#placed))
end, false)

-- ---- commands -------------------------------------------------------------
RegisterCommand(Config.Command, function()
    editing = not editing
    Game.Notify(editing and 'editor ON — /prop <model> or /matnext to spawn' or 'editor OFF', 'inform')
end, false)

RegisterCommand('prop', function(_, args) if editing and args[1] then spawnAtAim(args[1]) end end, false)
RegisterCommand('matnext', function()
    if not editing then return end
    local list = Config.QuickProps[curCat()]
    propIdx = propIdx % #list + 1
    spawnAtAim(list[propIdx])
end, false)
RegisterCommand('matprev', function()
    if not editing then return end
    local list = Config.QuickProps[curCat()]
    propIdx = (propIdx - 2) % #list + 1
    spawnAtAim(list[propIdx])
end, false)
RegisterCommand('matcat', function() catIdx = catIdx % #catNames + 1; propIdx = 0; Game.Notify('category: ' .. curCat()) end, false)
RegisterCommand('matdel', function() if editing then deleteSelected() end end, false)
RegisterCommand('mapclear', function() if editing then clearAll() Game.Notify('cleared') end end, false)
RegisterCommand('matrot', function(_, args)
    local r = selRec()
    if not r then return end
    r.rx = tonumber(args[1]) or r.rx; r.ry = tonumber(args[2]) or r.ry; r.rz = tonumber(args[3]) or r.rz
    applyTransform(r)
end, false)
RegisterCommand('matpick', function()
    if not editing then return end
    local x, y, z = Game.CameraAimPoint(30.0)
    if not x then return end
    local best, bestD
    for i, r in ipairs(placed) do
        local d = (r.x - x) ^ 2 + (r.y - y) ^ 2 + (r.z - z) ^ 2
        if not bestD or d < bestD then bestD, best = d, i end
    end
    if best then
        for i, r in ipairs(placed) do Game.SetObjectAlpha(r.obj, i == best and 200 or nil) end
        sel = best
        Game.Notify('selected ' .. placed[best].model)
    end
end, false)

-- ---- HUD ------------------------------------------------------------------
local function txt(s, x, y, sc, r, g, b)
    SetTextFont(4); SetTextScale(sc, sc); SetTextColour(r or 235, g or 235, b or 235, 235); SetTextOutline()
    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(s); EndTextCommandDisplayText(x, y)
end

local function drawHud()
    DrawRect(0.14, 0.26, 0.26, 0.24, 0, 0, 0, 150)
    txt('~b~MAP EDITOR', 0.02, 0.16, 0.5)
    local r = selRec()
    txt(r and ('sel: ' .. r.model) or 'sel: (none)', 0.02, 0.20, 0.34)
    if r then txt(('pos %.2f %.2f %.2f  yaw %.0f'):format(r.x, r.y, r.z, r.rz), 0.02, 0.225, 0.32, 180, 220, 255) end
    txt(('cat: %s   placed: %d'):format(curCat(), #placed), 0.02, 0.25, 0.32)
    txt('~s~LMB carry  Arrows move  Shift+Up/Dn Z  Q/E rot  Space snap', 0.02, 0.285, 0.30, 180, 220, 255)
    txt('~s~/prop <m>  /matnext  /matcat  /matpick  /matdel  /mapexport', 0.02, 0.31, 0.30, 180, 220, 255)
end

-- ---- live edit loop -------------------------------------------------------
CreateThread(function()
    while true do
        if editing then
            drawHud()
            DisableControlAction(0, 21, true)  -- sprint (Shift modifier)
            DisableControlAction(0, 22, true)  -- jump (Space snap)
            DisableControlAction(0, 24, true)  -- attack (LMB carry)
            DisableControlAction(0, 25, true)  -- aim
            for _, c in ipairs({ 30, 31, 32, 33, 34, 35, 44, 38 }) do DisableControlAction(0, c, true) end

            local r = selRec()
            if r then
                local shift = IsDisabledControlPressed(0, 21)
                local step = shift and Config.Step.moveFine or Config.Step.move
                local moved = false
                local rad = math.rad(GetGameplayCamRot(2).z)
                local fx, fy = -math.sin(rad), math.cos(rad)      -- camera-forward on ground
                if IsDisabledControlPressed(0, 24) then           -- LMB carry to aim
                    local ax, ay, az = Game.CameraAimPoint(30.0)
                    if ax then r.x, r.y, r.z = ax, ay, az; moved = true end
                end
                if IsControlPressed(0, 172) then if shift then r.z = r.z + step else r.x = r.x + fx * step; r.y = r.y + fy * step end moved = true end
                if IsControlPressed(0, 173) then if shift then r.z = r.z - step else r.x = r.x - fx * step; r.y = r.y - fy * step end moved = true end
                if IsControlPressed(0, 174) then r.x = r.x - fy * step; r.y = r.y + fx * step; moved = true end
                if IsControlPressed(0, 175) then r.x = r.x + fy * step; r.y = r.y - fx * step; moved = true end
                if IsDisabledControlPressed(0, 44) then r.rz = (r.rz - (shift and Config.Step.rotFine or Config.Step.rot)) % 360.0; moved = true end
                if IsDisabledControlPressed(0, 38) then r.rz = (r.rz + (shift and Config.Step.rotFine or Config.Step.rot)) % 360.0; moved = true end
                if IsDisabledControlJustPressed(0, 22) then
                    local sz = Game.SurfaceZBelow(r.x, r.y, r.z)
                    if sz then r.z = sz; moved = true end
                end
                if moved then applyTransform(r) end
            end
            if IsControlJustPressed(0, 202) then editing = false; Game.Notify('editor OFF') end   -- Esc
            Wait(0)
        else
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then clearAll() end end)
