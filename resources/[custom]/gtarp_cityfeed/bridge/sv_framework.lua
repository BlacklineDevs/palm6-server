-- ============================================================================
-- gtarp_cityfeed/bridge/sv_framework.lua
--
-- Runtime adapter (server). The ONLY file in this resource that calls a native
-- or reads a convar. server/main.lua calls Bridge.* only, so porting to GTA VI
-- is a rewrite of THIS FILE. See docs/GTA6-READINESS.md (Section 3).
-- ============================================================================

Bridge = {}

-- POST a JSON body with an explicit header set; cb(statusCode, responseText, headers).
function Bridge.HttpPostJson(url, body, headers, cb)
    PerformHttpRequest(url, function(status, text, respHeaders)
        cb(status, text, respHeaders or {})
    end, 'POST', body, headers)
end

function Bridge.GetConvar(name)
    local v = GetConvar(name, '')
    return v ~= '' and v or nil
end

-- Current online player count (for the "open" embed capacity line).
function Bridge.NumPlayers()
    return #GetPlayers()
end
