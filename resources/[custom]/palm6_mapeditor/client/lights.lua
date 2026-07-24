-- ============================================================================
-- palm6_mapeditor/client/lights.lua  —  light editor
--
-- Place point/spot lights (drawn per-frame, not entities), adjust color/range/
-- intensity, and include them in the editor export. Only the paid "Advanced Map
-- & Prop Editor" has a light editor — this is a differentiator. Natives via Game.*
-- ============================================================================

local lights = {}   -- { {x,y,z, r,g,b, range, intensity, kind='point'|'spot'}, ... }
local lsel = nil

local function lrec() return lsel and lights[lsel] or nil end

-- --- render loop (draws every light every frame) ---------------------------
CreateThread(function()
    while true do
        if MapEd and MapEd.isEditing() and #lights > 0 then
            for _, l in ipairs(lights) do
                if l.kind == 'spot' then
                    Game.DrawSpot(l.x, l.y, l.z, 0.0, 0.0, -1.0, l.r, l.g, l.b, l.range, l.intensity, 8.0, 1.0)
                else
                    Game.DrawPointLight(l.x, l.y, l.z, l.r, l.g, l.b, l.range, l.intensity)
                end
            end
            Wait(0)
        else
            Wait(400)
        end
    end
end)

-- --- commands --------------------------------------------------------------
RegisterCommand('matlight', function(_, args)
    if not (MapEd and MapEd.isEditing()) then Game.Notify('open the editor first (/mapedit)') return end
    local kind = (args[1] == 'spot') and 'spot' or 'point'
    local x, y, z = Game.CameraAimPoint(30.0)
    if not x then x, y, z = Game.PlayerPos(); z = z + 1.5 end
    lights[#lights + 1] = { x = x, y = y, z = z + 0.5, r = 255, g = 200, b = 140, range = 8.0, intensity = 5.0, kind = kind }
    lsel = #lights
    Game.Notify(('%s light placed (%d) — /matlightcolor /matlightrange /matlightint'):format(kind, #lights), 'success')
end, false)

RegisterCommand('matlightcolor', function(_, args)
    local l = lrec(); if not l then return end
    l.r = math.min(255, math.max(0, tonumber(args[1]) or l.r))
    l.g = math.min(255, math.max(0, tonumber(args[2]) or l.g))
    l.b = math.min(255, math.max(0, tonumber(args[3]) or l.b))
end, false)
RegisterCommand('matlightrange', function(_, args) local l = lrec(); if l then l.range = math.max(0.5, tonumber(args[1]) or l.range) end end, false)
RegisterCommand('matlightint', function(_, args) local l = lrec(); if l then l.intensity = math.max(0.1, tonumber(args[1]) or l.intensity) end end, false)
RegisterCommand('matlightdel', function() local l = table.remove(lights); if l and lsel and lsel > #lights then lsel = #lights > 0 and #lights or nil end Game.Notify('light removed (' .. #lights .. ')') end, false)

-- --- hooks (main.lua's export folds these in; load re-adds them) -----------
if MapEd then
    function MapEd.getLights() return lights end
    -- l is the raw JSON form { x,y,z, r,g,b, range, intensity, kind }.
    function MapEd.addLight(l)
        if type(l) ~= 'table' or not l.x then return end
        lights[#lights + 1] = {
            x = l.x + 0.0, y = l.y + 0.0, z = l.z + 0.0,
            r = l.r or 255, g = l.g or 200, b = l.b or 140,
            range = l.range or 8.0, intensity = l.intensity or 5.0, kind = l.kind or 'point',
        }
        lsel = #lights
    end
end
