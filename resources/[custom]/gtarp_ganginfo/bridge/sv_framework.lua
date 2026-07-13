-- ============================================================================
-- gtarp_ganginfo/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE. See
-- docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Copied from gtarp_blotter's bridge and trimmed to what a public read-only
-- directory needs: a citizenid lookup (debug/log only), a reply helper, a
-- notify helper (for rate-limit / not-found feedback), a resource-state check,
-- and a command registrar. There is deliberately NO ChargeBank / insert /
-- update helper and NO on-duty or admin gate: /ganginfo and /gangs are public
-- to any citizen, and this resource never writes.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil. Used only in debug/log lines here.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for the caller, used only in debug/log lines.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_ganginfo] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'Gangs', color = { 170, 130, 255 }, lines = lines })
end

-- Notify a player (used only for rate-limit / not-found feedback).
function Bridge.Notify(src, title, msg, t)
    if src == 0 then return end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all logic, including the rate limit, happens
-- server-side in the handler). The `false` restricted flag keeps it public.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
