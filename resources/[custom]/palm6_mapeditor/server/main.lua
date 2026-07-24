-- ============================================================================
-- palm6_mapeditor/server/main.lua
--
-- Persists editor exports to disk (clients can't write files). ACE-gated so
-- only admins can drive the editor / write files.
-- ============================================================================

local function isAllowed(src)
    return IsPlayerAceAllowed(src, Config.Ace) or src == 0
end

RegisterNetEvent('palm6_mapeditor:save', function(luaText, jsonText)
    local src = source
    if not isAllowed(src) then return end
    local stamp = os.date('%Y%m%d_%H%M%S')
    SaveResourceFile(GetCurrentResourceName(), ('data/exports/map_%s.lua'):format(stamp), luaText or '', -1)
    SaveResourceFile(GetCurrentResourceName(), ('data/exports/map_%s.json'):format(stamp), jsonText or '', -1)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Map Editor', description = 'saved data/exports/map_' .. stamp, type = 'success' })
    print(('[palm6_mapeditor] %s saved export map_%s'):format(GetPlayerName(src) or src, stamp))
end)
