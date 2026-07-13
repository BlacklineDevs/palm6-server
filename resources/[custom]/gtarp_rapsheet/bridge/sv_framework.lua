-- ============================================================================
-- gtarp_rapsheet/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE. See
-- docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Copied from gtarp_blotter / gtarp_citations bridges and trimmed to what a
-- read-only record surface needs: caller citizenid, the on-duty police gate,
-- an admin ace check, a target resolver (online player id or citizenid,
-- online or offline), reply / notify helpers, a resource-state check, and a
-- command registrar. There is deliberately NO ChargeBank / insert / update
-- helper here, the rap sheet never spends money and never writes.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id for the caller, or nil.
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
-- gtarp_citations / gtarp_blotter Bridge.IsOnDutyPolice exactly, reading the
-- job name from config so the gate is one edit away from any future rename.
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob and job.onduty == true
end

-- Console / ace check so staff can pull a sheet without being on the clock.
-- Mirrors gtarp_blotter Bridge.IsAdmin.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end  -- server console
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Resolve a citizenid to a display name, online or offline, or nil when no
-- such citizen exists (framework schema knowledge lives here). Copied from
-- gtarp_citations Bridge.GetCitizenName.
function Bridge.GetCitizenName(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return Bridge.GetPlayerName(src)
        end
    end
    local name
    pcall(function()
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if row and row.charinfo then
            local ci = json.decode(row.charinfo)
            if type(ci) == 'table' then
                name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
                    :gsub('^%s+', ''):gsub('%s+$', '')
            end
        end
    end)
    return name
end

-- Resolve a /priors argument into a citizenid + display name. The argument is
-- either an ONLINE player's server id (all digits, matching a connected
-- character) or a citizenid string (online or offline). Returns citizenid,
-- name on success, or nil, nil when no such citizen can be found. Read-only.
function Bridge.ResolveTarget(arg)
    arg = tostring(arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if arg == '' then return nil, nil end

    -- Try an online player server id first (only if the input is all digits
    -- AND a live character sits on that id, so a numeric citizenid still
    -- falls through to the citizenid lookup below).
    if arg:match('^%d+$') then
        local pid = tonumber(arg)
        local p = getPlayer(pid)
        if p and p.PlayerData and p.PlayerData.citizenid then
            return p.PlayerData.citizenid, Bridge.GetPlayerName(pid)
        end
    end

    -- Otherwise treat the raw string as a citizenid (name resolves online or
    -- offline via the players table).
    local name = Bridge.GetCitizenName(arg)
    if name then return arg, name end
    return nil, nil
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_rapsheet] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'Record', color = { 200, 160, 255 }, lines = lines })
end

-- Notify a player (used only for gate-denied / usage feedback).
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
