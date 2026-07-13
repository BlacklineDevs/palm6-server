-- ============================================================================
-- gtarp_citystats/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Trimmed to what a READ-ONLY, ungated command needs: identity for debug
-- attribution, a chat/console Reply, a Notify, a resource-state probe, and an
-- unrestricted command registrar. There are deliberately NO write helpers
-- (no ChargeBank / insert / announce) and NO on-duty gate: /citystats is
-- public, exactly like the website /city page it mirrors.
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

-- Notify a player (ox_lib toast). Console (src 0) has no ped, so it is a no-op
-- there; console feedback goes through Bridge.Reply instead.
function Bridge.Notify(src, title, msg, t)
    if src == 0 then return end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_citystats] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'CITY', color = { 120, 200, 255 }, lines = lines })
end

-- Is a given resource currently started? Used to soft-skip sections whose
-- owning resource is absent (never hard-fails; the query pcall also guards).
function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating, if any, happens server-side in the
-- handler). /citystats is intentionally open to every citizen.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
