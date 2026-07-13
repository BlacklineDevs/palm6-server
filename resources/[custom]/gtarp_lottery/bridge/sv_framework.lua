-- ============================================================================
-- gtarp_lottery/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua calls
-- Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Assembled from the proven adapters already in the tree: ChargeBank from
-- gtarp_citations / gtarp_ems, CreditBankByCitizenId (offline-safe) from
-- gtarp_bounty, IsAdmin (ace) from gtarp_blotter / gtarp_season.
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

-- Display name for the winner banner / prints.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Resolve a citizenid to a display name, online or offline, or nil when no
-- such citizen exists (framework schema knowledge lives here).
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

-- Server source for an online character, or nil.
function Bridge.GetSourceByCitizenId(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

-- Is the caller an admin? Ace-gated; the server console (src 0) is always
-- allowed so staff can force a draw from the box.
function Bridge.IsAdmin(src)
    if not src or src == 0 then return true end
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Charge `amount` from bank. Returns true only if the player could pay AND the
-- debit landed. Balance is re-read here server-side, never trusted from a
-- client.
function Bridge.ChargeBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (p.PlayerData.money.bank or 0) < amount then return false end
    return p.Functions.RemoveMoney('bank', amount, reason) and true or false
end

-- Credit bank by citizenid, online or offline (gtarp_bounty's offline-safe
-- payout pattern - the winnings land even if the winner has logged off).
-- Returns the real result so a failed credit is visible to the caller rather
-- than a blind true.
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            local ok, res = pcall(function() return p.Functions.AddMoney('bank', amount, reason) end)
            return ok and res ~= false
        end
    end
    local ok = pcall(function()
        MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
            { amount, citizenid }
        )
    end)
    return ok
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_lottery] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'Lottery', color = { 120, 200, 120 }, lines = lines })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
