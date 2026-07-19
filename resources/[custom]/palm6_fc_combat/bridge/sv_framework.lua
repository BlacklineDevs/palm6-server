-- ============================================================================
-- palm6_fc_combat/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side game natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- Verbatim clone of palm6_fightclub/bridge/sv_framework.lua (same API surface).
-- ============================================================================

Bridge = {}

local UNARMED_HASH = GetHashKey('WEAPON_UNARMED')

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for board/match listings.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_fc_combat] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 200, 40, 40 }, args = { 'Fight Club', line } })
        end
    end
end

-- Charge `amount` from bank. Returns true if the player could pay.
function Bridge.ChargeBank(src, amount, reason)
    -- §19.2 money-inert guard (defense-in-depth): the reserved '__' citizenid
    -- prefix (the PvE CPU sentinel) can NEVER be charged. Reject before any
    -- framework/DB call. A normal src is a number, so this never touches the
    -- real (non-'__') path.
    if type(src) == 'string' and src:sub(1, 2) == '__' then return false end
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (p.PlayerData.money.bank or 0) < amount then return false end
    return p.Functions.RemoveMoney('bank', amount, reason) and true or false
end

-- Credit bank by citizenid, online or offline (pumpcoin/insurance/bounty's
-- offline-safe pattern — payouts land even if the payee logged off).
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
    -- §19.2 money-inert guard (defense-in-depth): the reserved '__' citizenid
    -- prefix (the PvE CPU sentinel) can NEVER be credited. Reject BEFORE the
    -- online loop AND the offline `UPDATE players` fall-through (the fall-through
    -- bypasses GetSourceByCitizenId, so the guard must live here). Real cids
    -- never start with '__', so the normal path is unaffected.
    if type(citizenid) == 'string' and citizenid:sub(1, 2) == '__' then return false end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            p.Functions.AddMoney('bank', amount, reason)
            return true
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

-- Server source for an online character, or nil.
function Bridge.GetSourceByCitizenId(citizenid)
    -- §19.2 money-inert guard: the reserved '__' sentinel resolves to no source.
    if type(citizenid) == 'string' and citizenid:sub(1, 2) == '__' then return nil end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

-- Caller position as {x,y,z}, or nil.
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

-- Live server-synced ped health for an online source, or nil if the ped
-- isn't spawned/synced yet. Raw native value — threshold comparison stays
-- in the logic layer (shared/config.lua owns the number) — palm6_bounty
-- precedent.
function Bridge.GetHealth(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityHealth(ped)
end

-- Live server-synced current weapon hash for an online source, or nil.
-- "Is this unarmed" comparison stays in the logic layer against
-- Bridge.UnarmedHash() — same split as Bridge.GetHealth above.
function Bridge.GetCurrentWeaponHash(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, hash = pcall(GetSelectedPedWeapon, ped)
    if not ok then return nil end
    return hash
end

function Bridge.UnarmedHash()
    return UNARMED_HASH
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the
-- handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end

-- ============================================================================
-- T7 combat-native helpers (server-authoritative reach / confinement / facing).
-- GetEntityCoords/GetEntityHeading are valid server-side on a synced player ped.
-- ============================================================================

-- Distance (m) between two online fighters' peds; nil if either isn't readable.
function Bridge.Reach(aSrc, bSrc)
    local pa, pb = GetPlayerPed(aSrc), GetPlayerPed(bSrc)
    if not pa or pa == 0 or not pb or pb == 0 then return nil end
    return #(GetEntityCoords(pa) - GetEntityCoords(pb))
end

-- Distance (m) from an online player's ped to a ring-center {x,y,z}; nil if the
-- ped isn't readable (unsynced / gone) — caller treats nil as "skip", never a ring-out.
function Bridge.DistToRing(src, ring)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return #(GetEntityCoords(ped) - vec3(ring.x, ring.y, ring.z))
end

-- Is targetSrc's ped facing attackerSrc? Forward-dot toward the attacker > 0.25
-- (~75 deg frontal arc) = a valid guard direction. False if unreadable.
function Bridge.Facing(targetSrc, attackerSrc)
    local tp, ap = GetPlayerPed(targetSrc), GetPlayerPed(attackerSrc)
    if not tp or tp == 0 or not ap or ap == 0 then return false end
    local dir = GetEntityCoords(ap) - GetEntityCoords(tp)
    local len = #dir
    if len < 0.01 then return true end
    dir = dir / len
    local h = math.rad(GetEntityHeading(tp))    -- GTA heading 0 = +Y; forward = (-sin, cos)
    local fwd = vec3(-math.sin(h), math.cos(h), 0.0)
    return (fwd.x * dir.x + fwd.y * dir.y) > 0.25
end

-- ============================================================================
-- §19 PvE CPU-actor geometry. The dark-PvE CPU is a SERVER-OWNED logical entity
-- with NO src (§19.1) — it has a logical {x,y,z} position var, never a ped the
-- server can read. These variants measure reach/facing against that logical
-- position so the SAME §6 connect validator works for a CPU actor. Every one is
-- FAIL-CLOSED: a nil/malformed pos returns "no reach" / "not facing" so a
-- mis-plumbed CPU seat can never land or absorb a hit it shouldn't (§19.4).
-- ============================================================================

-- Distance (m) from an online player's ped to a logical {x,y,z}; nil (fail-
-- closed: caller treats as out-of-reach) if the ped is unreadable OR pos is bad.
function Bridge.ReachToPos(src, pos)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return #(GetEntityCoords(ped) - vec3(pos.x, pos.y, pos.z or 0.0))
end

-- Is targetSrc's ped facing a logical position `pos` (the CPU attacker)? Same
-- ~75deg frontal-arc test as Bridge.Facing, but the attacker is a logical point
-- instead of a ped. False (fail-closed) if the ped or pos is unreadable — so a
-- human whose facing can't be proven never gets the block-chip discount.
function Bridge.FacingPos(targetSrc, pos)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then return false end
    local tp = GetPlayerPed(targetSrc)
    if not tp or tp == 0 then return false end
    local dir = vec3(pos.x, pos.y, pos.z or 0.0) - GetEntityCoords(tp)
    local len = #dir
    if len < 0.01 then return true end
    dir = dir / len
    local h = math.rad(GetEntityHeading(tp))
    local fwd = vec3(-math.sin(h), math.cos(h), 0.0)
    return (fwd.x * dir.x + fwd.y * dir.y) > 0.25
end
