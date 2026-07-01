-- ============================================================================
-- gtarp_housing/server/main.lua
--
-- Property lifecycle: seed the for-sale catalog, buy/sell, access keys, and
-- instanced shell entry/exit. Pure logic — all framework/native access goes
-- through Bridge.* (bridge/sv_framework.lua). Our own `properties` table
-- (sql/0010_properties.sql) is portable, so it stays here.
-- ============================================================================

local properties = {}     -- [id] = { id, owner, street, region, shell, price,
                          --          for_sale, door={x,y,z,w}, access={cid,...} }
local playerInside = {}   -- [src] = propId  (who is currently in a shell)

local BUCKET_BASE = 1000  -- routing bucket for property id N = BUCKET_BASE + N

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function contains(list, v)
    for i = 1, #list do if list[i] == v then return true end end
    return false
end

local function stashId(id) return ('property_%d'):format(id) end

local function registerStash(p)
    Bridge.RegisterStash(stashId(p.id), ('Property — %s'):format(p.street or p.id), 50, 100000)
end

-- Build the per-player view (relation is computed for THIS player's cid).
local function viewFor(cid)
    local out = {}
    for _, p in pairs(properties) do
        local relation = 'none'
        if p.owner and p.owner == cid then relation = 'owned'
        elseif contains(p.access, cid) then relation = 'keyed'
        elseif p.for_sale == 1 then relation = 'forsale' end
        out[#out + 1] = {
            id = p.id, door = p.door, street = p.street, region = p.region,
            shell = p.shell, price = p.price, for_sale = p.for_sale,
            owned = (relation == 'owned'), relation = relation,
            -- only the owner sees the key list
            access = (relation == 'owned') and p.access or nil,
        }
    end
    return out
end

local function syncTo(src)
    local cid = Bridge.GetCitizenId(src)
    TriggerClientEvent('gtarp_housing:sync', src, viewFor(cid))
end

local function syncAll()
    for _, src in ipairs(GetPlayers()) do syncTo(tonumber(src)) end
end

-- ---------------------------------------------------------------------------
-- load + seed
-- ---------------------------------------------------------------------------
local function loadAll()
    properties = {}
    local rows = MySQL.query.await('SELECT * FROM properties') or {}
    for _, r in ipairs(rows) do
        local doorOk, door = pcall(json.decode, r.coords or 'null')
        local accOk, access = pcall(json.decode, r.has_access or '[]')
        properties[r.id] = {
            id = r.id, owner = r.owner, street = r.street, region = r.region,
            shell = r.shell, price = r.price or 0, for_sale = r.for_sale or 0,
            door = (doorOk and door) or nil,
            access = (accOk and type(access) == 'table') and access or {},
        }
        registerStash(properties[r.id])
    end
end

-- Ensure a DB row exists for each catalog entry (keyed by `apartment`).
local function ensureCatalog()
    for _, c in ipairs(Config.Properties) do
        local existing = MySQL.single.await(
            'SELECT id FROM properties WHERE apartment = ? LIMIT 1', { c.apartment })
        if not existing then
            local door = json.encode({ x = c.door.x, y = c.door.y, z = c.door.z, w = c.door.w })
            MySQL.insert.await(
                'INSERT INTO properties (owner, street, region, has_access, for_sale, price, shell, apartment, coords) \z
                 VALUES (NULL, ?, ?, ?, 1, ?, ?, ?, ?)',
                { c.street, c.region, '[]', c.price, c.shell, c.apartment, door })
        end
    end
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    ensureCatalog()
    loadAll()
    local count = 0
    for _ in pairs(properties) do count = count + 1 end
    print(('[gtarp_housing] loaded %d properties'):format(count))
end)

RegisterNetEvent('gtarp_housing:requestSync', function()
    syncTo(source)
end)

-- ---------------------------------------------------------------------------
-- proximity guard (server-side anti-abuse)
-- ---------------------------------------------------------------------------
local function nearDoor(src, p)
    local c = Bridge.GetCoords(src)
    if not c or not p.door then return true end  -- can't verify -> allow
    return Bridge.Distance(c, p.door) <= (Config.InteractRadius + 4.0)
end

-- ---------------------------------------------------------------------------
-- buy / sell
-- ---------------------------------------------------------------------------
RegisterNetEvent('gtarp_housing:buy', function(propId)
    local src = source
    local p = properties[propId]
    if not p then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if p.for_sale ~= 1 or p.owner then
        Bridge.Notify(src, 'Housing', 'That property is not for sale.', 'error'); return
    end
    if not nearDoor(src, p) then
        Bridge.Notify(src, 'Housing', 'You are too far from the property.', 'error'); return
    end
    local bal = Bridge.GetBankBalance(src)
    if not bal or bal < p.price then
        Bridge.Notify(src, 'Housing', ('You need $%d in the bank.'):format(p.price), 'error'); return
    end
    if not Bridge.ChargeBank(src, p.price, 'property-purchase') then
        Bridge.Notify(src, 'Housing', 'Payment failed.', 'error'); return
    end
    p.owner = cid; p.for_sale = 0; p.access = {}
    MySQL.update.await('UPDATE properties SET owner = ?, for_sale = 0, has_access = ? WHERE id = ?',
        { cid, '[]', propId })
    Bridge.Notify(src, 'Housing', ('Purchased %s for $%d.'):format(p.street, p.price), 'success')
    syncAll()
end)

RegisterNetEvent('gtarp_housing:sell', function(propId)
    local src = source
    local p = properties[propId]
    if not p then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or p.owner ~= cid then
        Bridge.Notify(src, 'Housing', 'You do not own that property.', 'error'); return
    end
    local refund = math.floor((p.price or 0) * (Config.SellBackRate or 0.5))
    Bridge.CreditBank(src, refund, 'property-sellback')
    p.owner = nil; p.for_sale = 1; p.access = {}
    MySQL.update.await('UPDATE properties SET owner = NULL, for_sale = 1, has_access = ? WHERE id = ?',
        { '[]', propId })
    Bridge.Notify(src, 'Housing', ('Sold %s back for $%d.'):format(p.street, refund), 'success')
    syncAll()
end)

-- ---------------------------------------------------------------------------
-- access keys
-- ---------------------------------------------------------------------------
local function persistAccess(p)
    MySQL.update.await('UPDATE properties SET has_access = ? WHERE id = ?',
        { json.encode(p.access), p.id })
end

RegisterNetEvent('gtarp_housing:grantAccess', function(propId, targetServerId)
    local src = source
    local p = properties[propId]
    if not p then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or p.owner ~= cid then
        Bridge.Notify(src, 'Housing', 'Only the owner can grant keys.', 'error'); return
    end
    local targetCid = Bridge.GetCitizenId(tonumber(targetServerId))
    if not targetCid then
        Bridge.Notify(src, 'Housing', 'That player is not nearby / online.', 'error'); return
    end
    if targetCid == cid or contains(p.access, targetCid) then
        Bridge.Notify(src, 'Housing', 'They already have a key.', 'error'); return
    end
    p.access[#p.access + 1] = targetCid
    persistAccess(p)
    Bridge.Notify(src, 'Housing', 'Key granted.', 'success')
    Bridge.Notify(tonumber(targetServerId), 'Housing', ('You received a key to %s.'):format(p.street), 'success')
    syncAll()
end)

RegisterNetEvent('gtarp_housing:revokeAccess', function(propId, targetCid)
    local src = source
    local p = properties[propId]
    if not p then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or p.owner ~= cid then
        Bridge.Notify(src, 'Housing', 'Only the owner can revoke keys.', 'error'); return
    end
    local kept = {}
    for i = 1, #p.access do if p.access[i] ~= targetCid then kept[#kept + 1] = p.access[i] end end
    p.access = kept
    persistAccess(p)
    Bridge.Notify(src, 'Housing', 'Key revoked.', 'success')
    syncAll()
end)

-- ---------------------------------------------------------------------------
-- enter / exit (instanced shell)
-- ---------------------------------------------------------------------------
local function canEnter(p, cid)
    return p.owner == cid or contains(p.access, cid)
end

RegisterNetEvent('gtarp_housing:enter', function(propId)
    local src = source
    local p = properties[propId]
    if not p then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or not canEnter(p, cid) then
        Bridge.Notify(src, 'Housing', 'You do not have a key to this property.', 'error'); return
    end
    if not nearDoor(src, p) then
        Bridge.Notify(src, 'Housing', 'You are too far from the door.', 'error'); return
    end
    local shell = Config.Shells[p.shell]
    if not shell then
        Bridge.Notify(src, 'Housing', 'This property has no interior configured.', 'error'); return
    end
    Bridge.SetRoutingBucket(src, BUCKET_BASE + p.id)
    playerInside[src] = p.id
    TriggerClientEvent('gtarp_housing:teleport', src, shell.interior)
end)

RegisterNetEvent('gtarp_housing:exit', function()
    local src = source
    local propId = playerInside[src]
    if not propId then return end
    local p = properties[propId]
    Bridge.SetRoutingBucket(src, 0)
    playerInside[src] = nil
    if p and p.door then
        TriggerClientEvent('gtarp_housing:teleport', src, p.door)
    end
end)

RegisterNetEvent('gtarp_housing:openStash', function()
    local src = source
    local propId = playerInside[src]
    if not propId then
        Bridge.Notify(src, 'Housing', 'You must be inside a property.', 'error'); return
    end
    local p = properties[propId]
    local cid = Bridge.GetCitizenId(src)
    if not p or not canEnter(p, cid) then return end
    TriggerClientEvent('gtarp_housing:openStash', src, stashId(propId))
end)

AddEventHandler('playerDropped', function()
    local src = source
    if playerInside[src] then
        Bridge.SetRoutingBucket(src, 0)  -- best effort; player is leaving anyway
        playerInside[src] = nil
    end
end)
