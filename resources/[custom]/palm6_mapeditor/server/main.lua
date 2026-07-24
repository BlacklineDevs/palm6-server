-- ============================================================================
-- palm6_mapeditor/server/main.lua
--
-- Persists editor exports to disk (clients can't write files). ACE-gated so
-- only admins can drive the editor / write files.
-- ============================================================================

local function isAllowed(src)
    return IsPlayerAceAllowed(src, Config.Ace) or src == 0
end

RegisterNetEvent('palm6_mapeditor:save', function(name, luaText, jsonText, ymapXml)
    local src = source
    if not isAllowed(src) then return end
    local safe = (tostring(name or 'map')):gsub('[^%w_%-]', '')
    if safe == '' then safe = 'map' end
    local stamp = os.date('%Y%m%d_%H%M%S')
    local base = ('data/exports/%s_%s'):format(safe, stamp)
    SaveResourceFile(GetCurrentResourceName(), base .. '.lua', luaText or '', -1)
    SaveResourceFile(GetCurrentResourceName(), base .. '.json', jsonText or '', -1)
    if ymapXml then SaveResourceFile(GetCurrentResourceName(), base .. '.ymap.xml', ymapXml, -1) end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'saved ' .. base .. ' (.lua/.json/.ymap.xml)', type = 'success' })
    print(('[palm6_mapeditor] %s saved export %s'):format(GetPlayerName(src) or src, base))
end)

-- Load a saved export back into the editor (save/load sessions).
RegisterNetEvent('palm6_mapeditor:load', function(fileName)
    local src = source
    if not isAllowed(src) then return end
    local safe = (tostring(fileName or '')):gsub('[^%w_%-%.]', '')
    if safe == '' then return end
    if not safe:find('%.json$') then safe = safe .. '.json' end
    local body = LoadResourceFile(GetCurrentResourceName(), 'data/exports/' .. safe)
    if not body then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'not found: ' .. safe, type = 'error' })
        return
    end
    TriggerClientEvent('palm6_mapeditor:loaded', src, body)
end)
