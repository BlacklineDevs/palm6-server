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

-- F9: fail-closed money-mirror latch. Set true at boot if fc_core's mirrored
-- pricing/betting-window drifts from this money authority (a real drift makes the
-- HUD/sportsbook lie). While set, OpenMatch refuses to open NEW (mispriced) matches;
-- settlement/void of in-flight rows still run off the real values below, so nothing
-- strands. Declared here so OpenMatch (defined above the boot check) can read it.
local moneyMirrorFailed = false

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same shape as palm6_courier and
-- palm6_ems: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- fightclub tables at all. Every query in this file is pcall-wrapped, so the
-- failure is SILENT: /fcmatches prints an empty board, /fcbet takes nothing,
-- and settleMatch quietly recovers no stranded money. On the live box these
-- statements are pure no-ops.
--
-- The CREATE TABLEs are copied VERBATIM from sql/0028_fightclub.sql (0066
-- re-states the same two tables byte-identically). The ALTERs come from
-- sql/0054_fightclub_settlement.sql and sql/0066_fightclub_defjam.sql. They
-- are repeated here (they also live in palm6_dbmigrate) because dbmigrate and
-- this resource boot on independent threads: whichever runs second is a no-op
-- and neither can lose the race. The DEFAULT values are load-bearing and must
-- NOT be changed - settled DEFAULT 1 and rep_awarded DEFAULT 1 are what stop
-- the boot reconcile from re-paying the entire match history exactly once.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- Statements THIS resource owns and can answer for. Only these feed
    -- SchemaReady. See the ALTER note below for why they are kept separate.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_fightclub_matches` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    fighter1_citizenid VARCHAR(64) NOT NULL,
    fighter1_name VARCHAR(100) NOT NULL DEFAULT '',
    fighter2_citizenid VARCHAR(64) NOT NULL,
    fighter2_name VARCHAR(100) NOT NULL DEFAULT '',
    status ENUM('betting','live','resolved') NOT NULL DEFAULT 'betting',
    winner_citizenid VARCHAR(64) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    betting_ends_at TIMESTAMP NULL DEFAULT NULL,
    live_started_at TIMESTAMP NULL DEFAULT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_fightclub_matches_status (status),
    INDEX idx_palm6_fightclub_matches_f1 (fighter1_citizenid),
    INDEX idx_palm6_fightclub_matches_f2 (fighter2_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_fightclub_bets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    match_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    fighter TINYINT UNSIGNED NOT NULL,
    amount INT UNSIGNED NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_fightclub_bet (match_id, citizenid),
    INDEX idx_palm6_fightclub_bets_match (match_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists. Folding these into SchemaReady would make a perfectly
    -- healthy MySQL box print `schema MISSING` on every single boot, which is
    -- the permanent false alarm that trains an operator to ignore the banner.
    -- The two CREATE TABLEs above are what SchemaReady answers for; these
    -- columns are additive and their absence is reported on its own line.
    -- Same pattern as palm6_courier and palm6_mdt's schemaOk.
    local alters = {
        [[
ALTER TABLE `palm6_fightclub_bets`
    ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 0
        ]],
        [[
ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `purse_paid` TINYINT NOT NULL DEFAULT 0
        ]],
        [[
ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1
        ]],
        [[
ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `style1`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `style2`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `fighter1_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `fighter2_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `method`         VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS `entry_pot`      INT     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid1`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid2`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `rep_awarded`    TINYINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS `is_pve`         TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `cpu_tier`       TINYINT NULL,
    ADD COLUMN IF NOT EXISTS `cpu_fighter`    VARCHAR(48) NULL
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_fightclub] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_fightclub] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

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
    if moneyMirrorFailed then return nil end   -- F9: mirror drift -> refuse new matches (caller refunds antes)
    if not aCid or not bCid then return nil end
    -- F7 §5 defense-in-depth: refuse if EITHER fighter is already in a betting/live
    -- row (the same guard fc_combat enforces), so the money authority self-enforces
    -- the one-match-per-fighter rule regardless of caller (e.g. /fcdebug). Caller
    -- refunds both antes on nil.
    local activeRow
    pcall(function()
        activeRow = MySQL.single.await([[
            SELECT id FROM palm6_fightclub_matches
             WHERE (fighter1_citizenid IN (?, ?) OR fighter2_citizenid IN (?, ?))
               AND status IN ('betting','live') LIMIT 1]], { aCid, bCid, aCid, bCid })
    end)
    if activeRow then
        dbg('OpenMatch refused — a fighter already has an active betting/live match (§5)')
        return nil
    end
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

-- fc_core's Config.Pve block (fail-closed nil if fc_core is missing/erroring).
local function pveCfg()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    if not ok or type(cfg) ~= 'table' then return nil end
    return cfg.Pve
end

-- Resolve a dark-PvE house CPU fighter's display name + ped model from
-- Config.Pve.CpuFighters by id. Display-only (never money), so a miss falls
-- back to the raw id string — same philosophy as fighterModel above.
local function cpuFighterInfo(pve, cpuId)
    if pve and type(pve.CpuFighters) == 'table' then
        for _, c in ipairs(pve.CpuFighters) do
            if c.id == cpuId then return c.name or tostring(cpuId), c.model or tostring(cpuId) end
        end
    end
    return tostring(cpuId), tostring(cpuId)
end

-- Open a MONEY-INERT PvE (solo/story) match row (spec §19). Charges NOTHING:
-- entry_pot is pinned 0 (Config.Pve.EntryFee), no ante, no betting window (the
-- fc_combat caller GoLives immediately). is_pve=1 so /fcbet rejects the row and
-- the §10b entry-pot payout no-ops. fighter2 is the server-owned CPU; its
-- fighter2_citizenid is the reserved per-match sentinel '__CPU__:<matchId>',
-- which the '__' bank guard makes structurally incapable of ever touching the
-- bank. INSERT failure returns nil — nothing was charged, so nothing to refund.
-- Returns matchId on success, nil on gate/fail.
exports('OpenPveMatch', function(humanCid, tier, styleH, fighterH, cpuFighter, cpuStyle)
    if not fcEnabled() then return nil end
    if moneyMirrorFailed then return nil end   -- F9: mirror drift -> refuse new matches
    if not humanCid then return nil end
    -- §19.4 gate: PvE ships dark; only open when fc_core's Config.Pve.Enabled is true.
    local pve = pveCfg()
    if not pve or pve.Enabled ~= true then return nil end
    tier = math.floor(tonumber(tier) or 0)

    -- §5 active-match guard: the human may not already be in a betting/live row.
    local activeRow
    pcall(function()
        activeRow = MySQL.single.await([[
            SELECT id FROM palm6_fightclub_matches
             WHERE (fighter1_citizenid = ? OR fighter2_citizenid = ?)
               AND status IN ('betting','live') LIMIT 1]], { humanCid, humanCid })
    end)
    if activeRow then
        dbg('OpenPveMatch refused — human already has an active betting/live match (§5)')
        return nil
    end

    local hName          = nameForCid(humanCid)
    local hModel         = fighterModel(fighterH)
    local cName, cModel  = cpuFighterInfo(pve, cpuFighter)

    -- INSERT is_pve=1, entry_pot=0 (EntryFee pinned 0 — NO charge, no ante),
    -- betting_ends_at=NOW() (no window). fighter2_citizenid is a placeholder
    -- immediately replaced below with the per-match '__CPU__:<id>' sentinel.
    local ok, matchId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_fightclub_matches
                (fighter1_citizenid, fighter1_name, fighter2_citizenid, fighter2_name,
                 style1, style2, fighter1_model, fighter2_model,
                 status, entry_pot, is_pve, cpu_tier, cpu_fighter, betting_ends_at)
            VALUES (?, ?, '__CPU__', ?, ?, ?, ?, ?, 'betting', 0, 1, ?, ?, NOW())
        ]], { humanCid, hName, cName, styleH, cpuStyle, hModel, cModel, tier, cpuFighter })
    end)
    if not ok or not matchId or matchId == 0 then
        dbg('OpenPveMatch INSERT failed — nothing charged, nothing to refund')
        return nil
    end

    -- Per-match CPU sentinel (spec §19.2): reserved '__' prefix (caught by the
    -- '__' bank guard) AND collision-free per match, so a future multi-ring can
    -- run two CPU bouts without a shared '__CPU__' false-positiving the §5
    -- active-match check. Set AFTER insert so it can key on the auto-increment id.
    pcall(function()
        MySQL.update.await(
            "UPDATE palm6_fightclub_matches SET fighter2_citizenid = CONCAT('__CPU__:', id) WHERE id = ?",
            { matchId })
    end)

    dbg(('OpenPveMatch #%d: %s vs CPU %s (tier=%d, is_pve=1, entry_pot=0, sentinel=__CPU__:%d)')
        :format(matchId, tostring(humanCid), tostring(cpuFighter), tier, matchId))
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
    -- The whole boot sequence runs on this thread because ensureSchema has to
    -- Wait for oxmysql's connection before any query can run, and the open-match
    -- count must not run before the table is guaranteed to exist. Total delay
    -- before reconcileUnsettled is unchanged at 8s (3000 + 5000).
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It exists to diagnose the fresh-box case where the
        -- tables are absent, which is otherwise completely silent: every query
        -- in this file is pcall'd, so the board just reports zero forever.
        if not SchemaReady then
            print('^1[palm6_fightclub] schema MISSING - betting and settlement are INERT on this box.^0')
        end
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
        Wait(5000)
        reconcileUnsettled()
        -- F5/F9 money-mirror drift guard, FAIL-CLOSED. The HUD/sportsbook quotes
        -- odds off fc_core's MIRRORED WinnerPursePct / Betting.RakePct, and fc_combat
        -- runs its betting-window close timer off fc_core's Timers.BetWindowSec while
        -- the DB betting_ends_at + the HUD board run off THIS resource's real values
        -- (Config.Fight.WinnerPursePct / Config.Betting.RakePct / Config.Betting.
        -- WindowSec) — any drift makes the board lie about payouts or the clock.
        -- A not-yet-started fc_core (late ensure order) is transient -> warn + skip;
        -- a REAL drift with fc_core up is fatal -> latch OpenMatch inert + loud error.
        local coreOk, core = pcall(function() return exports.palm6_fc_core:Config() end)
        if not coreOk or type(core) ~= 'table' then
            print('[palm6_fightclub] WARN money-mirror check skipped — fc_core not up yet')
        else
            local drift =
                math.abs((tonumber(core.WinnerPursePct) or -1) - Config.Fight.WinnerPursePct) >= 1e-9
                or math.abs((core.Betting and tonumber(core.Betting.RakePct) or -1) - Config.Betting.RakePct) >= 1e-9
                or (tonumber(core.Timers and core.Timers.BetWindowSec) ~= tonumber(Config.Betting.WindowSec))
            if drift then
                moneyMirrorFailed = true   -- F9: block new matches (in-flight rows still settle)
                print('[palm6_fightclub] FATAL money-mirror drift — fc_core mirror != money authority:')
                print(('  WinnerPursePct core=%s money=%s | RakePct core=%s money=%s | BetWindowSec core=%s money=%s')
                    :format(tostring(core.WinnerPursePct), tostring(Config.Fight.WinnerPursePct),
                            tostring(core.Betting and core.Betting.RakePct), tostring(Config.Betting.RakePct),
                            tostring(core.Timers and core.Timers.BetWindowSec), tostring(Config.Betting.WindowSec)))
                print('[palm6_fightclub] OpenMatch is now INERT until the mirror is fixed — no new matches will open.')
                error('[palm6_fightclub] money-mirror drift — refusing to open new matches (fix fc_core / fightclub config parity)')
            end
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
