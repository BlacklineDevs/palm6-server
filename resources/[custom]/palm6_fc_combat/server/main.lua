-- ============================================================================
-- palm6_fc_combat/server/main.lua
--
-- The fight LIFECYCLE + single resolver seam. Owns the in-memory match state,
-- CHALLENGE→SELECT→ACCEPTED→BETTING→COUNTDOWN→LIVE→RESOLVED transitions, and
-- the playerDropped DC handler. Money lives in palm6_fightclub (called via
-- OpenMatch/GoLive/ResolveMatch/VoidMatch/LiveVoidMatch). Combat strikes/HP are
-- added by Task 7, the finisher by Task 8 — both hook fc:combat:live + MatchState.
--
-- Ships prod-inert: every entry point gates on exports.palm6_fc_core:Config().Enabled.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Section A: state tables, config/gate helpers, ring + DB guards.
-- ---------------------------------------------------------------------------

local SELECT_WINDOW_SEC = 15   -- client-UX select window (not money); defaults applied if a side never picks
local RATE = { fcchallenge = 3, fcaccept = 1, fcdecline = 1, fcselect = 1 }

local matches        = {}   -- [matchId] = { cidA,cidB,srcA,srcB, selA,selB, nameA,nameB, modelA,modelB, roundStarted,resolving,inFinisher,startedAt,wentLive,bettingEndsAt }
local activeByCid    = {}   -- [cid]  = matchId (in-memory quick lookup; DB is the authority)
local activeBySrc    = {}   -- [src]  = matchId (playerDropped routing)
local pendingChallenges = {} -- [targetCid] = { fromCid, fromSrc, targetSrc, expiresAt }
local staging        = {}   -- [stgId] = { aCid,bCid,aSrc,bSrc, selA,selB, submittedA,submittedB, done }
local stagingBySrc   = {}   -- [src] = stgId
local stagingSeq     = 0
local lastAction     = {}   -- [src][key] = ts — command/event spam guard
local entryStakeCache = nil
local bootDone       = false -- boot no-contest must finish before any challenge is accepted (§11)

local function now() return os.time() end

local function fcCore()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and cfg or nil
end

local function enabled()
    local cfg = fcCore()
    return cfg ~= nil and cfg.Enabled == true
end

local function dbg(msg)
    local cfg = fcCore()
    if cfg and cfg.Debug then print('[palm6_fc_combat] ' .. msg) end
end

local function rl(src, key)
    local window = RATE[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function stateKeys()
    local ok, sk = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    return ok and sk or nil
end

local function atRing(src)
    local c = Bridge.GetCoords(src)
    local cfg = fcCore()
    if not c or not cfg then return false end
    return Bridge.Distance(c, cfg.Ring.coords) <= cfg.Ring.radius
end

-- DB is the single source of truth for occupancy (survives restart; the
-- in-memory maps are cleared by a crash) — mirrors fightclub activeMatchForCitizen.
local function activeMatchForCitizen(cid)
    local row
    pcall(function()
        row = MySQL.single.await(
            [[SELECT id FROM palm6_fightclub_matches
              WHERE (fighter1_citizenid = ? OR fighter2_citizenid = ?)
                AND status IN ('betting','live') LIMIT 1]], { cid, cid })
    end)
    return row ~= nil
end

local function ringBusy()
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id FROM palm6_fightclub_matches WHERE status IN ('betting','live') LIMIT 1")
    end)
    return row ~= nil
end

local function getEntryStake()
    if entryStakeCache ~= nil then return entryStakeCache end
    local ok, v = pcall(function() return exports.palm6_fightclub:GetEntryStake() end)
    entryStakeCache = (ok and tonumber(v)) or 0
    return entryStakeCache
end

local function validPick(fighterId, styleId)
    local cfg = fcCore()
    local f = exports.palm6_fc_core:GetFighter(fighterId)
    local s = exports.palm6_fc_core:GetStyle(styleId)
    if f and s then return fighterId, styleId end
    return cfg.DefaultFighter, cfg.DefaultStyle
end
-- (C7: no getFightMarks fallback here — T10's fc:match:countdown seam owns the
-- fight-mark geometry + the palm6_fc_arena:squareUp emission. T6 only fires the seam.)

-- ---------------------------------------------------------------------------
-- Section B: teardown + resolveFight (the single resolver hub T7/T8/DC/timeout
-- all route through). Both are in-file GLOBALS so T7/T8 code appended to THIS
-- file binds to them by name.
-- ---------------------------------------------------------------------------

-- Canonical teardown: clears statebag + player state, tells both clients to
-- unwind (drop model/appearance), fires the arena cleanup seam, frees the ring.
-- Called on RESOLVE, void, DC, and the boot broadcast.
function teardownMatch(matchId)
    local m = matches[matchId]
    if not m then return end
    local sk = stateKeys()
    if sk then
        GlobalState[sk.matchKey(matchId)] = nil
        for _, src in ipairs({ m.srcA, m.srcB }) do
            if src then
                Player(src).state:set(sk.PLAYER_ACTIVE, false, true)
                Player(src).state:set(sk.PLAYER_SLOT, false, true)
            end
        end
    end
    for _, src in ipairs({ m.srcA, m.srcB }) do
        if src then TriggerClientEvent('palm6_fc_combat:teardown', src, { matchId = matchId }) end
    end
    TriggerEvent('fc:match:teardown', { matchId = matchId })
    if m.cidA then activeByCid[m.cidA] = nil end
    if m.cidB then activeByCid[m.cidB] = nil end
    if m.srcA then activeBySrc[m.srcA] = nil end
    if m.srcB then activeBySrc[m.srcB] = nil end
    matches[matchId] = nil
    dbg(('match #%d torn down'):format(matchId))
end

-- The ONE resolve entry. winnerCid=nil => draw/void. method: ko/finisher/forfeit/draw/void.
-- Idempotent via the resolving flag + fightclub's own atomic status-guarded UPDATEs.
--   roundStarted           -> ResolveMatch (live row pays a winner)
--   wentLive & !roundStarted (COUNTDOWN) -> LiveVoidMatch (no-contest, never pays — §5 pre-LIVE)
--   !wentLive (BETTING)    -> VoidMatch (betting-row draw refund)
function resolveFight(matchId, winnerCid, method)
    local m = matches[matchId]
    if not m or m.resolving then return end
    m.resolving = true
    if m.roundStarted then
        exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method or 'ko')
    elseif m.wentLive then
        exports.palm6_fightclub:LiveVoidMatch(matchId)
    else
        exports.palm6_fightclub:VoidMatch(matchId)
    end
    teardownMatch(matchId)
end

-- Round-cap timeout. Task 7 REPLACES this body with an HP%-comparison winner
-- (DrawBand). Until T7 lands (no HP), a timeout is an honest draw.
function onRoundTimeout(matchId)
    local m = matches[matchId]
    if not m or m.resolving or not m.roundStarted then return end
    resolveFight(matchId, nil, 'draw')
end

local function startRoundTimer(matchId)
    local cap = fcCore().Timers.RoundSec
    CreateThread(function()
        Wait(cap * 1000)
        onRoundTimeout(matchId)
    end)
end

-- ---------------------------------------------------------------------------
-- Section C: enterLive + GoLive/countdown + betting timer (2s tote board).
-- ---------------------------------------------------------------------------

local function enterLive(matchId)
    local m = matches[matchId]
    if not m or m.resolving then return end
    m.roundStarted = true
    m.startedAt = now()
    local cfg = fcCore()
    local sk = stateKeys()
    if sk then
        GlobalState[sk.matchKey(matchId)] = {
            status = 'live', roundStarted = true,
            slot = {
                [1] = { hp = cfg.Vitals.StartHP, stam = cfg.Vitals.MaxStamina, blazin = 0, name = m.nameA, model = m.modelA },
                [2] = { hp = cfg.Vitals.StartHP, stam = cfg.Vitals.MaxStamina, blazin = 0, name = m.nameB, model = m.modelB },
            },
        }
        if m.srcA then Player(m.srcA).state:set(sk.PLAYER_ACTIVE, matchId, true); Player(m.srcA).state:set(sk.PLAYER_SLOT, 1, true) end
        if m.srcB then Player(m.srcB).state:set(sk.PLAYER_ACTIVE, matchId, true); Player(m.srcB).state:set(sk.PLAYER_SLOT, 2, true) end
    end
    -- seconds=0 => GO
    if m.srcA then TriggerClientEvent('palm6_fc_combat:countdown', m.srcA, { matchId = matchId, seconds = 0 }) end
    if m.srcB then TriggerClientEvent('palm6_fc_combat:countdown', m.srcB, { matchId = matchId, seconds = 0 }) end
    startRoundTimer(matchId)
    TriggerEvent('fc:combat:live', { matchId = matchId })   -- C8: T7 consumes this to startRound (no 1s dead-zone)
    dbg(('match #%d LIVE'):format(matchId))
end

local function goLiveAndCountdown(matchId)
    local m = matches[matchId]
    if not m or m.resolving or m.roundStarted then return end
    if not exports.palm6_fightclub:GoLive(matchId) then
        -- betting->live flip lost the race (already voided/resolved): clean up local shell
        teardownMatch(matchId)
        return
    end
    m.wentLive = true
    -- refresh srcs (a fighter could have reconnected during the 60s window)
    m.srcA = Bridge.GetSourceByCitizenId(m.cidA)
    m.srcB = Bridge.GetSourceByCitizenId(m.cidB)
    if m.srcA then activeBySrc[m.srcA] = matchId end
    if m.srcB then activeBySrc[m.srcB] = matchId end
    -- C7: T10 owns fight-mark geometry + the palm6_fc_arena:squareUp emission.
    -- T6 fires ONLY the countdown seam here (no squareUp send, no getFightMarks).
    TriggerEvent('fc:match:countdown', { matchId = matchId, cidA = m.cidA, cidB = m.cidB })  -- arena crowd/cam + square-up
    local cd = fcCore().Timers.CountdownSec
    if m.srcA then TriggerClientEvent('palm6_fc_combat:countdown', m.srcA, { matchId = matchId, seconds = cd }) end
    if m.srcB then TriggerClientEvent('palm6_fc_combat:countdown', m.srcB, { matchId = matchId, seconds = cd }) end
    dbg(('match #%d COUNTDOWN (%ds)'):format(matchId, cd))
    CreateThread(function()
        Wait(cd * 1000)
        enterLive(matchId)
    end)
end

-- C4: sportsbook 2s tote board + closing line. Rebroadcast the live parimutuel
-- line every OddsBroadcastSec while the match is still 'betting', until
-- betting_ends_at; THEN flip to live/countdown; THEN one final BroadcastOdds
-- AFTER the GoLive flip so T9's board reads status='live'/secsLeft=0 ("CLOSED").
local function startBettingTimer(matchId)
    local cfg = fcCore()
    local interval = math.max(1, math.floor(tonumber(cfg.Betting and cfg.Betting.OddsBroadcastSec) or 2))
    CreateThread(function()
        local m = matches[matchId]
        if not m then return end
        local endsAt = m.bettingEndsAt or (now() + cfg.Timers.BetWindowSec)
        while true do
            m = matches[matchId]
            if not m or m.resolving or m.wentLive or m.roundStarted then return end
            if now() >= endsAt then break end
            pcall(function() exports.palm6_fightclub:BroadcastOdds(matchId) end)
            Wait(interval * 1000)
        end
        -- close the book
        goLiveAndCountdown(matchId)
        -- closing line: one more broadcast AFTER the live flip (status=live, secsLeft=0)
        pcall(function() exports.palm6_fightclub:BroadcastOdds(matchId) end)
    end)
end

-- ---------------------------------------------------------------------------
-- Section D: ACCEPTED (charge antes → OpenMatch → refund both on nil).
-- ---------------------------------------------------------------------------

local function beginAccepted(s)
    local cfg = fcCore()
    local aSrc = Bridge.GetSourceByCitizenId(s.aCid)
    local bSrc = Bridge.GetSourceByCitizenId(s.bCid)
    if not aSrc or not bSrc then
        if aSrc then Bridge.Notify(aSrc, 'Fight Club', 'Opponent left before the fight opened.', 'error') end
        if bSrc then Bridge.Notify(bSrc, 'Fight Club', 'Opponent left before the fight opened.', 'error') end
        return
    end
    if activeMatchForCitizen(s.aCid) or activeMatchForCitizen(s.bCid) or ringBusy() then
        Bridge.Notify(aSrc, 'Fight Club', 'The ring is no longer free.', 'error')
        Bridge.Notify(bSrc, 'Fight Club', 'The ring is no longer free.', 'error')
        return
    end

    -- ACCEPTED charge + OpenMatch INSERT are ONE recoverable unit (§10b):
    -- charge A, then B; B fails -> refund A. Both land but INSERT fails -> refund BOTH.
    local stake = getEntryStake()
    if stake > 0 then
        if not Bridge.ChargeBank(aSrc, stake, 'fightclub-entry') then
            Bridge.Notify(aSrc, 'Fight Club', ('You need $%d to ante in.'):format(stake), 'error')
            Bridge.Notify(bSrc, 'Fight Club', 'Opponent could not cover the ante.', 'inform')
            return
        end
        if not Bridge.ChargeBank(bSrc, stake, 'fightclub-entry') then
            Bridge.CreditBankByCitizenId(s.aCid, stake, 'fightclub-entry-refund')  -- unwind A
            Bridge.Notify(bSrc, 'Fight Club', ('You need $%d to ante in.'):format(stake), 'error')
            Bridge.Notify(aSrc, 'Fight Club', 'Opponent could not cover the ante — ante refunded.', 'inform')
            return
        end
    end

    local styleA = s.selA.styleId
    local styleB = s.selB.styleId
    local fighterA = s.selA.fighterId
    local fighterB = s.selB.fighterId
    local matchId = exports.palm6_fightclub:OpenMatch(s.aCid, s.bCid, styleA, styleB, fighterA, fighterB, stake)
    if not matchId or matchId == 0 then
        if stake > 0 then   -- INSERT failed after both charges landed -> refund BOTH antes
            Bridge.CreditBankByCitizenId(s.aCid, stake, 'fightclub-entry-refund')
            Bridge.CreditBankByCitizenId(s.bCid, stake, 'fightclub-entry-refund')
        end
        Bridge.Notify(aSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        Bridge.Notify(bSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        return
    end

    local fA = exports.palm6_fc_core:GetFighter(fighterA) or exports.palm6_fc_core:GetFighter(cfg.DefaultFighter)
    local fB = exports.palm6_fc_core:GetFighter(fighterB) or exports.palm6_fc_core:GetFighter(cfg.DefaultFighter)
    matches[matchId] = {
        cidA = s.aCid, cidB = s.bCid, srcA = aSrc, srcB = bSrc,
        selA = s.selA, selB = s.selB,
        nameA = Bridge.GetPlayerName(aSrc), nameB = Bridge.GetPlayerName(bSrc),
        modelA = fA and fA.model or 'mp_m_freemode_01',
        modelB = fB and fB.model or 'mp_m_freemode_01',
        roundStarted = false, resolving = false, inFinisher = {}, startedAt = 0,
        wentLive = false, bettingEndsAt = now() + cfg.Timers.BetWindowSec,
    }
    activeByCid[s.aCid] = matchId; activeByCid[s.bCid] = matchId
    activeBySrc[aSrc] = matchId; activeBySrc[bSrc] = matchId
    TriggerEvent('fc:match:opened', { matchId = matchId, f1name = matches[matchId].nameA, f2name = matches[matchId].nameB, betWindowSec = cfg.Timers.BetWindowSec })
    Bridge.Notify(aSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, matches[matchId].nameB, cfg.Timers.BetWindowSec), 'success')
    Bridge.Notify(bSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, matches[matchId].nameA, cfg.Timers.BetWindowSec), 'success')
    startBettingTimer(matchId)
    dbg(('match #%d BETTING opened'):format(matchId))
end

local function finalizeStaging(stgId)
    local s = staging[stgId]
    if not s or s.done then return end
    s.done = true
    if s.aSrc then stagingBySrc[s.aSrc] = nil end
    if s.bSrc then stagingBySrc[s.bSrc] = nil end
    staging[stgId] = nil
    beginAccepted(s)
end

-- ---------------------------------------------------------------------------
-- Section E: net-event handlers, playerDropped DC, boot no-contest, MatchState.
-- ---------------------------------------------------------------------------

local function cleanupPendingForSrc(src)
    for tCid, pc in pairs(pendingChallenges) do
        if pc.fromSrc == src or pc.targetSrc == src then pendingChallenges[tCid] = nil end
    end
    local stgId = stagingBySrc[src]
    if stgId then finalizeStaging(stgId) end  -- resolves with defaults; harmless if empty
end

RegisterNetEvent('palm6_fc_combat:challenge', function(payload)
    local src = source
    if not enabled() or not bootDone then return end
    if type(payload) ~= 'table' or not rl(src, 'fcchallenge') then return end
    local targetSrc = tonumber(payload.targetServerId)
    if not targetSrc or targetSrc == src then return end
    local aCid = Bridge.GetCitizenId(src)
    local bCid = Bridge.GetCitizenId(targetSrc)
    if not aCid or not bCid then Bridge.Notify(src, 'Fight Club', 'Invalid opponent.', 'error') return end
    if not atRing(src) then Bridge.Notify(src, 'Fight Club', ('You must be at %s.'):format(fcCore().Ring.label), 'error') return end
    if not atRing(targetSrc) then Bridge.Notify(src, 'Fight Club', 'They are not at the ring.', 'error') return end
    if activeMatchForCitizen(aCid) or activeMatchForCitizen(bCid) then Bridge.Notify(src, 'Fight Club', 'One of you already has a match.', 'error') return end
    if ringBusy() then Bridge.Notify(src, 'Fight Club', 'The ring is in use.', 'error') return end
    if pendingChallenges[bCid] then Bridge.Notify(src, 'Fight Club', 'They already have a pending challenge.', 'error') return end
    local ttl = fcCore().Timers.ChallengeTTL
    pendingChallenges[bCid] = { fromCid = aCid, fromSrc = src, targetSrc = targetSrc, expiresAt = now() + ttl }
    TriggerClientEvent('palm6_fc_combat:challengePrompt', targetSrc, { fromName = Bridge.GetPlayerName(src), fromServerId = src, ttl = ttl })
    Bridge.Notify(src, 'Fight Club', ('Challenge sent — %ds to respond.'):format(ttl), 'inform')
    CreateThread(function()
        Wait(ttl * 1000)
        local pc = pendingChallenges[bCid]
        if pc and pc.fromCid == aCid then
            pendingChallenges[bCid] = nil
            local s2 = Bridge.GetSourceByCitizenId(aCid)
            if s2 then Bridge.Notify(s2, 'Fight Club', 'Challenge expired — no answer.', 'inform') end
        end
    end)
end)

RegisterNetEvent('palm6_fc_combat:decline', function()
    local src = source
    if not rl(src, 'fcdecline') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local pc = pendingChallenges[cid]
    if not pc then return end
    pendingChallenges[cid] = nil
    if pc.fromSrc then Bridge.Notify(pc.fromSrc, 'Fight Club', 'Your challenge was declined.', 'inform') end
end)

RegisterNetEvent('palm6_fc_combat:accept', function()
    local src = source
    if not enabled() or not bootDone then return end
    if not rl(src, 'fcaccept') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local pc = pendingChallenges[cid]
    if not pc then return end
    pendingChallenges[cid] = nil
    local aSrc, aCid, bSrc, bCid = pc.fromSrc, pc.fromCid, src, cid
    if Bridge.GetSourceByCitizenId(aCid) ~= aSrc then Bridge.Notify(bSrc, 'Fight Club', 'The challenger left.', 'error') return end
    if not atRing(aSrc) or not atRing(bSrc) then Bridge.Notify(bSrc, 'Fight Club', 'Both fighters must be at the ring.', 'error') return end
    if activeMatchForCitizen(aCid) or activeMatchForCitizen(bCid) or ringBusy() then Bridge.Notify(bSrc, 'Fight Club', 'The ring is in use.', 'error') return end
    local cfg = fcCore()
    stagingSeq = stagingSeq + 1
    local stgId = stagingSeq
    staging[stgId] = {
        aCid = aCid, bCid = bCid, aSrc = aSrc, bSrc = bSrc,
        selA = { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle },
        selB = { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle },
        submittedA = false, submittedB = false, done = false,
    }
    stagingBySrc[aSrc] = stgId; stagingBySrc[bSrc] = stgId
    TriggerClientEvent('palm6_fc_combat:openSelect', aSrc, { matchId = stgId })
    TriggerClientEvent('palm6_fc_combat:openSelect', bSrc, { matchId = stgId })
    CreateThread(function()
        Wait(SELECT_WINDOW_SEC * 1000)
        finalizeStaging(stgId)   -- proceed with whatever was picked (defaults otherwise)
    end)
end)

RegisterNetEvent('palm6_fc_combat:select', function(payload)
    local src = source
    if type(payload) ~= 'table' or not rl(src, 'fcselect') then return end
    local stgId = stagingBySrc[src]
    local s = stgId and staging[stgId]
    if not s or s.done then return end
    local fid, sid = validPick(payload.fighterId, payload.styleId)
    if src == s.aSrc then s.selA = { fighterId = fid, styleId = sid }; s.submittedA = true
    elseif src == s.bSrc then s.selB = { fighterId = fid, styleId = sid }; s.submittedB = true
    else return end
    if s.submittedA and s.submittedB then finalizeStaging(stgId) end
end)

-- DC handling. A participant drop maps through resolveFight (the single hub) by
-- match phase (§5): BETTING/COUNTDOWN (never roundStarted) -> void/no-contest
-- (never pays a winner for a fight that did not happen); LIVE+roundStarted ->
-- opponent wins by forfeit. resolveFight itself picks VoidMatch vs LiveVoidMatch
-- vs ResolveMatch off m.wentLive/m.roundStarted, so DC ALWAYS beats a finisher
-- end (it sets m.resolving first). C8: this is the ONLY playerDropped handler.
AddEventHandler('playerDropped', function()
    local src = source
    local matchId = activeBySrc[src]
    if not matchId then cleanupPendingForSrc(src); return end
    local m = matches[matchId]
    if not m then activeBySrc[src] = nil; return end
    local droppedCid = (src == m.srcA) and m.cidA or m.cidB
    if not m.roundStarted then
        -- BETTING or COUNTDOWN: a fight that never started must not pay a winner (§5) -> void/no-contest
        resolveFight(matchId, nil, 'void')
    else
        -- LIVE: the disconnecting fighter forfeits, opponent is paid (§5)
        local opponentCid = (droppedCid == m.cidA) and m.cidB or m.cidA
        resolveFight(matchId, opponentCid, 'forfeit')
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(8000)  -- let palm6_dbmigrate land the fc columns first (mirror fightclub's boot delay)
        TriggerClientEvent('palm6_fc_combat:teardown', -1, { matchId = 0 })  -- abort any client stuck mid-fight
        local rows = {}
        pcall(function()
            rows = MySQL.query.await("SELECT id, status FROM palm6_fightclub_matches WHERE status IN ('betting','live')") or {}
        end)
        for _, r in ipairs(rows) do
            if r.status == 'betting' then exports.palm6_fightclub:VoidMatch(r.id)
            else exports.palm6_fightclub:LiveVoidMatch(r.id) end
        end
        if #rows > 0 then print(('[palm6_fc_combat] boot no-contested %d stranded match(es)'):format(#rows)) end
        bootDone = true
        print('[palm6_fc_combat] ready — Enabled=' .. tostring(enabled()))
    end)
end)

-- T7/T8 read/mutate match state through this export (never re-declare matches[]).
exports('MatchState', function(matchId) return matches[matchId] end)
