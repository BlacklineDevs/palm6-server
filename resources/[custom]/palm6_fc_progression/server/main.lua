-- ============================================================================
-- palm6_fc_progression/server/main.lua
--
-- Rep / rank / unlock ledger for the fight club. Consumes the server-internal
-- seam fc:match:resolved (fired by palm6_fightclub after settleMatch). Rep is
-- DISPLAY/RANK ONLY — it pays no cash and unlocks only cosmetic/name variants
-- (styles are stat-identical, §8/§9), so farm->money is severed at the source.
--
-- Money-safety idioms mirror palm6_fightclub's settleMatch:
--   * atomic claim-before-credit: UPDATE ... SET rep_awarded=1 WHERE
--     rep_awarded=0 AND is_pve=0 (affected==1 gates) — exactly one award ever.
--   * a crash in the claim->credit window strands ONE award (never double-pays).
--   * boot reconcile re-drives status='resolved' AND rep_awarded=0 rows.
-- The is_pve=0 gate is load-bearing: PvP (this file) and the PvE §19.5 path
-- share ONE seam + ONE rep_awarded column; without it a CPU win would mint the
-- full RepPerPvpWin past every cap and try to credit the '__CPU__' sentinel.
-- ============================================================================

-- Rank bands (rep -> rank_tier). Resource-internal + tunable in feel-test; rep
-- is cash-neutral so these bands only drive the HUD career badge (T9).
local RANK_THRESHOLDS = { 300, 800, 1600, 3000, 5000 }

-- Config (from fc_core, isolated Lua state -> read via export). Cached on first
-- award; loadConf is idempotent and cheap.
local RepPerPvpWin, RepCooldownSec, DailyRepCap, DailyDistinctOpponentCap, LoserConsolation

local function loadConf()
    local ok, FC = pcall(function() return exports.palm6_fc_core:Config() end)
    if not ok or type(FC) ~= 'table' then
        -- fc_core not up yet: fall back to the spec anchors so a claim never
        -- silently no-ops on missing config (still cash-neutral).
        RepPerPvpWin, RepCooldownSec = 100, 3600
        DailyRepCap, DailyDistinctOpponentCap, LoserConsolation = 5, 4, 0
        return
    end
    local R = FC.Rep or {}
    RepPerPvpWin             = tonumber(FC.RepPerPvpWin) or 100
    RepCooldownSec           = tonumber(R.RepCooldownSec) or 3600
    DailyRepCap              = tonumber(R.DailyRepCap) or 5
    DailyDistinctOpponentCap = tonumber(R.DailyDistinctOpponentCap) or 4
    LoserConsolation         = tonumber(R.LoserConsolation) or 0
end

local function dbg(msg)
    print('[palm6_fc_progression] ' .. msg)
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same pattern as palm6_mdt/palm6_courier/
-- palm6_ems: Wait(3000) for oxmysql on a thread, per-statement pcall, CREATE
-- TABLE IF NOT EXISTS. sql/ files are applied BY HAND (deploy/README.md) and CI
-- never touches the DB, so a restored backup or a fresh box can boot without
-- these three tables. Every write here is pcall-wrapped, so that loss is
-- SILENT: rep/rank/unlocks quietly stop existing while the console says
-- nothing. Re-running is a harmless no-op on the live box, which already has
-- them.
--
-- Each statement is copied VERBATIM from sql/0066_fightclub_defjam.sql (only
-- the trailing semicolon dropped, since each is one MySQL.query call) so the
-- two can never diverge:
--   palm6_fc_progression, palm6_fc_unlocks, palm6_fc_daily <- sql/0066
--
-- DELIBERATELY NOT CREATED HERE, and this is not an oversight:
--   * palm6_fightclub_matches (read for the anti-farm windows and the
--     rep_awarded claim) is palm6_fightclub's table, created by that
--     resource's own migration path. A second copy of someone else's DDL is a
--     divergence waiting to happen.
--   * the 0066 ALTERs that add rep_awarded/is_pve to that table are likewise
--     palm6_fightclub's, and ADD COLUMN IF NOT EXISTS is MariaDB-only syntax
--     that THROWS on MySQL 8 even when the column is present.
--   * palm6_fc_pve_cooldowns exists in 0066 but no query in this resource
--     touches it, so creating it here would be creating an unused table.
--
-- There are no additive ALTERs on the three tables this resource owns, so
-- nothing is excluded from schemaOk here.
-- ---------------------------------------------------------------------------
local schemaOk = true

local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_fc_progression` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    rep INT NOT NULL DEFAULT 0,
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    rank_tier INT NOT NULL DEFAULT 0,
    pve_wins INT NOT NULL DEFAULT 0,
    pve_losses INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_fc_unlocks` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    unlock_id VARCHAR(48) NOT NULL,
    unlocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_fc_unlock (citizenid, unlock_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_fc_daily` (
    citizenid VARCHAR(64) NOT NULL,
    day_bucket VARCHAR(10) NOT NULL,
    pvp_rep_wins INT NOT NULL DEFAULT 0,
    pve_rep_wins INT NOT NULL DEFAULT 0,
    distinct_opponents INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, day_bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            schemaOk = false
            print(('^1[palm6_fc_progression] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    return schemaOk
end

-- Reserved sentinel guard: reject any non-string cid or a '__'-prefixed cid
-- (e.g. '__CPU__') so a mis-plumbed seam can never create a phantom row.
local function isReserved(cid)
    return type(cid) ~= 'string' or cid == '' or cid:sub(1, 2) == '__'
end

local function rankForRep(rep)
    rep = tonumber(rep) or 0
    local tier = 0
    for i = 1, #RANK_THRESHOLDS do
        if rep >= RANK_THRESHOLDS[i] then tier = i else break end
    end
    return tier
end

local function scalarCount(sql, params)
    local n = 0
    pcall(function()
        local r = MySQL.single.await(sql, params)
        if r then n = tonumber(r.n) or 0 end
    end)
    return n
end

-- ---------------------------------------------------------------------------
-- Ledger writers (upsert; row may not exist yet)
-- ---------------------------------------------------------------------------
local function bumpWin(cid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
            VALUES (?, 0, 1, 0, 0)
            ON DUPLICATE KEY UPDATE wins = wins + 1
        ]], { cid })
    end)
end

local function bumpLoss(cid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
            VALUES (?, 0, 0, 1, 0)
            ON DUPLICATE KEY UPDATE losses = losses + 1
        ]], { cid })
    end)
end

-- rep += amount, then recompute rank_tier off the new total.
local function addRep(cid, amount)
    if not amount or amount <= 0 then return end
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
            VALUES (?, ?, 0, 0, 0)
            ON DUPLICATE KEY UPDATE rep = rep + VALUES(rep)
        ]], { cid, amount })
    end)
    local newRep = amount
    pcall(function()
        local r = MySQL.single.await("SELECT rep FROM palm6_fc_progression WHERE citizenid = ?", { cid })
        if r then newRep = tonumber(r.rep) or amount end
    end)
    pcall(function()
        MySQL.update.await("UPDATE palm6_fc_progression SET rank_tier = ? WHERE citizenid = ?",
            { rankForRep(newRep), cid })
    end)
end

-- Shared cross-mode daily counter (contract-mandated for the future PvE path).
-- Incremented BEFORE the rep credit so a crash biases against the grinder.
local function bumpDaily(winnerCid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_daily (citizenid, day_bucket, pvp_rep_wins, pve_rep_wins, distinct_opponents)
            VALUES (?, ?, 1, 0, 0)
            ON DUPLICATE KEY UPDATE pvp_rep_wins = pvp_rep_wins + 1
        ]], { winnerCid, os.date('!%Y-%m-%d') })
    end)
end

-- ---------------------------------------------------------------------------
-- Anti-farm reads — all off palm6_fightclub_matches.resolved_at (true rolling
-- window; the current match is excluded by id, since we already claimed it
-- rep_awarded=1 before these run).
-- ---------------------------------------------------------------------------
local function wonAgainstWithin(matchId, winnerCid, loserCid, seconds)
    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT id FROM palm6_fightclub_matches
             WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
               AND winner_citizenid = ?
               AND (fighter1_citizenid = ? OR fighter2_citizenid = ?)
               AND resolved_at >= (NOW() - INTERVAL ? SECOND)
             LIMIT 1
        ]], { matchId, winnerCid, loserCid, loserCid, seconds })
    end)
    return row ~= nil
end

-- Returns (repAmount, reason). repAmount==0 => capped (reason logged/notified).
local function repToAward(matchId, winnerCid, loserCid)
    -- (b) same-opponent 1h cooldown
    if wonAgainstWithin(matchId, winnerCid, loserCid, RepCooldownSec) then
        return 0, 'cooldown'
    end
    -- (d) daily rep cap — rolling 24h count of this winner's rep-granted PvP wins
    local wins24 = scalarCount([[
        SELECT COUNT(*) AS n FROM palm6_fightclub_matches
         WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
           AND winner_citizenid = ?
           AND resolved_at >= (NOW() - INTERVAL 24 HOUR)
    ]], { matchId, winnerCid })
    if wins24 >= DailyRepCap then return 0, 'daily-cap' end
    -- (d) distinct-opponent cap — only blocks a NEW opponent (a re-beat inside
    -- 24h is already governed by wins24 above).
    if not wonAgainstWithin(matchId, winnerCid, loserCid, 86400) then
        local distinctOpp = scalarCount([[
            SELECT COUNT(DISTINCT CASE WHEN fighter1_citizenid = ?
                        THEN fighter2_citizenid ELSE fighter1_citizenid END) AS n
              FROM palm6_fightclub_matches
             WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
               AND winner_citizenid = ?
               AND resolved_at >= (NOW() - INTERVAL 24 HOUR)
        ]], { winnerCid, matchId, winnerCid })
        if distinctOpp >= DailyDistinctOpponentCap then return 0, 'distinct-cap' end
    end
    return RepPerPvpWin, 'ok'
end

-- ---------------------------------------------------------------------------
-- Award driver — atomic claim, authoritative re-read, ledger, gated rep.
-- Called by the seam handler AND boot reconcile (seam payload ignored for
-- everything money-adjacent; DB row is authority).
-- ---------------------------------------------------------------------------
local function awardRep(matchId)
    loadConf()

    -- 1. atomic claim: PvP only, exactly once. Gates re-fire + PvE rows.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_fightclub_matches SET rep_awarded = 1 WHERE id = ? AND rep_awarded = 0 AND is_pve = 0",
            { matchId }) == 1
    end)
    if not claimed then return end

    -- 2. authoritative resolved row
    local m
    pcall(function()
        m = MySQL.single.await([[
            SELECT winner_citizenid, method, fighter1_citizenid, fighter2_citizenid
              FROM palm6_fightclub_matches WHERE id = ? AND status = 'resolved'
        ]], { matchId })
    end)
    if not m then return end

    local winnerCid = m.winner_citizenid
    local method    = m.method or ''
    -- (c) decisive-only: draw/void produce no winner; forfeit has a winner but
    -- pays NO rep (spec §9c) AND (F10) NO win/loss ledger bump — a forfeit is
    -- uncapped (no pairing-cooldown / daily gate in front of it), so bumping the
    -- ledger on it lets an alt/collusion forfeit-loop farm the win/loss stats.
    local decisive = winnerCid and (method == 'ko' or method == 'finisher' or method == 'forfeit')
    if not decisive then return end
    if isReserved(winnerCid) then
        dbg(('match #%d: winner cid reserved (%s) — no rep'):format(matchId, tostring(winnerCid)))
        return
    end

    local loserCid = (m.fighter1_citizenid == winnerCid) and m.fighter2_citizenid or m.fighter1_citizenid

    -- ledger: ONLY the clean decisive results (ko/finisher). Never forfeit (F10).
    -- Rank is rep-derived, so skipping the forfeit bump keeps rank honest too.
    if method == 'ko' or method == 'finisher' then
        bumpWin(winnerCid)
        if loserCid and not isReserved(loserCid) then bumpLoss(loserCid) end
    end

    -- rep only on a clean decisive result (never forfeit/draw/void)
    if method == 'forfeit' or not loserCid or isReserved(loserCid) then return end

    local repAmount, reason = repToAward(matchId, winnerCid, loserCid)
    if repAmount > 0 then
        bumpDaily(winnerCid)          -- increment-before-credit
        addRep(winnerCid, repAmount)
        local ws = Bridge.GetSourceByCitizenId(winnerCid)
        if ws then
            Bridge.Notify(ws, 'Fight Club',
                ('+%d rep for the win.'):format(repAmount), 'success')
        end
        dbg(('match #%d: %s +%d rep (win over %s)'):format(matchId, winnerCid, repAmount, loserCid))
    else
        local ws = Bridge.GetSourceByCitizenId(winnerCid)
        if ws then
            Bridge.Notify(ws, 'Fight Club',
                'Win recorded — no rep (' .. reason .. ').', 'inform')
        end
        dbg(('match #%d: %s win recorded, rep skipped (%s)'):format(matchId, winnerCid, reason))
    end

    -- optional loser consolation (0 in MVP; same-opponent gated per spec §9b)
    if LoserConsolation > 0 and not wonAgainstWithin(matchId, winnerCid, loserCid, RepCooldownSec) then
        addRep(loserCid, LoserConsolation)
    end
end

-- ===========================================================================
-- §19.5 PvE progression + anti-farm. The PvE path SHARES the fc:match:resolved
-- seam and the rep_awarded column with PvP but claims the COMPLEMENTARY is_pve=1
-- rows — so §9's `is_pve=0` claim and this `is_pve=1` claim can never touch the
-- same match (no double-award, no cross-mint). Four stacked bounds (§19.5) keep a
-- full rolling-day of trivial-AI wins worth LESS than one real PvP win, and the
-- rep is cash-neutral (unlocks cosmetics only). CPU never gets a progression row.
-- ===========================================================================
local PveTierRepFrac, PveDimFactor, PveDailyRepGrantCap, PveRepCooldownSec, PveMinMatchSec

local function loadPveConf()
    local ok, FC = pcall(function() return exports.palm6_fc_core:Config() end)
    local P = (ok and type(FC) == 'table' and FC.Pve) or {}
    PveTierRepFrac      = (type(P.PveTierRepFrac) == 'table' and P.PveTierRepFrac)
                          or { T1 = 0.08, T2 = 0.14, T3 = 0.22, T4 = 0.32, T5 = 0.45 }
    PveDimFactor        = tonumber(P.DimFactor) or 0.5
    PveDailyRepGrantCap = tonumber(P.PveDailyRepGrantCap) or 3
    PveRepCooldownSec   = tonumber(P.PveRepCooldownSec) or 3600
    PveMinMatchSec      = tonumber(P.PveMinMatchSec) or 20
end

-- PvE-only W/L ledger (kept SEPARATE from PvP wins/rank so a CPU fight never pads
-- the real record — §19.5/§19.7). Upsert; the row may not exist yet.
local function bumpPveWin(cid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier, pve_wins, pve_losses)
            VALUES (?, 0, 0, 0, 0, 1, 0)
            ON DUPLICATE KEY UPDATE pve_wins = pve_wins + 1
        ]], { cid })
    end)
end
local function bumpPveLoss(cid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier, pve_wins, pve_losses)
            VALUES (?, 0, 0, 0, 0, 0, 1)
            ON DUPLICATE KEY UPDATE pve_losses = pve_losses + 1
        ]], { cid })
    end)
end

-- Today's shared daily counters (the single source of truth for the caps + the
-- geometric-decay `n`). day_bucket keyed UTC, same as bumpDaily.
local function pveDailyCounts(cid)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT pvp_rep_wins, pve_rep_wins FROM palm6_fc_daily WHERE citizenid = ? AND day_bucket = ?",
            { cid, os.date('!%Y-%m-%d') })
    end)
    return tonumber(row and row.pvp_rep_wins) or 0, tonumber(row and row.pve_rep_wins) or 0
end

-- Increment the PvE granted-win counter (the shared cap SUMs pvp+pve). Called
-- increment-before-credit so a crash biases against the grinder (never over-grants).
local function bumpPveDaily(cid)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_fc_daily (citizenid, day_bucket, pvp_rep_wins, pve_rep_wins, distinct_opponents)
            VALUES (?, ?, 0, 1, 0)
            ON DUPLICATE KEY UPDATE pve_rep_wins = pve_rep_wins + 1
        ]], { cid, os.date('!%Y-%m-%d') })
    end)
end

-- Bound 1: did this human already earn a rep-granting win vs the SAME cpu_tier
-- within the cooldown? (matches-table proxy off resolved_at, mirroring the PvP
-- wonAgainstWithin pattern; a capped prior win counts too -> conservative.)
local function beatTierWithin(matchId, human, tier, seconds)
    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT id FROM palm6_fightclub_matches
             WHERE id <> ? AND status = 'resolved' AND is_pve = 1 AND rep_awarded = 1
               AND winner_citizenid = ? AND cpu_tier = ?
               AND resolved_at >= (NOW() - INTERVAL ? SECOND)
             LIMIT 1
        ]], { matchId, human, tier, seconds })
    end)
    return row ~= nil
end

-- Returns (repAmount, reason). 0 => a bound blocked it (reason logged/notified).
local function repToAwardPve(matchId, human, tier, durSec)
    if durSec ~= nil and durSec < PveMinMatchSec then return 0, 'too-short' end     -- bound 4
    if beatTierWithin(matchId, human, tier, PveRepCooldownSec) then return 0, 'cooldown' end  -- bound 1
    local pvp, pve = pveDailyCounts(human)
    if pve >= PveDailyRepGrantCap then return 0, 'pve-daily-cap' end                -- bound 3
    if (pvp + pve) >= DailyRepCap then return 0, 'daily-cap' end                    -- shared ceiling
    -- bound 2: geometric daily decay. n = (PvE grants already today) + 1.
    local n    = pve + 1
    local frac = tonumber(PveTierRepFrac['T' .. tostring(tier)]) or 0
    local amount = math.floor(frac * RepPerPvpWin * (PveDimFactor ^ (n - 1)))
    if amount <= 0 then return 0, 'zero' end
    return amount, 'ok'
end

-- PvE award driver — atomic is_pve=1 claim, authoritative re-read, PvE ledger,
-- gated decayed rep. Called by the seam AND boot reconcile (row is authority).
local function awardPveRep(matchId)
    loadConf(); loadPveConf()

    -- 1. atomic claim: is_pve=1 complement of §9's claim, exactly once.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_fightclub_matches SET rep_awarded = 1 WHERE id = ? AND rep_awarded = 0 AND is_pve = 1",
            { matchId }) == 1
    end)
    if not claimed then return end

    -- 2. authoritative resolved row (fighter1 = the human; fighter2 = the sentinel).
    local m
    pcall(function()
        m = MySQL.single.await([[
            SELECT winner_citizenid, method, fighter1_citizenid, cpu_tier,
                   UNIX_TIMESTAMP(live_started_at) AS s, UNIX_TIMESTAMP(resolved_at) AS e
              FROM palm6_fightclub_matches WHERE id = ? AND status = 'resolved' AND is_pve = 1
        ]], { matchId })
    end)
    if not m then return end

    local human = m.fighter1_citizenid
    if isReserved(human) then                                   -- defensive: never a sentinel
        dbg(('PvE match #%d: human cid reserved (%s) — skip'):format(matchId, tostring(human)))
        return
    end
    local winnerCid = m.winner_citizenid
    local method    = m.method or ''
    local tier      = tonumber(m.cpu_tier) or 1
    local humanWon  = winnerCid and winnerCid == human and (method == 'ko' or method == 'finisher')
    local humanLost = winnerCid and winnerCid ~= human
                      and (method == 'ko' or method == 'finisher' or method == 'forfeit')

    -- PvE-only ledger (never on void/draw no-contest).
    if humanWon then bumpPveWin(human)
    elseif humanLost then bumpPveLoss(human) end

    if not humanWon then return end                             -- rep only on a clean human win

    local durSec = (m.s and m.e) and (tonumber(m.e) - tonumber(m.s)) or nil
    local amount, reason = repToAwardPve(matchId, human, tier, durSec)
    local hs = Bridge.GetSourceByCitizenId(human)
    if amount > 0 then
        bumpPveDaily(human)                                     -- increment-before-credit
        addRep(human, amount)
        if hs then Bridge.Notify(hs, 'Fight Club', ('+%d rep — Tier %d CPU down.'):format(amount, tier), 'success') end
        dbg(('PvE match #%d: %s +%d rep (tier %d)'):format(matchId, human, amount, tier))
    else
        if hs then Bridge.Notify(hs, 'Fight Club', 'CPU down — no rep (' .. reason .. ').', 'inform') end
        dbg(('PvE match #%d: %s win, rep skipped (%s)'):format(matchId, human, reason))
    end
end

-- ---------------------------------------------------------------------------
-- Seam consumer — server-internal event, NEVER RegisterNetEvent. Both drivers
-- self-gate on their complementary is_pve claim, so calling both on every resolve
-- is safe: a PvP row no-ops awardPveRep, a PvE row no-ops awardRep.
-- ---------------------------------------------------------------------------
AddEventHandler('fc:match:resolved', function(d)
    if type(d) ~= 'table' then return end
    local matchId = tonumber(d.matchId)
    if not matchId then return end
    awardRep(matchId)
    awardPveRep(matchId)
end)

-- ---------------------------------------------------------------------------
-- Boot reconcile — re-drive post-deploy matches whose rep award never landed
-- (crash between the seam fire and the credit). Idempotent via the claim gate.
-- Delayed so palm6_dbmigrate has created the tables + columns (mirror
-- fightclub's Wait(8000)); DEFAULT 1 on rep_awarded backfills history as done.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Schema FIRST, on its own thread. Wait(3000) is the house oxmysql-connect
    -- wait and is strictly less than the reconcile's Wait(8000) below, so the
    -- three CREATEs have landed before anything here SELECTs. Nothing in this
    -- resource holds an in-memory cap or cache that this thread populates (the
    -- daily caps are read straight out of palm6_fc_daily on each award), so no
    -- command or seam needs to be gated on it.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        print(('[palm6_fc_progression] schema %s'):format(schemaOk and 'OK' or '^1MISSING^0'))
    end)
    CreateThread(function()
        Wait(8000)
        local pending = {}
        pcall(function()
            pending = MySQL.query.await(
                "SELECT id, is_pve FROM palm6_fightclub_matches WHERE status = 'resolved' AND rep_awarded = 0") or {}
        end)
        for _, row in ipairs(pending) do
            if tonumber(row.is_pve) == 1 then awardPveRep(row.id) else awardRep(row.id) end
        end
        if #pending > 0 then
            print(('[palm6_fc_progression] boot reconcile awarded rep for %d match(es)'):format(#pending))
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Exports (server-only) — consumed by T9 HUD career panel + future unlock UI.
-- ---------------------------------------------------------------------------
exports('GetRep', function(citizenid)
    local r
    pcall(function()
        r = MySQL.single.await("SELECT rep FROM palm6_fc_progression WHERE citizenid = ?", { citizenid })
    end)
    return r and tonumber(r.rep) or 0
end)

exports('GetRank', function(citizenid)
    local r
    pcall(function()
        r = MySQL.single.await("SELECT rank_tier FROM palm6_fc_progression WHERE citizenid = ?", { citizenid })
    end)
    return r and tonumber(r.rank_tier) or 0
end)

exports('HasUnlock', function(citizenid, unlockId)
    local r
    pcall(function()
        r = MySQL.single.await(
            "SELECT 1 AS ok FROM palm6_fc_unlocks WHERE citizenid = ? AND unlock_id = ? LIMIT 1",
            { citizenid, unlockId })
    end)
    return r ~= nil
end)
