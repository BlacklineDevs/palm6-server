-- ============================================================================
-- gtarp_housing/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that knows about
-- qbx_core, the qbx money API, or server-side player natives (routing
-- buckets). server/main.lua calls Bridge.* only — the property lifecycle,
-- access model, and our own `properties` SQL are untouched. To port to GTA VI,
-- rewrite THIS FILE against the new money/identity API and instancing native.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id used as the property owner / access key, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData then return nil end
    return p.PlayerData.citizenid
end

-- Bank balance for an online source, or nil if not loaded.
function Bridge.GetBankBalance(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData or not p.PlayerData.money then return nil end
    return p.PlayerData.money.bank or 0
end

-- Debit `amount` from the source's bank. Returns true on success, false if
-- unaffordable or the player isn't loaded. Preserves the affordability check.
function Bridge.ChargeBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (p.PlayerData.money.bank or 0) < amount then return false end
    return p.Functions.RemoveMoney('bank', amount, reason) and true or false
end

-- Credit `amount` to the source's bank. Returns true if applied.
function Bridge.CreditBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('bank', amount, reason)
    return true
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Put a player into an instance so overlapping shell interiors don't collide.
-- bucket 0 is the shared world. Wraps the server-side routing-bucket native.
function Bridge.SetRoutingBucket(src, bucket)
    SetPlayerRoutingBucket(src, bucket or 0)
end

-- Current coords of a player's ped as {x,y,z}, or nil. Used for the
-- server-side proximity guard on buy/enter.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

-- Distance in metres between two {x,y,z}/{x,y,z,w} tables.
function Bridge.Distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

-- Register a per-property inventory stash with ox_inventory.
function Bridge.RegisterStash(id, label, slots, maxWeight)
    pcall(function()
        exports.ox_inventory:RegisterStash(id, label, slots or 50, maxWeight or 100000)
    end)
end
