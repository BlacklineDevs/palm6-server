-- ============================================================================
-- palm6_market/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access; oxmysql (MySQL.*) for our own palm6_market_* tables. No
-- direct framework / native calls here (Section 6 gate).
--
-- The Palm6 Commodity Exchange. A server-authoritative supply/demand market
-- for raw goods (palm6_grind outputs). Price is a PURE FUNCTION of the last
-- persisted {price, timestamp} and the current time — it recovers toward a
-- rested `base` over wall-clock time and drops as goods are sold. Nothing is a
-- client tick; nothing is trusted from the client (amounts, items and prices
-- are all server-decided). Money is consume-before-grant and the market only
-- moves on a real, completed sale.
-- ============================================================================

local commodity = {}    -- [item] = Config commodity entry
local State     = {}     -- [item] = { price = <float>, ts = <epoch seconds> }
local Stats     = { unitsSold = 0, totalPaid = 0 }  -- since boot (GetSummary)

local lastSell   = {}    -- [src] = ts  (atomic sell cooldown)
local lastBoard  = {}    -- [src] = ts  (/market spam guard)
local lastRefine = {}    -- [src] = ts  (atomic refine cooldown)

-- Soft gate: the refinery only serves once every refined item def exists in the
-- inventory registry (checked via Bridge.HasItemDef). checkRefine() flips this
-- false + prints a LOUD error naming the missing item(s) (mirrors palm6_drugs).
-- The :refine handler returns early when false, so a missing def never mints
-- refined goods.
local refineEnabled = false

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner
-- Flipped true once seedState() has run. seedState now lives behind the boot
-- thread's Wait(3000) (ensureSchema has to create the table before it reads
-- from it), and until it runs the `commodity` lookup is EMPTY, which makes
-- currentPrice() return 0 for every item. Selling in that window would tell a
-- player holding a full stack that they have nothing to sell, and the board
-- would price everything at $0. Both are gated on this flag instead.
local bootReady = false

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a new box boots with no
-- palm6_market_* tables. persist() and logTrade() are both pcall-wrapped and
-- both only dbg() on failure, so with Config.Debug off a missing table is
-- completely SILENT: every price permanently resets to base on restart (an
-- infinite-value dump exploit) and the trade ledger records nothing. On the
-- live box these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0046_market.sql (trailing semicolons dropped,
-- same as the other resources that carry their own DDL).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS palm6_market_state (
    commodity   VARCHAR(64)  NOT NULL PRIMARY KEY,
    price       DOUBLE       NOT NULL,
    last_ts     BIGINT       NOT NULL
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS palm6_market_trades (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid   VARCHAR(64)  NOT NULL,
    commodity   VARCHAR(64)  NOT NULL,
    qty         INT          NOT NULL,
    total       INT          NOT NULL,
    ts          BIGINT       NOT NULL,
    INDEX idx_palm6_market_trades_cid (citizenid),
    INDEX idx_palm6_market_trades_commodity (commodity)
)
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_market] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_market] ' .. msg) end
end

local function floorPrice(c) return c.base * c.floorPct end

-- Recovery-applied current price (float). Pure: reads persisted State, never
-- mutates it, so it is identical before and after a restart.
local function currentPrice(item)
    local c = commodity[item]
    if not c then return 0 end
    local st = State[item]
    if not st then return c.base end
    local elapsedMin = math.max(0, now() - st.ts) / 60
    local recovered = st.price + c.base * (Config.RecoverPctPerMin / 100) * elapsedMin
    if recovered > c.base then recovered = c.base end
    -- PURE base-scale price: this feeds the marginal-crash walk AND the persisted
    -- State, so it must NOT include the pulse multiplier (folding the boost into
    -- persisted state would defeat the anti-dump crash sink and reset the commodity
    -- to full price). The pulse boost is applied to the PAYOUT + display only.
    return recovered
end

-- palm6_pulse "Hot Exchange" multiplier for ONE spiked commodity. Server-read
-- (a client can never assert a multiplier), pcall+ResourceState-gated so market
-- runs standalone if pulse is absent. Applied to the player payout + /market
-- display only — never to the persisted price math.
local function pulseMarketMult(item)
    local mult = 1.0
    pcall(function()
        if GetResourceState('palm6_pulse') == 'started' then
            local m = exports.palm6_pulse:GetActiveModifier('market', item)
            if type(m) == 'number' and m > 0 then mult = m end
        end
    end)
    return mult
end

-- Persist a commodity's new price + timestamp. Memory is authoritative during
-- uptime; the DB write is best-effort (a failed write just means the price is
-- re-read from the last good row on restart — favourable to players, never a
-- SCRIPT ERROR if the table is absent).
local function persist(item, price)
    State[item] = { price = price, ts = now() }
    local ok = pcall(function()
        MySQL.update.await(
            'INSERT INTO palm6_market_state (commodity, price, last_ts) VALUES (?, ?, ?) '
            .. 'ON DUPLICATE KEY UPDATE price = VALUES(price), last_ts = VALUES(last_ts)',
            { item, price, State[item].ts })
    end)
    if not ok then dbg('persist failed for ' .. tostring(item)) end
end

-- Best-effort trade ledger. Never blocks or undoes a completed sale.
local function logTrade(cid, item, qty, total)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_market_trades (citizenid, commodity, qty, total, ts) VALUES (?, ?, ?, ?, ?)',
            { cid, item, qty, total, now() })
    end)
    if not ok then dbg('trade ledger insert failed for ' .. tostring(item)) end
end

-- ---------------------------------------------------------------------------
-- sell everything sellable, priced live, at the exchange counter
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_market:sell', function()
    local src = source

    -- Prices are not seeded yet (see bootReady): selling now would price every
    -- commodity at 0 and silently eat the attempt. Refuse and say so.
    if not bootReady then
        Bridge.Notify(src, Config.Exchange.label, 'The exchange is still opening. Try again in a moment.', 'error')
        return
    end

    -- Atomic cooldown set BEFORE any yield: two same-tick fires can't both pass.
    local t = now()
    if (lastSell[src] or 0) + Config.SellCooldown > t then return end
    lastSell[src] = t

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Server-side proximity — never trust the client that it is at the counter.
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, Config.Exchange.coords) > (Config.InteractRadius + 2.0) then
        Bridge.Notify(src, Config.Exchange.label, 'You are not at the exchange counter.', 'error')
        return
    end

    local soldLines, grandTotal, anySold = {}, 0, false

    for _, c in ipairs(Config.Commodities) do
        local item  = c.item
        local count = Bridge.CountItem(src, item)
        if count and count > 0 then
            if count > Config.MaxUnitsPerSale then count = Config.MaxUnitsPerSale end

            -- Marginal price walk: each successive unit sells a notch lower, so
            -- dumping a big stack crashes the price within the sale itself.
            local price  = currentPrice(item)
            local floorP = floorPrice(c)
            local impact = c.base * Config.ImpactPct
            local total  = 0
            for _ = 1, count do
                total = total + math.floor(price)
                price = price - impact
                if price < floorP then price = floorP end
            end

            if total > 0 then
                -- consume BEFORE grant; only move the market on a real sale.
                if Bridge.RemoveItem(src, item, count) then
                    -- palm6_pulse Hot Exchange boosts the PAYOUT only; the marginal
                    -- walk + persisted `price` stay on the base scale (above), so the
                    -- anti-dump crash sink is modifier-independent (the boost can't
                    -- reset the commodity to full price or defeat the sink).
                    local payout = math.floor(total * pulseMarketMult(item))
                    Bridge.AddCash(src, payout, 'market-sell')
                    persist(item, price)                 -- new depressed price (base scale)
                    Stats.unitsSold = Stats.unitsSold + count
                    Stats.totalPaid = Stats.totalPaid + payout
                    grandTotal      = grandTotal + payout
                    anySold         = true
                    soldLines[#soldLines + 1] = ('%dx %s -> $%d'):format(count, c.label, payout)
                    logTrade(cid, item, count, payout)
                end
            end
        end
    end

    if not anySold then
        Bridge.Notify(src, Config.Exchange.label, 'You have no raw goods to sell here.', 'inform')
        return
    end

    Bridge.Notify(src, Config.Exchange.label,
        ('Sold %s  (total $%d).'):format(table.concat(soldLines, ', '), grandTotal), 'success')
    dbg(('%s sold $%d of goods'):format(cid, grandTotal))
end)

-- ---------------------------------------------------------------------------
-- refine — convert raw goods into refined goods at the refinery (instant,
-- lossless-by-ratio, integer batches). The economic brake is the SELL side
-- (the refined commodities crash on the same marginal curve), not this
-- conversion, so it is instant. Money-safety discipline is unchanged from the
-- sell path: atomic cooldown before any yield, server-side proximity,
-- consume-before-grant, and a refund ladder if the grant fails.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_market:refine', function()
    local src = source
    local t = now()

    -- Refinery disabled (a refined item def is missing) — refuse silently; the
    -- LOUD reason was already printed at boot.
    if not refineEnabled then return end

    -- Atomic cooldown set BEFORE any yield: two same-tick fires can't both pass.
    if (lastRefine[src] or 0) + Config.RefineCooldown > t then return end
    lastRefine[src] = t

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Server-side proximity — never trust the client that it is at the refinery.
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, Config.RefineStation.coords) > (Config.InteractRadius + 2.0) then
        Bridge.Notify(src, Config.RefineStation.label, 'You are not at the refinery.', 'error')
        return
    end

    local lines, any = {}, false
    for _, r in ipairs(Config.Refine) do
        local have    = Bridge.CountItem(src, r.raw) or 0
        local batches = math.floor(have / r.ratio)   -- integer; have>=0, ratio>=2 -> no NaN/neg
        if batches > 0 then
            local consume = batches * r.ratio
            -- consume BEFORE grant; a completed conversion only ever removes
            -- exactly what it grants for.
            if Bridge.RemoveItem(src, r.raw, consume) then
                if Bridge.AddItem(src, r.refined, batches) then
                    any = true
                    lines[#lines + 1] = ('%dx %s -> %dx %s'):format(consume, r.raw, batches, r.refined)
                else
                    -- REFUND ladder: grant failed (e.g. inventory full) — give
                    -- the consumed raws back so nothing is destroyed.
                    Bridge.AddItem(src, r.raw, consume)
                end
            end
        end
    end

    if not any then
        Bridge.Notify(src, Config.RefineStation.label, 'Nothing to refine (need enough raw goods).', 'inform')
        return
    end

    Bridge.Notify(src, Config.RefineStation.label,
        'Refined ' .. table.concat(lines, ', ') .. '.', 'success')
    dbg(('%s refined %s'):format(cid, table.concat(lines, ', ')))
end)

-- ---------------------------------------------------------------------------
-- /market — the live price board (read-only, rate-limited, branded panel)
-- ---------------------------------------------------------------------------
local function boardLines()
    local L = {}
    L[#L + 1] = '=== Palm6 Commodity Exchange ==='
    -- Same reason as the sell gate: before seedState() the lookup is empty and
    -- every price would render as $0, which reads as a crashed market.
    if not bootReady then
        L[#L + 1] = 'The exchange is still opening. Try again in a moment.'
        return L
    end
    L[#L + 1] = 'Live buy prices. Sell at the exchange counter (E). Prices fall as goods flood the market and recover over time.'
    for _, c in ipairs(Config.Commodities) do
        local base = math.floor(currentPrice(c.item))
        local mult = pulseMarketMult(c.item)
        local p    = math.floor(base * mult)               -- boosted buy price shown
        local pct  = math.floor((base / c.base) * 100 + 0.5)  -- pct on the base scale (<=100)
        local hot  = mult > 1 and (' [HOT x%.2f]'):format(mult) or ''
        local cmp = c.grindFloor and (' | grind buyer pays $' .. c.grindFloor)
                                  or ' | exchange is the only buyer'
        L[#L + 1] = ('%s: $%d  (%d%% of rested $%d)%s%s'):format(c.label, p, pct, c.base, cmp, hot)
    end
    return L
end

Bridge.RegisterCommand(Config.Command, function(source)
    local src = source
    if src ~= 0 then
        local t = now()
        if (lastBoard[src] or 0) + 2 > t then return end
        lastBoard[src] = t
    end
    Bridge.Reply(src, boardLines())
end)

-- ---------------------------------------------------------------------------
-- Scoreboard export (palm6_economy aggregates this — CLEAN cash, informational)
-- ---------------------------------------------------------------------------
exports('GetSummary', function()
    return {
        commodities = #Config.Commodities,
        unitsSold   = Stats.unitsSold,
        totalPaid   = Stats.totalPaid,
    }
end)

-- ---------------------------------------------------------------------------
-- boot: build the lookup, seed persisted prices (missing = rested at base)
-- ---------------------------------------------------------------------------
local function seedState()
    for _, c in ipairs(Config.Commodities) do commodity[c.item] = c end

    local rows
    local ok = pcall(function()
        rows = MySQL.query.await('SELECT commodity, price, last_ts FROM palm6_market_state')
    end)
    if ok and rows then
        for _, r in ipairs(rows) do
            local c = commodity[r.commodity]
            if c then
                State[r.commodity] = {
                    price = tonumber(r.price)   or c.base,
                    ts    = tonumber(r.last_ts) or now(),
                }
            end
        end
    end
    for item, c in pairs(commodity) do
        if not State[item] then State[item] = { price = c.base, ts = now() } end
    end
end

-- Refinery soft gate: enable only if every refined item def exists in the
-- inventory registry. Missing item(s) -> LOUD error naming them + stays
-- disabled (mirrors palm6_drugs' meth cook chain). The exchange keeps running
-- either way.
local function checkRefine()
    local missing = {}
    for _, r in ipairs(Config.Refine) do
        if not Bridge.HasItemDef(r.refined) then missing[#missing + 1] = r.refined end
    end
    if #missing == 0 then
        refineEnabled = true
    else
        table.sort(missing)
        print(('^1[palm6_market] REFINERY DISABLED — %d refined item def(s) missing from the item '
            .. 'registry: %s. Register them (see README) to enable the refining tier.^0')
            :format(#missing, table.concat(missing, ', ')))
    end
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    checkRefine()  -- no DB access, so it stays synchronous exactly as before
    -- seedState reads palm6_market_state, so it must run after ensureSchema,
    -- which in turn has to Wait for oxmysql's connection. Sell + board are
    -- gated on bootReady for the length of that window.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        seedState()
        bootReady = true
        print(('[palm6_market] commodity exchange online — %d commodities, /%s for live prices%s'):format(
            #Config.Commodities, Config.Command,
            refineEnabled and (' | refinery online (%d recipes)'):format(#Config.Refine) or ' | refinery OFF'))
        if not SchemaReady then
            print('^1[palm6_market] schema MISSING - prices will NOT persist across restarts and no trade is logged.^0')
        end
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastSell[src]   = nil
    lastBoard[src]  = nil
    lastRefine[src] = nil
end)
