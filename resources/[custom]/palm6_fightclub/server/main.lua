-- ============================================================================
-- palm6_fightclub/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- Def Jam Fight Club rewire (Phase 0). The queue + server-swept combat are
-- GONE — the match lifecycle (challenge -> select -> betting -> live ->
-- resolved) is owned by palm6_fc_combat. This resource is now the MONEY
-- AUTHORITY only: it exposes guarded server exports that open/advance/resolve/
-- void a match row and runs the recoverable, idempotent settlement (spectator
-- parimutuel pool + the two-fighter entry-stake pot). Every money move is
-- charge-before-grant / claim-before-credit, every state flip is a guarded
-- UPDATE ... WHERE status='<expected>', and a crash mid-payout is re-driven by
-- the boot reconcile with NO double-pay. NEVER a mint: the winner's entry cut
-- is the RESIDUAL (entry_pot - entryRake - loserCut) so no config combo can
-- create money (spec 10b).
-- ============================================================================

local lastAction = {}    -- [src] = { [key] = ts } — chat-command spam guard

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_fightclub] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- HARD prod gate. fc_core owns Config.Enabled (isolated Lua state -> reached
-- via export). Missing/erroring fc_core => inert (false) so the feature never
-- opens new matches or takes bets before it is proven. Settlement/reconcile/
-- void are deliberately NOT gated so in-flight matches always finish paying
-- out even after a mid-session cutover (spec 15).
local function fcEnabled()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and cfg ~= nil and cfg.Enabled == true
end

-- Money-safety boot asserts (spec 10b). A failed assert stops the script — the
-- intended fail-closed gate: never boot a config that could mint on the entry
-- pot. entryRake + loserCut can never exceed the pot (winnerCut is the
-- residual), and a loss must always sting.
assert(Config.Fight.EntryRakePct + Config.Fight.EntryPotLoserPct <= 1,
    '[palm6_fightclub] money-safety: Config.Fight.EntryRakePct + EntryPotLoserPct must be <= 1')
assert(Config.Fight.EntryPotLoserPct < 0.5,
    '[palm6_fightclub] money-safety: Config.Fight.EntryPotLoserPct must be < 0.5 (a loss must sting)')

-- ---------------------------------------------------------------------------
-- Server-side name / model resolution for a match row (never client-trusted).
-- ---------------------------------------------------------------------------
local function nameForCid(cid)
    local s = Bridge.GetSourceByCitizenId(cid)
    if s then return Bridge.GetPlayerName(s) end
    return tostring(cid)
end

-- fighterId -> ped model, resolved through fc_core's data table; falls back to
-- treating the passed value as a raw model string (display-only, never money).
local function fighterModel(fighterId)
    local ok, f = pcall(function() return exports.palm6_fc_core:GetFighter(fighterId) end)
    if ok and f and f.model then return f.model end
    return tostring(fighterId)
end

-- ---------------------------------------------------------------------------
-- Idempotency claim helpers (claim-before-credit: WE flipped 0->1 iff true).
-- ---------------------------------------------------------------------------
local function claimBet(betId)
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_fightclub_bets SET paid = 1 WHERE id = ? AND paid = 0", { betId }) == 1
    end)
    return claimed
end

-- Claim one fighter's entry-pot payout flag. slot is a fixed 1|2 -> whitelisted
-- column name (never client input), so the interpolation is injection-safe.
local function claimEntry(matchId, slot)
    local col = (slot == 1) and 'entry_paid1' or 'entry_paid2'
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            ("UPDATE palm6_fightclub_matches SET %s = 1 WHERE id = ? AND %s = 0"):format(col, col),
            { matchId }) == 1
    end)
    return claimed
end

local function paidSnap(match, slot)
    return tonumber((slot == 1) and match.entry_paid1 or match.entry_paid2) == 1
end

local function markSettled(matchId)
    pcall(function()
        MySQL.update.await(
            "UPDATE palm6_fightclub_matches SET settled = 1 WHERE id = ? AND settled = 0", { matchId })
    end)
end

-- ---------------------------------------------------------------------------
-- Recoverable, idempotent settlement. Every credit is claimed BEFORE the money
-- moves; the entry-pot block runs BEFORE markSettled in BOTH branches so a
-- crash mid-credit leaves status='resolved' AND settled=0 -> re-driven by
-- reconcileUnsettled with no double-pay. entry_pot / entry_paid1 / entry_paid2
-- are in the SELECT so a replay can skip already-credited antes.
-- ---------------------------------------------------------------------------
local function settleMatch(matchId, reasonLabel)
    local match
    pcall(function()
        match = MySQL.single.await([[
            SELECT winner_citizenid, purse_paid, entry_pot, entry_paid1, entry_paid2,
                   fighter1_citizenid, fighter1_name,
                   fighter2_citizenid, fighter2_name
              FROM palm6_fightclub_matches WHERE id = ? AND status = 'resolved']],
            { matchId })
    end)
    if not match then
        dbg(('settle #%d skipped — resolved-row fetch failed; will retry on boot'):format(matchId))
        return
    end

    local bets = {}
    pcall(function()
        bets = MySQL.query.await(
            "SELECT id, citizenid, fighter, amount, paid FROM palm6_fightclub_bets WHERE match_id = ?", { matchId }) or {}
    end)

    local winnerCid = match.winner_citizenid  -- nil/NULL == draw / void
    local entryPot  = tonumber(match.entry_pot) or 0

    if not winnerCid then
        -- Draw / void: full refund of every unpaid bet + unwind the entry pot.
        for _, b in ipairs(bets) do
            if tonumber(b.paid) ~= 1 and claimBet(b.id) then
                Bridge.CreditBankByCitizenId(b.citizenid, tonumber(b.amount) or 0, 'fightclub-draw-refund')
                local s = Bridge.GetSourceByCitizenId(b.citizenid)
                if s then Bridge.Notify(s, 'Fight Club', ('Match #%d no contest — $%d refunded.'):format(matchId, b.amount), 'inform') end
            end
        end
        -- Entry-pot unwind: refund each ante half (2*EntryStake is even -> no
        -- dust). Claim-before-credit via entry_paid1/2; no-op when entry_pot==0.
        if entryPot > 0 then
            local half = math.floor(entryPot / 2)
            if not paidSnap(match, 1) and claimEntry(matchId, 1) then
                Bridge.CreditBankByCitizenId(match.fighter1_citizenid, half, 'fightclub-entry-refund')
                local s1 = Bridge.GetSourceByCitizenId(match.fighter1_citizenid)
                if s1 then Bridge.Notify(s1, 'Fight Club', ('Match #%d no contest — $%d entry refunded.'):format(matchId, half), 'inform') end
            end
            if not paidSnap(match, 2) and claimEntry(matchId, 2) then
                Bridge.CreditBankByCitizenId(match.fighter2_citizenid, entryPot - half, 'fightclub-entry-refund')
                local s2 = Bridge.GetSourceByCitizenId(match.fighter2_citizenid)
                if s2 then Bridge.Notify(s2, 'Fight Club', ('Match #%d no contest — $%d entry refunded.'):format(matchId, entryPot - half), 'inform') end
            end
        end
        markSettled(matchId)
        dbg(('match #%d settled DRAW/VOID (%s) — %d bet(s), entry_pot=%d'):format(matchId, reasonLabel or '?', #bets, entryPot))
        return
    end

    local winnerSlot = (match.fighter1_citizenid == winnerCid) and 1 or 2
    local winnerName = (winnerSlot == 1 and match.fighter1_name) or match.fighter2_name or 'the winner'
    local loserCid   = (winnerSlot == 1) and match.fighter2_citizenid or match.fighter1_citizenid

    -- Parimutuel pool math from the FULL bet set (deterministic on replay).
    local totalPool, winningSideTotal = 0, 0
    for _, b in ipairs(bets) do
        local amt = tonumber(b.amount) or 0
        totalPool = totalPool + amt
        if tonumber(b.fighter) == winnerSlot then winningSideTotal = winningSideTotal + amt end
    end

    local rake       = math.floor(totalPool * Config.Betting.RakePct)
    local purse      = math.floor(totalPool * Config.Fight.WinnerPursePct)
    local forBettors = math.max(0, totalPool - rake - purse)

    -- Winner betting-purse — claimed once via matches.purse_paid.
    if purse > 0 then
        local claimedPurse = false
        pcall(function()
            claimedPurse = MySQL.update.await(
                "UPDATE palm6_fightclub_matches SET purse_paid = 1 WHERE id = ? AND purse_paid = 0", { matchId }) == 1
        end)
        if claimedPurse then
            Bridge.CreditBankByCitizenId(winnerCid, purse, 'fightclub-purse')
            local ws = Bridge.GetSourceByCitizenId(winnerCid)
            if ws then Bridge.Notify(ws, 'Fight Club', ('You won match #%d (%s) — $%d purse.'):format(matchId, reasonLabel or 'knockout', purse), 'success') end
        end
    end

    if loserCid then
        local ls = Bridge.GetSourceByCitizenId(loserCid)
        if ls then Bridge.Notify(ls, 'Fight Club', ('You lost match #%d (%s vs %s) — %s.'):format(matchId, match.fighter1_name, match.fighter2_name, reasonLabel or 'knockout'), 'error') end
    end

    -- Parimutuel split: each bet claimed exactly once. Losing stakes + rounding
    -- remainder are the sink ("buys round up, payouts round down").
    for _, b in ipairs(bets) do
        if tonumber(b.paid) ~= 1 and claimBet(b.id) then
            if tonumber(b.fighter) == winnerSlot and winningSideTotal > 0 and forBettors > 0 then
                local share = math.floor(forBettors * (tonumber(b.amount) or 0) / winningSideTotal)
                if share > 0 then
                    Bridge.CreditBankByCitizenId(b.citizenid, share, 'fightclub-bet-win')
                    local s = Bridge.GetSourceByCitizenId(b.citizenid)
                    if s then Bridge.Notify(s, 'Fight Club', ('Match #%d: %s won — you collected $%d.'):format(matchId, winnerName, share), 'success') end
                end
            end
        end
    end

    -- Entry-pot payout (winner RESIDUAL — never a mint). winnerCut absorbs the
    -- remainder so entryRake + loserCut + winnerCut == entry_pot exactly for ANY
    -- config combo. Claim-before-credit via entry_paid<slot>. BEFORE markSettled
    -- so a crash mid-credit is re-driven by the boot reconcile. No-op when
    -- entry_pot == 0 (historical / for-rep-only / is_pve rows).
    if entryPot > 0 then
        local entryRake = math.floor(entryPot * Config.Fight.EntryRakePct)
        local loserCut  = math.floor(entryPot * Config.Fight.EntryPotLoserPct)
        local winnerCut = entryPot - entryRake - loserCut          -- residual
        local loserSlot = (winnerSlot == 1) and 2 or 1
        if not paidSnap(match, winnerSlot) and claimEntry(matchId, winnerSlot) then
            Bridge.CreditBankByCitizenId(winnerCid, winnerCut, 'fightclub-entry')
            local ws = Bridge.GetSourceByCitizenId(winnerCid)
            if ws then Bridge.Notify(ws, 'Fight Club', ('Match #%d — $%d entry purse.'):format(matchId, winnerCut), 'success') end
        end
        if loserCut > 0 and loserCid then
            if not paidSnap(match, loserSlot) and claimEntry(matchId, loserSlot) then
                Bridge.CreditBankByCitizenId(loserCid, loserCut, 'fightclub-entry-consolation')
                local ls2 = Bridge.GetSourceByCitizenId(loserCid)
                if ls2 then Bridge.Notify(ls2, 'Fight Club', ('Match #%d — $%d consolation.'):format(matchId, loserCut), 'inform') end
            end
        end
    end

    markSettled(matchId)
    dbg(('match #%d settled: winner=%s (%s), pool=%d rake=%d purse=%d forBettors=%d entry_pot=%d')
        :format(matchId, winnerCid, reasonLabel or '?', totalPool, rake, purse, forBettors, entryPot))
end

-- Boot reconcile — re-drive any match flipped 'resolved' whose payout never
-- finished (server died mid-settlement). Idempotent: settleMatch skips every
-- already-claimed step. Delayed so palm6_dbmigrate's ALTERs (settled/paid/
-- purse_paid/entry_paid1/2 columns) have landed first.
local function reconcileUnsettled()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            "SELECT id FROM palm6_fightclub_matches WHERE status = 'resolved' AND settled = 0") or {}
    end)
    for _, row in ipairs(pending) do
        settleMatch(row.id, 'recovered')
    end
    if #pending > 0 then
        print(('[palm6_fightclub] boot reconcile settled %d interrupted payout(s)'):format(#pending))
    end
end

-- Server-internal seam — fired AFTER settle so downstream (T5 rep, T10 arena)
-- sees a fully-paid terminal row. TriggerEvent (NEVER a net event): unspoofable.
local function fireResolved(matchId, winnerCid, method)
    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT fighter1_citizenid, fighter2_citizenid,
                   UNIX_TIMESTAMP(live_started_at) AS started_at,
                   UNIX_TIMESTAMP(resolved_at)     AS ended_at,
                   is_pve, cpu_tier
              FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
    end)
    local loserCid = nil
    if row and winnerCid then
        loserCid = (row.fighter1_citizenid == winnerCid) and row.fighter2_citizenid or row.fighter1_citizenid
    end
    TriggerEvent('fc:match:resolved', {
        matchId   = matchId,
        winnerCid = winnerCid,
        loserCid  = loserCid,
        method    = method,
        startedAt = row and tonumber(row.started_at) or nil,
        endedAt   = row and tonumber(row.ended_at) or nil,
        isPve     = row and tonumber(row.is_pve) == 1 or false,
        cpuTier   = row and row.cpu_tier or nil,
    })
end

-- Atomic live->resolved flip (winnerCid=nil => draw). settled=0 + rep_awarded=0
-- mark the row for settlement (this boot) and rep (T5). Reused by ResolveMatch.
local function resolveLive(matchId, winnerCid, method)
    local marked = false
    pcall(function()
        marked = MySQL.update.await([[
            UPDATE palm6_fightclub_matches
               SET status = 'resolved', winner_citizenid = ?, method = ?,
                   resolved_at = NOW(), settled = 0, rep_awarded = 0
             WHERE id = ? AND status = 'live']], { winnerCid, method, matchId }) == 1
    end)
    if not marked then return false end
    settleMatch(matchId, method)
    fireResolved(matchId, winnerCid, method)
    return true
end

-- Parimutuel tote board broadcast (display-only; settlement is the pool truth).
local function broadcastOdds(matchId)
    local m
    pcall(function()
        m = MySQL.single.await([[
            SELECT status, GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), betting_ends_at)) AS secs_left
              FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
    end)
    if not m then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT fighter, COALESCE(SUM(amount),0) AS total, COUNT(*) AS n
              FROM palm6_fightclub_bets WHERE match_id = ? GROUP BY fighter]], { matchId }) or {}
    end)
    local sideA, sideB, betCount = 0, 0, 0
    for _, r in ipairs(rows) do
        betCount = betCount + (tonumber(r.n) or 0)
        if tonumber(r.fighter) == 1 then sideA = tonumber(r.total) or 0
        elseif tonumber(r.fighter) == 2 then sideB = tonumber(r.total) or 0 end
    end
    local secsLeft = (m.status == 'betting') and (tonumber(m.secs_left) or 0) or 0
    TriggerClientEvent('palm6_fightclub:oddsUpdate', -1, {
        matchId = matchId, sideA = sideA, sideB = sideB, betCount = betCount, secsLeft = secsLeft,
    })
end

-- ---------------------------------------------------------------------------
-- Server-only money / lifecycle exports (consumed by T4 debug + T6 combat).
-- ---------------------------------------------------------------------------

-- Open a betting-window match row. Does NOT charge antes (caller charges per
-- spec 10b then unwinds on nil). Returns matchId on success, nil on gate/fail.
exports('OpenMatch', function(aCid, bCid, styleA, styleB, fighterA, fighterB, entryStake)
    if not fcEnabled() then return nil end
    if not aCid or not bCid then return nil end
    entryStake = math.floor(tonumber(entryStake) or 0)
    if entryStake < 0 then return nil end
    local entryPot     = 2 * entryStake
    local aName, bName = nameForCid(aCid), nameForCid(bCid)
    local mdlA, mdlB   = fighterModel(fighterA), fighterModel(fighterB)
    local ok, matchId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_fightclub_matches
                (fighter1_citizenid, fighter1_name, fighter2_citizenid, fighter2_name,
                 style1, style2, fighter1_model, fighter2_model,
                 status, entry_pot, is_pve, betting_ends_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'betting', ?, 0, NOW() + INTERVAL ? SECOND)
        ]], { aCid, aName, bCid, bName, styleA, styleB, mdlA, mdlB, entryPot, Config.Betting.WindowSec })
    end)
    if not ok or not matchId or matchId == 0 then
        dbg('OpenMatch INSERT failed — caller must refund both antes')
        return nil
    end
    dbg(('OpenMatch #%d: %s vs %s (entry_pot=%d)'):format(matchId, aCid, bCid, entryPot))
    return matchId
end)

-- betting -> live (guarded). Closes /fcbet by leaving the 'betting' state.
exports('GoLive', function(matchId)
    local moved = false
    pcall(function()
        moved = MySQL.update.await(
            "UPDATE palm6_fightclub_matches SET status = 'live', live_started_at = NOW() WHERE id = ? AND status = 'betting'",
            { matchId }) == 1
    end)
    if moved then dbg(('match #%d betting closed — fight is live'):format(matchId)) end
    return moved
end)

-- live -> resolved (atomic) + settle + seam. winnerCid=nil => draw.
exports('ResolveMatch', function(matchId, winnerCid, method)
    return resolveLive(matchId, winnerCid, method or 'ko')
end)

-- betting -> resolved(void): abort a match that never went live. Refunds bets +
-- both antes via settleMatch's draw branch.
exports('VoidMatch', function(matchId)
    local marked = false
    pcall(function()
        marked = MySQL.update.await([[
            UPDATE palm6_fightclub_matches
               SET status = 'resolved', winner_citizenid = NULL, method = 'void',
                   resolved_at = NOW(), settled = 0, rep_awarded = 0
             WHERE id = ? AND status = 'betting']], { matchId }) == 1
    end)
    if not marked then return false end
    settleMatch(matchId, 'void')
    fireResolved(matchId, nil, 'void')
    return true
end)

-- live -> resolved(void): no-contest a LIVE row (boot strand / mid-match cutover
-- / preempt). Refunds bets + both antes via the draw branch.
exports('LiveVoidMatch', function(matchId)
    local marked = false
    pcall(function()
        marked = MySQL.update.await([[
            UPDATE palm6_fightclub_matches
               SET status = 'resolved', winner_citizenid = NULL, method = 'void',
                   resolved_at = NOW(), settled = 0, rep_awarded = 0
             WHERE id = ? AND status = 'live']], { matchId }) == 1
    end)
    if not marked then return false end
    settleMatch(matchId, 'void')
    fireResolved(matchId, nil, 'void')
    return true
end)

exports('BroadcastOdds', function(matchId)
    broadcastOdds(matchId)
end)

-- ---------------------------------------------------------------------------
-- /fcbet <matchid> <1|2> <amount> — spectator wager, guarded atomic claim.
-- ---------------------------------------------------------------------------
local function cmdFcBet(src, args)
    if src == 0 then return end
    if not rl(src, 'fcbet') then return end
    if not fcEnabled() then
        Bridge.Notify(src, 'Fight Club', 'Betting is closed.', 'error')
        return
    end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local matchId = tonumber(args[1])
    local slot    = tonumber(args[2])
    local amount  = math.floor(tonumber(args[3]) or 0)

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
            "SELECT fighter1_citizenid, fighter2_citizenid FROM palm6_fightclub_matches WHERE id = ? AND status = 'betting' AND is_pve = 0",
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

    -- Consume-before-grant: take the stake FIRST; refunded on any insert failure.
    if not Bridge.ChargeBank(src, amount, 'fightclub-bet') then
        Bridge.Notify(src, 'Fight Club', ('You need $%d in the bank.'):format(amount), 'error')
        return
    end

    -- Atomic claim: inserts only if the match is STILL betting, is_pve=0, AND the
    -- aggregate pool + this stake stays <= MaxPoolPerMatch — all folded into ONE
    -- statement (no read-then-write TOCTOU). The pool sum reads the bets table
    -- through a DERIVED table (materialized) so MySQL/MariaDB accepts the target
    -- table inside an INSERT...SELECT subquery (a raw self-reference throws error
    -- 1093). 0 disables the cap. UNIQUE(match_id,citizenid) rejects a double bet.
    local maxPool = Config.Betting.MaxPoolPerMatch or 0
    local insOk, insId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_fightclub_bets (match_id, citizenid, fighter, amount)
            SELECT ?, ?, ?, ? FROM palm6_fightclub_matches
            WHERE id = ? AND status = 'betting' AND is_pve = 0
              AND (? = 0 OR (
                    SELECT COALESCE(SUM(b.amount), 0)
                    FROM (SELECT amount FROM palm6_fightclub_bets WHERE match_id = ?) AS b
                  ) + ? <= ?)
        ]], { matchId, cid, slot, amount, matchId, maxPool, matchId, amount, maxPool })
    end)
    if not insOk then
        Bridge.CreditBankByCitizenId(cid, amount, 'fightclub-bet-refund')
        Bridge.Notify(src, 'Fight Club', 'You already have a bet on this match.', 'error')
        return
    end
    if not insId or insId == 0 then
        Bridge.CreditBankByCitizenId(cid, amount, 'fightclub-bet-refund')
        Bridge.Notify(src, 'Fight Club', 'Betting just closed, or the match pool cap is full.', 'error')
        return
    end

    Bridge.Notify(src, 'Fight Club',
        ('Bet placed: $%d on fighter %d in match #%d.'):format(amount, slot, matchId), 'success')
    dbg(('bet %d on match #%d fighter %d by %s'):format(amount, matchId, slot, cid))
    broadcastOdds(matchId)
end

-- ---------------------------------------------------------------------------
-- /fcmatches — open board (betting + live), read-only.
-- ---------------------------------------------------------------------------
local function cmdFcMatches(src)
    if src == 0 then return end
    if not rl(src, 'fcmatches') then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, status, fighter1_name, fighter2_name,
                   TIMESTAMPDIFF(SECOND, NOW(), betting_ends_at) AS secs_left
            FROM palm6_fightclub_matches
            WHERE status IN ('betting', 'live')
            ORDER BY id DESC LIMIT 20
        ]]) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no open matches — challenge someone at the ring to start one' })
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
-- Commands + boot. /fcjoin, /fcleave, the sweep thread, and the playerDropped
-- match-resolution are GONE — the lifecycle is owned by palm6_fc_combat (T6).
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('fcbet', function(source, args) cmdFcBet(source, args) end)
Bridge.RegisterCommand('fcmatches', function(source) cmdFcMatches(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local openN = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_fightclub_matches WHERE status IN ('betting', 'live')")
        openN = r and tonumber(r.n) or 0
    end)
    -- Open betting/live rows are NOT auto-resolved here; T6 owns the live-strand
    -- no-contest (LiveVoidMatch) at its own boot. This only reports + recovers
    -- interrupted payouts.
    print(('[palm6_fightclub] money authority up — %d match(es) still open'):format(openN))
    CreateThread(function()
        Wait(8000)
        reconcileUnsettled()
        -- C5 money-mirror drift guard: the HUD/sportsbook quotes odds off
        -- fc_core's MIRRORED WinnerPursePct / Betting.RakePct, but settlement
        -- pays off THIS resource's real values — if they ever drift, the board
        -- lies about payouts. pcall-guarded so a not-yet-started fc_core (or a
        -- late ensure order) degrades to a warning instead of a hard stop; a
        -- real drift with fc_core up surfaces as a loud console error.
        local ok, err = pcall(function()
            local core = exports.palm6_fc_core:Config()
            assert(math.abs(core.WinnerPursePct - Config.Fight.WinnerPursePct) < 1e-9
                and math.abs(core.Betting.RakePct - Config.Betting.RakePct) < 1e-9,
                '[palm6_fightclub] money-mirror drift')
        end)
        if not ok then
            print(('[palm6_fightclub] WARN money-mirror check: %s'):format(tostring(err)))
        end
    end)
end)

---Open-match count for devtest and future consumers.
exports('GetSummary', function()
    local out = { openMatches = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_fightclub_matches WHERE status IN ('betting', 'live')")
        out.openMatches = r and tonumber(r.n) or 0
    end)
    return out
end)

---Read-only money-authority getter: the entry ante fc_combat charges + passes to OpenMatch.
---Lives here so shared/config.lua Config.Fight.EntryStake stays the single source of truth (no drift).
exports('GetEntryStake', function()
    return math.floor(tonumber(Config.Fight and Config.Fight.EntryStake) or 0)
end)
