-- ============================================================================
-- gtarp_numbers/server/main.lua
--
-- Pure logic. Calls Bridge.* for all framework / inventory / native access.
-- No direct framework / native calls here (§6 gate).
--
-- The racket: stake CLEAN cash on a number (00-99) with the bookie; every
-- Config.DrawIntervalSec the house draws a winning number and marks hits WON
-- at Config.PayoutMultiple × stake; winners collect their winnings as DIRTY
-- money (black_money) at the bookie, online or later. The payout multiple is
-- below true odds (a house edge) so the stake pool is a net sink. Nothing here
-- trusts a client-supplied number, stake, position, or item.
-- ============================================================================

local lastBet    = {}     -- [src] = ts of last /numbers (spam guard)
local claimLock  = {}     -- [citizenid] = true while a collect is in flight
local openDrawSeq = 1     -- the draw new bets accumulate into
local nextDrawAt = 0      -- os.time() the open draw resolves (for the countdown)
local drawEnabled = false -- gated on the win-item existing at boot
local drawNonce  = 0      -- per-draw counter folded into the reseed

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_numbers] ' .. msg) end
end

local function atBookie(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Bookie.coords) <= Config.Bookie.radius
end

-- ---------------------------------------------------------------------------
-- The draw. Resolves every open bet for the current sequence, records the
-- result, opens the next sequence. Payouts are recorded (status='won',
-- payout=$) but NOT delivered here — winners collect at the bookie, so an
-- offline winner still gets paid on their next collect.
-- ---------------------------------------------------------------------------
local function runDraw()
    local seq = openDrawSeq
    -- Advance the open sequence BEFORE snapshotting so any bet placed from here
    -- on attaches to the NEXT draw, and resolve every open bet with draw_seq <=
    -- seq so a straggler inserted mid-resolve is still swept — never orphaned
    -- with its stake lost. (fixes the resolve-window orphaned-bet race)
    openDrawSeq = seq + 1
    nextDrawAt = now() + Config.DrawIntervalSec

    -- Reseed per draw from entropy a client can't observe (sub-second os.clock +
    -- server game timer + a nonce). The winning number is drawn from math.random,
    -- which is NOT a CSPRNG — seeded only once at boot from os.time(), the whole
    -- future sequence would be brute-forceable from the public winning-number
    -- history, letting a player predict draws and print money at 60x. Reseeding
    -- each draw from unobservable entropy breaks that boot-seed prediction.
    drawNonce = drawNonce + 1
    math.randomseed((os.time() * 1000)
        + math.floor((os.clock() % 1) * 1e6)
        + (Bridge.GameTimer() % 1000000)
        + drawNonce * 2654435761)
    math.random(); math.random()  -- warm the reseeded state
    local win = math.random(0, Config.MaxNumber)

    local bets = {}
    pcall(function()
        bets = MySQL.query.await(
            "SELECT id, citizenid, number, stake FROM gtarp_numbers_bets WHERE draw_seq <= ? AND status = 'open'",
            { seq }) or {}
    end)

    local staked, payoutTotal, winners = 0, 0, {}
    for _, b in ipairs(bets) do
        staked = staked + tonumber(b.stake)
        local won = (tonumber(b.number) == win)
        local payout = won and (tonumber(b.stake) * Config.PayoutMultiple) or 0
        local applied = false
        pcall(function()
            local aff = MySQL.update.await(
                "UPDATE gtarp_numbers_bets SET status = ?, payout = ? WHERE id = ? AND status = 'open'",
                { won and 'won' or 'lost', payout, b.id })
            applied = (tonumber(aff) or 0) > 0
        end)
        if applied and won then
            payoutTotal = payoutTotal + payout
            winners[b.citizenid] = (winners[b.citizenid] or 0) + payout
        end
    end

    pcall(function()
        MySQL.insert.await(
            "INSERT INTO gtarp_numbers_draws (draw_seq, winning_number, bets, staked, payout_total) VALUES (?, ?, ?, ?, ?)",
            { seq, win, #bets, staked, payoutTotal })
    end)

    for cid, amt in pairs(winners) do
        local sid = Bridge.GetSourceByCitizenId(cid)
        if sid then
            Bridge.Notify(sid, 'Numbers',
                ('Your number %02d hit — $%d waiting at %s.'):format(win, amt, Config.Bookie.label), 'success')
        end
    end

    -- Hype: a draw that actually paid out is street news (rare — 1/100 a slip).
    if payoutTotal > 0 then
        Bridge.Announce('heat', {
            title = 'Numbers came in',
            description = ('Tonight\'s number was **%02d** — the bookie paid out **$%d** to the lucky ones.'):format(win, payoutTotal),
        })
    end
    print(('[gtarp_numbers] draw #%d — winning number %02d (%d bet(s), $%d staked, $%d owed)'):format(
        seq, win, #bets, staked, payoutTotal))
    dbg(('draw %d resolved'):format(seq))
end

-- ---------------------------------------------------------------------------
-- /numbers <NN> <stake> — place a slip.
-- ---------------------------------------------------------------------------
local function cmdNumbers(src, args)
    if src == 0 then return end
    if not drawEnabled then
        Bridge.Notify(src, 'Numbers', 'The numbers game is offline.', 'error')
        return
    end
    local t = now()
    -- Atomic check-and-set before any DB yield (rl() idiom) so two same-tick
    -- slips can't both slip past the cooldown.
    if (lastBet[src] or 0) + Config.BetCooldownSec > t then
        Bridge.Notify(src, 'Numbers', 'Ease up — one slip at a time.', 'error')
        return
    end

    local num = tonumber(args[1])
    local stake = tonumber(args[2])
    if not num or not stake or num ~= math.floor(num) or stake ~= math.floor(stake) then
        Bridge.Notify(src, 'Numbers', ('Usage: /numbers [0-%d] [stake]'):format(Config.MaxNumber), 'error')
        return
    end
    if num < 0 or num > Config.MaxNumber then
        Bridge.Notify(src, 'Numbers', ('Pick a number 0-%d.'):format(Config.MaxNumber), 'error')
        return
    end
    if stake < Config.MinStake or stake > Config.MaxStake then
        Bridge.Notify(src, 'Numbers', ('Stakes run $%d to $%d.'):format(Config.MinStake, Config.MaxStake), 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atBookie(src) then
        Bridge.Notify(src, 'Numbers', ('You need to find %s.'):format(Config.Bookie.label), 'error')
        return
    end
    lastBet[src] = t

    local seq = openDrawSeq
    local cnt = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_numbers_bets WHERE citizenid = ? AND draw_seq = ?", { cid, seq })
        cnt = r and tonumber(r.n) or 0
    end)
    if cnt >= Config.MaxBetsPerDraw then
        Bridge.Notify(src, 'Numbers', ('You already hold %d slips on this draw.'):format(cnt), 'error')
        return
    end

    if not Bridge.TakeCash(src, stake, 'numbers-bet') then
        Bridge.Notify(src, 'Numbers', 'Not enough clean cash on you.', 'error')
        return
    end

    local ok = pcall(function()
        MySQL.insert.await(
            "INSERT INTO gtarp_numbers_bets (citizenid, number, stake, draw_seq) VALUES (?, ?, ?, ?)",
            { cid, num, stake, seq })
    end)
    if not ok then
        Bridge.GiveCash(src, stake, 'numbers-refund')  -- stake pulled but slip failed — refund
        Bridge.Notify(src, 'Numbers', 'The slip tore — your stake was returned.', 'error')
        return
    end

    local mins = math.max(0, math.ceil((nextDrawAt - t) / 60))
    Bridge.Notify(src, 'Numbers',
        ('Slip down: %02d for $%d. Draw in ~%d min. Wins pay %dx (dirty).'):format(num, stake, mins, Config.PayoutMultiple),
        'success')
    dbg(('%s staked $%d on %02d (draw %d)'):format(cid, stake, num, seq))
end

-- ---------------------------------------------------------------------------
-- /collectnumbers — collect winnings (paid in black_money) at the bookie.
-- ---------------------------------------------------------------------------
local function cmdCollect(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atBookie(src) then
        Bridge.Notify(src, 'Numbers', ('Collect at %s.'):format(Config.Bookie.label), 'error')
        return
    end
    if claimLock[cid] then
        Bridge.Notify(src, 'Numbers', 'Still counting your last payout.', 'error')
        return
    end
    claimLock[cid] = true

    local total, ids = 0, {}
    local ok = pcall(function()
        local rows = MySQL.query.await(
            "SELECT id, payout FROM gtarp_numbers_bets WHERE citizenid = ? AND status = 'won' AND paid = 0", { cid }) or {}
        for _, r in ipairs(rows) do
            total = total + tonumber(r.payout)
            ids[#ids + 1] = tonumber(r.id)
        end
    end)
    if not ok then
        claimLock[cid] = nil
        Bridge.Notify(src, 'Numbers', 'The books are jammed — try again.', 'error')
        return
    end
    if total <= 0 or #ids == 0 then
        claimLock[cid] = nil
        Bridge.Notify(src, 'Numbers', 'Nothing to collect.', 'inform')
        return
    end

    -- Mark exactly the rows we summed (not a blanket predicate) so a win the
    -- draw thread lands mid-collect isn't flipped paid without being paid.
    local placeholders = {}
    for i = 1, #ids do placeholders[i] = '?' end
    local marked = 0
    pcall(function()
        local aff = MySQL.update.await(
            "UPDATE gtarp_numbers_bets SET paid = 1 WHERE paid = 0 AND id IN (" .. table.concat(placeholders, ',') .. ")",
            ids)
        marked = tonumber(aff) or 0
    end)
    if marked ~= #ids then
        -- Couldn't cleanly claim exactly what we counted — undo and bail rather
        -- than risk over/under-paying. (Serialized by claimLock, so this is a
        -- belt-and-braces guard, not an expected path.)
        pcall(function()
            MySQL.update.await(
                "UPDATE gtarp_numbers_bets SET paid = 0 WHERE id IN (" .. table.concat(placeholders, ',') .. ")", ids)
        end)
        claimLock[cid] = nil
        Bridge.Notify(src, 'Numbers', 'Payout hiccup — nothing collected, try again.', 'error')
        return
    end

    if not Bridge.GiveItem(src, Config.WinItem, total) then
        -- Delivery failed — restore the rows so the winnings aren't lost.
        pcall(function()
            MySQL.update.await(
                "UPDATE gtarp_numbers_bets SET paid = 0 WHERE id IN (" .. table.concat(placeholders, ',') .. ")", ids)
        end)
        claimLock[cid] = nil
        Bridge.Notify(src, 'Numbers', 'Could not hand over the cash — try again.', 'error')
        return
    end

    claimLock[cid] = nil
    Bridge.Notify(src, 'Numbers', ('Collected $%d in dirty money. Best get it washed.'):format(total), 'success')
    dbg(('%s collected $%d across %d slip(s)'):format(cid, total, #ids))
end

-- ---------------------------------------------------------------------------
-- /numbersinfo — countdown, your open slips, pending winnings, last result.
-- ---------------------------------------------------------------------------
local function cmdInfo(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local secs = math.max(0, nextDrawAt - now())
    local last
    pcall(function()
        last = MySQL.single.await(
            "SELECT draw_seq, winning_number FROM gtarp_numbers_draws ORDER BY draw_seq DESC LIMIT 1")
    end)
    local pending, open = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(payout),0) AS p FROM gtarp_numbers_bets WHERE citizenid = ? AND status = 'won' AND paid = 0",
            { cid })
        pending = r and tonumber(r.p) or 0
    end)
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_numbers_bets WHERE citizenid = ? AND draw_seq = ? AND status = 'open'",
            { cid, openDrawSeq })
        open = r and tonumber(r.n) or 0
    end)
    local lastStr = last and ('last #%d hit %02d'):format(last.draw_seq, last.winning_number) or 'no draws yet'
    Bridge.Notify(src, 'Numbers',
        ('Next draw ~%dm%02ds · %d open slip(s) · $%d dirty to collect · %s · pays %dx'):format(
            math.floor(secs / 60), secs % 60, open, pending, lastStr, Config.PayoutMultiple), 'inform')
end

-- ---------------------------------------------------------------------------
-- Commands, draw loop, boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('numbers', function(source, args) cmdNumbers(source, args) end)
Bridge.RegisterCommand('collectnumbers', function(source) cmdCollect(source) end)
Bridge.RegisterCommand('numbersinfo', function(source) cmdInfo(source) end)

CreateThread(function()
    while true do
        Wait(Config.DrawIntervalSec * 1000)
        if drawEnabled then runDraw() end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not Bridge.ItemExists(Config.WinItem) then
        print(('^1[gtarp_numbers] FATAL: win item "%s" is not registered in ox_inventory — '
            .. 'numbers game disabled (nothing to pay winners in).^0'):format(Config.WinItem))
        return
    end
    -- Continue an in-progress open draw across restarts: pick up after the last
    -- resolved sequence, but never behind an existing open bet's sequence.
    local maxDrawn, maxOpen = 0, 0
    pcall(function()
        local r = MySQL.single.await("SELECT COALESCE(MAX(draw_seq),0) AS n FROM gtarp_numbers_draws")
        maxDrawn = r and tonumber(r.n) or 0
    end)
    pcall(function()
        local r = MySQL.single.await("SELECT COALESCE(MAX(draw_seq),0) AS n FROM gtarp_numbers_bets WHERE status = 'open'")
        maxOpen = r and tonumber(r.n) or 0
    end)
    openDrawSeq = math.max(maxDrawn + 1, maxOpen, 1)
    nextDrawAt = now() + Config.DrawIntervalSec
    drawEnabled = true

    local draws, staked = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS c, COALESCE(SUM(staked),0) AS s FROM gtarp_numbers_draws")
        draws = r and tonumber(r.c) or 0
        staked = r and tonumber(r.s) or 0
    end)
    print(('[gtarp_numbers] bookie open — draw #%d live (every %dm), %d draw(s) run, $%d staked all-time; pays %dx'):format(
        openDrawSeq, math.floor(Config.DrawIntervalSec / 60), draws, staked, Config.PayoutMultiple))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { draws = 0, totalStaked = 0, totalPaid = 0, openDrawSeq = openDrawSeq }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS c, COALESCE(SUM(staked),0) AS s, COALESCE(SUM(payout_total),0) AS p FROM gtarp_numbers_draws")
        if r then
            out.draws = tonumber(r.c) or 0
            out.totalStaked = tonumber(r.s) or 0
            out.totalPaid = tonumber(r.p) or 0
        end
    end)
    return out
end)
