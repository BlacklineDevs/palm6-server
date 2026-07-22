-- ============================================================================
-- palm6_threads/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls qbx_core /
-- server natives. server/main.lua holds the logic and calls Bridge.* only, so a
-- port to GTA VI is a rewrite of THIS FILE (the palm6_business / palm6_gangs
-- pattern). Our OWN SQL (palm6_clothing_*) stays in the logic layer.
--
-- Identity is bridge-resolved server-side and NEVER client-asserted: a player can
-- only ever receive their own citizenid's deployed designs.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- The caller's in-game citizenid, or nil. The authority for "whose designs".
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- ox_lib toast to a player. Soft: never errors if ox_lib isn't the notify handler.
function Bridge.Notify(src, title, msg, t)
    if not src or src == 0 then return end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end
