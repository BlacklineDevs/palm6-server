-- ============================================================================
-- palm6_heat/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE. See
-- docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Copied from palm6_wanted's bridge (a read/command civic resource) and given
-- two extras heat needs that a pure reader does not: an on-duty POLICE gate
-- (the /heat priority board is police-only) and an online citizenid -> name
-- resolver (so AddHeat callers that pass only a citizenid still get a display
-- name on the board, without this resource ever reading the qbx players
-- schema). There is deliberately NO money / write / charge helper — heat never
-- moves money and writes only its OWN table (in server/main via oxmysql).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id for a live source, or nil (used by /myheat).
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for a live source (debug/log lines; also the name captured on
-- an AddHeat call when the caller passes a source-derived name).
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Resolve a citizenid to an RP name IF that character is currently online, else
-- nil. Lets AddHeat(citizenid, ...) stamp a fresh display name on the board
-- without this resource ever touching the qbx `players` table (name is
-- denormalised onto our own row, the palm6_wanted pattern). Mirrors
-- palm6_clout's GetSourceByCitizenId online scan.
function Bridge.GetNameByCitizenId(citizenid)
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return Bridge.GetPlayerName(src)
        end
    end
    return nil
end

-- Is this source an on-duty police officer? Gates the /heat priority board.
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob and job.onduty == true
end

-- Reply to a command invoker: console gets prints, players get one palm6_ui
-- panel (same renderer palm6_wanted / palm6_rapsheet use) instead of chat spam.
function Bridge.Reply(src, tag, color, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[palm6_heat] ' .. line) end
        return
    end
    TriggerClientEvent('palm6_ui:show', src, { tag = tag, color = color, lines = lines })
end

-- Notify a player (only used for "no character yet" feedback on /myheat).
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
