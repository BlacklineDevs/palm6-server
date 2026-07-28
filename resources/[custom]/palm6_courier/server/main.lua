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

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a new box boots with no
-- courier_postings at all. The old failure mode was ONE boot-time Lua error
-- from the unguarded loadPostings() and then nothing: the board showed no
-- postings forever, with no line saying why. Loud once, then silent - which is
-- silence by the time an operator looks. On the live box these statements are
-- pure no-ops.
--
-- The DDL is copied VERBATIM from sql/0006_courier.sql, plus the two
-- idempotent ALTERs from sql/0050_courier_pickup.sql and
-- sql/0056_courier_settlement.sql. The ALTERs are repeated here (they also
-- live in palm6_dbmigrate) because dbmigrate and this resource boot on
-- independent threads: whichever runs second is a no-op, and neither can lose
-- the race. settled DEFAULT 1 is load-bearing and must NOT be changed to 0 -
-- see the long note in sql/0056: DEFAULT 0 would make the boot reconcile
-- re-pay the entire terminal history exactly once.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- Statements THIS resource owns and can answer for. Only these feed
    -- SchemaReady. See the ALTER note below for why they are kept separate.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `courier_postings` (
    `id`                 INT AUTO_INCREMENT PRIMARY KEY,
    `poster_citizenid`   VARCHAR(50) NOT NULL,
    `courier_citizenid`  VARCHAR(50) DEFAULT NULL,
    `bounty`             INT NOT NULL,
    `pickup_x`           DOUBLE NOT NULL,
    `pickup_y`           DOUBLE NOT NULL,
    `pickup_z`           DOUBLE NOT NULL,
    `dropoff_x`          DOUBLE NOT NULL,
    `dropoff_y`          DOUBLE NOT NULL,
    `dropoff_z`          DOUBLE NOT NULL,
    `label`              VARCHAR(100) DEFAULT 'Package',
    `status`             ENUM('open','taken','complete','cancelled','expired') NOT NULL DEFAULT 'open',
    `created_at`         DATETIME NOT NULL,
    `accepted_at`        DATETIME DEFAULT NULL,
    `completed_at`       DATETIME DEFAULT NULL,
    KEY `idx_status_created` (`status`, `created_at`),
    KEY `idx_poster`         (`poster_citizenid`),
    KEY `idx_courier`        (`courier_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists. Folding these into SchemaReady made a perfectly healthy
    -- MySQL box print `schema MISSING` on every single boot, which is the
    -- permanent-false-alarm failure that trains an operator to ignore the
    -- banner (the same argument palm6_perf/server/tables.lua makes in its
    -- header). courier_postings is the table this resource owns and is what
    -- SchemaReady answers for; these two columns are additive and their
    -- absence is reported on its own line instead. Same pattern as
    -- palm6_mdt/server/main.lua's schemaOk.
    local alters = {
        [[
ALTER TABLE `courier_postings`
    ADD COLUMN IF NOT EXISTS `picked_up` TINYINT NOT NULL DEFAULT 0
        ]],
        [[
ALTER TABLE `courier_postings`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_courier] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_courier] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local PostingsLoaded = false  -- true once a load has actually populated the cache

local function loadPostings()
    local rows = MySQL.query.await('SELECT * FROM courier_postings WHERE status = ?', { 'open' })
    Postings = {}
    if rows then
        for _, r in ipairs(rows) do Postings[r.id] = r end
    end
    PostingsLoaded = true  -- set LAST: a throw above must leave this false
    print(('[palm6_courier] loaded %d open postings'):format(#(rows or {})))
end

-- Counts a poster's live postings for the MaxPostingsPerPlayer cap.
--
-- The cache is EMPTY until the boot load lands, and that load runs ~3s after
-- onResourceStart because it has to wait for oxmysql's connection. A
-- cache-only count would therefore report 0 for everyone during those 3s, so
-- an `ensure palm6_courier` with players online would open a window where the
-- per-player cap is not enforced at all. Until the cache is authoritative we
-- ask the DB instead; if that query fails we return the cap itself so the
-- caller refuses the post. No count, no posting.
local function countActiveByCitizen(citizenid)
    if not PostingsLoaded then
        local n
        local ok = pcall(function()
            n = MySQL.scalar.await(
                "SELECT COUNT(*) FROM courier_postings WHERE poster_citizenid = ? AND status = 'open'",
                { citizenid })
        end)
        if not ok or not tonumber(n) then return Config.MaxPostingsPerPlayer end
        return tonumber(n)
    end
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
-- Client-supplied coordinate validation.
--
-- A posting's pickup/dropoff come straight off the client, and until this
-- existed the ONLY check was `type(payload.pickup) ~= 'table'` - the x/y/z
-- members themselves were never looked at. A table carrying NaN, +-inf, a
-- string, or nil members sailed through, the escrow was charged, and then the
-- INSERT either exploded (uncaught, money gone) or stored a coordinate no
-- courier can ever reach (money locked until the abandoned sweep).
--
-- BOUNDS ONLY. We reject a bad coordinate, we never substitute one: silently
-- moving another player's delivery to 0,0,0 would be worse than refusing the
-- post, because the poster paid for a run to somewhere they picked. The
-- envelope matches palm6_mapeditor's cleanPlacement (server/live.lua:86-97)
-- so both agree on what "inside the world" means.
--
-- Returns the three numbers on success (normalised via tonumber so the INSERT
-- binds numerics, not whatever type the client sent), or nil on rejection.
-- NaN fails every comparison so it is tested explicitly; +-inf is caught by
-- the range checks.
local function cleanCoords(c)
    if type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not x or not y or not z then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    if x < -20000.0 or x > 20000.0 then return nil end
    if y < -20000.0 or y > 20000.0 then return nil end
    if z < -2000.0 or z > 5000.0 then return nil end
    return x, y, z
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
    -- Validate the coordinates BEFORE the escrow is charged. Order matters: the
    -- charge below is real money, so every reason to refuse the post has to be
    -- known first, or we take the money for a posting we then cannot store.
    local pux, puy, puz = cleanCoords(payload and payload.pickup)
    local dox, doy, doz = cleanCoords(payload and payload.dropoff)
    if not pux or not dox then
        return Bridge.Notify(src, 'Courier', 'Invalid pickup/dropoff', 'error')
    end
    -- `label` lands in a VARCHAR(100) column (sql/0006_courier.sql). Uncapped, a
    -- long client string makes the INSERT fail outright under strict mode - and
    -- the INSERT now happens after the charge, so an avoidable failure there is
    -- an avoidable refund.
    --
    -- :sub() counts BYTES, not characters. Under utf8mb4 a blind 100-byte cut
    -- can slice a multi-byte sequence in half and MySQL then rejects the row
    -- with "Incorrect string value" anyway, landing us in the failure path
    -- below for a post we could have accepted. So: reject a label that is not
    -- valid UTF-8 outright (before the charge, per the ordering note above),
    -- and when we do cut, walk the tail back to a whole character. The walk is
    -- at most 3 bytes and only runs on input that WAS valid, so it can never
    -- eat a label down to nothing.
    local label = tostring(payload.label or 'Package')
    if not utf8.len(label) then
        return Bridge.Notify(src, 'Courier', 'Invalid label', 'error')
    end
    if #label > 100 then
        label = label:sub(1, 100)
        while #label > 0 and not utf8.len(label) do label = label:sub(1, #label - 1) end
    end

    if not Bridge.ChargeBank(src, b, 'courier-escrow') then
        return Bridge.Notify(src, 'Courier', 'Insufficient bank balance for escrow', 'error')
    end

    -- The escrow is already gone by this line. An unguarded INSERT that throws
    -- (DB pool down, courier_postings missing on a fresh box, column drift)
    -- would eat the poster's money with no row to ever refund it from, and no
    -- boot reconcile can recover what was never written. pcall it, and on
    -- failure hand the escrow back through the same CreditBankByCitizenId path
    -- settlePosting uses, with its own money-log reason so a support ticket can
    -- tell a failed post from a cancelled one - but ONLY once we have proved
    -- the row is not there. See the confirm step below.
    local ok, id = pcall(function()
        return MySQL.insert.await(
            "INSERT INTO courier_postings (poster_citizenid, bounty, pickup_x, pickup_y, pickup_z, dropoff_x, dropoff_y, dropoff_z, label, status, created_at) VALUES (?,?,?,?,?,?,?,?,?, 'open', NOW())",
            {
                citizenid, b,
                pux, puy, puz,
                dox, doy, doz,
                label,
            }
        )
    end)
    if not ok or not tonumber(id) then
        -- A throw does NOT prove the INSERT did not land. An oxmysql query
        -- timeout or a connection drop raises just as readily AFTER the
        -- statement executed, and refunding on that path is a MINT: the escrow
        -- goes back to the poster while a live status='open' row with their
        -- citizenid sits on the board, and one /cancel later settlePosting
        -- credits the same bounty a second time. That inverts this file's
        -- stated money bias (see the settlePosting note above: "a rare
        -- self-inflicted shortfall, never a mint").
        --
        -- So: refund only when we can prove no row landed. The confirm looks
        -- for a still-open posting of ours with the same bounty and label from
        -- the last two minutes. Two ways it declines to refund, both on the
        -- safe side of the bias:
        --   * a matching row IS there  -> the INSERT actually succeeded, the
        --     escrow is correctly attached to a real posting, and the poster
        --     can /cancel it for the normal single refund.
        --   * the confirm itself fails -> we cannot tell, so we keep the money
        --     where it is and print a line an operator can settle by hand.
        -- The one false negative (the poster already had an identical open
        -- posting from the last two minutes) costs that poster their escrow
        -- until staff settle it. A shortfall, never a mint.
        local confirmed, orphan = pcall(function()
            return MySQL.scalar.await(
                "SELECT id FROM courier_postings WHERE poster_citizenid = ? AND bounty = ? AND label = ? AND status = 'open' AND created_at >= (NOW() - INTERVAL 2 MINUTE) ORDER BY id DESC LIMIT 1",
                { citizenid, b, label })
        end)
        if confirmed and not orphan then
            Bridge.CreditBankByCitizenId(citizenid, b, 'courier-refund-postfailed')
            print(('[palm6_courier] post INSERT failed for %s with no row written, escrow $%d refunded: %s')
                :format(citizenid, b, tostring(id)))
            return Bridge.Notify(src, 'Courier', 'Could not save the posting. Your escrow was refunded.', 'error')
        end
        -- Either the row landed or we cannot tell. Refresh the cache so a row
        -- that DID land appears on the board and stays cancellable (:cancel
        -- reads Postings, so an unloaded row is an unrefundable one).
        pcall(loadPostings)
        print(('^1[palm6_courier] post INSERT for %s ($%d) reported failure but a matching open row may exist (confirm ok=%s, existing id=%s) - escrow NOT auto-refunded, settle by hand: %s^0')
            :format(citizenid, b, tostring(confirmed), tostring(orphan), tostring(id)))
        return Bridge.Notify(src, 'Courier',
            'Could not confirm your posting. Check the board before posting again - if it is there, cancel it to get your escrow back.', 'error')
    end
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
    -- Recover any terminal posting whose payout/refund was interrupted by the
    -- last restart. Delayed so palm6_dbmigrate's 0056 ALTER (the `settled`
    -- column) has landed first — before that the WHERE settled=0 query errors
    -- (pcall-swallowed) and recovers nothing. Non-time-critical, so wait it out.
    --
    -- The whole boot sequence now runs on this thread because ensureSchema has
    -- to Wait for oxmysql's connection before any query, and loadPostings must
    -- not run before the table is guaranteed to exist.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It exists to diagnose the fresh-box case where the
        -- table is absent, and with loadPostings() called unguarded ahead of
        -- it that was the ONE case it could not report: the SELECT raised,
        -- killed this thread, and took both the banner and the reconcile with
        -- it. Same ordering as palm6_evidence and palm6_staff. loadPostings is
        -- now pcall'd for the second half of that: a boot-time DB failure must
        -- not cost us reconcileUnsettled(), which is what pays out the money a
        -- crash left owing.
        if not SchemaReady then
            print('^1[palm6_courier] schema MISSING - the delivery board is INERT on this box.^0')
        end
        pcall(loadPostings)
        Wait(5000)
        reconcileUnsettled()
    end)
end)

exports('GetOpenPostings', function() return Postings end)
