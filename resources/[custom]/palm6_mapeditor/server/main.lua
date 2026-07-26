-- ============================================================================
-- palm6_mapeditor/server/main.lua
--
-- Persists editor exports to disk (clients can't write files). ACE-gated so
-- only admins can drive the editor / write files.
-- ============================================================================

local function isAllowed(src)
    return IsPlayerAceAllowed(src, Config.Ace) or src == 0
end

local function deny(src)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'not authorized (needs admin)', type = 'error' })
end

-- Client asks on load whether it may drive the editor (gates the commands).
RegisterNetEvent('palm6_mapeditor:checkPerm', function()
    TriggerClientEvent('palm6_mapeditor:perm', source, isAllowed(source))
end)

RegisterNetEvent('palm6_mapeditor:save', function(name, luaText, jsonText, ymapXml, pyText)
    local src = source
    if not isAllowed(src) then deny(src) return end
    local safe = (tostring(name or 'map')):gsub('[^%w_%-]', '')
    if safe == '' then safe = 'map' end
    local stamp = os.date('%Y%m%d_%H%M%S')
    local base = ('data/exports/%s_%s'):format(safe, stamp)
    SaveResourceFile(GetCurrentResourceName(), base .. '.lua', luaText or '', -1)
    SaveResourceFile(GetCurrentResourceName(), base .. '.json', jsonText or '', -1)
    local fmts = '.lua/.json'
    if ymapXml then SaveResourceFile(GetCurrentResourceName(), base .. '.ymap.xml', ymapXml, -1); fmts = fmts .. '/.ymap.xml' end
    if pyText then SaveResourceFile(GetCurrentResourceName(), base .. '.py', pyText, -1); fmts = fmts .. '/.py' end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'saved ' .. base .. ' (' .. fmts .. ')', type = 'success' })
    print(('[palm6_mapeditor] %s saved export %s'):format(GetPlayerName(src) or src, base))
end)

-- Load a saved export back into the editor (save/load sessions).
RegisterNetEvent('palm6_mapeditor:load', function(fileName)
    local src = source
    if not isAllowed(src) then deny(src) return end
    -- Strip separators are impossible ([^%w_%-%.] removes / and \), but also
    -- collapse any '..' so no traversal token can ever form (defence in depth).
    local safe = (tostring(fileName or '')):gsub('[^%w_%-%.]', ''):gsub('%.%.+', '.')
    if safe == '' then return end
    if not safe:find('%.json$') then safe = safe .. '.json' end
    local body = LoadResourceFile(GetCurrentResourceName(), 'data/exports/' .. safe)
    if not body then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'not found: ' .. safe, type = 'error' })
        return
    end
    TriggerClientEvent('palm6_mapeditor:loaded', src, body)
end)
