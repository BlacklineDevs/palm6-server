-- ============================================================================
-- palm6_lottery/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (the bridge gate).
--
-- A city lottery, built as an ECONOMY SINK. Players buy tickets with CLEAN
-- bank money into a shared pot. On a scheduled draw a random ticket wins the
-- pot minus a house rake; the rake is money that was charged from buyers and
-- never credited back, so it leaves circulation for good (the sink).
--
-- Money safety (this file touches money, so every rule is deliberate):
--   * All amounts are server-computed from Config; the client sends only a
--     ticket count, which is re-validated here.
--   * Buy is CHARGE-THEN-RECORD: debit the bank first, insert the ticket rows
--     only if the debit succeeded. A failed record after a good charge is the
--     recoverable-visible failure (debit in the money log, no rows), never a
--     free ticket and never a double-charge.
--   * The pot is the SUM of actual recorded ticket prices, never a client
--     value.
--   * The draw runs server-side only. The winner is a server-side uniform
--     random over the REAL ticket rows (more tickets bought = more chances).
--   * Double-draw is guarded two ways: an in-process lock, and a status-gated
--     UPDATE (open -> drawing) that only one caller can win. The result is
--     RECORDED (draw marked drawn under the lock) BEFORE the winner is paid,
--     so a crash can never re-draw or double-pay - at worst a recorded draw is
--     left unpaid and staff can settle it by hand.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts }
local isDrawing = false -- in-process re-entry guard for the draw

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_lottery] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors the palm6_dbmigrate / palm6_ems
-- pattern: Wait(3000), per-statement pcall, CREATE TABLE IF NOT EXISTS. A new
-- sql/ file would NOT auto-apply on the unreachable prod DB, so the resource
-- creates its OWN tables at boot. Re-runs are harmless no-ops.
--
-- palm6_lottery_tickets stores a per-row `price` so the pot is literally the
-- SUM of recorded ticket prices even if Config.TicketPrice changes mid-draw.
-- palm6_lottery_draws carries a transient 'drawing' status used only as the
-- double-draw lock between 'open' and 'drawn'.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_lottery_draws` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    pot INT UNSIGNED NOT NULL DEFAULT 0,
    rake INT UNSIGNED NOT NULL DEFAULT 0,
    winner_citizenid VARCHAR(64) NULL DEFAULT NULL,
    ticket_count INT UNSIGNED NOT NULL DEFAULT 0,
    status ENUM('open','drawing','drawn') NOT NULL DEFAULT 'open',
    paid TINYINT NOT NULL DEFAULT 0,
    draw_at TIMESTAMP NULL DEFAULT NULL,
    opened_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    drawn_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_lottery_draws_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        -- Idempotent self-heal for an existing draws table created before the
        -- recoverable-payout rework: add the `paid` claim-before-credit flag so
        -- the boot reconcile's `WHERE status='drawn' AND paid=0` query is valid
        -- even on the unreachable prod DB (sql/0059 may never apply there). No-op
        -- once the column exists. Runs BEFORE the reconcile below in this thread.
        -- DEFAULT 1 (first-boot safety): on an EXISTING table full of live 'drawn'
        -- rows already paid under the old code, this backfills them as settled so
        -- the reconcile skips all of payment history on the first boot instead of
        -- re-paying it. IF NOT EXISTS runs the backfill exactly once. runDraw's
        -- finalize resets paid=0 for draws that resolve after this deploy. (The
        -- fresh CREATE TABLE above keeps DEFAULT 0 — no pre-existing rows there.)
        [[ALTER TABLE `palm6_lottery_draws` ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 1;]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_lottery_tickets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    draw_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    price INT UNSIGNED NOT NULL,
    bought_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_lottery_tickets_draw (draw_id),
    INDEX idx_palm6_lottery_tickets_cid (draw_id, citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print(('[palm6_lottery] schema init FAILED -> %s'):format(tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Draw helpers
-- ---------------------------------------------------------------------------

-- The single open draw (oldest, if somehow more than one), with seconds left
-- until its scheduled draw time. nil when none is open.
local function currentOpenDraw()
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, TIMESTAMPDIFF(SECOND, NOW(), draw_at) AS secs_left FROM palm6_lottery_draws WHERE status = 'open' ORDER BY id ASC LIMIT 1")
    end)
    return row
end

-- Insert a fresh open draw scheduled one interval out. Returns its id or nil.
local function openNewDraw()
    local id
    pcall(function()
        id = MySQL.insert.await(
            "INSERT INTO palm6_lottery_draws (status, draw_at) VALUES ('open', NOW() + INTERVAL ? MINUTE)",
            { Config.DrawIntervalMinutes })
    end)
    return id
end

-- Guarantee exactly one open draw exists (called at boot and defensively).
local function ensureOpenDraw()
    if not currentOpenDraw() then openNewDraw() end
end

-- Pot ($) and ticket count for a draw, computed as the SUM of recorded ticket
-- prices - the authoritative pot value, never a client number.
local function drawPot(drawId)
    local pot, cnt = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(price), 0) AS pot, COUNT(*) AS cnt FROM palm6_lottery_tickets WHERE draw_id = ?",
            { drawId })
        if r then
            pot = tonumber(r.pot) or 0
            cnt = tonumber(r.cnt) or 0
        end
    end)
    return pot, cnt
end

-- ---------------------------------------------------------------------------
-- /lottery buy [n] - buy n tickets into the open draw from bank (clean money)
-- ---------------------------------------------------------------------------
local function cmdBuy(src, nRaw)
    if src == 0 then
        Bridge.Reply(src, { 'buy tickets in-game as a player' })
        return
    end
    if not rl(src, 'buy') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local n = math.floor(tonumber(nRaw) or 1)
    if n < 1 then n = 1 end
    if n > Config.MaxPerBuy then
        Bridge.Notify(src, 'Lottery',
            ('You can buy at most %d ticket(s) at once.'):format(Config.MaxPerBuy), 'error')
        return
    end

    local draw = currentOpenDraw()
    if not draw then
        ensureOpenDraw()
        draw = currentOpenDraw()
        if not draw then
            Bridge.Notify(src, 'Lottery', 'No draw is open right now, try again shortly.', 'error')
            return
        end
    end

    -- Per-player cap for this draw.
    local held = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS c FROM palm6_lottery_tickets WHERE draw_id = ? AND citizenid = ?",
            { draw.id, cid })
        held = r and tonumber(r.c) or 0
    end)
    if held + n > Config.MaxTicketsPerDraw then
        local left = Config.MaxTicketsPerDraw - held
        if left <= 0 then
            Bridge.Notify(src, 'Lottery',
                ('You already hold the max %d tickets this draw.'):format(Config.MaxTicketsPerDraw), 'error')
        else
            Bridge.Notify(src, 'Lottery',
                ('You can buy at most %d more ticket(s) this draw.'):format(left), 'error')
        end
        return
    end

    -- All amounts server-computed. Never trust a client price/cost.
    local price = Config.TicketPrice
    local cost = n * price

    -- CHARGE FIRST. Only record tickets if the debit actually landed.
    if not Bridge.ChargeBank(src, cost, 'lottery-ticket') then
        Bridge.Notify(src, 'Lottery',
            ('You need $%d in the bank for %d ticket(s).'):format(cost, n), 'error')
        return
    end

    -- Record the tickets. A SQL failure here is the recoverable-visible case:
    -- the charge shows in the money log, no rows were written. It is never a
    -- double-charge and never a free ticket.
    -- Status-gated insert: each row only materializes while the draw is still
    -- 'open', so a draw that finalized during the charge yields ZERO inserted
    -- rows (all SELECTs read one statement snapshot) instead of orphaning
    -- paid-for tickets into a drawn draw. Mirrors the open->drawing claim gate.
    -- Each row binds four params: the three column values plus the WHERE id.
    local inserted = 0
    local ok = pcall(function()
        local rows, params = {}, {}
        for _ = 1, n do
            rows[#rows + 1] = "SELECT ?, ?, ? FROM palm6_lottery_draws WHERE id = ? AND status = 'open'"
            params[#params + 1] = draw.id
            params[#params + 1] = cid
            params[#params + 1] = price
            params[#params + 1] = draw.id
        end
        inserted = MySQL.update.await(
            'INSERT INTO palm6_lottery_tickets (draw_id, citizenid, price) ' .. table.concat(rows, ' UNION ALL '),
            params) or 0
    end)
    if not ok then
        Bridge.Notify(src, 'Lottery',
            'Ticket recording failed after the charge - contact staff (your bank shows the debit).', 'error')
        return
    end
    -- The draw drew between the charge and this insert: nothing landed, so
    -- refund the charge rather than silently eating it (never a lost ticket).
    if inserted < n then
        Bridge.CreditBankByCitizenId(cid, cost, 'lottery-refund')
        Bridge.Notify(src, 'Lottery',
            ('The draw closed as you bought in - your $%d was refunded, try the next draw.'):format(cost), 'error')
        return
    end

    local pot = drawPot(draw.id)
    Bridge.Notify(src, 'Lottery',
        ('Bought %d ticket(s) for $%d. Pot is now $%d.'):format(n, cost, pot), 'success')
    dbg(('%s bought %d ticket(s) in draw #%d ($%d)'):format(cid, n, draw.id, cost))
end

-- ---------------------------------------------------------------------------
-- /lottery status - current pot, your tickets, time to next draw
-- ---------------------------------------------------------------------------
local function cmdStatus(src)
    if src ~= 0 and not rl(src, 'status') then return end

    local draw = currentOpenDraw()
    if not draw then
        Bridge.Reply(src, { 'no draw is open right now' })
        return
    end

    local pot, cnt = drawPot(draw.id)
    local mine = 0
    local cid = src ~= 0 and Bridge.GetCitizenId(src) or nil
    if cid then
        pcall(function()
            local r = MySQL.single.await(
                "SELECT COUNT(*) AS c FROM palm6_lottery_tickets WHERE draw_id = ? AND citizenid = ?",
                { draw.id, cid })
            mine = r and tonumber(r.c) or 0
        end)
    end

    local secs = tonumber(draw.secs_left) or 0
    local nextIn = secs > 0
        and ('%dm %ds'):format(math.floor(secs / 60), secs % 60)
        or 'due now (waiting on the minimum pot)'
    local rake = math.floor(pot * Config.RakePercent / 100)

    Bridge.Reply(src, {
        ('Lottery draw #%d - pot $%d across %d ticket(s)'):format(draw.id, pot, cnt),
        ('Winner takes $%d after a %d%% house rake ($%d).'):format(pot - rake, Config.RakePercent, rake),
        ('Your tickets: %d  |  ticket price $%d  |  next draw in %s'):format(mine, Config.TicketPrice, nextIn),
        ('Minimum pot to draw: $%d%s'):format(
            Config.MinPotToDraw, pot < Config.MinPotToDraw and ' (not reached yet)' or ' (reached)'),
    })
end

-- ---------------------------------------------------------------------------
-- Recoverable winner payout (claim-before-credit). Callable from BOTH the live
-- draw path AND the boot reconcile, so a crash between the 'drawn' finalize and
-- the credit is re-drivable with NO double-pay.
--
-- The payout is recomputed deterministically from the FINALIZED draw row itself
-- (pot - rake were written under the status lock at finalize), so a replay pays
-- the exact same amount. The `paid` flag is CLAIMED (0->1) BEFORE the money
-- moves: only the caller that flips it credits, so exactly one settlement run —
-- live or boot-recovery — ever pays a given draw. Bias (matching /lottery buy's
-- charge-before-record): a crash in the tiny window between claiming paid=1 and
-- the credit costs that one payout — a rare shortfall staff can see via the
-- '[CREDIT FAILED - settle manually]' log, never a mint.
--
-- Returns (claimed, credited): claimed=true iff WE flipped paid 0->1 this run;
-- credited=Bridge's credit return (false => log a manual-settle fallback).
-- ---------------------------------------------------------------------------
local function settleDraw(drawId, triggeredBy)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT pot, rake, winner_citizenid FROM palm6_lottery_draws WHERE id = ? AND status = 'drawn' AND winner_citizenid IS NOT NULL",
            { drawId })
    end)
    -- Not a drawn+winner row (or fetch failed): nothing to settle. A transient
    -- DB failure here is retried by the boot reconcile on the next restart.
    if not row or not row.winner_citizenid then return false, false end

    local winnerCid = row.winner_citizenid
    local payout = math.max(0, (tonumber(row.pot) or 0) - (tonumber(row.rake) or 0))

    -- CLAIM BEFORE CREDIT: flip paid 0->1 atomically. Only the run that wins this
    -- claim credits; a replay of an already-paid draw sees paid=1 and skips.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_lottery_draws SET paid = 1 WHERE id = ? AND status = 'drawn' AND paid = 0",
            { drawId }) == 1
    end)
    if not claimed then return false, false end

    -- Pay the winner (offline-safe). The rake was never credited - that is the sink.
    local paid = Bridge.CreditBankByCitizenId(winnerCid, payout, 'lottery-winnings')
    local winnerName = Bridge.GetCitizenName(winnerCid) or winnerCid
    local wSrc = Bridge.GetSourceByCitizenId(winnerCid)
    if wSrc then
        Bridge.Notify(wSrc, 'Lottery',
            ('You won lottery draw #%d - $%d hit your bank!'):format(drawId, payout), 'success')
    end
    if not paid then
        -- Claim-before-credit bias: the flag is already set, so this draw won't
        -- auto-retry. Surface it for a manual settle (preserves the prior log).
        print(('[palm6_lottery] draw #%d winner %s (%s) payout $%d [CREDIT FAILED - settle manually]')
            :format(drawId, winnerName, winnerCid, payout))
    end
    dbg(('[%s] draw #%d settled: winner %s (%s) payout $%d%s'):format(
        tostring(triggeredBy), drawId, winnerName, winnerCid, payout,
        paid and '' or ' [CREDIT FAILED - settle manually]'))
    return true, paid
end

-- ---------------------------------------------------------------------------
-- The draw itself - server-side only. Returns ok, message.
-- ---------------------------------------------------------------------------
local function runDraw(triggeredBy)
    if isDrawing then return false, 'a draw is already in progress' end
    isDrawing = true
    local result
    local okAll, err = pcall(function()
        local draw = currentOpenDraw()
        if not draw then result = 'no open draw'; return end

        -- CLAIM the draw with a status-gated UPDATE: only the caller that
        -- flips open -> drawing proceeds, so the timer and /lotterydraw can
        -- never both draw the same pot.
        local claimed = false
        pcall(function()
            claimed = MySQL.update.await(
                "UPDATE palm6_lottery_draws SET status = 'drawing' WHERE id = ? AND status = 'open'",
                { draw.id }) == 1
        end)
        if not claimed then result = 'draw already being processed'; return end

        -- Read the REAL ticket rows. Pot is the SUM of recorded prices.
        local rows = {}
        pcall(function()
            rows = MySQL.query.await(
                "SELECT id, citizenid, price FROM palm6_lottery_tickets WHERE draw_id = ?",
                { draw.id }) or {}
        end)
        local pot = 0
        for _, t in ipairs(rows) do pot = pot + (tonumber(t.price) or 0) end
        local ticketCount = #rows

        -- Not enough to draw: release the claim and roll the schedule forward
        -- so the pot keeps building. This covers an admin forcing an empty or
        -- under-minimum draw.
        if ticketCount == 0 or pot < Config.MinPotToDraw then
            pcall(function()
                MySQL.update.await(
                    "UPDATE palm6_lottery_draws SET status = 'open', draw_at = NOW() + INTERVAL ? MINUTE WHERE id = ? AND status = 'drawing'",
                    { Config.DrawIntervalMinutes, draw.id })
            end)
            result = ('draw #%d held: pot $%d below minimum $%d (or no tickets), rolled forward'):format(
                draw.id, pot, Config.MinPotToDraw)
            return
        end

        local rake = math.floor(pot * Config.RakePercent / 100)
        local payout = pot - rake

        -- Winner: uniform random over the real ticket rows. Because each ticket
        -- is one row, buying more tickets gives proportionally more chances.
        local win = rows[math.random(1, ticketCount)]
        local winnerCid = win.citizenid

        -- FINALIZE BEFORE PAYING. Record the result under the status lock so a
        -- crash can never re-draw or double-pay. A failed credit after this is
        -- a recorded-but-unpaid draw staff can see and settle by hand.
        -- paid = 0 here (first-boot safety): this is the point a draw NEWLY enters
        -- the recoverable 'drawn' state, so reset the backfilled DEFAULT 1 to 0 so
        -- settleDraw/boot reconcile can drive its payout. The WHERE status='drawing'
        -- guard means only a genuine new transition resets it; pre-existing 'drawn'
        -- rows are never re-flipped and keep their backfilled paid=1.
        local finalized = false
        pcall(function()
            finalized = MySQL.update.await(
                "UPDATE palm6_lottery_draws SET status = 'drawn', pot = ?, rake = ?, winner_citizenid = ?, ticket_count = ?, paid = 0, drawn_at = NOW() WHERE id = ? AND status = 'drawing'",
                { pot, rake, winnerCid, ticketCount, draw.id }) == 1
        end)
        if not finalized then
            result = ('draw #%d finalize write failed - not paid'):format(draw.id)
            return
        end

        -- Pay the winner via the recoverable, claim-before-credit settle path.
        -- The draw is now 'drawn' with paid=0, so settleDraw claims paid=1 then
        -- credits; a crash before this (or before the credit lands) is re-driven
        -- idempotently by the boot reconcile with no double-pay. settleDraw does
        -- the winner notification, so we don't repeat it here.
        local _claimed, paid = settleDraw(draw.id, triggeredBy)
        local winnerName = Bridge.GetCitizenName(winnerCid) or winnerCid

        -- Open the next draw so the game continues.
        openNewDraw()

        result = ('draw #%d DRAWN: pot $%d, rake $%d, %d ticket(s), winner %s (%s)%s'):format(
            draw.id, pot, rake, ticketCount, winnerName, winnerCid,
            paid and '' or ' [CREDIT FAILED - settle manually]')
        dbg(('[%s] %s'):format(tostring(triggeredBy), result))
    end)
    isDrawing = false
    if not okAll then return false, tostring(err) end
    return true, result
end

-- ---------------------------------------------------------------------------
-- /lotterydraw - admin (ace) or console forces the draw now
-- ---------------------------------------------------------------------------
local function cmdDraw(src)
    if src ~= 0 and not rl(src, 'draw') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, 'Lottery', 'You are not authorized to draw the lottery.', 'error')
        return
    end
    local ok, msg = runDraw('admin')
    Bridge.Reply(src, { ok and ('draw: ' .. tostring(msg)) or ('draw not run: ' .. tostring(msg)) })
end

-- ---------------------------------------------------------------------------
-- /lottery dispatcher
-- ---------------------------------------------------------------------------
local function cmdLottery(src, args)
    local sub = tostring(args[1] or 'status'):lower()
    if sub == 'buy' then
        cmdBuy(src, args[2])
    elseif sub == 'status' then
        cmdStatus(src)
    else
        Bridge.Reply(src, { 'usage: /lottery buy [n]  |  /lottery status' })
    end
end

-- ---------------------------------------------------------------------------
-- Scheduled draw timer - fires runDraw when the open draw is due
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait((Config.TickSeconds or 30) * 1000)
        local draw = currentOpenDraw()
        if draw and (tonumber(draw.secs_left) or 1) <= 0 then
            local ok, msg = runDraw('schedule')
            if ok then dbg('scheduled ' .. tostring(msg)) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Boot: create tables, ensure an open draw, register commands, print banner.
-- Uses the palm6_dbmigrate Wait(3000) pattern so oxmysql is connected first.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Register synchronously at boot so the commands exist immediately, matching
    -- the proven siblings (palm6_mdt/citations/legal). The handlers are all
    -- DB-pcall-guarded, so an ultra-early call before the schema thread runs just
    -- replies 'no draw is open right now' - visible output, no crash.
    Bridge.RegisterCommand('lottery', function(source, args) cmdLottery(source, args) end)
    Bridge.RegisterCommand('lotterydraw', function(source) cmdDraw(source) end)
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        math.randomseed(GetGameTimer() + os.time())
        ensureSchema()
        -- Self-heal a draw that crashed mid-resolve: a row stuck in the transient
        -- 'drawing' status (process died between the open->drawing claim and the
        -- drawing->drawn finalize) was never drawn, so its tickets are intact —
        -- reopen it so it draws normally instead of orphaning the pot forever.
        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_lottery_draws SET status = 'open' WHERE status = 'drawing'")
        end)

        -- Recover a draw that finalized to 'drawn' with a recorded winner but
        -- whose payout never landed (process died between the drawing->drawn
        -- finalize and the winner credit). Idempotent: settleDraw claims paid=1
        -- before crediting, so an already-paid draw (paid=1) is skipped and this
        -- only pays what a crash left owing. The `paid` column is guaranteed
        -- present by ensureSchema's ALTER above (and sql/0059 via palm6_dbmigrate);
        -- every query is pcall-guarded, so a missing column recovers nothing
        -- rather than crashing. This complements the 'drawing'->'open' self-heal
        -- above, which only handled draws that never reached 'drawn'.
        local unpaid = {}
        pcall(function()
            unpaid = MySQL.query.await(
                "SELECT id FROM palm6_lottery_draws WHERE status = 'drawn' AND paid = 0 AND winner_citizenid IS NOT NULL") or {}
        end)
        for _, row in ipairs(unpaid) do
            settleDraw(row.id, 'recovered')
        end
        if #unpaid > 0 then
            print(('[palm6_lottery] boot reconcile settled %d interrupted payout(s)'):format(#unpaid))
        end

        ensureOpenDraw()

        local draw = currentOpenDraw()
        local pot = draw and drawPot(draw.id) or 0
        print(('[palm6_lottery] open - draw #%s, pot $%d; rake %d%%, min pot $%d, interval %dm')
            :format(draw and draw.id or '?', pot, Config.RakePercent, Config.MinPotToDraw, Config.DrawIntervalMinutes))
    end)
end)

-- ---------------------------------------------------------------------------
-- Additive export (never-change-signature rule, matching the sibling
-- resources). Lets palm6_economy or a future surface read the sink totals.
-- ---------------------------------------------------------------------------
exports('GetSummary', function()
    local out = { draws = 0, paidOut = 0, rakeSunk = 0, openPot = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(pot - rake), 0) AS paid, COALESCE(SUM(rake), 0) AS rake FROM palm6_lottery_draws WHERE status = 'drawn'")
        if r then
            out.draws = tonumber(r.n) or 0
            out.paidOut = tonumber(r.paid) or 0
            out.rakeSunk = tonumber(r.rake) or 0
        end
    end)
    local d = currentOpenDraw()
    if d then out.openPot = (drawPot(d.id)) end
    return out
end)
