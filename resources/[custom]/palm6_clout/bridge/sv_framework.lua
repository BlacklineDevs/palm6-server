-- ============================================================================
-- palm6_clout/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that knows
-- about qbx_core (identity, job, money), ox_inventory, ox_lib notifications,
-- server-side natives, or the engine's server game events (weapon damage /
-- explosions).
--
-- Core logic (server/main.lua) calls Bridge.* and nothing else: the viewer
-- simulation, donation economy, milestone/deal lifecycle, VOD writes, and
-- every validation gate above this file are framework-free. To port to
-- GTA VI, rewrite THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

-- Resolve the framework player object for a server source, or nil.
local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character identity used as the key in our own tables.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData then return nil end
    return p.PlayerData.citizenid
end

-- RP display name (streamer handle, VOD suspect attribution).
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        local name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
        name = name:gsub('^%s+', ''):gsub('%s+$', '')
        if #name > 0 then return name end
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Is this source an on-duty police officer right now? (Subpoena gate +
-- police-chase viewer scoring.)
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == 'police' and job.onduty == true
end

-- Credit `amount` of CASH to an online source (simulated donations are
-- pocket money). Returns true if applied.
function Bridge.CreditCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('cash', amount, reason)
    return true
end

-- Credit `amount` to an online source's bank (brand-deal payouts).
function Bridge.CreditBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('bank', amount, reason)
    return true
end

-- Credit `amount` to a character's bank BY citizenid — works whether or not
-- they are online (mirrors palm6_fightclub's boot-reconcile credit). Online:
-- go through qbx_core so live UI updates. Offline: a JSON_SET fallback on the
-- players row so a brand deal stranded by a crash still lands next boot.
-- Returns true iff the credit was applied.
function Bridge.CreditBankByCitizenId(citizenid, amount, reason)
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

-- Server source for an online character, or nil (used to notify a recovered
-- streamer if they happen to be online at boot-reconcile time).
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

-- How many of `item` the player holds (0 on any failure). ox_inventory's
-- documented count query — same call palm6_grind uses.
function Bridge.CountItem(src, item)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and tonumber(n) or 0
end

-- Current coords of a player's ped as {x,y,z}, or nil. Used for every
-- server-side proximity gate and the witness-radius scoring.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

-- Distance in metres between two coord tables (accepts vector3/4 too).
function Bridge.Distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

-- Player ped speed in m/s (0 on any failure). OneSync server-side velocity.
function Bridge.GetSpeed(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    local ok, v = pcall(function() return GetEntityVelocity(ped) end)
    if not ok or not v then return 0 end
    return #(vector3(v.x, v.y, v.z))
end

-- Current ped health (server-side entity read); nil when unavailable.
-- The dead/alive threshold itself is Config (engine-specific value).
function Bridge.GetHealth(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, h = pcall(function() return GetEntityHealth(ped) end)
    return ok and h or nil
end

-- Every online player as { src = n, coords = {x,y,z} } (coords may be nil
-- for sources still loading). One snapshot per tick for crowd/chase math.
function Bridge.GetPlayersWithCoords()
    local out = {}
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        out[#out + 1] = { src = src, coords = Bridge.GetCoords(src) }
    end
    return out
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Notify every online player (go-live announcements).
function Bridge.NotifyAll(title, msg, t)
    TriggerClientEvent('ox_lib:notify', -1, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- ---------------------------------------------------------------------------
-- Engine game-event subscriptions. These are OneSync server-side game events
-- relayed FROM CLIENTS (weaponDamageEvent / explosionEvent) — a modded client
-- can fire them at will with an arbitrary payload, so everything here is an
-- UNTRUSTED HINT that must be reconciled against server state before any
-- economic value is granted. The engine-specific names and payload shapes are
-- quarantined here; logic just gets callbacks with server-verified data.
-- ---------------------------------------------------------------------------

local UNARMED = joaat('WEAPON_UNARMED')

-- A payload position that strays further than this from the sender's actual
-- server-side ped is a spoof (or a projectile fired from far outside any
-- witnessable engagement) — either way it earns nothing.
local EVENT_POS_TOLERANCE = 120.0

-- cb({ src, coords, weapon }) whenever a player deals weapon damage.
-- Fist fights are filtered out — content requires actual firepower.
-- Server authority: coords come from the sender's server-side ped (never the
-- payload), and the claimed victim must resolve to a real networked entity —
-- a fabricated packet with no actual victim scores nothing.
function Bridge.OnWeaponDamage(cb, isActive)
    AddEventHandler('weaponDamageEvent', function(sender, data)
        -- Cheapest possible early-out: if nobody is streaming, do NO entity
        -- resolution at all — weaponDamageEvent fires for every gunshot server-wide.
        if isActive and not isActive() then return end
        local src = tonumber(sender)
        if not src or src <= 0 then return end
        local weapon = data and data.weaponType or 0
        if weapon == UNARMED then return end

        -- Reconcile the claimed victim against server state.
        local hitId = data and tonumber(data.hitGlobalId) or 0
        if hitId == 0 and data and type(data.hitGlobalIds) == 'table' then
            hitId = tonumber(data.hitGlobalIds[1]) or 0
        end
        if hitId == 0 then return end
        local okEnt, victim = pcall(NetworkGetEntityFromNetworkId, hitId)
        if not okEnt or not victim or victim == 0 or not DoesEntityExist(victim) then return end

        local coords = Bridge.GetCoords(src)
        if not coords then return end
        -- The victim must be within a plausible engagement range of the
        -- shooter — kills "I damaged something across the map" spoofs.
        local okPos, vpos = pcall(GetEntityCoords, victim)
        if okPos and vpos and Bridge.Distance(coords, vpos) > EVENT_POS_TOLERANCE then return end

        cb({ src = src, coords = coords, weapon = weapon })
    end)
end

-- cb({ src, coords }) whenever an explosion goes off.
-- Server authority: never trust the payload position for scoring. Requires a
-- valid sender and reads THAT ped's coords server-side; the payload posX/Y/Z
-- is only kept (for VOD placement) when it agrees with the sender's actual
-- position within tolerance, otherwise the event is dropped as spoofed.
function Bridge.OnExplosion(cb, isActive)
    AddEventHandler('explosionEvent', function(sender, ev)
        -- Cheapest early-out: no streamers live => skip all coord work.
        if isActive and not isActive() then return end
        local src = tonumber(sender)
        if not src or src <= 0 or not ev then return end
        local senderCoords = Bridge.GetCoords(src)
        if not senderCoords then return end

        local coords = senderCoords
        if ev.posX and ev.posY and ev.posZ then
            local claimed = { x = ev.posX + 0.0, y = ev.posY + 0.0, z = ev.posZ + 0.0 }
            if Bridge.Distance(senderCoords, claimed) > EVENT_POS_TOLERANCE then return end
            coords = claimed
        end

        cb({ src = src, coords = coords })
    end)
end
