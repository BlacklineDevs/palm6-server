-- ============================================================================
-- palm6_mapeditor/client/lights.lua  —  light editor
--
-- Place point/spot lights (drawn per-frame, not entities), adjust color/range/
-- intensity, and include them in the editor export. Only the paid "Advanced Map
-- & Prop Editor" has a light editor — this is a differentiator. Natives via Game.*
-- ============================================================================

local lights = {}   -- { {id, x,y,z, r,g,b, range, intensity, kind='point'|'spot'}, ... }
local lsel = nil
local nextLightId = 1   -- stable id per light (for the outliner)

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
    lights[#lights + 1] = { id = nextLightId, x = x, y = y, z = z + 0.5, r = 255, g = 200, b = 140, range = 8.0, intensity = 5.0, kind = kind }
    nextLightId = nextLightId + 1
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
RegisterCommand('matlightpick', function()
    if #lights == 0 then return end
    local x, y, z = Game.CameraAimPoint(40.0)
    if not x then return end
    local best, bd
    for i, l in ipairs(lights) do local d = (l.x - x) ^ 2 + (l.y - y) ^ 2 + (l.z - z) ^ 2; if not bd or d < bd then bd, best = d, i end end
    lsel = best; Game.Notify('light ' .. best .. ' selected')
end, false)
RegisterCommand('matlightdel', function()
    if not lsel or not lights[lsel] then return end
    table.remove(lights, lsel)
    lsel = #lights > 0 and math.min(lsel, #lights) or nil
    Game.Notify('light removed (' .. #lights .. ')')
end, false)

-- --- hooks (main.lua's export folds these in; load re-adds them) -----------
if MapEd then
    function MapEd.getLights() return lights end
    -- Drop the session lights (called after /mapcommit publishes them, so the
    -- returning LIVE lights aren't drawn on top of the session copies).
    function MapEd.clearLights() lights = {}; lsel = nil end
    -- l is the raw JSON form { x,y,z, r,g,b, range, intensity, kind }.
    function MapEd.addLight(l)
        if type(l) ~= 'table' or not l.x then return end
        lights[#lights + 1] = {
            id = nextLightId,
            x = l.x + 0.0, y = l.y + 0.0, z = l.z + 0.0,
            r = l.r or 255, g = l.g or 200, b = l.b or 140,
            range = l.range or 8.0, intensity = l.intensity or 5.0, kind = l.kind or 'point',
        }
        nextLightId = nextLightId + 1
        lsel = #lights
    end

    -- Outliner: list / delete / jump-to session lights by stable id.
    function MapEd.lightList()
        local out = {}
        for _, l in ipairs(lights) do
            out[#out + 1] = { id = l.id, kind = l.kind, x = l.x, y = l.y, z = l.z, r = l.r, g = l.g, b = l.b }
        end
        return out
    end
    function MapEd.deleteLightById(id)
        for i, l in ipairs(lights) do
            if l.id == id then
                table.remove(lights, i)
                lsel = #lights > 0 and math.min(lsel or 1, #lights) or nil
                Game.Notify('light removed (' .. #lights .. ')')
                return true
            end
        end
        return false
    end
    function MapEd.gotoLightById(id)
        for i, l in ipairs(lights) do
            if l.id == id then
                lsel = i
                Game.TeleportPlayer(l.x, l.y, l.z)
                Game.Notify('jumped to ' .. tostring(l.kind) .. ' light', 'inform')
                return true
            end
        end
        return false
    end
end
