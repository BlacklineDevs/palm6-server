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
-- Recoverable settlement (claim-before-credit).
--
-- Every bank move in this resource (the courier payout + all three poster
-- refunds) runs through settlePosting so it is crash-recoverable and callable
-- from BOTH the live path (right after the terminal status flip) AND the boot
-- reconcile. The `settled` idempotency flag is CLAIMED atomically BEFORE the
-- money moves — UPDATE ... SET settled=1 WHERE id=? AND status='<terminal>'
-- AND settled=0 returns 1 to exactly one caller — so a replay can NEVER
-- double-pay: an already-settled row has settled=1 and is skipped. The payee
-- is recomputed from the row itself, so a boot replay is deterministic:
--   status='complete'            -> pay the courier (bounty -> courier_citizenid)
--   status='cancelled'/'expired' -> refund the poster (bounty -> poster_citizenid)
--
-- Bias (matching palm6_fightclub's settleMatch / palm6_courier's escrow model):
-- a crash in the tiny window between claiming the flag and the bank credit costs
-- that one payout — a rare self-inflicted shortfall, never a mint — while the
-- common crash (after the status flip, before settle ran) is fully recovered on
-- the next boot. Credits go through CreditBankByCitizenId so an offline courier
-- or poster is still paid on recovery.
--
-- Returns true iff WE claimed this row (and therefore issued its credit).
local function settlePosting(row, refundReason)
    if not row or not row.id or not row.status then return false end
    local status = row.status
    -- Claim BEFORE credit: this UPDATE is the atomic idempotency gate. If it
    -- doesn't return 1 (someone else settled it, or the status changed under
    -- us), we pay nothing.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE courier_postings SET settled=1 WHERE id=? AND status=? AND settled=0",
            { row.id, status }) == 1
    end)
    if not claimed then return false end

    if status == 'complete' then
        -- Only a truly-completed delivery pays the courier. A 'complete' row
        -- with no courier_citizenid is anomalous (a delivery is only ever
        -- flipped to 'complete' with the courier set) — we claim it so the
        -- reconcile won't reconsider it, but pay no one.
        if row.courier_citizenid and row.courier_citizenid ~= '' then
            Bridge.CreditBankByCitizenId(row.courier_citizenid, row.bounty, 'courier-payout')
        end
    else
        -- 'cancelled' / 'expired' -> refund the poster's escrow.
        Bridge.CreditBankByCitizenId(row.poster_citizenid, row.bounty, refundReason or 'courier-refund')
    end
    return true
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
        pickup = { x = row.pickup_x, y = row.pickup_y, z = row.pickup_z },
        dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z },
        label = row.label,
    })
end

RegisterNetEvent('palm6_courier:accept', function(id)
    acceptPosting(source, id)
end)

-- Pickup leg: the courier must physically visit the pickup before the delivery
-- can be completed. Sets a persisted picked_up flag (server-verified proximity),
-- then routes the client to the dropoff. Mirrors :complete's guards.
local lastPickup = {}  -- [src] = ts — per-source rate limit (anti-DoS)

RegisterNetEvent('palm6_courier:pickup', function(id)
    local src = source
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    local nid = tonumber(id)
    if not nid then return end
    local ctNow = os.time()
    if ctNow - (lastPickup[src] or 0) < 1 then return end
    lastPickup[src] = ctNow
    local row = MySQL.single.await('SELECT * FROM courier_postings WHERE id=?', { nid })
    if not row or row.status ~= 'taken' or row.courier_citizenid ~= citizenid then
        return Bridge.Notify(src, 'Courier', 'Not your active delivery', 'error')
    end
    -- Already collected (e.g. a client re-sync) — just point them at the dropoff.
    if tonumber(row.picked_up) == 1 then
        return TriggerClientEvent('palm6_courier:onPickedUp', src, {
            id = nid, dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z }, label = row.label })
    end
    -- Server-authoritative proximity to the pickup (client distance is presentation).
    local here = Bridge.GetCoords(src)
    local pickup = { x = row.pickup_x, y = row.pickup_y, z = row.pickup_z }
    if not here or Bridge.Distance(here, pickup) > (Config.DeliveryRadiusMeters + Config.DeliveryArrivalSlack) then
        return Bridge.Notify(src, 'Courier', 'You are not at the pickup yet.', 'error')
    end
    -- Atomic set; picked_up=0 guard means a race can only flip it once.
    MySQL.update.await(
        "UPDATE courier_postings SET picked_up=1 WHERE id=? AND status='taken' AND courier_citizenid=? AND picked_up=0",
        { nid, citizenid })
    TriggerClientEvent('palm6_courier:onPickedUp', src, {
        id = nid, dropoff = { x = row.dropoff_x, y = row.dropoff_y, z = row.dropoff_z }, label = row.label })
    Bridge.Notify(src, 'Courier', 'Package picked up. Head to the dropoff.', 'success')
end)

local lastComplete = {}  -- [src] = ts — per-source rate limit on :complete (anti-DoS)

RegisterNetEvent('palm6_courier:complete', function(id)
    local src = source
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    -- Reject non-numeric ids + rate-limit BEFORE the DB read so a modified client
    -- can't flood the shared DB pool by looping this event (DoS). NOTE: we must NOT
    -- cache-gate here — the Postings cache holds only status='open' rows, but a
    -- deliverable is status='taken' (purged from the cache on accept), so a
    -- cache-first check rejects EVERY legitimate delivery. The DB read + the
    -- WHERE status='taken' AND courier_citizenid=? guard below are authoritative.
    local nid = tonumber(id)
    if not nid then return end
    local ctNow = os.time()
    if ctNow - (lastComplete[src] or 0) < 1 then return end
    lastComplete[src] = ctNow
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

    -- Must have collected the package first (server-verified at the pickup). A
    -- modified client that skips straight to :complete is stopped here.
    if tonumber(row.picked_up) ~= 1 then
        return Bridge.Notify(src, 'Courier', 'You never picked up the package — collect it first.', 'error')
    end

    local paid = MySQL.update.await(
        "UPDATE courier_postings SET status='complete', settled=0, completed_at=NOW() WHERE id=? AND status='taken' AND courier_citizenid=? AND picked_up=1",
        { nid, citizenid }
    ) == 1
    if not paid then
        return Bridge.Notify(src, 'Courier', 'Not your active delivery', 'error')
    end
    -- Claim-before-credit: the terminal flip above already landed, so the row is
    -- status='complete' AND settled=0; settlePosting claims settled=1 and pays
    -- the courier by citizenid. On a crash before this ran, the boot reconcile
    -- re-drives it. (settled was just added to the table, so the live claim
    -- always wins here.)
    settlePosting({
        id = nid, status = 'complete',
        courier_citizenid = citizenid, poster_citizenid = row.poster_citizenid,
        bounty = row.bounty,
    })
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
        "UPDATE courier_postings SET status='cancelled', settled=0 WHERE id=? AND status='open' AND poster_citizenid=?",
        { id, citizenid }
    ) == 1
    if not refunded then
        loadPostings()
        return Bridge.Notify(src, 'Courier', 'Cannot cancel that posting', 'error')
    end
    -- Claim-before-credit refund; recoverable on boot if we crash before it runs.
    settlePosting({ id = id, status = 'cancelled', poster_citizenid = citizenid, bounty = row.bounty })
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
                if MySQL.update.await("UPDATE courier_postings SET status='expired', settled=0 WHERE id=? AND status='open'", { r.id }) == 1 then
                    -- Claim-before-credit refund; recoverable on boot.
                    settlePosting({ id = r.id, status = 'expired', poster_citizenid = r.poster_citizenid, bounty = r.bounty }, 'courier-refund')
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
                if MySQL.update.await("UPDATE courier_postings SET status='expired', settled=0 WHERE id=? AND status='taken'", { r.id }) == 1 then
                    -- Claim-before-credit refund; recoverable on boot. Keeps the
                    -- distinct 'courier-refund-abandoned' money-log reason on the
                    -- live path (a boot reconcile can't tell an abandoned expiry
                    -- from a lifetime one — both are status='expired' — so it
                    -- falls back to the generic 'courier-refund' label).
                    settlePosting({ id = r.id, status = 'expired', poster_citizenid = r.poster_citizenid, bounty = r.bounty }, 'courier-refund-abandoned')
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Boot reconcile — re-drive any terminal posting whose payout/refund never
-- landed (server died in the window between the status flip and settlePosting).
-- Idempotent: settlePosting claims settled=1 BEFORE crediting, so this only
-- pays what a crash left owing and can never double-pay an already-settled row.
-- A 'complete' row pays the courier only if courier_citizenid is set; every
-- 'cancelled'/'expired' row refunds the poster.
-- ---------------------------------------------------------------------------
local function reconcileUnsettled()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            "SELECT id, status, poster_citizenid, courier_citizenid, bounty FROM courier_postings WHERE status IN ('complete','cancelled','expired') AND settled=0") or {}
    end)
    local n = 0
    for _, row in ipairs(pending) do
        if settlePosting(row) then n = n + 1 end
    end
    if n > 0 then
        print(('[palm6_courier] boot reconcile settled %d interrupted payout(s)'):format(n))
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    loadPostings()
    -- Recover any terminal posting whose payout/refund was interrupted by the
    -- last restart. Delayed so palm6_dbmigrate's 0056 ALTER (the `settled`
    -- column) has landed first — before that the WHERE settled=0 query errors
    -- (pcall-swallowed) and recovers nothing. Non-time-critical, so wait it out.
    CreateThread(function()
        Wait(8000)
        reconcileUnsettled()
    end)
end)

exports('GetOpenPostings', function() return Postings end)
