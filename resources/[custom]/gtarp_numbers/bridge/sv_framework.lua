-- ============================================================================
-- gtarp_numbers/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / ox_inventory / ox_lib or server-side natives. server/main.lua
-- (the racket logic — bets, the draw, claims) calls Bridge.* only, so a port
-- to GTA VI is a rewrite of THIS FILE. See docs/GTA6-READINESS.md §3.
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

-- Server id currently playing `citizenid`, or nil (offline). Used to notify a
-- winner at draw time; offline winners simply collect later.
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

-- Take `amount` clean cash as the stake. ATOMIC: qbx RemoveMoney returns false
-- (and removes nothing) when the player can't cover it, so this is the only
-- funds check needed — no separate read-then-remove race.
function Bridge.TakeCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    local ok = p.Functions.RemoveMoney('cash', amount, reason)
    return ok == true
end

-- Refund clean cash (bet rejected after the stake was pulled — should be rare).
function Bridge.GiveCash(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('cash', amount, reason)
    return true
end

-- Presence check: can ox_inventory resolve this item name? Boot self-disable.
function Bridge.ItemExists(name)
    local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
    return ok and item ~= nil
end

-- Pay dirty winnings (black_money, plain count == dollars). Returns true if it
-- all fit. black_money carries no weight, so this effectively never fails, but
-- the caller still only marks a bet paid when this returns true.
function Bridge.GiveItem(src, name, count)
    local ok, added = pcall(function()
        return exports.ox_inventory:AddItem(src, name, count)
    end)
    return ok and added and true or false
end

-- Caller's ped position as {x,y,z}, or nil (server-side proximity — never
-- trust a client-supplied coordinate).
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Bridge.Distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

-- Notify a player (src 0 = server console).
function Bridge.Notify(src, title, msg, t)
    if src == 0 then
        print(('[gtarp_numbers] %s: %s'):format(title, msg))
        return
    end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Soft hype broadcast to the gtarp_discord announcer (tolerated absent; a feed
-- with no webhook convar set is a silent no-op inside the announcer).
function Bridge.Announce(feed, payload)
    if GetResourceState('gtarp_discord') ~= 'started' then return end
    pcall(function() exports.gtarp_discord:Announce(feed, payload) end)
end

-- High-resolution server timer (ms since server start). Mixed into the
-- per-draw RNG reseed as an entropy source a client can't observe — see the
-- reseed in server/main.lua runDraw() (defeats boot-seed prediction of draws).
function Bridge.GameTimer()
    return GetGameTimer()
end

-- Unrestricted chat command (all gating is server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
