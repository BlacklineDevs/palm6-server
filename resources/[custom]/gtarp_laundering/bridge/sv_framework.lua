-- ============================================================================
-- gtarp_laundering/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / ox_inventory / qbx_police / ox_lib or server-side game natives.
-- server/main.lua holds the laundering logic and calls Bridge.* only, so a
-- port to GTA VI is a rewrite of THIS FILE. See docs/GTA6-READINESS.md §3.
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

-- List of server ids of on-duty police (fallback dispatch fan-out).
local function onDutyPolice()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        local p = getPlayer(sid)
        local job = p and p.PlayerData and p.PlayerData.job
        if job and job.name == 'police' and job.onduty then
            out[#out + 1] = sid
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Money + inventory
-- ---------------------------------------------------------------------------

-- Credit CLEAN funds to the player's bank (the wash output). Returns true if
-- applied. The caller is always the online command source, so this only fails
-- if the framework object is unexpectedly gone.
function Bridge.CreditBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('bank', amount, reason)
    return true
end

-- Presence check: can ox_inventory resolve this item name? Used at boot to
-- self-disable loudly if the dirty-money item isn't registered.
function Bridge.ItemExists(name)
    local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
    return ok and item ~= nil
end

-- How many of a plain (count-based) item the player holds. black_money is
-- count == dollars, so this is the player's total dirty balance.
function Bridge.CountItem(src, name)
    local ok, n = pcall(function()
        return exports.ox_inventory:Search(src, 'count', name)
    end)
    return ok and (tonumber(n) or 0) or 0
end

-- Remove exactly `count` of a plain item. Returns true only if ox reports the
-- removal succeeded — the logic layer credits nothing it didn't actually take.
function Bridge.RemoveItem(src, name, count)
    local ok, removed = pcall(function()
        return exports.ox_inventory:RemoveItem(src, name, count)
    end)
    return ok and removed and true or false
end

-- Give `count` of a plain item back (the refund path when a bank credit fails
-- after the dirty money was already pulled).
function Bridge.GiveItem(src, name, count)
    local ok, added = pcall(function()
        return exports.ox_inventory:AddItem(src, name, count)
    end)
    return ok and added and true or false
end

-- ---------------------------------------------------------------------------
-- Police alerting (heat outcome). Reuses the exact cornerselling/counterfeit
-- contract: police:server:policeAlert derives the alert/blip coords from
-- arg 3 (the suspect's source) server-side. Falls back to a direct dispatch
-- fan-out to on-duty police when qbx_police isn't running.
-- ---------------------------------------------------------------------------
function Bridge.PoliceAlert(src, text)
    if GetResourceState('qbx_police') == 'started' then
        local ok = pcall(function()
            TriggerEvent('police:server:policeAlert', text, nil, src)
        end)
        if ok then return end
    end
    local ped = GetPlayerPed(src)
    local c = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not c then return end
    for _, sid in ipairs(onDutyPolice()) do
        TriggerClientEvent('gtarp_laundering:dispatch', sid, {
            coords = { x = c.x, y = c.y, z = c.z }, label = text,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Presence / world
-- ---------------------------------------------------------------------------

-- Caller's ped position as {x,y,z}, or nil. Server-side anti-abuse proximity —
-- never trust a client-supplied position.
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
        print(('[gtarp_laundering] %s: %s'):format(title, msg))
        return
    end
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating is server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
