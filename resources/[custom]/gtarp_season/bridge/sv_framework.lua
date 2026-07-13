-- ============================================================================
-- gtarp_season/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / sibling exports / server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Mirrors gtarp_ems / gtarp_citations. The ladder SELECTs need no framework
-- access (they run straight on oxmysql); the bridge exists for the caller's
-- citizenid, the caller's player-run crew, chat/notify output, and the admin
-- ace check on the season-control commands.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id for the caller, or nil.
function Bridge.GetCitizenId(src)
    if not src or src == 0 then return nil end
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- ox_lib notification to a player (no-op for the console).
function Bridge.Notify(src, title, msg, t)
    if not src or src == 0 then return end
    TriggerClientEvent('ox_lib:notify', src, { title = title, description = msg, type = t or 'inform' })
end

-- A single scoreboard line into the caller's chat (no-op for the console).
function Bridge.ChatEcho(src, prefix, line)
    if not src or src == 0 then return end
    TriggerClientEvent('chat:addMessage', src, {
        color = { 120, 200, 255 }, multiline = true, args = { prefix, line },
    })
end

-- Multi-line scoreboard output as ONE gtarp_ui panel instead of chat spam.
-- Console falls back to prints since NUI cannot target src 0.
function Bridge.Reply(src, lines)
    if not src or src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_season] ' .. line) end
        return
    end
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'Season', color = { 120, 200, 255 }, lines = lines })
end

-- Console / ace check for the admin season-control commands.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end  -- server console
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Player-run crew for a citizenid (soft tie-in; nil if gtarp_gangs is absent).
function Bridge.GetCrew(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    if GetResourceState('gtarp_gangs') ~= 'started' then return nil end
    local ok, g = pcall(function() return exports.gtarp_gangs:GetGang(citizenid) end)
    return (ok and type(g) == 'table') and g or nil
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command; all gating happens server-side in the handler.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
