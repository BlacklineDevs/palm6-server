-- ============================================================================
-- gtarp_fightclub/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The ring. Two citizens present at the ring queue up; the instant a second
-- one joins they're auto-paired into a match that opens a betting window.
-- Spectators wager cash on either fighter (parimutuel pool, house rake).
-- When betting closes the fight goes live: the sweep polls both fighters
-- every Config.Fight.PollSec off their live synced peds — health, position,
-- current weapon — and declares a winner on knockout, forfeits the fighter
-- who leaves the ring / draws a weapon / disconnects, and calls a full-
-- refund draw on a mutual forfeit or a timeout with no knockout.
--
-- Nothing here trusts the client: proximity, health, and weapon are all
-- server-derived off the live entity (gtarp_bounty's /capture technique).
-- Every state transition that moves money or resolves a match is a guarded
-- UPDATE ... WHERE status = '<expected>' so a race between the sweep thread
-- and a player command (or two racing commands) can only ever let one path
-- through — the same idiom gtarp_bounty's /capture and gtarp_courier's
-- acceptPosting fix use. Betting itself is closed by an atomic
-- INSERT ... SELECT ... WHERE status = 'betting' guarded further by a
-- UNIQUE(match_id, citizenid) key, so double-betting can't slip through the
-- same in-memory-cache gap that bit gtarp_pumpcoin's ticker-uniqueness bug —
-- here the database itself is the only source of truth for "is this bet
-- allowed to exist," not a Lua table that might be stale mid-yield.
-- ============================================================================

local queue = {}         -- ordered array of { citizenid, src, name, queuedAt }
local lastAction = {}    -- [src] = { [key] = ts } — chat-command spam guard

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_fightclub] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function atRing(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Ring.coords) <= Config.Ring.radius
end

-- Does this citizen already have an open (betting/live) match? Prevents
-- queueing or being paired twice.
local function activeMatchForCitizen(cid)
    local row
    pcall(function()
        row = MySQL.single.await(
            [[SELECT id FROM gtarp_fightclub_matches
              WHERE (fighter1_citizenid = ? OR fighter2_citizenid = ?)
                AND status IN ('betting', 'live') LIMIT 1]],
            { cid, cid })
    end)
    return row ~= nil
end

local function removeFromQueueBySrc(src)
    for i = #queue, 1, -1 do
        if queue[i].src == src then table.remove(queue, i) end
    end
end

local function removeFromQueueByCitizenId(cid)
    for i = #queue, 1, -1 do
        if queue[i].citizenid == cid then table.remove(queue, i) end
    end
end

-- Re-validate a queued entry is still the same character, still online, and
-- still at the ring right before pairing — the queue can go stale between
-- join and pairing (reconnect, walked off, swapped character).
local function stillQueueable(entry)
    if not entry or not entry.src then return false end
    if Bridge.GetCitizenId(entry.src) ~= entry.citizenid then return false end
    return atRing(entry.src)
end

-- ---------------------------------------------------------------------------
-- Match creation
-- ---------------------------------------------------------------------------
-- Returns true on success. On DB failure both fighters are requeued and the
-- caller must NOT immediately retry pairing them again in the same pass —
-- see tryPairQueue's early `return` below. Without that, a persistently
-- failing DB would make tryPairQueue re-pop and re-fail the same pair in an
-- unbounded loop within a single /fcjoin invocation (each MySQL.insert.await
-- still yields, so it isn't a hard freeze, but it never terminates and
-- hammers the DB the whole time).
local function createMatch(a, b)
    local ok, matchId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_fightclub_matches
                (fighter1_citizenid, fighter1_name, fighter2_citizenid, fighter2_name,
                 status, betting_ends_at)
            VALUES (?, ?, ?, ?, 'betting', NOW() + INTERVAL ? SECOND)
        ]], { a.citizenid, a.name, b.citizenid, b.name, Config.Betting.WindowSec })
    end)
    if not ok or not matchId or matchId == 0 then
        dbg('createMatch failed to insert — requeueing both')
        queue[#queue + 1] = a
        queue[#queue + 1] = b
        return false
    end
    Bridge.Notify(a.src, 'Fight Club',
        ('Match #%d: you vs %s. Betting is open for %ds — fight starts after.')
        :format(matchId, b.name, Config.Betting.WindowSec), 'success')
    Bridge.Notify(b.src, 'Fight Club',
        ('Match #%d: you vs %s. Betting is open for %ds — fight starts after.')
        :format(matchId, a.name, Config.Betting.WindowSec), 'success')
    dbg(('match #%d created: %s vs %s'):format(matchId, a.citizenid, b.citizenid))
    return true
end

local function tryPairQueue()
    while #queue >= 2 do
        local a = table.remove(queue, 1)
        local b = table.remove(queue, 1)
        local aOk, bOk = stillQueueable(a), stillQueueable(b)
        if aOk and bOk then
            if not createMatch(a, b) then
                -- DB is failing right now; both are back in the queue, but
                -- stop pairing this pass instead of looping forever on the
                -- same insert. The next /fcjoin (or a future join) retries.
                return
            end
        elseif aOk then
            queue[#queue + 1] = a  -- requeue the still-valid one at the back
            if b.src then Bridge.Notify(b.src, 'Fight Club', 'You left the queue.', 'inform') end
        elseif bOk then
            queue[#queue + 1] = b
            if a.src then Bridge.Notify(a.src, 'Fight Club', 'You left the queue.', 'inform') end
        end
        -- neither valid: both silently dropped, loop continues in case more remain
    end
end

-- ---------------------------------------------------------------------------
-- /fcjoin — queue up at the ring
-- ---------------------------------------------------------------------------
local function cmdFcJoin(src)
    if src == 0 then return end
    if not rl(src, 'fcjoin') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if not atRing(src) then
        Bridge.Notify(src, 'Fight Club', ('You need to be at %s.'):format(Config.Ring.label), 'error')
        return
    end
    for _, q in ipairs(queue) do
        if q.citizenid == cid then
            Bridge.Notify(src, 'Fight Club', "You're already in the queue.", 'error')
            return
        end
    end
    if activeMatchForCitizen(cid) then
        Bridge.Notify(src, 'Fight Club', 'You already have a match in progress.', 'error')
        return
    end

    queue[#queue + 1] = { citizenid = cid, src = src, name = Bridge.GetPlayerName(src), queuedAt = now() }
    Bridge.Notify(src, 'Fight Club', 'Queued at the ring. Waiting for an opponent...', 'inform')
    tryPairQueue()
end

-- ---------------------------------------------------------------------------
-- /fcleave — leave the queue before being paired
-- ---------------------------------------------------------------------------
local function cmdFcLeave(src)
    if src == 0 then return end
    if not rl(src, 'fcleave') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    removeFromQueueByCitizenId(cid)
    Bridge.Notify(src, 'Fight Club', 'You left the queue.', 'inform')
end

-- ---------------------------------------------------------------------------
-- /fcbet <matchid> <1|2> <amount> — spectator wager, guarded atomic claim
-- ---------------------------------------------------------------------------
local function cmdFcBet(src, args)
    if src == 0 then return end
    if not rl(src, 'fcbet') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local matchId = tonumber(args[1])
    local slot = tonumber(args[2])
    local amount = math.floor(tonumber(args[3]) or 0)

    if not matchId or (slot ~= 1 and slot ~= 2)
        or amount < Config.Betting.MinBet or amount > Config.Betting.MaxBet then
        Bridge.Notify(src, 'Fight Club',
            ('Usage: /fcbet [match #] [1 or 2] [$%d-%d]')
            :format(Config.Betting.MinBet, Config.Betting.MaxBet), 'error')
        return
    end

    local m
    pcall(function()
        m = MySQL.single.await(
            "SELECT fighter1_citizenid, fighter2_citizenid FROM gtarp_fightclub_matches WHERE id = ? AND status = 'betting'",
            { matchId })
    end)
    if not m then
        Bridge.Notify(src, 'Fight Club', 'No open betting window with that match number.', 'error')
        return
    end
    if cid == m.fighter1_citizenid or cid == m.fighter2_citizenid then
        Bridge.Notify(src, 'Fight Club', 'Fighters cannot bet on their own match.', 'error')
        return
    end

    -- Atomic claim: the row only inserts if the match is STILL in the
    -- betting window at the exact instant of insert (WHERE status =
    -- 'betting' evaluated inside the same statement, no read-then-write
    -- gap), and the schema's UNIQUE(match_id, citizenid) key rejects a
    -- second bet from the same citizen outright — see the module header
    -- for why this must be a DB constraint, not an in-memory check.
    local insOk, insId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_fightclub_bets (match_id, citizenid, fighter, amount)
            SELECT ?, ?, ?, ? FROM gtarp_fightclub_matches
            WHERE id = ? AND status = 'betting'
        ]], { matchId, cid, slot, amount, matchId })
    end)
    if not insOk then
        Bridge.Notify(src, 'Fight Club', 'You already have a bet on this match.', 'error')
        return
    end
    if not insId or insId == 0 then
        Bridge.Notify(src, 'Fight Club', 'Betting just closed on that match.', 'error')
        return
    end

    if not Bridge.ChargeBank(src, amount, 'fightclub-bet') then
        pcall(function() MySQL.update.await('DELETE FROM gtarp_fightclub_bets WHERE id = ?', { insId }) end)
        Bridge.Notify(src, 'Fight Club', ('You need $%d in the bank.'):format(amount), 'error')
        return
    end

    Bridge.Notify(src, 'Fight Club',
        ('Bet placed: $%d on fighter %d in match #%d.'):format(amount, slot, matchId), 'success')
    dbg(('bet %d on match #%d fighter %d by %s'):format(amount, matchId, slot, cid))
end

-- ---------------------------------------------------------------------------
-- /fcmatches — open board (betting + live)
-- ---------------------------------------------------------------------------
local function cmdFcMatches(src)
    if src == 0 then return end
    if not rl(src, 'fcmatches') then return end

    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, status, fighter1_name, fighter2_name,
                   TIMESTAMPDIFF(SECOND, NOW(), betting_ends_at) AS secs_left
            FROM gtarp_fightclub_matches
            WHERE status IN ('betting', 'live')
            ORDER BY id DESC LIMIT 20
        ]]) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no open matches — /fcjoin at the ring to start one' })
        return
    end
    local lines = {}
    for _, r in ipairs(rows) do
        if r.status == 'betting' then
            local secs = math.max(0, tonumber(r.secs_left) or 0)
            lines[#lines + 1] = ('#%d [BETTING %ds left] 1) %s vs 2) %s — /fcbet %d [1|2] [$]')
                :format(r.id, secs, r.fighter1_name, r.fighter2_name, r.id)
        else
            lines[#lines + 1] = ('#%d [LIVE] %s vs %s'):format(r.id, r.fighter1_name, r.fighter2_name)
        end
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- Resolution — guarded UPDATE before any money moves, exactly once per
-- match (the sweep thread is the only writer of 'live'->'resolved', but the
-- guard is kept regardless — cheap, and matches house style).
-- ---------------------------------------------------------------------------
local function resolveMatch(matchId, winnerCid, reasonLabel)
    local marked = false
    pcall(function()
        marked = MySQL.update.await(
            "UPDATE gtarp_fightclub_matches SET status = 'resolved', winner_citizenid = ?, resolved_at = NOW() WHERE id = ? AND status = 'live'",
            { winnerCid, matchId }) == 1
    end)
    if not marked then return end

    local match
    pcall(function()
        match = MySQL.single.await(
            "SELECT fighter1_citizenid, fighter1_name, fighter2_citizenid, fighter2_name FROM gtarp_fightclub_matches WHERE id = ?",
            { matchId })
    end)
    local bets = {}
    pcall(function()
        bets = MySQL.query.await(
            "SELECT citizenid, fighter, amount FROM gtarp_fightclub_bets WHERE match_id = ?", { matchId }) or {}
    end)

    if not winnerCid then
        -- Draw (mutual forfeit or timeout): full refund, no rake, no purse.
        -- Doesn't need `match` at all, so this path is safe even if the
        -- fighter-row fetch above failed.
        for _, b in ipairs(bets) do
            Bridge.CreditBankByCitizenId(b.citizenid, tonumber(b.amount) or 0, 'fightclub-draw-refund')
            local s = Bridge.GetSourceByCitizenId(b.citizenid)
            if s then Bridge.Notify(s, 'Fight Club', ('Match #%d ended in a draw — $%d refunded.'):format(matchId, b.amount), 'inform') end
        end
        dbg(('match #%d resolved DRAW (%s) — %d bet(s) refunded'):format(matchId, reasonLabel or '?', #bets))
        return
    end

    if not match then
        -- The status flip to 'resolved' already landed (the guarded UPDATE
        -- above succeeded), but the follow-up SELECT for fighter names
        -- failed. Do NOT guess which slot the winner was — that would risk
        -- crediting the purse/pool against the wrong fighter's bettors.
        -- Bets are left untouched and unpaid; the match row (status,
        -- winner_citizenid) is still correct and fixable by hand.
        dbg(('match #%d resolved but fighter-row fetch failed — payout SKIPPED, fix manually')
            :format(matchId))
        return
    end

    local winnerSlot = (match.fighter1_citizenid == winnerCid) and 1 or 2
    local winnerName = (winnerSlot == 1 and match and match.fighter1_name)
        or (match and match.fighter2_name) or 'the winner'

    local totalPool, winningSideTotal = 0, 0
    for _, b in ipairs(bets) do
        local amt = tonumber(b.amount) or 0
        totalPool = totalPool + amt
        if tonumber(b.fighter) == winnerSlot then winningSideTotal = winningSideTotal + amt end
    end

    local rake = math.floor(totalPool * Config.Betting.RakePct)
    local purse = math.floor(totalPool * Config.Fight.WinnerPursePct)
    local forBettors = math.max(0, totalPool - rake - purse)

    if purse > 0 then
        Bridge.CreditBankByCitizenId(winnerCid, purse, 'fightclub-purse')
        local ws = Bridge.GetSourceByCitizenId(winnerCid)
        if ws then Bridge.Notify(ws, 'Fight Club', ('You won match #%d (%s) — $%d purse.'):format(matchId, reasonLabel or 'knockout', purse), 'success') end
    end

    local loserCid = (winnerSlot == 1) and (match and match.fighter2_citizenid) or (match and match.fighter1_citizenid)
    if loserCid then
        local ls = Bridge.GetSourceByCitizenId(loserCid)
        if ls then Bridge.Notify(ls, 'Fight Club', ('You lost match #%d (%s vs %s) — %s.'):format(matchId, match.fighter1_name, match.fighter2_name, reasonLabel or 'knockout'), 'error') end
    end

    -- Parimutuel split: each winning bettor gets their proportional share,
    -- rounded down. Losing-side bets and rounding remainder are the sink —
    -- same "buys round up, payouts round down" honesty gtarp_pumpcoin uses.
    if winningSideTotal > 0 and forBettors > 0 then
        for _, b in ipairs(bets) do
            if tonumber(b.fighter) == winnerSlot then
                local share = math.floor(forBettors * (tonumber(b.amount) or 0) / winningSideTotal)
                if share > 0 then
                    Bridge.CreditBankByCitizenId(b.citizenid, share, 'fightclub-bet-win')
                    local s = Bridge.GetSourceByCitizenId(b.citizenid)
                    if s then Bridge.Notify(s, 'Fight Club', ('Match #%d: %s won — you collected $%d.'):format(matchId, winnerName, share), 'success') end
                end
            end
        end
    end
    dbg(('match #%d resolved: winner=%s (%s), pool=%d rake=%d purse=%d forBettors=%d')
        :format(matchId, winnerCid, reasonLabel or '?', totalPool, rake, purse, forBettors))
end

-- ---------------------------------------------------------------------------
-- Sweep — queue timeout, betting->live transitions, live-match monitoring.
-- Runs every Config.Fight.PollSec (>=2s, never Wait(0)).
-- ---------------------------------------------------------------------------
local function sweepQueueTimeouts()
    local t = now()
    for i = #queue, 1, -1 do
        local q = queue[i]
        if (t - q.queuedAt) >= Config.Queue.MaxWaitSec then
            table.remove(queue, i)
            if q.src then Bridge.Notify(q.src, 'Fight Club', 'No opponent found — dropped from the queue.', 'inform') end
        end
    end
end

local function sweepBettingToLive()
    local due = {}
    pcall(function()
        due = MySQL.query.await(
            "SELECT id FROM gtarp_fightclub_matches WHERE status = 'betting' AND betting_ends_at <= NOW()") or {}
    end)
    for _, row in ipairs(due) do
        local moved = false
        pcall(function()
            moved = MySQL.update.await(
                "UPDATE gtarp_fightclub_matches SET status = 'live', live_started_at = NOW() WHERE id = ? AND status = 'betting'",
                { row.id }) == 1
        end)
        if moved then dbg(('match #%d betting closed — fight is live'):format(row.id)) end
    end
end

-- Server-derived check: is this fighter still eligible to keep fighting?
-- Returns (out, reason) — out=true means disqualified/forfeited/KO'd.
local function checkFighter(citizenid)
    local src = Bridge.GetSourceByCitizenId(citizenid)
    if not src then return true, 'disconnected' end
    local c = Bridge.GetCoords(src)
    if not c or Bridge.Distance(c, Config.Ring.coords) > Config.Ring.radius then
        return true, 'left the ring'
    end
    if Config.Fight.RequireUnarmed then
        local wh = Bridge.GetCurrentWeaponHash(src)
        if wh and wh ~= Bridge.UnarmedHash() then
            return true, 'drew a weapon'
        end
    end
    local health = Bridge.GetHealth(src)
    if health and health <= Config.Fight.KOHealth then
        return true, 'knocked out'
    end
    return false, nil
end

local function sweepLiveMatches()
    local live = {}
    pcall(function()
        live = MySQL.query.await([[
            SELECT id, fighter1_citizenid, fighter2_citizenid,
                   TIMESTAMPDIFF(SECOND, live_started_at, NOW()) AS elapsed
            FROM gtarp_fightclub_matches WHERE status = 'live'
        ]]) or {}
    end)
    for _, m in ipairs(live) do
        local out1, reason1 = checkFighter(m.fighter1_citizenid)
        local out2, reason2 = checkFighter(m.fighter2_citizenid)
        if out1 and out2 then
            resolveMatch(m.id, nil, ('double forfeit: %s / %s'):format(reason1, reason2))
        elseif out1 then
            resolveMatch(m.id, m.fighter2_citizenid, reason1)
        elseif out2 then
            resolveMatch(m.id, m.fighter1_citizenid, reason2)
        elseif (tonumber(m.elapsed) or 0) >= Config.Fight.MaxDurationSec then
            resolveMatch(m.id, nil, 'timeout')
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Fight.PollSec * 1000)
        sweepQueueTimeouts()
        sweepBettingToLive()
        sweepLiveMatches()
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot + cleanup
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('fcjoin', function(source) cmdFcJoin(source) end)
Bridge.RegisterCommand('fcleave', function(source) cmdFcLeave(source) end)
Bridge.RegisterCommand('fcbet', function(source, args) cmdFcBet(source, args) end)
Bridge.RegisterCommand('fcmatches', function(source) cmdFcMatches(source) end)

AddEventHandler('playerDropped', function()
    removeFromQueueBySrc(source)
    -- Live/betting matches involving a dropped fighter self-resolve on the
    -- next sweep tick (checkFighter treats "not online" as a forfeit) —
    -- nothing to do here beyond the queue, which has no DB row yet.
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local openN = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_fightclub_matches WHERE status IN ('betting', 'live')")
        openN = r and tonumber(r.n) or 0
    end)
    print(('[gtarp_fightclub] ring open — %d match(es) in progress'):format(openN))
end)

---Open-match / queue counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { openMatches = 0, queued = #queue }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_fightclub_matches WHERE status IN ('betting', 'live')")
        out.openMatches = r and tonumber(r.n) or 0
    end)
    return out
end)
