-- ============================================================================
-- gtarp_blotter/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE. See
-- docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Copied from gtarp_citations / gtarp_ems bridges and trimmed to what a
-- read-only aggregator needs: the on-duty police gate, an admin ace check,
-- a reply helper, a command registrar, a resource-state check, and a soft
-- Discord announce wrapper. There is deliberately no ChargeBank / insert
-- helper here, the blotter never spends money and never writes.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
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

-- Is this source an on-duty police officer right now? Mirrors
-- gtarp_citations Bridge.IsOnDutyPolice exactly, reading the job name from
-- config so the gate is one edit away from any future rename.
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob and job.onduty == true
end

-- Console / ace check so staff can pull the blotter without being on the
-- clock. Mirrors gtarp_season Bridge.IsAdmin.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end  -- server console
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_blotter] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'Blotter', color = { 100, 170, 255 }, lines = lines })
end

-- Notify a player (used only for gate-denied feedback).
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Soft Discord announce. Returns false (and does nothing) if gtarp_discord
-- is absent or the call throws, so the digest can never break gameplay. The
-- Announce(feed, payload) signature is frozen in gtarp_discord/server/main.lua.
function Bridge.Announce(feed, payload)
    if not Bridge.ResourceStarted('gtarp_discord') then return false end
    local ok, queued = pcall(function()
        return exports.gtarp_discord:Announce(feed, payload)
    end)
    return ok and queued == true
end

-- Unrestricted chat command (all gating happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
