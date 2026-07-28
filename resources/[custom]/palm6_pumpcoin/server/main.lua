-- ============================================================================
-- palm6_pumpcoin/server/main.lua
--
-- Back-alley memecoin exchange: player-issued tokens on a server-side
-- bonding curve. Price is pure in-game supply and demand — early buyers
-- profit only if later buyers come in. Creators hold a hidden dev wallet;
-- dumping it in one clip is a RUG that broadcasts to every holder and
-- reveals the creator after an anonymity window. Coins force-delist after
-- Config.CoinLifetimeDays with a pro-rata settlement.
--
-- Pure logic — every framework/native call goes through Bridge.* (§6 gate).
-- Our own palm6_pumpcoin_* SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
--
-- Server authority: every charge/credit, proximity gate, cooldown, holding
-- check, and curve computation happens HERE. The NUI/client only ever sends
-- intents (coin id + unit count); it is never trusted for prices, balances,
-- discounts, or identity.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local Coins = {}            -- coin id -> record (live + rugged; delisted drop out)
local Locks = {}            -- coin id -> true while a fill/settlement is in flight
local Shills = {}           -- coin id -> { expires = epoch }
local Billboards = {}       -- billboard id -> { coords, label, expires } (DB-backed)
local Cooldowns = {}        -- citizenid -> { key -> epoch of last accepted use }

-- In-flight ticker reservations. The uniqueness scan below only reads the
-- in-memory Coins table, and Coins[coinId] is not populated until AFTER
-- isVerifiedCreator's (conditional) turf query and two DB inserts yield —
-- without this, two players racing to mint the identical ticker both pass
-- the uniqueness check in the same window and both land live coins sharing
-- one ticker (there is no DB UNIQUE constraint on ticker: it must stay
-- reusable after a delist, so the guard has to be this in-memory reservation,
-- same idiom as palm6_counterfeit's placingPrinter). Cleared on every exit
-- path below.
local MintingTickers = {}   -- ticker -> true while its mint insert is in flight

local DAY = 86400

local SchemaReady = false   -- flipped by ensureSchema(); reported in the boot banner
-- Flipped true once the coin board has been loaded from the DB. The load now
-- sits behind the boot thread's Wait(3000) (ensureSchema has to create the
-- tables before anything reads them), and until it runs `Coins` is EMPTY.
-- An empty Coins does not just show an empty board: the mint handler derives
-- ticker uniqueness, Config.MaxLiveCoins and Config.MaxCoinsPerCreator by
-- scanning it, so minting in that window would bypass all three caps and could
-- land a duplicate ticker on the board. The mint handler is gated on this flag.
local bootReady = false

local function now() return os.time() end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a new box boots with no
-- palm6_pumpcoin_* tables. Almost every write here is pcall-wrapped, so the
-- damage is near-silent and financial: a mint charges $MintCost, the insert
-- fails, and the refund path fires (fine) - but a BUY debits the bank inside
-- the coin lock and persists the holding separately, and the boot reconcile
-- that finishes an interrupted delist payout reads coins/holdings, so with the
-- tables absent no holder is ever settled and nothing says why. On the live box
-- these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0014_pumpcoin.sql (coins, holdings, trades) and
-- sql/0053_pumpcoin_billboards.sql, plus the additive ALTERs from
-- sql/0063_pumpcoin_delist_settlement.sql. Trailing semicolons dropped, same as
-- the other resources that carry their own DDL. 0053 is also embedded in
-- palm6_dbmigrate, which that file notes; both are IF NOT EXISTS so whichever
-- runs second no-ops.
--
-- Only the tables this resource OWNS are created here. palm6_turf (read for the
-- VERIFIED badge) and palm6_evidence (the rug-reveal fraud entry) belong to
-- those resources and are created by their own boot DDL, the same way
-- palm6_courier and palm6_evidence each create only their own.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_pumpcoin_coins` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(32) NOT NULL,
    ticker VARCHAR(8) NOT NULL,
    emoji VARCHAR(16) NOT NULL,
    creator_citizenid VARCHAR(64) NOT NULL,
    creator_name VARCHAR(100) NOT NULL,
    -- Bonding-curve parameters, frozen at mint time.
    base_price DECIMAL(12,2) NOT NULL,
    curve_k INT UNSIGNED NOT NULL,
    -- Units currently on the curve (includes the dev premine). Total units
    -- held across all holders always equals this number.
    supply_sold INT UNSIGNED NOT NULL DEFAULT 0,
    -- Units premined to the creator's hidden dev wallet at mint.
    dev_allocation INT UNSIGNED NOT NULL DEFAULT 0,
    -- 1 when the creator's gang held enough turf at mint (palm6_turf synergy).
    verified TINYINT(1) NOT NULL DEFAULT 0,
    status ENUM('live','rugged','delisted') NOT NULL DEFAULT 'live',
    rugged_at TIMESTAMP NULL DEFAULT NULL,
    -- 1 once the post-rug anonymity window has elapsed and the creator's
    -- identity has been broadcast.
    revealed TINYINT(1) NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    delisted_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_pumpcoin_coins_status (status),
    INDEX idx_palm6_pumpcoin_coins_creator (creator_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_pumpcoin_holdings` (
    coin_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    units INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (coin_id, citizenid),
    INDEX idx_palm6_pumpcoin_holdings_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_pumpcoin_trades` (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    coin_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    side ENUM('mint','buy','sell','rug','delist') NOT NULL,
    units INT UNSIGNED NOT NULL,
    -- Average unit price for this fill (pre-fee), for the chart.
    unit_price DECIMAL(12,2) NOT NULL,
    -- What actually moved in/out of the player's bank (post-fee, whole $).
    total INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_pumpcoin_trades_coin (coin_id, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_pumpcoin_billboards` (
    `id`         INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    `coord_x`    DOUBLE      NOT NULL,
    `coord_y`    DOUBLE      NOT NULL,
    `coord_z`    DOUBLE      NOT NULL,
    `label`      VARCHAR(64) NOT NULL,
    `expires_at` BIGINT      NOT NULL,
    INDEX `idx_palm6_pumpcoin_billboards_exp` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists. Folding these into SchemaReady would make a perfectly
    -- healthy MySQL box print `schema MISSING` on every boot, which is the
    -- permanent-false-alarm failure that trains an operator to ignore the
    -- banner. The CREATE TABLEs above are what this resource owns and what
    -- SchemaReady answers for; these three columns are the delist-settlement
    -- markers from 0063 and their absence is reported on its own line. Same
    -- pattern as palm6_mdt/server/main.lua's schemaOk.
    local alters = {
        [[
ALTER TABLE `palm6_pumpcoin_holdings`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 0
        ]],
        [[
ALTER TABLE `palm6_pumpcoin_coins`
    ADD COLUMN IF NOT EXISTS `delist_pool` BIGINT NULL DEFAULT NULL
        ]],
        [[
ALTER TABLE `palm6_pumpcoin_coins`
    ADD COLUMN IF NOT EXISTS `delist_supply` INT UNSIGNED NULL DEFAULT NULL
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_pumpcoin] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_pumpcoin] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- Soft dependency: exchange posts go out iff palm6_discord is running with
-- the 'market' feed configured. Never blocks or errors exchange flows.
local function discordAnnounce(payload)
    if GetResourceState('palm6_discord') ~= 'started' then return end
    pcall(function() exports.palm6_discord:Announce('market', payload) end)
end

local function dbg(...)
    if Config.Debug then print('[palm6_pumpcoin]', ...) end
end

-- ---------------------------------------------------------------------------
-- Cooldowns (server-side rate limits, keyed by character not source)
-- ---------------------------------------------------------------------------

-- Check-and-consume: returns true (and rejects) if still cooling down,
-- otherwise stamps now and returns false.
local function onCooldown(cid, key, secs)
    local c = Cooldowns[cid]
    if not c then c = {} Cooldowns[cid] = c end
    local t = now()
    if c[key] and (t - c[key]) < secs then return true end
    c[key] = t
    return false
end

-- Un-stamp a consumed cooldown (used when the gated action later fails for
-- reasons that were not the player's spam — e.g. a DB error).
local function refundCooldown(cid, key)
    local c = Cooldowns[cid]
    if c then c[key] = nil end
end

-- ---------------------------------------------------------------------------
-- Bonding curve math (exact integrals — no per-unit loops)
--   price(s)     = base * (1 + s/k)^2
--   reserve(s)   = ∫0..s price = base * k/3 * ((1 + s/k)^3 - 1)
-- ---------------------------------------------------------------------------

local function curveReserve(coin, s)
    local k = coin.curve_k
    return coin.base_price * k / 3.0 * ((1 + s / k) ^ 3 - 1)
end

local function spotPrice(coin, s)
    s = s or coin.supply_sold
    return coin.base_price * (1 + s / coin.curve_k) ^ 2
end

-- Pre-fee cost to buy `units` starting from the coin's current supply.
local function buyGross(coin, units)
    return curveReserve(coin, coin.supply_sold + units) - curveReserve(coin, coin.supply_sold)
end

-- Pre-fee proceeds for selling `units` down from the current supply.
local function sellGross(coin, units)
    return curveReserve(coin, coin.supply_sold) - curveReserve(coin, coin.supply_sold - units)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Serialize all supply-mutating work per coin. The critical sections yield
-- on DB awaits, so without this two concurrent fills could read the same
-- supply. The lock is released on EVERY path, including errors. Returns
-- false only when the lock was already held (caller should say "busy").
local function withCoinLock(coinId, fn)
    if Locks[coinId] then return false end
    Locks[coinId] = true
    local ok, err = pcall(fn)
    Locks[coinId] = nil
    if not ok then print(('[palm6_pumpcoin] locked section error (coin %s): %s'):format(coinId, err)) end
    return true
end

-- Server-side proximity gate: is this source actually at an exchange
-- terminal? (+3.0 slack over the client prompt radius, like palm6_evidence.)
local function nearExchange(src)
    local coords = Bridge.GetCoords(src)
    if not coords then return false end
    for _, ex in ipairs(Config.Exchanges) do
        if Bridge.Distance(coords, ex) <= (Config.InteractRadius + 3.0) then return true end
    end
    return false
end

local function findLiveCoinByTicker(ticker)
    for _, coin in pairs(Coins) do
        if coin.status == 'live' and coin.ticker == ticker then return coin end
    end
    return nil
end

-- Round for display (2dp); money that actually moves is whole dollars.
local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

-- Effective street-shill discount, clamped so a discounted buy + immediate
-- sell of the same units can NEVER round-trip at a profit. Both legs
-- integrate the identical curve segment, so the buyer pays
-- gross*(1-d)*(1+fee) and the seller receives gross*(1-fee): the trip
-- prints house money whenever d > 2*fee/(1+fee) (~3.92% at the 2% default
-- fee), and the only self-deal guard (cid ~= creator) is trivially bypassed
-- by an alt or accomplice standing in the shill radius. Cap the discount at
-- 80% of break-even so every round-trip strictly loses money no matter how
-- Config is tuned.
local function shillDiscount()
    local breakEven = 2 * Config.TradeFeePct / (1 + Config.TradeFeePct)
    return math.min(Config.ShillDiscountPct, breakEven * 0.8)
end

-- ---------------------------------------------------------------------------
-- Delist settlement (recoverable) — claim-before-credit per holder.
--
-- Pays each still-unsettled holder of a delisted coin their curve-reserve
-- share, claiming holdings.settled 0 -> 1 BEFORE the bank credit so a boot
-- reconcile can re-drive a crash-interrupted delist without ever paying a
-- holder twice. `pool`/`supply` are the delist-time snapshot (stored on the
-- coin row) so shares are identical on replay. Returns holders credited.
-- ---------------------------------------------------------------------------
local function settleDelistHolders(coinId, ticker, pool, supply, finalPrice)
    if not supply or supply <= 0 then return 0 end
    local holders = {}
    pcall(function()
        holders = MySQL.query.await(
            'SELECT citizenid, units FROM palm6_pumpcoin_holdings WHERE coin_id = ? AND units > 0 AND settled = 0',
            { coinId }) or {}
    end)
    local n = 0
    for _, h in ipairs(holders) do
        local claimed = false
        pcall(function()
            claimed = MySQL.update.await(
                'UPDATE palm6_pumpcoin_holdings SET settled = 1 WHERE coin_id = ? AND citizenid = ? AND settled = 0',
                { coinId, h.citizenid }) == 1
        end)
        if claimed then
            n = n + 1
            local share = math.floor(pool * (h.units / supply) * (1 - Config.TradeFeePct))
            if share > 0 then
                Bridge.CreditBankByCitizenId(h.citizenid, share, 'pumpcoin-delist-' .. ticker)
            end
            pcall(function()
                MySQL.insert.await(
                    'INSERT INTO palm6_pumpcoin_trades (coin_id, citizenid, side, units, unit_price, total) VALUES (?, ?, ?, ?, ?, ?)',
                    { coinId, h.citizenid, 'delist', h.units, finalPrice, share })
            end)
            local s = Bridge.GetSourceByCitizenId(h.citizenid)
            if s then
                Bridge.Notify(s, 'Exchange',
                    ('$%s hit end-of-life and was delisted. Your %d units settled for $%d.')
                    :format(ticker, h.units, share), 'inform')
            end
        end
    end
    return n
end

-- Boot reconcile — finish paying any delist interrupted by the last restart.
-- Delisted coins now keep their holdings (settled flag) + the pool/supply
-- basis, so we re-settle only the still-unpaid holders idempotently.
local function reconcileDelists()
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT c.id AS id, c.ticker AS ticker, c.delist_pool AS delist_pool, c.delist_supply AS delist_supply
              FROM palm6_pumpcoin_coins c
             WHERE c.status = 'delisted' AND c.delist_pool IS NOT NULL AND c.delist_supply IS NOT NULL
               AND EXISTS (SELECT 1 FROM palm6_pumpcoin_holdings h
                            WHERE h.coin_id = c.id AND h.units > 0 AND h.settled = 0)
        ]]) or {}
    end)
    local total = 0
    for _, c in ipairs(rows) do
        local supply = tonumber(c.delist_supply) or 0
        local pool = tonumber(c.delist_pool) or 0
        if supply > 0 then
            total = total + settleDelistHolders(c.id, c.ticker, pool, supply, round2(pool / supply))
        end
    end
    if total > 0 then
        print(('[palm6_pumpcoin] boot reconcile settled %d interrupted delist holder(s)'):format(total))
    end
end

-- ---------------------------------------------------------------------------
-- Boot: load live+rugged coins, sanity-check the premine economics
-- ---------------------------------------------------------------------------
-- Loads the coin board + billboards into memory. Split out of onResourceStart
-- because it must run AFTER ensureSchema, which has to Wait for oxmysql's
-- connection first. Sets bootReady on the way out (see its declaration).
local function loadBoard()
    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT id, name, ticker, emoji, creator_citizenid, creator_name,
                   base_price + 0 AS base_price, curve_k, supply_sold,
                   dev_allocation, verified, status, revealed,
                   UNIX_TIMESTAMP(created_at) AS created_ts,
                   UNIX_TIMESTAMP(rugged_at)  AS rugged_ts
            FROM palm6_pumpcoin_coins
            WHERE status <> 'delisted'
        ]])
    end)
    if not ok then
        -- bootReady stays false: minting must NOT run against a board we
        -- failed to load, or the live-coin and per-creator caps are bypassed.
        print('[palm6_pumpcoin] ERROR loading coins — is sql/0014_pumpcoin.sql applied?')
        return
    end

    local n = 0
    for _, r in ipairs(rows or {}) do
        r.base_price = tonumber(r.base_price) or Config.BasePrice
        r.curve_k = tonumber(r.curve_k) or Config.CurveK
        r.supply_sold = tonumber(r.supply_sold) or 0
        Coins[r.id] = r
        n = n + 1
    end
    print(('[palm6_pumpcoin] exchange online — %d coin(s) on the board'):format(n))

    -- Rehydrate live billboards so a paid $2,500 blip survives a restart.
    pcall(function()
        MySQL.update.await('DELETE FROM palm6_pumpcoin_billboards WHERE expires_at <= ?', { now() })
        local bs = MySQL.query.await(
            'SELECT id, coord_x, coord_y, coord_z, label, expires_at FROM palm6_pumpcoin_billboards') or {}
        for _, r in ipairs(bs) do
            Billboards[tonumber(r.id)] = {
                coords  = { x = tonumber(r.coord_x) or 0.0, y = tonumber(r.coord_y) or 0.0, z = tonumber(r.coord_z) or 0.0 },
                label   = r.label,
                expires = tonumber(r.expires_at) or 0,
            }
        end
    end)

    -- bootReady flips only HERE, below the billboard rehydrate, not above it.
    -- The schema work put this whole function behind Wait(3000) plus several DB
    -- round-trips, while client/main.lua fires requestBillboards exactly once at
    -- its own t=3000 and never retries. Flipping the flag before the rehydrate
    -- would leave requestBillboards answering from an empty Billboards table,
    -- and billboardSync REMOVES every existing blip before adding, so a paid
    -- $2,500 billboard would silently vanish for the rest of its window.
    bootReady = true

    -- Belt and braces: the single-shot client ask can still land before we get
    -- here, so push the set once ourselves. Late joiners keep using the pull.
    local out, t = {}, now()
    for id, b in pairs(Billboards) do
        if b.expires > t then
            out[#out + 1] = { id = id, coords = b.coords, label = b.label }
        end
    end
    TriggerClientEvent('palm6_pumpcoin:billboardSync', -1, out)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Economics guard: the premine's curve value must stay under the mint
    -- cost, or delist settlements pay out more than minting cost (printer).
    local premineValue = Config.BasePrice * Config.CurveK / 3.0
        * ((1 + Config.DevAllocationUnits / Config.CurveK) ^ 3 - 1)
    if premineValue >= Config.MintCost then
        print(('[palm6_pumpcoin] WARNING: dev premine curve value ($%d) >= MintCost ($%d). '
            .. 'Minting is now a money printer at delist — lower DevAllocationUnits or raise MintCost.')
            :format(math.floor(premineValue), Config.MintCost))
    end

    -- Economics guard #2: a shill discount at/over the round-trip fee turns
    -- shill windows into a buy/sell money printer for any alt or accomplice.
    -- The buy handler clamps via shillDiscount(); this just surfaces the
    -- misconfiguration.
    if Config.ShillDiscountPct > shillDiscount() then
        print(('[palm6_pumpcoin] WARNING: ShillDiscountPct (%.1f%%) meets/exceeds the round-trip '
            .. 'trade fee break-even (%.2f%%) — clamping effective discount to %.2f%%.')
            :format(Config.ShillDiscountPct * 100,
                2 * Config.TradeFeePct / (1 + Config.TradeFeePct) * 100,
                shillDiscount() * 100))
    end

    -- The whole DB half of boot runs on this thread: ensureSchema has to Wait
    -- for oxmysql's connection before any query, and loadBoard must not read
    -- palm6_pumpcoin_coins before the table is guaranteed to exist.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        if not SchemaReady then
            print('^1[palm6_pumpcoin] schema MISSING - the exchange is INERT on this box and no ' ..
                  'interrupted delist can be settled.^0')
        end
        loadBoard()
        -- Finish any delist payout the last restart interrupted, once oxmysql +
        -- palm6_dbmigrate (0063 settled/delist_pool/delist_supply columns) are
        -- up. Total wait is unchanged at ~8s from resource start.
        Wait(5000)
        reconcileDelists()
    end)
end)

-- ---------------------------------------------------------------------------
-- Market snapshot for the NUI (per-requester: includes their own holdings
-- and whether each coin is theirs — never anyone else's positions)
-- ---------------------------------------------------------------------------
local function buildMarket(cid)
    local holderCounts = {}
    pcall(function()
        local rows = MySQL.query.await(
            'SELECT coin_id, COUNT(*) AS c FROM palm6_pumpcoin_holdings WHERE units > 0 GROUP BY coin_id')
        for _, r in ipairs(rows or {}) do holderCounts[r.coin_id] = r.c end
    end)

    local mine = {}
    pcall(function()
        local rows = MySQL.query.await(
            'SELECT coin_id, units FROM palm6_pumpcoin_holdings WHERE citizenid = ?', { cid })
        for _, r in ipairs(rows or {}) do mine[r.coin_id] = r.units end
    end)

    local t = now()
    local list = {}
    for id, coin in pairs(Coins) do
        list[#list + 1] = {
            id = id,
            name = coin.name,
            ticker = coin.ticker,
            emoji = coin.emoji,
            price = round2(spotPrice(coin)),
            launchPrice = round2(spotPrice(coin, coin.dev_allocation)),
            supply = coin.supply_sold,
            holders = holderCounts[id] or 0,
            myUnits = mine[id] or 0,
            status = coin.status,
            verified = coin.verified == 1,
            shill = Shills[id] ~= nil and Shills[id].expires > t,
            -- Creators are anonymous until a rug reveal fires.
            creator = coin.revealed == 1 and coin.creator_name or ('anon-%03d'):format(id % 1000),
            mine = coin.creator_citizenid == cid,
            expiresInSec = math.max(0, (coin.created_ts or t) + Config.CoinLifetimeDays * DAY - t),
        }
    end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

local function sendMarket(src, cid)
    TriggerClientEvent('palm6_pumpcoin:data', src, {
        coins = buildMarket(cid),
        bank = Bridge.GetBankBalance(src) or 0,
    })
end

-- ---------------------------------------------------------------------------
-- Open / refresh / chart (all proximity-gated + throttled server-side)
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_pumpcoin:requestOpen', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not nearExchange(src) then
        Bridge.Notify(src, 'Exchange', 'You need to be at an exchange terminal.', 'error')
        return
    end
    if onCooldown(cid, 'data', Config.DataCooldownSec) then return end

    TriggerClientEvent('palm6_pumpcoin:open', src, {
        coins = buildMarket(cid),
        bank = Bridge.GetBankBalance(src) or 0,
        ui = {
            mintCost = Config.MintCost,
            feePct = Config.TradeFeePct,
            maxUnits = Config.MaxTradeUnits,
            devAlloc = Config.DevAllocationUnits,
            lifetimeDays = Config.CoinLifetimeDays,
            emojis = Config.Emojis,
            nameMax = Config.NameMaxLen,
            tickerMax = Config.TickerMaxLen,
        },
    })
end)

RegisterNetEvent('palm6_pumpcoin:requestData', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not nearExchange(src) then return end
    if onCooldown(cid, 'data', Config.DataCooldownSec) then return end
    sendMarket(src, cid)
end)

RegisterNetEvent('palm6_pumpcoin:requestChart', function(data)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not nearExchange(src) then return end
    local coinId = type(data) == 'table' and math.floor(tonumber(data.coinId) or 0) or 0
    if not Coins[coinId] then return end
    if onCooldown(cid, 'chart', Config.DataCooldownSec) then return end

    local points = {}
    pcall(function()
        local rows = MySQL.query.await([[
            SELECT UNIX_TIMESTAMP(created_at) AS t, unit_price + 0 AS p, side
            FROM palm6_pumpcoin_trades WHERE coin_id = ?
            ORDER BY id DESC LIMIT ?
        ]], { coinId, Config.ChartTradeLimit })
        -- Returned newest-first; flip to chronological for the chart.
        for i = #(rows or {}), 1, -1 do
            local r = rows[i]
            points[#points + 1] = { t = r.t, p = tonumber(r.p) or 0, s = r.side }
        end
    end)
    TriggerClientEvent('palm6_pumpcoin:chart', src, { coinId = coinId, points = points })
end)

-- ---------------------------------------------------------------------------
-- Mint: $MintCost buys a listing + the hidden dev premine
-- ---------------------------------------------------------------------------

-- palm6_turf synergy: gang turf dominance at mint == a VERIFIED badge.
-- Soft dependency — any failure (no table, no gang) just means unverified.
local function isVerifiedCreator(src)
    if not Config.VerifiedEnabled then return 0 end
    local gang = Bridge.GetGangName(src)
    if not gang then return 0 end
    local zones = 0
    pcall(function()
        local r = MySQL.scalar.await('SELECT COUNT(*) FROM palm6_turf WHERE owner_gang = ?', { gang })
        zones = tonumber(r) or 0
    end)
    return zones >= Config.VerifiedTurfZones and 1 or 0
end

RegisterNetEvent('palm6_pumpcoin:mint', function(data)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    -- The board is not loaded yet (see bootReady): the ticker-uniqueness scan
    -- and both mint caps below read Coins, so minting now would bypass all
    -- three. Refuse until loadBoard() has run.
    if not bootReady then
        Bridge.Notify(src, 'Exchange', 'The exchange is still opening. Try again in a moment.', 'error')
        return
    end
    if not nearExchange(src) then
        Bridge.Notify(src, 'Exchange', 'You need to be at an exchange terminal.', 'error')
        return
    end
    if type(data) ~= 'table'
        or type(data.name) ~= 'string'
        or type(data.ticker) ~= 'string'
        or type(data.emoji) ~= 'string' then
        return
    end

    -- Sanitize + validate inputs (never trust the NUI).
    local name = data.name:gsub('[^%w %-%._!]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local ticker = data.ticker:upper()
    local emoji = data.emoji

    if #name < Config.NameMinLen or #name > Config.NameMaxLen then
        Bridge.Notify(src, 'Exchange', ('Coin name must be %d-%d characters.'):format(Config.NameMinLen, Config.NameMaxLen), 'error')
        return
    end
    if not ticker:match('^[A-Z0-9]+$') or #ticker < Config.TickerMinLen or #ticker > Config.TickerMaxLen then
        Bridge.Notify(src, 'Exchange', ('Ticker must be %d-%d letters/digits.'):format(Config.TickerMinLen, Config.TickerMaxLen), 'error')
        return
    end
    local emojiOk = false
    for _, e in ipairs(Config.Emojis) do
        if e == emoji then emojiOk = true break end
    end
    if not emojiOk then
        Bridge.Notify(src, 'Exchange', 'Pick an emoji from the list.', 'error')
        return
    end

    -- Caps + ticker uniqueness among non-delisted coins.
    if MintingTickers[ticker] then
        Bridge.Notify(src, 'Exchange', ('$%s is already on the board.'):format(ticker), 'error')
        return
    end
    local liveCount, myCount = 0, 0
    for _, coin in pairs(Coins) do
        if coin.ticker == ticker then
            Bridge.Notify(src, 'Exchange', ('$%s is already on the board.'):format(ticker), 'error')
            return
        end
        if coin.status == 'live' then
            liveCount = liveCount + 1
            if coin.creator_citizenid == cid then myCount = myCount + 1 end
        end
    end
    if liveCount >= Config.MaxLiveCoins then
        Bridge.Notify(src, 'Exchange', 'The board is full. Wait for a delisting.', 'error')
        return
    end
    if myCount >= Config.MaxCoinsPerCreator then
        Bridge.Notify(src, 'Exchange', ('You already run %d live coin(s). Rug or wait.'):format(myCount), 'error')
        return
    end
    if onCooldown(cid, 'mint', Config.MintCooldownSec) then
        Bridge.Notify(src, 'Exchange', 'You minted recently. Cool down.', 'error')
        return
    end

    -- Reserve the ticker for the rest of this mint. Every exit path from here
    -- on must clear it — the success path clears it once Coins[coinId] itself
    -- becomes the permanent record.
    MintingTickers[ticker] = true

    -- Charge, then persist. Refund + un-stamp the cooldown on DB failure.
    if not Bridge.ChargeBank(src, Config.MintCost, 'pumpcoin-mint') then
        MintingTickers[ticker] = nil
        refundCooldown(cid, 'mint')
        Bridge.Notify(src, 'Exchange', ('Minting costs $%d (bank).'):format(Config.MintCost), 'error')
        return
    end

    local creatorName = Bridge.GetPlayerName(src)
    local verified = isVerifiedCreator(src)
    local launchPrice = round2(Config.BasePrice * (1 + Config.DevAllocationUnits / Config.CurveK) ^ 2)

    local coinId
    local ok = pcall(function()
        coinId = MySQL.insert.await([[
            INSERT INTO palm6_pumpcoin_coins
                (name, ticker, emoji, creator_citizenid, creator_name,
                 base_price, curve_k, supply_sold, dev_allocation, verified)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], { name, ticker, emoji, cid, creatorName,
              Config.BasePrice, Config.CurveK,
              Config.DevAllocationUnits, Config.DevAllocationUnits, verified })
        MySQL.insert.await(
            'INSERT INTO palm6_pumpcoin_holdings (coin_id, citizenid, units) VALUES (?, ?, ?)',
            { coinId, cid, Config.DevAllocationUnits })
        MySQL.insert.await(
            'INSERT INTO palm6_pumpcoin_trades (coin_id, citizenid, side, units, unit_price, total) VALUES (?, ?, ?, ?, ?, ?)',
            { coinId, cid, 'mint', Config.DevAllocationUnits, launchPrice, 0 })
    end)

    if not ok or not coinId then
        -- Player may have dropped during the DB awaits — refund by
        -- citizenid (offline-safe) so the mint fee is never kept.
        if not Bridge.CreditBank(src, Config.MintCost, 'pumpcoin-mint-refund') then
            Bridge.CreditBankByCitizenId(cid, Config.MintCost, 'pumpcoin-mint-refund')
        end
        MintingTickers[ticker] = nil
        refundCooldown(cid, 'mint')
        Bridge.Notify(src, 'Exchange', 'Mint failed — you were refunded.', 'error')
        return
    end

    Coins[coinId] = {
        id = coinId, name = name, ticker = ticker, emoji = emoji,
        creator_citizenid = cid, creator_name = creatorName,
        base_price = Config.BasePrice, curve_k = Config.CurveK,
        supply_sold = Config.DevAllocationUnits,
        dev_allocation = Config.DevAllocationUnits,
        verified = verified, status = 'live', revealed = 0,
        created_ts = now(), rugged_ts = nil,
    }
    -- Coins[coinId] is now the permanent authority for this ticker (the
    -- uniqueness scan above sees it on every future mint) — release the
    -- in-flight reservation.
    MintingTickers[ticker] = nil

    dbg(('minted %s ($%s) by %s'):format(name, ticker, cid))
    -- Creator identity stays out of the post — anonymity until a rug
    -- reveal is the whole game.
    discordAnnounce({
        title = ('NEW LISTING — %s $%s %s'):format(name, ticker, emoji),
        description = ('Fresh on the board at $%.2f. Bonding-curve priced — early buys move it. %s')
            :format(launchPrice, verified and 'Verified creator.' or 'Anonymous creator. You know the risks.'),
    })
    Bridge.Notify(src, 'Exchange',
        ('%s $%s is live. Your dev wallet holds %d units. Nobody knows it is you.')
        :format(emoji, ticker, Config.DevAllocationUnits), 'success')
    sendMarket(src, cid)
end)

-- ---------------------------------------------------------------------------
-- Buy
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_pumpcoin:buy', function(data)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if type(data) ~= 'table' then return end

    local coinId = math.floor(tonumber(data.coinId) or 0)
    local units = math.floor(tonumber(data.units) or 0)
    local coin = Coins[coinId]
    if not coin then return end

    -- Positive-form bounds check: NaN fails every comparison, so `units < 1`
    -- style negative checks would let a crafted NaN through.
    if not (units >= 1 and units <= Config.MaxTradeUnits) then
        Bridge.Notify(src, 'Exchange', ('Order size must be 1-%d units.'):format(Config.MaxTradeUnits), 'error')
        return
    end
    if not nearExchange(src) then
        Bridge.Notify(src, 'Exchange', 'You need to be at an exchange terminal.', 'error')
        return
    end
    if coin.status ~= 'live' then
        Bridge.Notify(src, 'Exchange', ('$%s is %s. No more buys.'):format(coin.ticker, coin.status), 'error')
        return
    end
    if coin.supply_sold + units > Config.MaxSupply then
        Bridge.Notify(src, 'Exchange', ('$%s is near max supply.'):format(coin.ticker), 'error')
        return
    end
    if onCooldown(cid, 'trade', Config.TradeCooldownSec) then return end

    local acquired = withCoinLock(coinId, function()
        local gross = buyGross(coin, units)

        -- Street-shill discount: active window AND physically near the
        -- creator RIGHT NOW, checked server-side. Creators can't discount
        -- themselves.
        local discounted = false
        local sh = Shills[coinId]
        if sh and sh.expires > now() and cid ~= coin.creator_citizenid then
            local devSrc = Bridge.GetSourceByCitizenId(coin.creator_citizenid)
            if devSrc then
                local a, b = Bridge.GetCoords(src), Bridge.GetCoords(devSrc)
                if a and b and Bridge.Distance(a, b) <= Config.ShillRadius then
                    gross = gross * (1 - shillDiscount())
                    discounted = true
                end
            end
        end

        -- House rounds in its own favour: buys ceil, sells floor.
        local total = math.ceil(gross * (1 + Config.TradeFeePct))
        if not Bridge.ChargeBank(src, total, 'pumpcoin-buy-' .. coin.ticker) then
            Bridge.Notify(src, 'Exchange', ('That costs $%d (bank).'):format(total), 'error')
            return
        end

        local avgPrice = round2(gross / units)
        local ok = pcall(function()
            MySQL.update.await('UPDATE palm6_pumpcoin_coins SET supply_sold = supply_sold + ? WHERE id = ?',
                { units, coinId })
            MySQL.insert.await([[
                INSERT INTO palm6_pumpcoin_holdings (coin_id, citizenid, units) VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE units = units + VALUES(units)
            ]], { coinId, cid, units })
            MySQL.insert.await(
                'INSERT INTO palm6_pumpcoin_trades (coin_id, citizenid, side, units, unit_price, total) VALUES (?, ?, ?, ?, ?, ?)',
                { coinId, cid, 'buy', units, avgPrice, total })
        end)
        if not ok then
            -- Player may have dropped during the DB awaits — refund by
            -- citizenid (offline-safe) so the charge is never kept.
            if not Bridge.CreditBank(src, total, 'pumpcoin-buy-refund') then
                Bridge.CreditBankByCitizenId(cid, total, 'pumpcoin-buy-refund')
            end
            Bridge.Notify(src, 'Exchange', 'Order failed — you were refunded.', 'error')
            return
        end

        coin.supply_sold = coin.supply_sold + units
        Bridge.Notify(src, 'Exchange',
            ('Bought %d $%s @ ~$%.2f%s — total $%d.')
            :format(units, coin.ticker, avgPrice, discounted and ' (shill discount)' or '', total), 'success')
        sendMarket(src, cid)
    end)
    if not acquired then
        Bridge.Notify(src, 'Exchange', 'Order engine busy — try again.', 'error')
    end
end)

-- ---------------------------------------------------------------------------
-- Sell (and rug detection)
-- ---------------------------------------------------------------------------

-- Broadcast a rug to every online holder of the coin.
local function broadcastRug(coin)
    local holders = {}
    pcall(function()
        holders = MySQL.query.await(
            'SELECT citizenid FROM palm6_pumpcoin_holdings WHERE coin_id = ? AND units > 0',
            { coin.id }) or {}
    end)
    local minutes = math.floor(Config.RevealDelaySec / 60)
    for _, h in ipairs(holders) do
        local s = Bridge.GetSourceByCitizenId(h.citizenid)
        if s then
            Bridge.Notify(s, '🚨 RUGGED',
                ('$%s just got RUGGED — the dev dumped the wallet. Identity revealed in %d minutes.')
                :format(coin.ticker, minutes), 'error')
            TriggerClientEvent('palm6_pumpcoin:rugged', s, { coinId = coin.id, ticker = coin.ticker })
        end
    end
    discordAnnounce({
        title = ('🚨 RUG PULL — $%s %s'):format(coin.ticker, coin.emoji),
        description = ('The dev just dumped the wallet on %d holder(s). Identity hits the public record in %d minutes.')
            :format(#holders, minutes),
    })
end

RegisterNetEvent('palm6_pumpcoin:sell', function(data)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if type(data) ~= 'table' then return end

    local coinId = math.floor(tonumber(data.coinId) or 0)
    local units = math.floor(tonumber(data.units) or 0)
    local coin = Coins[coinId]
    if not coin then return end

    -- Positive-form bounds check (NaN guard — see buy handler).
    if not (units >= 1 and units <= Config.MaxTradeUnits) then
        Bridge.Notify(src, 'Exchange', ('Order size must be 1-%d units.'):format(Config.MaxTradeUnits), 'error')
        return
    end
    if not nearExchange(src) then
        Bridge.Notify(src, 'Exchange', 'You need to be at an exchange terminal.', 'error')
        return
    end
    -- Selling is allowed on live AND rugged coins (dumping into the crater
    -- is part of the drama); only delisted coins are gone.
    if onCooldown(cid, 'trade', Config.TradeCooldownSec) then return end

    local acquired = withCoinLock(coinId, function()
        -- Holdings are the source of truth, read inside the lock.
        local held = 0
        pcall(function()
            local r = MySQL.scalar.await(
                'SELECT units FROM palm6_pumpcoin_holdings WHERE coin_id = ? AND citizenid = ?',
                { coinId, cid })
            held = tonumber(r) or 0
        end)
        if held < units then
            Bridge.Notify(src, 'Exchange', ('You only hold %d $%s.'):format(held, coin.ticker), 'error')
            return
        end
        if units > coin.supply_sold then return end -- invariant guard; cannot happen

        local gross = sellGross(coin, units)
        local proceeds = math.floor(gross * (1 - Config.TradeFeePct))
        local avgPrice = round2(gross / units)

        -- RUG: the creator dumping >= threshold of the original dev
        -- allocation in a single clip.
        local isRug = coin.status == 'live'
            and cid == coin.creator_citizenid
            and units >= math.floor(coin.dev_allocation * Config.RugThresholdPct)

        local ok = pcall(function()
            if isRug then
                MySQL.update.await(
                    "UPDATE palm6_pumpcoin_coins SET supply_sold = supply_sold - ?, status = 'rugged', rugged_at = NOW() WHERE id = ?",
                    { units, coinId })
            else
                MySQL.update.await(
                    'UPDATE palm6_pumpcoin_coins SET supply_sold = supply_sold - ? WHERE id = ?',
                    { units, coinId })
            end
            MySQL.update.await(
                'UPDATE palm6_pumpcoin_holdings SET units = units - ? WHERE coin_id = ? AND citizenid = ?',
                { units, coinId, cid })
            MySQL.update.await(
                'DELETE FROM palm6_pumpcoin_holdings WHERE coin_id = ? AND citizenid = ? AND units = 0',
                { coinId, cid })
            MySQL.insert.await(
                'INSERT INTO palm6_pumpcoin_trades (coin_id, citizenid, side, units, unit_price, total) VALUES (?, ?, ?, ?, ?, ?)',
                { coinId, cid, isRug and 'rug' or 'sell', units, avgPrice, proceeds })
        end)
        if not ok then
            Bridge.Notify(src, 'Exchange', 'Order failed. Nothing moved.', 'error')
            return
        end

        coin.supply_sold = coin.supply_sold - units
        -- The DB awaits above yield: the player may have dropped mid-fill.
        -- Holdings are already deducted and the trade row written, so the
        -- proceeds must not evaporate — credit by citizenid (offline-safe).
        if not Bridge.CreditBank(src, proceeds, 'pumpcoin-sell-' .. coin.ticker) then
            Bridge.CreditBankByCitizenId(cid, proceeds, 'pumpcoin-sell-' .. coin.ticker)
        end

        if isRug then
            coin.status = 'rugged'
            coin.rugged_ts = now()
            dbg(('RUG: %s dumped %d $%s for $%d'):format(cid, units, coin.ticker, proceeds))
            Bridge.Notify(src, 'Exchange',
                ('You rugged $%s for $%d. You have %d minutes before everyone knows.')
                :format(coin.ticker, proceeds, math.floor(Config.RevealDelaySec / 60)), 'warning')
            broadcastRug(coin)
        else
            Bridge.Notify(src, 'Exchange',
                ('Sold %d $%s @ ~$%.2f — you got $%d.'):format(units, coin.ticker, avgPrice, proceeds), 'success')
        end
        sendMarket(src, cid)
    end)
    if not acquired then
        Bridge.Notify(src, 'Exchange', 'Order engine busy — try again.', 'error')
    end
end)

-- ---------------------------------------------------------------------------
-- /shill — start a street-shill window for your own live coin
-- ---------------------------------------------------------------------------
RegisterCommand('shill', function(src, args)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local ticker = tostring(args[1] or ''):upper()
    local coin = findLiveCoinByTicker(ticker)
    if not coin or coin.creator_citizenid ~= cid then
        Bridge.Notify(src, 'Exchange', 'Usage: /shill TICKER — must be a live coin you created.', 'error')
        return
    end
    if onCooldown(cid, 'shill', Config.ShillCooldownSec) then
        Bridge.Notify(src, 'Exchange', 'You are still cooling down from the last shill.', 'error')
        return
    end

    Shills[coin.id] = { expires = now() + Config.ShillDurationSec }
    -- Advertise the EFFECTIVE (clamped) discount, not the raw config value.
    local discountPct = math.floor(shillDiscount() * 100 + 0.5)
    Bridge.Notify(src, 'Exchange',
        ('Shill window open — %ds. Buys within %dm of you get %d%% off. Work the street.')
        :format(Config.ShillDurationSec, math.floor(Config.ShillRadius), discountPct),
        'success')
    -- Global hype ping. Deliberately does not say WHERE — finding the
    -- shiller (and thereby maybe clocking the dev) is the game.
    Bridge.NotifyAll('📢 Street Shill',
        ('$%s %s shill is LIVE — buy within %dm of the shiller in the next %ds for %d%% off.')
        :format(coin.ticker, coin.emoji, math.floor(Config.ShillRadius),
            Config.ShillDurationSec, discountPct), 'inform')
end, false)

-- ---------------------------------------------------------------------------
-- /pumpboard — paid billboard blip at your position for your own live coin
-- ---------------------------------------------------------------------------
RegisterCommand('pumpboard', function(src, args)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local ticker = tostring(args[1] or ''):upper()
    local coin = findLiveCoinByTicker(ticker)
    if not coin or coin.creator_citizenid ~= cid then
        Bridge.Notify(src, 'Exchange', 'Usage: /pumpboard TICKER — must be a live coin you created.', 'error')
        return
    end
    if onCooldown(cid, 'board', Config.BillboardCooldownSec) then
        Bridge.Notify(src, 'Exchange', 'Billboard slot cooling down.', 'error')
        return
    end
    local coords = Bridge.GetCoords(src)
    if not coords then refundCooldown(cid, 'board') return end
    if not Bridge.ChargeBank(src, Config.BillboardCost, 'pumpcoin-billboard') then
        refundCooldown(cid, 'board')
        Bridge.Notify(src, 'Exchange', ('A billboard costs $%d (bank).'):format(Config.BillboardCost), 'error')
        return
    end

    -- Persist the billboard so it survives a restart within its 30-min window
    -- (it was memory-only, so a reboot silently destroyed a paid $2,500 blip
    -- with no refund). The DB auto-increment id is the billboard id.
    local label = ('$%s %s'):format(coin.ticker, coin.emoji)
    local expires = now() + Config.BillboardDurationSec
    local id
    pcall(function()
        id = MySQL.insert.await(
            'INSERT INTO palm6_pumpcoin_billboards (coord_x, coord_y, coord_z, label, expires_at) '
            .. 'VALUES (?, ?, ?, ?, ?)',
            { coords.x, coords.y, coords.z, label, expires })
    end)
    if not id then
        -- Write failed after the charge landed — refund so the player isn't billed
        -- for a billboard that was never posted.
        if not Bridge.CreditBank(src, Config.BillboardCost, 'pumpcoin-billboard-refund') then
            Bridge.CreditBankByCitizenId(cid, Config.BillboardCost, 'pumpcoin-billboard-refund')
        end
        Bridge.Notify(src, 'Exchange', 'The billboard could not be posted — you were refunded.', 'error')
        return
    end
    Billboards[id] = { coords = coords, label = label, expires = expires }
    TriggerClientEvent('palm6_pumpcoin:billboardAdd', -1, id, Billboards[id].coords, Billboards[id].label)
    Bridge.Notify(src, 'Exchange',
        ('Billboard live for %d minutes. Every grinder on the server can see it.')
        :format(math.floor(Config.BillboardDurationSec / 60)), 'success')
end, false)

-- Late joiners / resource restarts ask for the current billboard set.
-- Throttled per-source (not per-character — it fires on client load, which
-- can be before a character is picked).
local BillboardSyncLast = {}
RegisterNetEvent('palm6_pumpcoin:requestBillboards', function()
    local src = source
    local t = now()
    -- Refuse before the rehydrate has run rather than answering from an empty
    -- table: billboardSync clears every blip client-side before it adds, so an
    -- empty early reply is destructive. Returning BEFORE the throttle stamp is
    -- deliberate, so a refused ask does not burn the caller's 5s window. The
    -- broadcast at the end of loadBoard() covers anyone refused here.
    if not bootReady then return end
    if BillboardSyncLast[src] and (t - BillboardSyncLast[src]) < 5 then return end
    BillboardSyncLast[src] = t
    local out = {}
    for id, b in pairs(Billboards) do
        if b.expires > t then
            out[#out + 1] = { id = id, coords = b.coords, label = b.label }
        end
    end
    TriggerClientEvent('palm6_pumpcoin:billboardSync', src, out)
end)

-- Housekeeping: drop per-source throttle state on disconnect. (Cooldowns is
-- deliberately NOT cleared — it is keyed by character, so relogging does not
-- reset the mint/trade cooldowns.)
AddEventHandler('playerDropped', function()
    BillboardSyncLast[source] = nil
end)

-- ---------------------------------------------------------------------------
-- Reveal + delist + expiry sweeps (one housekeeping thread)
-- ---------------------------------------------------------------------------

-- Post-rug identity reveal: server-wide broadcast + fraud entry in the
-- police evidence log (palm6_evidence synergy, soft dependency).
local function revealCreator(coin)
    coin.revealed = 1
    pcall(function()
        MySQL.update.await('UPDATE palm6_pumpcoin_coins SET revealed = 1 WHERE id = ?', { coin.id })
    end)

    Bridge.NotifyAll('🕵️ RUG REVEALED',
        ('$%s %s was rugged by %s. Settle it in RP — that is now public record.')
        :format(coin.ticker, coin.emoji, coin.creator_name), 'error')
    -- Same information the in-city NotifyAll just made public record —
    -- never post an identity Discord-first.
    discordAnnounce({
        title = ('🕵️ RUG REVEALED — $%s'):format(coin.ticker),
        description = ('%s rugged $%s. Public record now. Settle it in the city.')
            :format(coin.creator_name, coin.ticker),
    })

    if Config.WriteEvidenceOnReveal then
        pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_evidence (citizenid, officer_name, description) VALUES (?, ?, ?)',
                { coin.creator_citizenid, 'PumpCoin Exchange (automated)',
                  ('FRAUD: %s rugged the memecoin %s ($%s) — dumped the hidden dev wallet on their own holders. Exchange tape: palm6_pumpcoin_trades coin_id %d.')
                  :format(coin.creator_name, coin.name, coin.ticker, coin.id) })
        end)
    end
    dbg(('revealed rug creator for $%s'):format(coin.ticker))
end

-- Forced endgame: pay every remaining holder their pro-rata slice of the
-- curve reserve (minus the fee), online or offline, then delist.
local function delistCoin(coinId)
    local coin = Coins[coinId]
    if not coin then return end

    withCoinLock(coinId, function()
        -- A creator who rugs within RevealDelaySec of the lifetime deadline
        -- would otherwise get the coin delisted before the reveal timer
        -- fires — and delisted rows are excluded from the boot reload, so
        -- the identity reveal (and the palm6_evidence fraud entry) would be
        -- lost forever. Force any pending reveal before settlement.
        if coin.status == 'rugged' and coin.revealed ~= 1 then
            revealCreator(coin)
        end

        local supply = coin.supply_sold
        local pool = supply > 0 and curveReserve(coin, supply) or 0
        local finalPrice = round2(supply > 0 and (pool / supply) or 0)

        -- Persist the delist BEFORE paying anyone, but KEEP the holdings rows
        -- (each carries a `settled` flag) and SNAPSHOT the share basis
        -- (delist_pool / delist_supply) onto the coin. This is what makes the
        -- payout recoverable: a crash mid-payout leaves the coin 'delisted'
        -- with unsettled holders, which the boot reconcile finishes using the
        -- exact same pool/supply — and each holder is claimed (settled 0 -> 1)
        -- before its credit, so no one is ever paid twice (the old design
        -- deleted holdings first to avoid a double-pay, but that turned a crash
        -- into a permanent strand). Guarded on status so a re-delist can't
        -- overwrite the basis. If this write fails, abort — the coin stays on
        -- the board and the next sweep retries the whole delist.
        local persisted = pcall(function()
            MySQL.update.await(
                "UPDATE palm6_pumpcoin_coins SET status = 'delisted', delisted_at = NOW(), delist_pool = ?, delist_supply = ? WHERE id = ? AND status <> 'delisted'",
                { pool, supply, coinId })
        end)
        if not persisted then
            print(('[palm6_pumpcoin] delist of $%s failed to persist — retrying next sweep'):format(coin.ticker))
            return
        end

        local settled = settleDelistHolders(coinId, coin.ticker, pool, supply, finalPrice)

        Coins[coinId] = nil
        Shills[coinId] = nil
        print(('[palm6_pumpcoin] delisted $%s — settled %d holder(s)'):format(coin.ticker, settled))
    end)
end

CreateThread(function()
    while true do
        Wait(Config.SweepIntervalMs)
        local t = now()

        -- Expired shill windows.
        for id, sh in pairs(Shills) do
            if sh.expires <= t then Shills[id] = nil end
        end

        -- Expired billboards.
        for id, b in pairs(Billboards) do
            if b.expires <= t then
                Billboards[id] = nil
                TriggerClientEvent('palm6_pumpcoin:billboardRemove', -1, id)
            end
        end

        -- Due identity reveals (persisted via rugged_at — survives restarts).
        for _, coin in pairs(Coins) do
            if coin.status == 'rugged' and coin.revealed ~= 1
                and coin.rugged_ts and t >= coin.rugged_ts + Config.RevealDelaySec then
                revealCreator(coin)
            end
        end

        -- Due delists. Collect ids first — delistCoin mutates Coins.
        local due = {}
        for id, coin in pairs(Coins) do
            if coin.created_ts and t >= coin.created_ts + Config.CoinLifetimeDays * DAY then
                due[#due + 1] = id
            end
        end
        for _, id in ipairs(due) do delistCoin(id) end
    end
end)
