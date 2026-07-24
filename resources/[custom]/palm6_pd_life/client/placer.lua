-- ============================================================================
-- palm6_pd_life/client/placer.lua  —  /placeped IN-GAME PLACEMENT TOOL
--
-- The reusable NPC-placement pipeline: populate any interior in minutes of
-- walk-and-click instead of hours of coordinate guessing. "You are the gizmo" —
-- stand where the NPC goes and face where it should look, spawn a preview, nudge
-- it live, cycle scenarios to preview the pose, then export a ready-to-paste
-- config line. WYSIWYG: the preview spawns through the SAME path as production
-- (warp-seated), so what you place is exactly what ships.
--
-- This is an admin DEV tool. The live input/HUD uses natives directly (it never
-- ships to GTA VI, so it's exempt from the bridge pattern); ped spawn/reposition/
-- clipboard still go through Game.* so the pose logic stays in one place.
--
-- COMMANDS
--   /placeped [scenario]   spawn a preview at your feet+facing (default clipboard)
--   /pedscen <name>        set the scenario explicitly
--   /pedrole cop|civ       swap the model pool
--   /pedsave [room] [post] export the config line (clipboard + chat), keep placing
--   /pednext | /pedprev    cycle the scenario (preview the pose live)
--   /pedcancel             remove the preview
-- WHILE A PREVIEW IS UP (you are planted so only the ped moves):
--   Arrow keys     move on the ground   Shift+Up/Down  raise / lower height
--   Q / E          rotate               Enter          quick-save to clipboard
--   /pednext/prev  cycle scenario       Esc/Backspace  cancel
-- ============================================================================

local preview = nil          -- { ped, x, y, z, h, scen, seated }
local role = 'cop'
local scenIdx = 1

-- Curated scenarios you actually want in a station, cyclable with PageUp/Down.
local SCENARIOS = {
    'PROP_HUMAN_SEAT_CHAIR', 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', 'PROP_HUMAN_SEAT_COMPUTER',
    'PROP_HUMAN_SEAT_BENCH', 'WORLD_HUMAN_CLIPBOARD', 'WORLD_HUMAN_STAND_MOBILE',
    'WORLD_HUMAN_COP_IDLES', 'WORLD_HUMAN_GUARD_STAND', 'WORLD_HUMAN_STAND_IMPATIENT',
    'WORLD_HUMAN_AA_COFFEE', 'WORLD_HUMAN_DRINKING', 'WORLD_HUMAN_HANG_OUT_STREET',
}

local function isSeated(s) return s and s:find('SEAT') ~= nil end
local function poolFor(r) return Config.Peds[r] or Config.Peds.civ end
local function pick(t) return t[math.random(#t)] end

local function despawn()
    if preview and preview.ped then Game.DeletePed(preview.ped) end
    preview = nil
end

-- (Re)spawn the preview ped at the current preview transform + scenario.
local function render()
    if not preview then return end
    if preview.ped then Game.DeletePed(preview.ped) end
    preview.seated = isSeated(preview.scen)
    preview.ped = Game.SpawnScenarioPed(pick(poolFor(role)),
        preview.x, preview.y, preview.z, preview.h, preview.scen, preview.seated)
    if preview.ped then Game.SetPreviewAlpha(preview.ped, 200) end
end

-- Move/rotate the live ped without a full respawn (smooth nudge).
local function reposition()
    if preview and preview.ped then
        Game.RepositionPed(preview.ped, preview.x, preview.y, preview.z, preview.h,
            preview.scen, preview.seated)
    end
end

local function configLine(room, post)
    local pf = post and (", post='" .. post .. "'") or ''
    local rf = room and (", room='" .. room .. "'") or ''
    local kf = preview.seated and 'seat' or 'desk'
    return ("{ scen='%s', ped='%s'%s, kind='%s'%s, coords=vector4(%.2f, %.2f, %.2f, %.1f) },")
        :format(preview.scen, role, rf, kf, pf, preview.x, preview.y, preview.z, preview.h)
end

-- ---- commands -------------------------------------------------------------
RegisterCommand('placeped', function(_, args)
    local scen = args[1] or 'WORLD_HUMAN_CLIPBOARD'
    local x, y, z, h = Game.PlayerPoseVec()
    preview = { x = x, y = y, z = z, h = h, scen = scen, seated = isSeated(scen) }
    -- seated: bump to a sensible starting seat height; you nudge from there.
    if preview.seated then preview.z = preview.z + 0.45 end
    for i, s in ipairs(SCENARIOS) do if s == scen then scenIdx = i break end end
    render()
    Game.Chat('[placeped]', 'preview up (you are planted) — Arrows move, Shift+Up/Down = height, Q/E rotate, Enter save, Esc cancel, /pednext scenario')
end, false)

RegisterCommand('pedscen', function(_, args)
    if not preview or not args[1] then return end
    preview.scen = args[1]
    render()
end, false)

RegisterCommand('pedrole', function(_, args)
    role = (args[1] == 'civ') and 'civ' or 'cop'
    if preview then render() end
    Game.Chat('[placeped]', 'role = ' .. role)
end, false)

RegisterCommand('pedsave', function(_, args)
    if not preview then Game.Chat('[placeped]', 'nothing to save') return end
    local line = configLine(args[1], args[2])
    Game.SetClipboard(line)
    Game.Chat('[placeped]', 'copied: ' .. line)
end, false)

RegisterCommand('pedcancel', function()
    despawn()
    Game.Chat('[placeped]', 'cancelled')
end, false)

RegisterCommand('pednext', function()
    if not preview then return end
    scenIdx = scenIdx % #SCENARIOS + 1
    preview.scen = SCENARIOS[scenIdx]; render()
    Game.Chat('[placeped]', 'scenario: ' .. preview.scen)
end, false)

RegisterCommand('pedprev', function()
    if not preview then return end
    scenIdx = (scenIdx - 2) % #SCENARIOS + 1
    preview.scen = SCENARIOS[scenIdx]; render()
    Game.Chat('[placeped]', 'scenario: ' .. preview.scen)
end, false)

-- ---- live edit loop (natives: pure input + HUD, dev-tool only) -------------
local function drawHud()
    local p = preview
    local txt = ('%s  z=%.2f  h=%.0f  %s'):format(p.scen, p.z, p.h, p.seated and '[seated]' or '[standing]')
    SetDrawOrigin(p.x, p.y, p.z + 1.15, 0)
    SetTextScale(0.34, 0.34)
    SetTextFont(4); SetTextCentre(true); SetTextColour(120, 220, 255, 220)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(txt)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

CreateThread(function()
    while true do
        if preview then
            drawHud()
            -- Plant the player so ONLY the preview moves (and Shift never sprints
            -- you away — that was the "it stops moving / I lose it" bug).
            DisableControlAction(0, 21, true)   -- sprint (frees Shift as a modifier)
            DisableControlAction(0, 22, true)   -- jump
            DisableControlAction(0, 30, true); DisableControlAction(0, 31, true)  -- move analog
            DisableControlAction(0, 32, true); DisableControlAction(0, 33, true)  -- move up/down
            DisableControlAction(0, 34, true); DisableControlAction(0, 35, true)  -- move left/right

            local step = 0.03
            local up = IsControlPressed(0, 21)   -- Shift held = height mode
            local moved = false
            -- forward vector from current heading (GTA: heading 0 = +Y, CCW)
            local rad = math.rad(preview.h)
            local fx, fy = -math.sin(rad), math.cos(rad)
            if IsControlPressed(0, 172) then           -- Up arrow: raise (Shift) or forward
                if up then preview.z = preview.z + step
                else preview.x = preview.x + fx * step; preview.y = preview.y + fy * step end
                moved = true
            end
            if IsControlPressed(0, 173) then           -- Down arrow: lower (Shift) or back
                if up then preview.z = preview.z - step
                else preview.x = preview.x - fx * step; preview.y = preview.y - fy * step end
                moved = true
            end
            if IsControlPressed(0, 174) then preview.x = preview.x - fy * step; preview.y = preview.y + fx * step; moved = true end -- Left strafe
            if IsControlPressed(0, 175) then preview.x = preview.x + fy * step; preview.y = preview.y - fx * step; moved = true end -- Right strafe
            if IsControlPressed(0, 44) then preview.h = (preview.h - 1.5) % 360.0; moved = true end  -- Q rotate
            if IsControlPressed(0, 38) then preview.h = (preview.h + 1.5) % 360.0; moved = true end  -- E rotate
            if moved then reposition() end
            if IsControlJustPressed(0, 201) then                    -- Enter = quick save
                local line = configLine()
                Game.SetClipboard(line)
                Game.Chat('[placeped]', 'SAVED (clipboard): ' .. line)
            end
            if IsControlJustPressed(0, 202) then despawn() end      -- Esc/Backspace = cancel
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then despawn() end
end)
