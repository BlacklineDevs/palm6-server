-- ============================================================================
-- gtarp_courier/server/main.lua
--
-- Player-run delivery board. Postings are persisted in MySQL via oxmysql.
-- ============================================================================

local Postings = {}  -- id -> posting (snapshot from DB, refreshed on mutation)

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

local function getCitizenId(src)
    local p = getPlayer(src)
    if not p then return nil end
    return p.PlayerData and p.PlayerData.citizenid or nil
end

local function chargePoster(src, amount)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (p.PlayerData.money.bank or 0) < amount then return false end
    return p.Functions.RemoveMoney('bank', amount, 'courier-escrow')
end

local function refundPoster(citizenid, amount)
    -- Find the online player for citizenid; if offline, deposit via direct
    -- DB write so the refund isn't lost.
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData.citizenid == citizenid then
            p.Functions.AddMoney('bank', amount, 'courier-refund')
            return true
        end
    end
    MySQL.update.await(
        "UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money,'$.bank') AS UNSIGNED) + ?) WHERE citizenid = ?",
        { amount, citizenid }
    )
    return true
end

local function payCourier(src, amount)
    local p = getPlayer(src)
    if p and p.Functions then
        p.Functions.AddMoney('bank', amount, 'courier-payout')
    end
end

local function loadPostings()
    local rows = MySQL.query.await('SELECT * FROM courier_postings WHERE status = ?', { 'open' })
    Postings = {}
    if rows then
        for _, r in ipairs(rows) do Postings[r.id] = r end
    end
    print(('[gtarp_courier] loaded %d open postings'):format(#(rows or {})))
end

local function countActiveByCitizen(citizenid)
    local n = 0
    for _, p in pairs(Postings) do
        if p.poster_citizenid == citizenid and p.status == 'open' then n = n + 1 end
    end
    return n
end

local function notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- ---------------------------------------------------------------------------
-- Net events
-- ---------------------------------------------------------------------------

RegisterNetEvent('gtarp_courier:post', function(payload)
    local src = source
    local citizenid = getCitizenId(src)
    if not citizenid then return notify(src, 'Courier', 'Player not loaded', 'error') end

    local b = tonumber(payload and payload.bounty) or 0
    if b < Config.BountyBounds.min or b > Config.BountyBounds.max then
        return notify(src, 'Courier', ('Bounty must be %d..%d'):format(
            Config.BountyBounds.min, Config.BountyBounds.max), 'error')
    end
    if countActiveByCitizen(citizenid) >= Config.MaxPostingsPerPlayer then
        return notify(src, 'Courier', 'Too many active postings', 'error')
    end
    if type(payload.pickup) ~= 'table' or type(payload.dropoff) ~= 'table' then
        return notify(src, 'Courier', 'Invalid pickup/dropoff', 'error')
    end

    if not chargePoster(src, b) then
        return notify(src, 'Courier', 'Insufficient bank balance for escrow', 'error')
    end

    local id = MySQL.insert.await(
        "INSERT INTO courier_postings (poster_citizenid, bounty, pickup_x, pickup_y, pickup_z, dropoff_x, dropoff_y, dropoff_z, label, status, created_at) VALUES (?,?,?,?,?,?,?,?,?, 'open', NOW())",
        {
            citizenid, b,
            payload.pickup.x, payload.pickup.y, payload.pickup.z,
            payload.dropoff.x, payload.dropoff.y, payload.dropoff.z,
            tostring(payload.label or 'Package'),
        }
    )
    loadPostings()
    notify(src, 'Courier', ('Posted #%d for $%d'):format(id, b), 'success')
end)

RegisterNetEvent('gtarp_courier:accept', function(id)
    local src = source
    local citizenid = getCitizenId(src)
    if not citizenid then return end
    local row = Postings[id]
    if not row or row.status ~= 'open' then
        return notify(src, 'Courier', 'Posting unavailable', 'error')
    end
    if row.poster_citizenid == citizenid then
        return notify(src, 'Courier', 'Cannot accept your own posting', 'error')
    end
    MySQL.update.await(
        "UPDATE courier_postings SET status='taken', courier_citizenid=?, accepted_at=NOW() WHERE id=? AND status='open'",
        { citizenid, id }
    )
    loadPostings()
    TriggerClientEvent('gtarp_courier:onAccepted', src, {
        id = id,
        dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z },
        label = row.label,
    })
end)

RegisterNetEvent('gtarp_courier:complete', function(id)
    local src = source
    local citizenid = getCitizenId(src)
    if not citizenid then return end
    local row = MySQL.single.await('SELECT * FROM courier_postings WHERE id=?', { id })
    if not row or row.status ~= 'taken' or row.courier_citizenid ~= citizenid then
        return notify(src, 'Courier', 'Not your active delivery', 'error')
    end
    MySQL.update.await(
        "UPDATE courier_postings SET status='complete', completed_at=NOW() WHERE id=?",
        { id }
    )
    payCourier(src, row.bounty)
    loadPostings()
    notify(src, 'Courier', ('Delivered. +$%d'):format(row.bounty), 'success')
end)

RegisterNetEvent('gtarp_courier:cancel', function(id)
    local src = source
    local citizenid = getCitizenId(src)
    if not citizenid then return end
    local row = Postings[id]
    if not row or row.status ~= 'open' or row.poster_citizenid ~= citizenid then
        return notify(src, 'Courier', 'Cannot cancel that posting', 'error')
    end
    MySQL.update.await("UPDATE courier_postings SET status='cancelled' WHERE id=?", { id })
    refundPoster(citizenid, row.bounty)
    loadPostings()
    notify(src, 'Courier', 'Posting cancelled, bounty refunded', 'success')
end)

-- ---------------------------------------------------------------------------
-- List / chat command
-- ---------------------------------------------------------------------------

RegisterCommand('courier', function(source, args)
    if source == 0 then
        print(('[gtarp_courier] %d open postings'):format(
            (function() local n = 0; for _ in pairs(Postings) do n = n + 1 end; return n end)()))
        return
    end
    local sub = args[1]
    if sub == 'list' or not sub then
        local n = 0
        for id, r in pairs(Postings) do
            if r.status == 'open' then
                TriggerClientEvent('chat:addMessage', source, {
                    args = { 'courier', ('#%d  $%d  %s'):format(id, r.bounty, r.label or 'Package') },
                })
                n = n + 1
            end
        end
        if n == 0 then notify(source, 'Courier', 'No open postings', 'inform') end
    elseif sub == 'accept' and args[2] then
        local id = tonumber(args[2])
        if id then TriggerEvent('gtarp_courier:accept', { source = source }, id) end
    end
end, false)

-- ---------------------------------------------------------------------------
-- Lifetime sweep — refunds posts older than Config.PostingLifetimeMinutes
-- ---------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(60000)
        local expired = MySQL.query.await(
            "SELECT id, poster_citizenid, bounty FROM courier_postings WHERE status='open' AND created_at < (NOW() - INTERVAL ? MINUTE)",
            { Config.PostingLifetimeMinutes }
        )
        if expired then
            for _, r in ipairs(expired) do
                MySQL.update.await("UPDATE courier_postings SET status='expired' WHERE id=?", { r.id })
                refundPoster(r.poster_citizenid, r.bounty)
            end
            if #expired > 0 then loadPostings() end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    loadPostings()
end)

exports('GetOpenPostings', function() return Postings end)
