-- ============================================================================
-- gtarp_help/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Trimmed to what a READ-ONLY, ungated reference command needs: identity for
-- debug attribution, a chat/console Reply, an admin ace check for the gated
-- Admin category, and an unrestricted command registrar. There are deliberately
-- NO write helpers and NO database access anywhere in this resource.
--
-- Shape copied from gtarp_citystats/bridge/sv_framework.lua (Reply, RegisterCommand)
-- plus the IsAdmin helper from gtarp_season/bridge/sv_framework.lua.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil. Used only for debug attribution.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for debug lines.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Console / ace check for the gated Admin help category. Console (src 0) always
-- passes; players must hold Config.AdminAce.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_help] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    local c = Config.ChatColor or { 130, 205, 140 }
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'HELP', color = { c[1], c[2], c[3] }, lines = lines })
end

-- Unrestricted chat command (all gating, if any, happens server-side in the
-- handler). /help is intentionally open to every citizen.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
