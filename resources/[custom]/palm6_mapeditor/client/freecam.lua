-- ============================================================================
-- palm6_mapeditor/client/freecam.lua  —  optional editor freecam
--
-- /mapcam (default key B) detaches a smooth scripted camera you can fly with
-- WASD + mouse look, with mouse-wheel FOV zoom. It is OPT-IN and fully isolated:
-- the editor's aim raycasts read the freecam only via the EditorCam global
-- (bridge/cl_game.lua camView), so with the freecam OFF the placement path is the
-- audited gameplay-cam behaviour, byte-for-byte. Turning it on can never regress
-- normal editing; worst case you toggle it back off.
--
-- CONTROLS (while active): WASD fly (toward look dir) · mouse look · Shift fast ·
--   Alt slow · mouse wheel zoom (FOV) · Backspace / B exit.
-- ============================================================================

EditorCam = { active = false, pos = nil, rot = nil }

local cam = nil
local px, py, pz = 0.0, 0.0, 0.0
local pitch, yaw, fov = 0.0, 0.0, 50.0
local SENS = 6.0            -- mouse-look sensitivity
local BASE_SPEED = 0.35     -- metres/frame at 60fps before fast/slow mods
local FOV_MIN, FOV_MAX = 12.0, 80.0

local function start()
    -- Silent outside the editor: the default keybind is B, so it must never act or
    -- notify unless the editor is open (same rule as /maphelp, /maplog).
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then return end
    if EditorCam.active then return end
    local x, y, z, pit, ya, fv = Game.GameplayCamState()
    px, py, pz = x, y, z
    pitch, yaw, fov = pit, ya, fv
    cam = Game.CamCreate(px, py, pz, pitch, yaw, fov)
    EditorCam.pos = { x = px, y = py, z = pz }
    EditorCam.rot = { x = pitch, y = 0.0, z = yaw }
    EditorCam.active = true
    Game.Notify('freecam ON — WASD fly, mouse look, wheel zoom, Backspace exit', 'inform')
end

local function stop()
    if not EditorCam.active then return end
    EditorCam.active = false
    Game.CamDestroy(cam); cam = nil
    Game.Notify('freecam OFF', 'inform')
end

RegisterCommand('mapcam', function()
    -- Silent no-op outside the editor: B is a bare keybind, so it must never act
    -- or notify unless the map editor is actually open (same shape as the
    -- /maphelp and /maplog guards in nui.lua).
    if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then return end
    if EditorCam.active then stop() else start() end
end, false)
RegisterKeyMapping('mapcam', 'Map editor: freecam', 'keyboard', 'B')

CreateThread(function()
    while true do
        if EditorCam.active then
            -- Editor toggled off underneath the freecam: tear it down.
            if not (MapEd and MapEd.isEditing and MapEd.isEditing()) then
                stop()
            else
                local ft = GetFrameTime()
                local scale = ft * 60.0            -- frame-rate independent

                -- own the inputs we read, so nothing else reacts to them
                DisableControlAction(0, 1, true)   -- look LR
                DisableControlAction(0, 2, true)   -- look UD
                DisableControlAction(0, 24, true)  -- attack (no weapon fire)
                DisableControlAction(0, 25, true)  -- aim
                for _, c in ipairs({ 21, 19, 30, 31, 32, 33, 34, 35, 14, 15 }) do DisableControlAction(0, c, true) end

                -- mouse look
                local lx = GetDisabledControlNormal(0, 1)
                local ly = GetDisabledControlNormal(0, 2)
                yaw = (yaw - lx * SENS * scale * 8.0) % 360.0
                pitch = math.max(-89.0, math.min(89.0, pitch - ly * SENS * scale * 8.0))

                -- WASD fly (forward includes pitch, so look-up + W climbs)
                local fwd = GetDisabledControlNormal(0, 32) - GetDisabledControlNormal(0, 33)  -- W - S
                local side = GetDisabledControlNormal(0, 35) - GetDisabledControlNormal(0, 34) -- D - A
                local fast = IsDisabledControlPressed(0, 21)   -- LShift
                local slow = IsDisabledControlPressed(0, 19)   -- LAlt
                local spd = BASE_SPEED * scale * (fast and 3.0 or 1.0) * (slow and 0.3 or 1.0)
                local ry, rx = math.rad(yaw), math.rad(pitch)
                local cpx = math.cos(rx)
                local fvx, fvy, fvz = -math.sin(ry) * cpx, math.cos(ry) * cpx, math.sin(rx)
                local svx, svy = math.cos(ry), math.sin(ry)
                px = px + (fvx * fwd + svx * side) * spd
                py = py + (fvy * fwd + svy * side) * spd
                pz = pz + (fvz * fwd) * spd

                -- mouse-wheel FOV zoom (wheel up = zoom in). 15/14 = weapon-wheel
                -- prev/next (the on-foot scroll); 241/242 = cursor scroll fallback.
                if IsControlJustPressed(0, 15) or IsDisabledControlJustPressed(0, 241) then
                    fov = math.max(FOV_MIN, fov - 4.0)
                elseif IsControlJustPressed(0, 14) or IsDisabledControlJustPressed(0, 242) then
                    fov = math.min(FOV_MAX, fov + 4.0)
                end

                Game.CamApply(cam, px, py, pz, pitch, yaw, fov)
                EditorCam.pos.x, EditorCam.pos.y, EditorCam.pos.z = px, py, pz
                EditorCam.rot.x, EditorCam.rot.z = pitch, yaw

                Game.DrawRect2D(0.5, 0.94, 0.235, 0.045, 0, 0, 0, 160)
                Game.DrawText2D(('~w~FREECAM   FOV ~b~%d~w~    [Backspace] exit'):format(math.floor(fov + 0.5)),
                    0.5, 0.922, 0.36, 235, 235, 235, true)

                if IsRawKeyPressed(0x08) then stop() end   -- Backspace, hardware-level

                Wait(0)
            end
        else
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and EditorCam.active then Game.CamDestroy(cam) end
end)
