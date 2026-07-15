-- ============================================================================
-- palm6_courier/server/main.lua
--
-- Player-run delivery board. Pure business logic: postings cache, net
-- events, lifetime sweep. All framework money/identity/notify calls go
-- through Bridge.* (bridge/sv_framework.lua) so this file is engine- and
-- framework-agnostic. Our own courier_postings SQL stays here — it is our
-- schema, fully portable. See docs/GTA6-READINESS.md.
-- ============================================================================

local Postings = {}  -- id -> posting (snapshot from DB, refreshed on mutation)

local function loadPostings()
    local rows = MySQL.query.await('SELECT * FROM courier_postings WHERE status = ?', { 'open' })
    Postings = {}
    if rows then
        for _, r in ipairs(rows) do Postings[r.id] = r end
    end
    print(('[palm6_courier] loaded %d open postings'):format(#(rows or {})))
end

local function countActiveByCitizen(citizenid)
    local n = 0
    for _, p in pairs(Postings) do
        if p.poster_citizenid == citizenid and p.status == 'open' then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Net events
-- ---------------------------------------------------------------------------

RegisterNetEvent('palm6_courier:post', function(payload)
    local src = source
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return Bridge.Notify(src, 'Courier', 'Player not loaded', 'error') end

    local b = tonumber(payload and payload.bounty)
    -- reject nil / NaN (b~=b) / +-inf / non-integer BEFORE the range check:
    -- for NaN both `NaN < min` and `NaN > max` are false, so a NaN would slip
    -- past a bare range guard and poison the bank balance (RemoveMoney(NaN)).
    if type(b) ~= 'number' or b ~= b or b == math.huge or b == -math.huge
        or b % 1 ~= 0 or b < Config.BountyBounds.min or b > Config.BountyBounds.max then
        return Bridge.Notify(src, 'Courier', ('Bounty must be a whole number %d..%d'):format(
            Config.BountyBounds.min, Config.BountyBounds.max), 'error')
    end
    if countActiveByCitizen(citizenid) >= Config.MaxPostingsPerPlayer then
        return Bridge.Notify(src, 'Courier', 'Too many active postings', 'error')
    end
    if type(payload.pickup) ~= 'table' or type(payload.dropoff) ~= 'table' then
        return Bridge.Notify(src, 'Courier', 'Invalid pickup/dropoff', 'error')
    end

    if not Bridge.ChargeBank(src, b, 'courier-escrow') then
        return Bridge.Notify(src, 'Courier', 'Insufficient bank balance for escrow', 'error')
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
    Bridge.Notify(src, 'Courier', ('Posted #%d for $%d'):format(id, b), 'success')
end)

-- Accept a posting on behalf of player `src`. Shared by the net event and
-- the /courier accept command so both paths carry the real player source.
local function acceptPosting(src, id)
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    local row = Postings[id]
    if not row or row.status ~= 'open' then
        return Bridge.Notify(src, 'Courier', 'Posting unavailable', 'error')
    end
    if row.poster_citizenid == citizenid then
        return Bridge.Notify(src, 'Courier', 'Cannot accept your own posting', 'error')
    end
    -- The local Postings cache can be stale if two couriers race the same
    -- posting: both read status='open' before either write lands. The
    -- UPDATE's own WHERE status='open' is the real atomic gate — only one
    -- of the two racing UPDATEs affects a row. Check that before telling
    -- THIS courier they won, or the loser gets a false "accepted" blip for
    -- a delivery the DB actually assigned to someone else.
    local marked = MySQL.update.await(
        "UPDATE courier_postings SET status='taken', courier_citizenid=?, accepted_at=NOW() WHERE id=? AND status='open'",
        { citizenid, id }
    ) == 1
    loadPostings()
    if not marked then
        return Bridge.Notify(src, 'Courier', 'Posting unavailable', 'error')
    end
    TriggerClientEvent('palm6_courier:onAccepted', src, {
        id = id,
        dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z },
        label = row.label,
    })
end

RegisterNetEvent('palm6_courier:accept', function(id)
    acceptPosting(source, id)
end)

RegisterNetEvent('palm6_courier:complete', function(id)
    local src = source
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    -- Validate + cache-first (mirror accept/cancel): reject non-numeric ids and
    -- deliveries this player doesn't hold BEFORE any DB read, so a modified client
    -- can't flood the shared DB pool by looping this event with junk ids (DoS).
    local nid = tonumber(id)
    if not nid then return end
    local cached = Postings[nid]
    if not cached or cached.status ~= 'taken' or cached.courier_citizenid ~= citizenid then
        return Bridge.Notify(src, 'Courier', 'Not your active delivery', 'error')
    end
    local row = MySQL.single.await('SELECT * FROM courier_postings WHERE id=?', { nid })
    if not row or row.status ~= 'taken' or row.courier_citizenid ~= citizenid then
        return Bridge.Notify(src, 'Courier', 'Not your active delivery', 'error')
    end

    -- The client only fires this after ITS OWN distance check passes — that
    -- is presentation, not proof. A modified client can call this event the
    -- instant a delivery is accepted and collect the bounty from anywhere.
    -- Re-check arrival against the server's own read of the courier's
    -- position before paying out real money.
    local here = Bridge.GetCoords(src)
    local dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z }
    if not here or Bridge.Distance(here, dropoff) > (Config.DeliveryRadiusMeters + Config.DeliveryArrivalSlack) then
        return Bridge.Notify(src, 'Courier', 'You are not at the dropoff yet.', 'error')
    end

    local paid = MySQL.update.await(
        "UPDATE courier_postings SET status='complete', completed_at=NOW() WHERE id=? AND status='taken' AND courier_citizenid=?",
        { nid, citizenid }
    ) == 1
    if not paid then
        return Bridge.Notify(src, 'Courier', 'Not your active delivery', 'error')
    end
    Bridge.CreditBank(src, row.bounty, 'courier-payout')
    loadPostings()
    Bridge.Notify(src, 'Courier', ('Delivered. +$%d'):format(row.bounty), 'success')
end)

RegisterNetEvent('palm6_courier:cancel', function(id)
    local src = source
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    local row = Postings[id]
    if not row or row.status ~= 'open' or row.poster_citizenid ~= citizenid then
        return Bridge.Notify(src, 'Courier', 'Cannot cancel that posting', 'error')
    end
    local refunded = MySQL.update.await(
        "UPDATE courier_postings SET status='cancelled' WHERE id=? AND status='open' AND poster_citizenid=?",
        { id, citizenid }
    ) == 1
    if not refunded then
        loadPostings()
        return Bridge.Notify(src, 'Courier', 'Cannot cancel that posting', 'error')
    end
    Bridge.CreditBankByCitizenId(citizenid, row.bounty, 'courier-refund')
    loadPostings()
    Bridge.Notify(src, 'Courier', 'Posting cancelled, bounty refunded', 'success')
end)

-- ---------------------------------------------------------------------------
-- List / chat command
-- ---------------------------------------------------------------------------

RegisterCommand('courier', function(source, args)
    if source == 0 then
        print(('[palm6_courier] %d open postings'):format(
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
        if n == 0 then Bridge.Notify(source, 'Courier', 'No open postings', 'inform') end
    elseif sub == 'accept' and args[2] then
        local id = tonumber(args[2])
        if id then acceptPosting(source, id) end
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
                if MySQL.update.await("UPDATE courier_postings SET status='expired' WHERE id=? AND status='open'", { r.id }) == 1 then
                    Bridge.CreditBankByCitizenId(r.poster_citizenid, r.bounty, 'courier-refund')
                end
            end
            if #expired > 0 then loadPostings() end
        end

        -- 'taken' postings have no other expiry path: a courier who accepts
        -- and then goes idle/logs off/never travels locks the poster's
        -- escrow forever otherwise. Sweep those too, on a longer clock.
        local abandoned = MySQL.query.await(
            "SELECT id, poster_citizenid, bounty FROM courier_postings WHERE status='taken' AND accepted_at < (NOW() - INTERVAL ? MINUTE)",
            { Config.AcceptedLifetimeMinutes }
        )
        if abandoned then
            for _, r in ipairs(abandoned) do
                if MySQL.update.await("UPDATE courier_postings SET status='expired' WHERE id=? AND status='taken'", { r.id }) == 1 then
                    Bridge.CreditBankByCitizenId(r.poster_citizenid, r.bounty, 'courier-refund-abandoned')
                end
            end
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
