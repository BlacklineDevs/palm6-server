-- ============================================================================
-- palm6_business/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / server natives. server/main.lua holds the business logic and calls
-- Bridge.* only, so a port to GTA VI is a rewrite of THIS FILE (the bridge
-- pattern, same as palm6_gangs). Our OWN SQL (palm6_businesses / _members /
-- _ledger) stays in the logic layer — our schema, fully portable. Only reads/
-- writes against the FRAMEWORK's own player money belong here.
--
-- Business money is BANK money (clean, auditable) throughout — deposits pull the
-- owner's bank, charges pull the customer's bank, payroll/withdraw credit a bank.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- The player's raw Discord id (no 'discord:' prefix), or nil. Used only by the
-- Starter Pack entitlement (per-Discord-account, mirrors how the website links
-- identity). Same helper as palm6_founder's bridge.
function Bridge.GetDiscordId(src)
    local ids = GetPlayerIdentifiers(src) or {}
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'discord:' then return ids[i]:sub(9) end
    end
    return nil
end

-- Character display name for the roster / ledger. NB: the :gsub-count leak that
-- broke gang create/join is avoided by assigning to a local before returning.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        local name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
        name = name:gsub('^%s+', ''):gsub('%s+$', '')
        return name
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- ---------------------------------------------------------------------------
-- Money (BANK — clean, auditable)
-- ---------------------------------------------------------------------------

-- Whole-dollar bank balance the player holds right now.
function Bridge.GetBank(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData or not p.PlayerData.money then return 0 end
    return tonumber(p.PlayerData.money.bank) or 0
end

-- Charge `amount` from the player's BANK. Returns true ONLY if the framework
-- confirms it left their account (affordability checked before the debit), so
-- the caller credits the business account nothing it did not take.
function Bridge.ChargeBank(src, amount, reason)
    if amount <= 0 then return true end
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (tonumber(p.PlayerData.money.bank) or 0) < amount then return false end
    local ok, res = pcall(function() return p.Functions.RemoveMoney('bank', amount, reason) end)
    return ok and res ~= false
end

-- Credit a bank balance by citizenid, online or offline (payroll/withdraw must
-- land even for an employee who logged off, and the account-refund path on a
-- failed credit). Online -> AddMoney; offline -> the JSON_SET SQL fallback.
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    if amount <= 0 then return true end
    -- Defense-in-depth: never credit a sentinel actor id (NPC/system).
    if type(citizenid) == 'string' and citizenid:sub(1, 2) == '__' then return false end
    local src = Bridge.GetSourceByCitizenId(citizenid)
    if src then
        local p = getPlayer(src)
        if p and p.Functions then
            local ok = pcall(function() p.Functions.AddMoney('bank', amount, reason) end)
            if ok then return true end
        end
    end
    -- Offline fallback. Return true ONLY if a row was actually updated — a 0-row
    -- result (e.g. a since-deleted character) must return false so the caller
    -- (settlePayout) takes the refund path instead of burning the payout against a
    -- non-existent payee. reconcilePending now depends on this boolean being honest.
    local ok, affected = pcall(function()
        return MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
            { amount, citizenid })
    end)
    return ok and (tonumber(affected) or 0) > 0
end

-- ---------------------------------------------------------------------------
-- Presence / world
-- ---------------------------------------------------------------------------

function Bridge.GetOnlinePlayers()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do out[#out + 1] = tonumber(sid) end
    return out
end

function Bridge.GetSourceByCitizenId(citizenid)
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        local p = getPlayer(sid)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return sid
        end
    end
    return nil
end

-- Caller's ped position as {x,y,z}, or nil. Server-side proximity anti-abuse for
-- hire/charge target selection — never trust a client-supplied position.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Bridge.Distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Caller's ped heading (0-360), or 0.0. Phase-1 storefront placement captures it
-- server-side so a future greeter ped faces the right way — never client-supplied.
function Bridge.GetHeading(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0.0 end
    return GetEntityHeading(ped) or 0.0
end

-- Best-effort police alert (robbery). Soft: fires qbx_police's dispatch event only
-- if that resource is running, pcall-guarded so a missing/renamed handler never
-- errors the robbery. No hard dependency — if no police system is present, the
-- robbery still completes silently.
function Bridge.PoliceAlert(src, text)
    if GetResourceState('qbx_police') ~= 'started' then return end
    pcall(function() TriggerEvent('police:server:policeAlert', text, nil, src) end)
end

-- ---------------------------------------------------------------------------
-- Notify / commands
-- ---------------------------------------------------------------------------

function Bridge.Notify(src, title, msg, t)
    if not src or src == 0 then return end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating is server-side in the handler, or the
-- command just opens the menu which is itself server-gated).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
