-- ============================================================================
-- palm6_season/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / sibling exports / server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Mirrors palm6_ems / palm6_citations. The ladder SELECTs need no framework
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

-- Multi-line scoreboard output as ONE palm6_ui panel instead of chat spam.
-- Console falls back to prints since NUI cannot target src 0.
function Bridge.Reply(src, lines)
    if not src or src == 0 then
        for _, line in ipairs(lines) do print('[palm6_season] ' .. line) end
        return
    end
    TriggerClientEvent('palm6_ui:show', src, { tag = 'Season', color = { 120, 200, 255 }, lines = lines })
end

-- Console / ace check for the admin season-control commands.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end  -- server console
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Player-run crew for a citizenid (soft tie-in; nil if palm6_gangs is absent).
function Bridge.GetCrew(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    if GetResourceState('palm6_gangs') ~= 'started' then return nil end
    local ok, g = pcall(function() return exports.palm6_gangs:GetGang(citizenid) end)
    return (ok and type(g) == 'table') and g or nil
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Credit CLEAN funds to an online player's bank (season prize payout). Returns
-- AddMoney's real result (not a blind true) so the caller reverts the claim if
-- the credit didn't land — a prize must never be marked claimed but unpaid.
function Bridge.AddBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    local ok, res = pcall(function() return p.Functions.AddMoney('bank', amount, reason or 'season-prize') end)
    return ok and res ~= false
end

-- Credit CLEAN funds to a player's bank BY citizenid, online or offline — the
-- offline-safe payout pattern (palm6_fightclub / pumpcoin / bounty). Used by
-- the boot reconcile, where the prize's owner is often logged off after the
-- restart that stranded the payout. Returns true iff the credit landed.
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    if not citizenid or citizenid == '' then return false end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            local ok, res = pcall(function() return p.Functions.AddMoney('bank', amount, reason or 'season-prize') end)
            return ok and res ~= false
        end
    end
    local ok = pcall(function()
        MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
            { amount, citizenid })
    end)
    return ok
end

-- Server source for an online character, or nil (used only to toast a recovered
-- prize to its owner if they happen to be back online at reconcile time).
function Bridge.GetSourceByCitizenId(citizenid)
    if not citizenid or citizenid == '' then return nil end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

-- Unrestricted chat command; all gating happens server-side in the handler.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
