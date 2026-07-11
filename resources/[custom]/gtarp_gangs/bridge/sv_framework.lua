-- ============================================================================
-- gtarp_gangs/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side game natives. server/main.lua
-- holds the gang-management, vault, and reputation LOGIC and calls Bridge.*
-- only, so a port to GTA VI is a rewrite of THIS FILE. See
-- docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Our OWN SQL (gtarp_gangs / gtarp_gang_members / gtarp_gang_vault_log) stays
-- in the logic layer — it is our schema, fully portable. Only reads/writes
-- against the FRAMEWORK's own player money belong here.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Character display name for the roster / logs.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        -- NB: :gsub returns (string, count); assigning to a local truncates to
        -- the string. Returning the gsub expression directly would leak the
        -- count as a 2nd return value, which expands inside a
        -- `{ ..., Bridge.GetPlayerName(src) }` insert-params table into an extra
        -- element (5 values for 4 columns) and fails the INSERT — this broke
        -- gang create AND join.
        local name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
        name = name:gsub('^%s+', ''):gsub('%s+$', '')
        return name
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- The source's current qbx_core (STATIC) gang, or nil when 'none'. Read-only —
-- exposed so consumers can reason about the framework gang independent of our
-- player-run layer if they ever need to. Not used to gate anything here.
function Bridge.GetQbxGang(src)
    local p = getPlayer(src)
    local gang = p and p.PlayerData and p.PlayerData.gang
    if not gang or gang.name == 'none' then return nil end
    return { name = gang.name, label = gang.label or gang.name, grade = gang.grade }
end

-- Best-effort mirror of a player-run gang into qbx_core's PlayerData.gang so
-- framework-gang consumers (e.g. gtarp_turf, which reads the qbx gang) reflect
-- membership. NO-OP unless Config.MirrorToQbxGang AND qbx_core's static gang
-- registry accepts the name — pcall-guarded so a rejected/unknown gang can
-- never error or corrupt state. Our DB stays authoritative regardless.
function Bridge.MirrorQbxGang(src, gangName, grade)
    if not Config.MirrorToQbxGang then return end
    local p = getPlayer(src)
    if not p or not p.Functions or not p.Functions.SetGang then return end
    pcall(function() p.Functions.SetGang(gangName, grade or 0) end)
end

-- ---------------------------------------------------------------------------
-- Money (CASH vault)
-- ---------------------------------------------------------------------------

-- Whole-dollar cash the player is holding right now.
function Bridge.GetCash(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData or not p.PlayerData.money then return 0 end
    return tonumber(p.PlayerData.money.cash) or 0
end

-- Remove `amount` cash. Returns true ONLY if the framework confirms it left
-- the player's wallet — the caller credits the vault nothing it didn't take.
function Bridge.RemoveCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (tonumber(p.PlayerData.money.cash) or 0) < amount then return false end
    local ok, res = pcall(function() return p.Functions.RemoveMoney('cash', amount, reason) end)
    return ok and res ~= false
end

-- Give `amount` cash back (vault withdrawal payout, or a deposit refund when
-- the vault credit failed after the cash was pulled).
function Bridge.AddCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    local ok, res = pcall(function() return p.Functions.AddMoney('cash', amount, reason) end)
    return ok and res ~= false
end

-- Charge the founder's BANK for the creation fee. Returns true only if they
-- could pay (affordability checked before the debit).
function Bridge.ChargeBank(src, amount, reason)
    if amount <= 0 then return true end
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (tonumber(p.PlayerData.money.bank) or 0) < amount then return false end
    local ok, res = pcall(function() return p.Functions.RemoveMoney('bank', amount, reason) end)
    return ok and res ~= false
end

-- Credit a bank balance by citizenid, online or offline (the disband-payout
-- path — the vault remainder must land even if written just before logout).
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    if amount <= 0 then return true end
    local src = Bridge.GetSourceByCitizenId(citizenid)
    if src then
        local p = getPlayer(src)
        if p and p.Functions then
            local ok = pcall(function() p.Functions.AddMoney('bank', amount, reason) end)
            if ok then return true end
        end
    end
    return pcall(function()
        MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
            { amount, citizenid })
    end) and true or false
end

-- ---------------------------------------------------------------------------
-- Presence / world
-- ---------------------------------------------------------------------------

-- Online server ids as numbers.
function Bridge.GetOnlinePlayers()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do out[#out + 1] = tonumber(sid) end
    return out
end

-- Server source for an online character, or nil.
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

-- Caller's ped position as {x,y,z}, or nil. Server-side proximity anti-abuse
-- for invites — never trust a client-supplied position.
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

-- Unrestricted chat command (all gating happens server-side in the handler,
-- or the command just opens the menu which is itself server-gated).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
