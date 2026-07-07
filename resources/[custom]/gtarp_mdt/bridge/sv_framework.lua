-- ============================================================================
-- gtarp_mdt/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
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

-- Display name for BOLO/report attribution.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Is this source an on-duty police officer right now? (gtarp_evidence's
-- exact gate.)
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == 'police' and job.onduty == true
end

-- Is the source carrying at least one of `item`?
function Bridge.HasItem(src, item)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and (tonumber(n) or 0) > 0
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Notify every on-duty officer (BOLO broadcast).
function Bridge.NotifyPolice(title, msg, t)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        if Bridge.IsOnDutyPolice(src) then
            Bridge.Notify(src, title, msg, t)
        end
    end
end

-- Reply to a command invoker: console gets prints, players get chat lines
-- (gtarp_perf's /diag pattern).
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[gtarp_mdt] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 116, 178, 255 }, args = { 'MDT', line } })
        end
    end
end

-- The qbx_police_overrides GetMDT() contract, or nil when that resource
-- isn't running (caller falls back to Config.MDTDefaults).
function Bridge.GetMDTContract()
    if GetResourceState('qbx_police_overrides') ~= 'started' then return nil end
    local ok, mdt = pcall(function() return exports.qbx_police_overrides:GetMDT() end)
    return ok and type(mdt) == 'table' and mdt or nil
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating — job, tablet item, cooldowns —
-- happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
