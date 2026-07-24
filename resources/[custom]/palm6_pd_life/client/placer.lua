-- ============================================================================
-- palm6_pd_life/client/placer.lua  —  /placeped IN-GAME PLACEMENT EDITOR (v2)
--
-- The reusable NPC-placement pipeline: populate any interior in minutes instead
-- of hours of coordinate guessing. Point the camera to place, snap to the seat,
-- fine-nudge, then place the WHOLE room and export every config line at once.
-- The preview spawns through the SAME production path (WYSIWYG, warp-seated), so
-- what you place is exactly what ships.
--
-- This is an admin DEV tool: the live input/HUD uses natives directly (never
-- ships to GTA VI). Ped spawn/move/raycast/clipboard go through Game.* (bridge).
--
-- COMMANDS
--   /placeped [scenario]   start the editor (preview where you aim / at your feet)
--   /pedroom <name>        tag the room the next placements belong to
--   /pedscen <name>        set the scenario explicitly
--   /pednext | /pedprev    cycle the scenario (preview the pose live)
--   /pedmodel              cycle the ped model in the current role pool
--   /pedrole cop|civ       swap the model pool
--   /pedexport [post]      copy EVERY placed line to clipboard (+ print)
--   /pedundo               remove the last placed ped
--   /pedclear              remove all placed peds + preview
--   /pedstop               close the editor (placed peds stay for export)
-- LIVE (while the editor is open — you are planted, camera free):
--   Hold Left-Click  carry: preview follows where you look
--   Arrows           fine move on the ground     Shift+Up/Down  height
--   Q / E or Scroll  rotate                       Space          snap onto surface
--   Enter            place it + start the next    Esc            close editor
-- ============================================================================

local editing = false
local preview = nil          -- { ped, x, y, z, h, scen, seated, modelIdx }
local placed = {}            -- { { ped, line }, ... } committed this session
local role = 'cop'
local scenIdx = 1
local modelIdx = 1
local roomTag = nil
local wasMoving = false

local SCENARIOS = {
    'PROP_HUMAN_SEAT_CHAIR', 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', 'PROP_HUMAN_SEAT_COMPUTER',
    'PROP_HUMAN_SEAT_BENCH', 'WORLD_HUMAN_CLIPBOARD', 'WORLD_HUMAN_STAND_MOBILE',
    'WORLD_HUMAN_COP_IDLES', 'WORLD_HUMAN_GUARD_STAND', 'WORLD_HUMAN_STAND_IMPATIENT',
    'WORLD_HUMAN_AA_COFFEE', 'WORLD_HUMAN_DRINKING', 'WORLD_HUMAN_HANG_OUT_STREET',
}

local function isSeated(s) return s and s:find('SEAT') ~= nil end
local function pool() return Config.Peds[role] or Config.Peds.civ end
local function curModel() local p = pool(); return p[((modelIdx - 1) % #p) + 1] end

-- ---- preview lifecycle ----------------------------------------------------
local function spawnPreview()
    if not preview then return end
    if preview.ped then Game.DeletePed(preview.ped) end
    preview.seated = isSeated(preview.scen)
    preview.ped = Game.SpawnScenarioPed(curModel(), preview.x, preview.y, preview.z,
        preview.h, preview.scen, preview.seated)
    if preview.ped then Game.SetPreviewAlpha(preview.ped, 190) end
end

local function configLine(post)
    local rf = roomTag and (", room='" .. roomTag .. "'") or ''
    local pf = post and (", post='" .. post .. "'") or ''
    local kf = isSeated(preview.scen) and 'seat' or 'desk'
    return ("    { scen='%s', ped='%s'%s, kind='%s'%s, coords=vector4(%.2f, %.2f, %.2f, %.1f) },")
        :format(preview.scen, role, rf, kf, pf, preview.x, preview.y, preview.z, preview.h)
end

local function startEditor(scen)
    if preview and preview.ped then Game.DeletePed(preview.ped) end   -- replace, don't orphan
    editing = true
    local x, y, z, h = Game.PlayerPoseVec()
    local ax, ay, az = Game.CameraAimPoint(25.0)   -- prefer where you're looking
    if ax then x, y, z = ax, ay, az end
    preview = { x = x, y = y, z = z, h = h, scen = scen or 'WORLD_HUMAN_CLIPBOARD' }
    if isSeated(preview.scen) then preview.z = preview.z + 0.45 end
    for i, s in ipairs(SCENARIOS) do if s == preview.scen then scenIdx = i break end end
    spawnPreview()
end

-- commit the preview into the room, keep it visible, start a fresh one
local function commit()
    if not preview or not preview.ped then return end
    local line = configLine()
    SetEntityAlpha(preview.ped, 255, false)                 -- solidify
    placed[#placed + 1] = { ped = preview.ped, line = line }
    Game.Chat('[placeped]', ('placed #%d — %s'):format(#placed, line:gsub('^%s+', '')))
    -- next preview at the same spot so you can place a neighbour fast
    preview = { x = preview.x, y = preview.y, z = preview.z, h = preview.h, scen = preview.scen }
    spawnPreview()
end

local function closeEditor()
    if preview and preview.ped then Game.DeletePed(preview.ped) end
    preview = nil
    editing = false
end

local function clearAll()
    closeEditor()
    for _, p in ipairs(placed) do Game.DeletePed(p.ped) end
    placed = {}
end

-- ---- commands -------------------------------------------------------------
RegisterCommand('placeped', function(_, args) startEditor(args[1]) end, false)
RegisterCommand('pedroom', function(_, args) roomTag = args[1]; Game.Chat('[placeped]', 'room = ' .. tostring(roomTag)) end, false)
RegisterCommand('pedscen', function(_, args) if preview and args[1] then preview.scen = args[1]; spawnPreview() end end, false)
RegisterCommand('pednext', function() if preview then scenIdx = scenIdx % #SCENARIOS + 1; preview.scen = SCENARIOS[scenIdx]; spawnPreview() end end, false)
RegisterCommand('pedprev', function() if preview then scenIdx = (scenIdx - 2) % #SCENARIOS + 1; preview.scen = SCENARIOS[scenIdx]; spawnPreview() end end, false)
RegisterCommand('pedmodel', function() if preview then modelIdx = modelIdx + 1; spawnPreview() end end, false)
RegisterCommand('pedrole', function(_, args) role = (args[1] == 'civ') and 'civ' or 'cop'; modelIdx = 1; if preview then spawnPreview() end end, false)
RegisterCommand('pedundo', function()
    if #placed == 0 then return end
    local last = table.remove(placed)
    Game.DeletePed(last.ped)
    Game.Chat('[placeped]', 'removed last (' .. #placed .. ' left)')
end, false)
RegisterCommand('pedclear', function() clearAll(); Game.Chat('[placeped]', 'cleared all') end, false)
RegisterCommand('pedstop', function() closeEditor(); Game.Chat('[placeped]', ('editor closed — %d placed, /pedexport to copy'):format(#placed)) end, false)
RegisterCommand('pedexport', function(_, args)
    if #placed == 0 then Game.Chat('[placeped]', 'nothing placed yet') return end
    local lines = {}
    for _, p in ipairs(placed) do lines[#lines + 1] = p.line end
    local blob = table.concat(lines, '\n')
    Game.SetClipboard(blob)
    for _, l in ipairs(lines) do Game.Chat('[placeped]', l:gsub('^%s+', '')) end
    Game.Chat('[placeped]', ('^2%d lines copied to clipboard^7'):format(#lines))
end, false)

-- ---- on-screen HUD --------------------------------------------------------
local function txt(s, x, y, scale, r, g, b)
    SetTextFont(4); SetTextScale(scale, scale); SetTextColour(r or 235, g or 235, b or 235, 235)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

local function drawPanel()
    DrawRect(0.135, 0.30, 0.25, 0.30, 0, 0, 0, 150)
    txt('~b~PLACE PED', 0.02, 0.17, 0.5)
    txt('model:  ' .. curModel(), 0.02, 0.215, 0.34)
    txt('scenario: ' .. preview.scen, 0.02, 0.245, 0.34)
    txt(('room: %s   z=%.2f   placed:%d'):format(tostring(roomTag), preview.z, #placed), 0.02, 0.275, 0.34)
    txt('~s~LMB carry  Arrows move  Shift+Up/Dn height', 0.02, 0.315, 0.30, 180, 220, 255)
    txt('~s~Q/E rotate  Space snap  Enter place  Esc close', 0.02, 0.34, 0.30, 180, 220, 255)
    txt('~s~/pednext scen  /pedmodel  /pedroom  /pedexport', 0.02, 0.365, 0.30, 180, 220, 255)
    -- floating tag on the ped
    SetDrawOrigin(preview.x, preview.y, preview.z + 1.15, 0)
    txt(preview.seated and '[seated]' or '[standing]', 0.0, 0.0, 0.3, 120, 220, 255)
    ClearDrawOrigin()
end

-- ---- live edit loop -------------------------------------------------------
CreateThread(function()
    while true do
        if editing and preview then
            drawPanel()
            -- plant the player + suppress fire so only the preview moves
            DisableControlAction(0, 21, true)  -- sprint  (Shift = height modifier)
            DisableControlAction(0, 22, true)  -- jump    (Space = snap)
            DisableControlAction(0, 24, true)  -- attack  (LMB = carry)
            DisableControlAction(0, 25, true)  -- aim
            for _, c in ipairs({ 30, 31, 32, 33, 34, 35, 140, 141, 142, 257, 14, 15, 16, 17 }) do DisableControlAction(0, c, true) end

            local step = 0.03
            local up = IsDisabledControlPressed(0, 21)      -- Shift = height mode
            local moved = false
            local rad = math.rad(preview.h)
            local fx, fy = -math.sin(rad), math.cos(rad)

            -- carry: preview follows the camera aim point while LMB held
            if IsDisabledControlPressed(0, 24) then
                local ax, ay, az = Game.CameraAimPoint(25.0)
                if ax then
                    preview.x, preview.y = ax, ay
                    preview.z = isSeated(preview.scen) and (az + 0.45) or az
                    moved = true
                end
            end
            if IsControlPressed(0, 172) then
                if up then preview.z = preview.z + step else preview.x = preview.x + fx * step; preview.y = preview.y + fy * step end
                moved = true
            end
            if IsControlPressed(0, 173) then
                if up then preview.z = preview.z - step else preview.x = preview.x - fx * step; preview.y = preview.y - fy * step end
                moved = true
            end
            if IsControlPressed(0, 174) then preview.x = preview.x - fy * step; preview.y = preview.y + fx * step; moved = true end
            if IsControlPressed(0, 175) then preview.x = preview.x + fy * step; preview.y = preview.y - fx * step; moved = true end
            if IsControlPressed(0, 44) then preview.h = (preview.h - 1.5) % 360.0; moved = true end
            if IsControlPressed(0, 38) then preview.h = (preview.h + 1.5) % 360.0; moved = true end
            if IsDisabledControlPressed(0, 15) then preview.h = (preview.h - 3.0) % 360.0; moved = true end  -- scroll up
            if IsDisabledControlPressed(0, 14) then preview.h = (preview.h + 3.0) % 360.0; moved = true end  -- scroll down

            -- Space = snap onto the surface below (floor or a chair/desk top)
            if IsDisabledControlJustPressed(0, 22) then
                local sz = Game.SurfaceZBelow(preview.x, preview.y, preview.z)
                if sz then preview.z = sz + (isSeated(preview.scen) and 0.40 or 0.0); moved = true end
            end

            if moved then
                Game.MovePed(preview.ped, preview.x, preview.y, preview.z, preview.h)
                wasMoving = true
            elseif wasMoving then
                Game.RepositionPed(preview.ped, preview.x, preview.y, preview.z, preview.h, preview.scen, preview.seated)
                wasMoving = false
            end

            if IsControlJustPressed(0, 201) then commit() end      -- Enter = place + next
            if IsControlJustPressed(0, 202) then                   -- Esc = close editor
                closeEditor()
                Game.Chat('[placeped]', ('editor closed — %d placed, /pedexport to copy'):format(#placed))
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)
