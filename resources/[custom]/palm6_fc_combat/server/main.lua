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
local RATE = { fcchallenge = 3, fcaccept = 1, fcdecline = 1, fcselect = 1, fcpve = 3 }

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
    -- F8: cache ONLY a good read; leave the cache nil on a transient fail so the
    -- NEXT match retries instead of latching $0 forever off one bad read.
    if ok and tonumber(v) then entryStakeCache = tonumber(v) end
    return entryStakeCache or 0
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
--   roundStarted   -> ResolveMatch (live row pays a winner)
--   !roundStarted (BETTING or COUNTDOWN, §5 pre-LIVE) -> STATE-AGNOSTIC void:
--     VoidMatch (betting-row draw refund); if that no-ops because GoLive already
--     flipped the row to 'live', fall through to LiveVoidMatch. Either way a fight
--     that never started refunds and never pays a winner (F1).
function resolveFight(matchId, winnerCid, method)
    local m = matches[matchId]
    if not m or m.resolving then return end
    m.resolving = true
    if m.roundStarted then
        exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method or 'ko')
    else
        -- F1: STATE-AGNOSTIC pre-LIVE void. GoLive flips the DB row to 'live'
        -- BEFORE m.wentLive is set, so a DC in that window must NOT route off
        -- m.wentLive (VoidMatch is guarded WHERE status='betting' and would no-op
        -- on the now-'live' row -> no refund, ring bricked). Try the betting-guarded
        -- VoidMatch first; if it no-ops (row already live -> returns false), fall
        -- through to LiveVoidMatch. Both are idempotent, guarded, and resolve to
        -- winner=NULL draw-refund, so a pre-roundStarted abort ALWAYS refunds.
        if not exports.palm6_fightclub:VoidMatch(matchId) then
            exports.palm6_fightclub:LiveVoidMatch(matchId)
        end
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
    m.countdownStartedAt = now()
    if m.srcA then TriggerClientEvent('palm6_fc_combat:countdown', m.srcA, { matchId = matchId, seconds = cd }) end
    if m.srcB then TriggerClientEvent('palm6_fc_combat:countdown', m.srcB, { matchId = matchId, seconds = cd }) end
    dbg(('match #%d COUNTDOWN (%ds)'):format(matchId, cd))
    -- F4: gate LIVE on BOTH clients ack'ing their preload (model + anims loaded)
    -- via palm6_fc_combat:ready, OR a deadline (countdown + preload grace). The
    -- 3-2-1 visual keeps firing above; enterLive only fires once the visual has
    -- elapsed AND both readied. On deadline-without-both-ready, no-contest void
    -- (state-agnostic refund, §5/§8) instead of entering LIVE half-loaded.
    local graceSec = 5
    CreateThread(function()
        local deadline = now() + cd + graceSec
        while true do
            Wait(250)
            local mm = matches[matchId]
            if not mm or mm.resolving or mm.roundStarted then return end
            if now() >= deadline then
                dbg(('match #%d preload gate TIMED OUT — voiding (no-contest)'):format(matchId))
                resolveFight(matchId, nil, 'void')   -- F1 state-agnostic void: refund, never LIVE
                return
            end
            local bothReady = mm.ready and mm.ready[mm.cidA] and mm.ready[mm.cidB]
            if bothReady and now() >= (mm.countdownStartedAt or 0) + cd then
                enterLive(matchId)
                return
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- §19 dark-PvE lifecycle (server). A solo human opens a MONEY-INERT CPU bout via
-- palm6_fightclub:OpenPveMatch (is_pve=1, entry_pot=0, betting_ends_at=NOW()).
-- We build the same in-memory shell a PvP match uses — but fighter2 is the
-- server-owned CPU: cidB = the '__CPU__:'..id sentinel, srcB = nil, and its
-- preload ack is PRE-SET so the F4 gate only waits on the human. Then we route
-- straight through goLiveAndCountdown (no betting window) — the identical LIVE
-- path, so the client can't tell PvE from PvP and needs no special-casing to fight.
-- The CPU actor + aiThink brain are seeded later by startRound's is_pve branch.
-- ---------------------------------------------------------------------------
local function cpuForTier(tier)
    local cfg = fcCore()
    local list = cfg and cfg.Pve and cfg.Pve.CpuFighters
    if type(list) ~= 'table' then return nil end
    for _, c in ipairs(list) do
        if tonumber(c.tier) == tier then return c end
    end
    return nil
end

-- Returns true if the bout opened. Human fights as the DEFAULT fighter in P2 (the
-- client has no PvE select yet, so server + client must agree on the default);
-- a PvE fighter-select lands with the client puppet phase.
local function startPveMatch(humanSrc, humanCid, tier)
    local cfg = fcCore()
    local cpu = cpuForTier(tier)
    if not cpu then
        Bridge.Notify(humanSrc, 'Fight Club', 'No CPU challenger for that tier.', 'error')
        return false
    end

    local fighterH, styleH = cfg.DefaultFighter, cfg.DefaultStyle

    -- OpenMatch-equivalent money-inert row. pcall-wrapped: a throw/nil is the single
    -- failure branch (nothing was charged, so nothing to refund — §19.2).
    local ok, matchId = pcall(function()
        return exports.palm6_fightclub:OpenPveMatch(humanCid, tier, styleH, fighterH, cpu.id, cpu.styleId)
    end)
    if not ok or not matchId or matchId == 0 then
        Bridge.Notify(humanSrc, 'Fight Club', 'Could not start the CPU bout — try again.', 'error')
        return false
    end

    local sentinel = '__CPU__:' .. matchId

    -- Resolve the human's fighter model + name BEFORE building the shell (mirrors
    -- beginAccepted's F3 guards so no unguarded call can throw mid-setup).
    local function safeFighter(id)
        local okF, f = pcall(function() return exports.palm6_fc_core:GetFighter(id) end)
        return (okF and f) or nil
    end
    local fH     = safeFighter(fighterH) or safeFighter(cfg.DefaultFighter)
    local modelH = (fH and fH.model) or 'mp_m_freemode_01'
    local okName, nameH = pcall(function() return Bridge.GetPlayerName(humanSrc) end)
    nameH = (okName and nameH) or ('fighter %s'):format(tostring(humanCid))

    matches[matchId] = {
        cidA = humanCid, cidB = sentinel, srcA = humanSrc, srcB = nil,
        selA = { fighterId = fighterH, styleId = styleH },
        selB = { fighterId = cpu.id, styleId = cpu.styleId },
        nameA = nameH, nameB = cpu.name or 'CPU',
        modelA = modelH, modelB = cpu.model or 'mp_m_freemode_01',
        roundStarted = false, resolving = false, inFinisher = {}, startedAt = 0,
        wentLive = false, bettingEndsAt = now(),
        isPve = true, cpuTier = tier,
        ready = { [sentinel] = true },   -- CPU auto-ready: the F4 preload gate only waits on the human
    }
    activeByCid[humanCid] = matchId
    activeBySrc[humanSrc] = matchId

    -- No betting window — straight to countdown/LIVE via the shared path.
    goLiveAndCountdown(matchId)
    Bridge.Notify(humanSrc, 'Fight Club',
        ('Sparring %s (Tier %d) — square up.'):format(cpu.name or 'a challenger', tier), 'inform')
    dbg(('PvE match #%d opened: %s vs CPU %s (tier %d)'):format(matchId, tostring(humanCid), cpu.id, tier))
    return true
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

    -- F3: resolve EVERY framework-dependent value (fighter models + player names)
    -- BEFORE the OpenMatch money commit, each pcall-guarded, so no unguarded call
    -- can throw between the ante charge and the row INSERT (strand antes) OR between
    -- the INSERT and startBettingTimer (orphan a paid-up betting row: no timer, ring
    -- stuck). After OpenMatch the tail only builds tables + fires the timer.
    local function safeFighter(id)
        local okF, f = pcall(function() return exports.palm6_fc_core:GetFighter(id) end)
        return (okF and f) or nil
    end
    local fA = safeFighter(fighterA) or safeFighter(cfg.DefaultFighter)
    local fB = safeFighter(fighterB) or safeFighter(cfg.DefaultFighter)
    local modelA = (fA and fA.model) or 'mp_m_freemode_01'
    local modelB = (fB and fB.model) or 'mp_m_freemode_01'
    local okNameA, nameA = pcall(function() return Bridge.GetPlayerName(aSrc) end)
    local okNameB, nameB = pcall(function() return Bridge.GetPlayerName(bSrc) end)
    nameA = (okNameA and nameA) or ('fighter %s'):format(tostring(s.aCid))
    nameB = (okNameB and nameB) or ('fighter %s'):format(tostring(s.bCid))

    -- F2: OpenMatch is a cross-resource call AFTER both antes are charged. A bare
    -- call only catches a nil RETURN; a THROW (fightclub reloading) would strand both
    -- antes. pcall-wrap it and treat ok=false OR nil/0 as the SINGLE failure branch.
    local ok, matchId = pcall(function()
        return exports.palm6_fightclub:OpenMatch(s.aCid, s.bCid, styleA, styleB, fighterA, fighterB, stake)
    end)
    if not ok or not matchId or matchId == 0 then
        if stake > 0 then   -- INSERT failed / threw after both charges landed -> refund BOTH antes
            Bridge.CreditBankByCitizenId(s.aCid, stake, 'fightclub-entry-refund')
            Bridge.CreditBankByCitizenId(s.bCid, stake, 'fightclub-entry-refund')
        end
        Bridge.Notify(aSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        Bridge.Notify(bSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        return
    end

    matches[matchId] = {
        cidA = s.aCid, cidB = s.bCid, srcA = aSrc, srcB = bSrc,
        selA = s.selA, selB = s.selB,
        nameA = nameA, nameB = nameB,
        modelA = modelA, modelB = modelB,
        roundStarted = false, resolving = false, inFinisher = {}, startedAt = 0,
        wentLive = false, bettingEndsAt = now() + cfg.Timers.BetWindowSec,
        ready = {},   -- F4: per-match client preload acks (palm6_fc_combat:ready)
    }
    activeByCid[s.aCid] = matchId; activeByCid[s.bCid] = matchId
    activeBySrc[aSrc] = matchId; activeBySrc[bSrc] = matchId
    -- Arm the betting timer BEFORE any remaining trigger/notify so even a throw in
    -- the announce tail leaves the ring on a live timer (F3), never a stuck orphan.
    startBettingTimer(matchId)
    TriggerEvent('fc:match:opened', { matchId = matchId, f1name = nameA, f2name = nameB, betWindowSec = cfg.Timers.BetWindowSec })
    Bridge.Notify(aSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, nameB, cfg.Timers.BetWindowSec), 'success')
    Bridge.Notify(bSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, nameA, cfg.Timers.BetWindowSec), 'success')
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

-- F4: client preload ack. The client emits this AFTER it has loaded the fighter
-- model + anim dicts (that half is the client batch). The server tracks which of
-- the two fighters have ack'd so goLiveAndCountdown can GATE enterLive on both
-- being ready. Validated: sender must be a participant of THIS pre-LIVE match
-- (activeBySrc + srcA/srcB), so a spoofed ready for someone else's match no-ops.
RegisterNetEvent('palm6_fc_combat:ready', function(payload)
    local src = source
    if not enabled() then return end
    local matchId = activeBySrc[src]
    if not matchId then return end
    if type(payload) == 'table' and payload.matchId and tonumber(payload.matchId) ~= matchId then return end
    local m = matches[matchId]
    if not m or m.roundStarted or m.resolving then return end
    local cid = (src == m.srcA and m.cidA) or (src == m.srcB and m.cidB) or nil
    if not cid then return end
    m.ready = m.ready or {}
    m.ready[cid] = true
    dbg(('match #%d: preload ready ack from %s'):format(matchId, tostring(cid)))
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

-- §19.4 population gate: is any OTHER human standing at the ring? PvE is a
-- "no real opponents around" mode (RequireNoHumanAtRing) — if a second human is
-- at the ring they should be challenged, not shadow-boxed past. Skips selfSrc.
local function otherHumanAtRing(selfSrc)
    for _, ps in ipairs(GetPlayers()) do
        local s = tonumber(ps)
        if s and s ~= selfSrc and atRing(s) then return true end
    end
    return false
end

-- /fcpve [tier 1-5] — open a dark-PvE bout vs the tier's house CPU. Gated on
-- Config.Pve.Enabled (ships dark), the feature Enabled + boot no-contest, being
-- at the ring, not already in a match, a free ring, and the §19.4 population gate.
Bridge.RegisterCommand('fcpve', function(src, args)
    if src == 0 then return end
    if not enabled() or not bootDone then return end
    if not rl(src, 'fcpve') then return end

    local pve = (fcCore() or {}).Pve
    if not pve or pve.Enabled ~= true then
        Bridge.Notify(src, 'Fight Club', 'Solo sparring is not available.', 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atRing(src) then
        Bridge.Notify(src, 'Fight Club', ('You must be at %s.'):format(fcCore().Ring.label), 'error')
        return
    end
    if activeMatchForCitizen(cid) then
        Bridge.Notify(src, 'Fight Club', 'You already have a match.', 'error')
        return
    end
    if ringBusy() then
        Bridge.Notify(src, 'Fight Club', 'The ring is in use.', 'error')
        return
    end
    if pve.RequireNoHumanAtRing and otherHumanAtRing(src) then
        Bridge.Notify(src, 'Fight Club', 'Another fighter is at the ring — challenge them instead.', 'error')
        return
    end
    local maxPop = tonumber(pve.MaxPop) or 6
    if #GetPlayers() > maxPop then
        Bridge.Notify(src, 'Fight Club', 'Too many players online for solo sparring — find a real opponent.', 'error')
        return
    end

    -- tier: default 1, clamped to the configured tier count.
    local maxTier = (type(pve.Tiers) == 'table' and #pve.Tiers) or 5
    local tier = math.floor(tonumber(args[1]) or 1)
    if tier < 1 then tier = 1 elseif tier > maxTier then tier = maxTier end

    startPveMatch(src, cid, tier)
end)

-- T7/T8 read/mutate match state through this export (never re-declare matches[]).
exports('MatchState', function(matchId) return matches[matchId] end)

-- ============================================================================
-- T7: server move clock. HP/stamina/momentum are server script vars keyed by
-- matchId..':'..cid (never ped health). Combat numbers come from palm6_fc_core
-- (§6a). Per-match live state comes from T6 via MatchState(matchId).
-- ============================================================================

local DBG = false
local Combat = {}   -- [matchId..':'..cid] = { slot, cid, src, hp, stam, blazin, blocking, cd={}, active, name, model, animStrike }
local Active = {}    -- [matchId] = true   (T7-managed: LIVE + roundStarted)
local Dirty  = {}    -- [matchId] = true   (statebag needs a throttled flush)

-- fc_core caches (populated once the export is up; pcall-retry survives load order).
local MOVES, VIT, MOM, TIM, BLZ, RING, SK
CreateThread(function()
    while not MOVES do
        local ok, c = pcall(function() return exports.palm6_fc_core:Config() end)
        if ok and c and c.Moves then
            MOVES, VIT, MOM, TIM, BLZ, RING = c.Moves, c.Vitals, c.Momentum, c.Timers, c.Blazin, c.Ring
        end
        if not SK then
            local ok2, k = pcall(function() return exports.palm6_fc_core:StateKeys() end)
            if ok2 and k then SK = k end
        end
        if not MOVES then Wait(250) end
    end
    if DBG then print('[palm6_fc_combat] T7 combat config cached') end
end)

local function ckey(matchId, cid) return matchId .. ':' .. cid end
local function mkey(matchId) return (SK and SK.matchKey(matchId)) or ('fc:match:' .. matchId) end
local function ms(matchId) return exports.palm6_fc_combat:MatchState(matchId) end

-- Throttled statebag write (§6/§12: send-on-change, not per-frame). Writes the
-- SAME slot shape T6's enterLive seeded and T9 reads: slot 1 = cidA/srcA,
-- slot 2 = cidB/srcB. Only the client-display fields go on the wire (never cd/active/src).
local function flush(matchId)
    local st = ms(matchId)
    if not st then return end
    local a = Combat[ckey(matchId, st.cidA)]
    local b = Combat[ckey(matchId, st.cidB)]
    if not a or not b then return end
    local function view(f) return { hp = f.hp, stam = f.stam, blazin = f.blazin, name = f.name, model = f.model } end
    GlobalState[mkey(matchId)] = {
        status = 'live', roundStarted = true,
        slot = { [1] = view(a), [2] = view(b) },
    }
end

-- Build the server-owned fight state for a match that just went LIVE. One DB
-- read maps slot -> cid/name/model/style; everything else lives in memory only.
-- Guards double-init via Active[matchId] (claimed BEFORE the await) so the
-- fc:combat:live seam (C8) and the 1s discovery backstop can't both seed it.
local function startRound(matchId)
    local st = ms(matchId)
    if not st or not st.roundStarted or Active[matchId] then return end
    if not VIT then return end          -- fc_core not cached yet; discovery retries
    Active[matchId] = true              -- claim BEFORE the await so discovery can't double-init

    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT fighter1_citizenid, fighter2_citizenid,
                   fighter1_name, fighter2_name,
                   fighter1_model, fighter2_model,
                   style1, style2, is_pve, cpu_tier
              FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
    end)
    if not row then Active[matchId] = nil; return end   -- transient DB fail; retry next pass

    local function strikeDictFor(styleId)
        local okS, style = pcall(function() return exports.palm6_fc_core:GetStyle(styleId) end)
        if okS and style and style.animDicts and style.animDicts.strike then
            return style.animDicts.strike
        end
        return 'melee@unarmed@streamed_core'
    end

    local seats = {
        { slot = 1, cid = row.fighter1_citizenid, src = st.srcA, name = row.fighter1_name, model = row.fighter1_model, dict = strikeDictFor(row.style1) },
        { slot = 2, cid = row.fighter2_citizenid, src = st.srcB, name = row.fighter2_name, model = row.fighter2_model, dict = strikeDictFor(row.style2) },
    }
    for _, s in ipairs(seats) do
        Combat[ckey(matchId, s.cid)] = {
            slot = s.slot, cid = s.cid, src = s.src,
            hp = VIT.StartHP, stam = VIT.MaxStamina, blazin = 0,
            blocking = false, cd = {}, active = nil,
            name = s.name or ('fighter %d'):format(s.slot),
            model = s.model or 'mp_m_freemode_01',
            animStrike = s.dict,
        }
        if s.src then
            Player(s.src).state:set('fc:active', matchId, true)
            Player(s.src).state:set('fc:slot', s.slot, true)
        end
    end

    -- §19.1 dark-PvE: slot 2 is the server-owned CPU logical actor (src=nil). Mark
    -- its Combat seat with the CPU fields the connect validator + brain read, seed
    -- its logical position near the human, then start the aiThink brain. Guarded on
    -- is_pve so a normal PvP round is byte-for-byte unaffected.
    if tonumber(row.is_pve) == 1 then
        local cpu = Combat[ckey(matchId, row.fighter2_citizenid)]
        local humanSrc = st.srcA
        if cpu and humanSrc then
            startCpuActor(matchId, cpu, humanSrc, tonumber(row.cpu_tier) or 1)
        end
    end

    Dirty[matchId] = true
    if DBG then print(('[palm6_fc_combat] round started #%d'):format(matchId)) end
end

-- ============================================================================
-- §19 dark-PvE CPU brain (server-authoritative). The CPU is a SERVER-OWNED
-- logical actor: its HP/stam/blazin live on its Combat seat (seeded by startRound
-- exactly like a human seat, but with src=nil + isCpu=true), its POSITION is a
-- server var stepped toward the human each tick (§19.1 locomotion, leashed to the
-- ring so it can't be kited out of reach), and EVERY move choice is authored here
-- by the tier policy (§19.3). It never trusts a client, never sends a net event
-- (no spoof surface), and never touches money/rep (is_pve=1 + '__' sentinel). One
-- aiThink thread per live PvE match, gated on a liveness flag AND the live match
-- state, so it exits within one tick of resolve/teardown — no leak (§19.6).
-- Lives in the T7 chunk so it binds Combat/ckey/ms/Dirty/Active/resolveFight/MOVES.
-- ============================================================================
local PveActors = {}   -- [matchId] = { alive = true }  (aiThink liveness flag, §19.1 review fix)

local function pveConfig()
    local ok, c = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and type(c) == 'table' and c.Pve or nil
end

-- The tier row (reactionMs / blockChance / aggression / comboDepth). Difficulty is
-- POLICY-ONLY — never HP/damage inflation (§19.2) — so a CPU win stays cash-neutral.
local function tierPolicy(tier)
    local p = pveConfig()
    if p and type(p.Tiers) == 'table' then
        for _, t in ipairs(p.Tiers) do if t.tier == tier then return t end end
        return p.Tiers[1]
    end
    return { tier = tier, reactionMs = 600, blockChance = 0.20, aggression = 0.60, comboDepth = 2 }
end

-- Authored move pick: light-biased, heavier tiers reach for heavies more often,
-- and a heavy the CPU can't afford falls back to a light. Uses the SAME §6a Move
-- table the human draws from (no bespoke CPU damage — policy is timing, not stats).
local function cpuPickMove(cpu, policy)
    if not MOVES then return nil end
    local lights, heavies = {}, {}
    for id, mv in pairs(MOVES) do
        if mv.kind == 'heavy' then heavies[#heavies + 1] = id else lights[#lights + 1] = id end
    end
    if #lights == 0 and #heavies == 0 then return nil end
    local heavyBias = math.min(0.7, 0.15 + 0.10 * (policy.tier or 1))
    local pool = (#heavies > 0 and math.random() < heavyBias) and heavies or lights
    if #pool == 0 then pool = (#lights > 0) and lights or heavies end
    local id = pool[math.random(1, #pool)]
    local move = MOVES[id]
    if move and move.kind == 'heavy' and cpu.stam < (move.staminaCost or 0) and #lights > 0 then
        move = MOVES[lights[math.random(1, #lights)]]   -- can't afford the heavy -> jab instead
    end
    return move
end

-- The CPU lands an authored strike on the human. Server-authoritative mirror of
-- the §6 connect handler with the human as target: reach = human ped -> CPU
-- logical pos, block-chip respects the human's guard+facing, damage/momentum are
-- the SAME numbers a human attacker would deal. A KO flips the row through the one
-- resolveFight hub with the CPU sentinel as winner (is_pve=1 + '__' guard => no
-- rep, no cash — a bare loss for the human).
local function cpuStrike(matchId, cpu, human, humanSrc, move)
    if not move or not cpu.pos then return end
    local reach = Bridge.ReachToPos(humanSrc, cpu.pos)               -- fail-closed: nil pos -> no reach
    if not reach or reach > move.reach then return end
    local dmg = move.damage
    if human.blocking and Bridge.FacingPos(humanSrc, cpu.pos) then
        dmg = math.floor(move.damage * (move.chipPct or 0))          -- chip through the guard
        human.stam = math.max(0, human.stam - (move.blockStamCost or 0))
        if human.stam <= 0 then human.blocking = false end
    end
    human.hp = human.hp - dmg
    local cap = (BLZ and BLZ.FullThreshold) or 100
    cpu.blazin   = math.min(cap, cpu.blazin + (MOM.PerLandedHit or 0))
    human.blazin = math.min(cap, human.blazin + (MOM.PerTakenHit or 0))
    Dirty[matchId] = true
    if human.hp <= 0 then
        if humanSrc then TriggerClientEvent('palm6_fc_combat:koRagdoll', humanSrc, { matchId = matchId }) end
        resolveFight(matchId, cpu.cid, 'ko')                         -- CPU wins; cpu.cid is the '__CPU__' sentinel
    end
end

-- Boot the CPU actor: mark its seat, seed its logical position near the human, and
-- spawn the single aiThink thread. GLOBAL (called from startRound across the same
-- chunk) — mirrors the resolveFight/teardownMatch/Fin cross-binding convention.
function startCpuActor(matchId, cpu, humanSrc, tier)
    cpu.isCpu = true
    cpu.tier  = tier
    cpu.cd    = cpu.cd or {}
    local hc = Bridge.GetCoords(humanSrc)
    if hc then
        cpu.pos = { x = hc.x + 1.5, y = hc.y + 1.5, z = hc.z }        -- square up ~2m off the human
    elseif RING then
        cpu.pos = { x = RING.coords.x, y = RING.coords.y, z = RING.coords.z }
    else
        cpu.pos = { x = 0.0, y = 0.0, z = 0.0 }
    end

    PveActors[matchId] = { alive = true }
    local policy    = tierPolicy(tier)
    local pcfg      = pveConfig() or {}
    local tickMs    = math.max(100, math.floor(tonumber(pcfg.AiTickMs) or 250))
    local stepSpeed = tonumber(pcfg.CpuStepSpeed) or 2.2
    local ringRad   = (RING and RING.radius) or 15.0
    local ringC     = RING and RING.coords or nil

    CreateThread(function()
        local lastSwingMs = 0
        while true do
            Wait(tickMs)
            local actor = PveActors[matchId]
            if not actor or not actor.alive then return end          -- liveness gate (§19.1/§19.6)
            local st = ms(matchId)
            if not st or not st.roundStarted or st.resolving or not Active[matchId] then
                PveActors[matchId] = nil                             -- resolved/torn down -> stop cleanly
                return
            end
            local human = Combat[ckey(matchId, st.cidA)]
            local self  = Combat[ckey(matchId, cpu.cid)]
            if not human or not self or not self.pos then PveActors[matchId] = nil; return end

            -- Locomotion (§19.1): step the logical pos toward the human, stopping at
            -- striking range, then leash inside the ring so it can't be kited out.
            local hcoords = Bridge.GetCoords(st.srcA)
            if hcoords then
                local dx, dy = hcoords.x - self.pos.x, hcoords.y - self.pos.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d > 0.05 then
                    local step   = stepSpeed * (tickMs / 1000)
                    local stopGap = 1.2                              -- stand within striking range
                    local moveBy = math.min(step, math.max(0, d - stopGap))
                    self.pos.x = self.pos.x + (dx / d) * moveBy
                    self.pos.y = self.pos.y + (dy / d) * moveBy
                    self.pos.z = hcoords.z
                end
            end
            if ringC then
                local rx, ry = self.pos.x - ringC.x, self.pos.y - ringC.y
                local rd = math.sqrt(rx * rx + ry * ry)
                if rd > ringRad then
                    self.pos.x = ringC.x + (rx / rd) * ringRad
                    self.pos.y = ringC.y + (ry / rd) * ringRad
                end
            end

            -- Block policy: roll a guard stance for this tick (blocking suppresses the
            -- attack + lets the human's stamina regen, matching the T7 human model).
            self.blocking = math.random() < (policy.blockChance or 0)

            -- Attack policy: aggression-gated, throttled by the tier reaction gate.
            local nowMs = GetGameTimer()
            if not self.blocking
               and math.random() < (policy.aggression or 0.6)
               and (nowMs - lastSwingMs) >= (policy.reactionMs or 600) then
                local move = cpuPickMove(self, policy)
                if move and self.stam >= (move.staminaCost or 0) and nowMs >= (self.cd[move.moveId] or 0) then
                    self.stam = math.max(0, self.stam - (move.staminaCost or 0))
                    self.cd[move.moveId] = nowMs + (move.cooldownMs or 500)
                    lastSwingMs = nowMs
                    cpuStrike(matchId, self, human, st.srcA, move)
                end
            end
            Dirty[matchId] = true
        end
    end)
    if DBG then print(('[palm6_fc_combat] PvE CPU actor #%d live (tier %d)'):format(matchId, tier)) end
end

-- T7 REPLACES T6's draw-only round-cap timeout with an HP%-comparison decision:
-- higher HP% wins by decision (method='ko'); an HP gap within Config.Timers.DrawBand
-- (percentage points) is an honest draw. Redefines the in-file GLOBAL so the T6
-- startRoundTimer's call-time lookup picks up this body; routes through the
-- resolveFight hub and NEVER pre-sets m.resolving (resolveFight owns that flag).
function onRoundTimeout(matchId)
    local m = matches[matchId]
    if not m or m.resolving or not m.roundStarted then return end
    local a = Combat[ckey(matchId, m.cidA)]
    local b = Combat[ckey(matchId, m.cidB)]
    if not a or not b or not VIT then
        resolveFight(matchId, nil, 'draw')          -- no combat state to judge -> honest draw
        return
    end
    local maxHp = (VIT.StartHP and VIT.StartHP > 0) and VIT.StartHP or 100
    local aPct = math.max(0, a.hp) / maxHp * 100
    local bPct = math.max(0, b.hp) / maxHp * 100
    local band = (TIM and TIM.DrawBand) or 0
    if math.abs(aPct - bPct) <= band then
        resolveFight(matchId, nil, 'draw')
    elseif aPct > bPct then
        resolveFight(matchId, m.cidA, 'ko')
    else
        resolveFight(matchId, m.cidB, 'ko')
    end
end

-- Strike (§6 step 2): validate -> deduct stamina -> open active window -> order
-- the attacker's OWN client to play the swing (replication shows it to everyone).
RegisterNetEvent('palm6_fc_combat:strike', function(data)
    local src = source
    if not MOVES or type(data) ~= 'table' then return end
    local matchId = tonumber(data.matchId)
    local moveId  = data.moveId
    if not matchId or type(moveId) ~= 'string' then return end
    local move = MOVES[moveId]
    if not move then return end

    local st = ms(matchId)
    if not st or not st.roundStarted or st.resolving then return end
    local cid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
    if not cid then return end
    local f = Combat[ckey(matchId, cid)]
    if not f then return end

    local nowMs = GetGameTimer()
    if nowMs < (f.cd[moveId] or 0) then return end                          -- cooldown not elapsed
    if move.kind == 'heavy' and f.stam < move.staminaCost then return end    -- 0-stam = light only

    f.stam = math.max(0, f.stam - move.staminaCost)
    f.cd[moveId] = nowMs + move.cooldownMs
    f.active = { moveId = moveId, expiresAt = nowMs + move.activeWindowMs }
    Dirty[matchId] = true

    TriggerClientEvent('palm6_fc_combat:playClip', src,
        { matchId = matchId, cid = cid, moveId = moveId, animDict = f.animStrike })
end)

-- Block: held stance (server records on/off). Cost is drained per absorbed hit
-- in the connect handler; while blocking, stamina does not regenerate (§6a).
RegisterNetEvent('palm6_fc_combat:block', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local matchId = tonumber(data.matchId)
    if not matchId then return end
    local st = ms(matchId)
    if not st or not st.roundStarted or st.resolving then return end
    local cid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
    if not cid then return end
    local f = Combat[ckey(matchId, cid)]
    if not f then return end
    f.blocking = data.on and true or false
end)

-- Connect (§6 step 4): the attacker client claims a visual hit; the SERVER
-- validates window + reach + block and applies authoritative damage/momentum.
RegisterNetEvent('palm6_fc_combat:connect', function(data)
    local src = source
    if not MOVES or type(data) ~= 'table' then return end
    local matchId = tonumber(data.matchId)
    if not matchId then return end
    local st = ms(matchId)
    if not st or not st.roundStarted or st.resolving then return end

    local attCid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
    if not attCid then return end
    local att = Combat[ckey(matchId, attCid)]
    if not att or not att.active then return end                     -- no live swing
    if GetGameTimer() > att.active.expiresAt then att.active = nil; return end  -- window closed

    local move = MOVES[att.active.moveId]
    if not move then att.active = nil; return end

    local tgtCid = (attCid == st.cidA) and st.cidB or st.cidA
    local tgt = Combat[ckey(matchId, tgtCid)]
    if not tgt then att.active = nil; return end

    -- §19.4 CPU-target branch: a human striking the dark-PvE CPU. The CPU has NO
    -- src (a server-owned logical actor), so reach is measured human-ped -> the
    -- CPU's server logical-position var, and the guard-chip uses the CPU's rolled
    -- block state directly (it always squares up to the human, so no facing native
    -- is needed). FAIL-CLOSED: an unset CPU pos yields nil reach -> no connect.
    local reach
    if tgt.isCpu then
        reach = Bridge.ReachToPos(att.src, tgt.pos)                   -- human ped vs CPU logical pos
    else
        reach = Bridge.Reach(att.src, tgt.src)                        -- server distance, never client (PvP)
    end
    if not reach or reach > move.reach then att.active = nil; return end

    att.active = nil                                                  -- one connect per swing

    local dmg = move.damage
    local blocked = tgt.isCpu and tgt.blocking or (tgt.blocking and tgt.src and Bridge.Facing(tgt.src, att.src))
    if blocked then
        dmg = math.floor(move.damage * (move.chipPct or 0))           -- chip through the guard
        tgt.stam = math.max(0, tgt.stam - (move.blockStamCost or 0))
        if tgt.stam <= 0 then tgt.blocking = false end                -- block breaks at 0 stamina
    end

    tgt.hp = tgt.hp - dmg
    local cap = (BLZ and BLZ.FullThreshold) or 100
    att.blazin = math.min(cap, att.blazin + (MOM.PerLandedHit or 0))  -- both gain (Def Jam feel)
    Fin.tryTrigger(matchId, attCid, tgtCid, move.moveId)             -- [T8] Blazin finisher trigger (heavy + full meter)
    tgt.blazin = math.min(cap, tgt.blazin + (MOM.PerTakenHit or 0))
    Dirty[matchId] = true

    if tgt.hp <= 0 then
        -- KO. Route through the single resolveFight hub (C1): it guards+sets
        -- m.resolving itself (do NOT pre-set) and sends teardown to BOTH fighters
        -- so the winner is restored out of the fighter ped/loadout (§8/§11). The
        -- ragdoll order is skipped for a CPU victim (no src; its client puppet, P3,
        -- plays its own KO), guarded so the PvP path is unchanged.
        if tgt.src then TriggerClientEvent('palm6_fc_combat:koRagdoll', tgt.src, { matchId = matchId }) end
        resolveFight(matchId, attCid, 'ko')
    end
end)

-- Discovery (boot/reconnect backstop for the C8 fc:combat:live seam): a
-- DB-authoritative sweep that promotes any LIVE row whose T6 round has actually
-- started into Active. Cheap 1s cadence; empty result set at idle. startRound
-- self-guards double-init, so overlap with the live seam is harmless.
CreateThread(function()
    while true do
        Wait(1000)
        if not enabled() then
            Wait(5000)   -- F6: prod-inert idle — no 1s DB poll while the feature is disabled
        elseif MOVES then
            local live = {}
            pcall(function()
                live = MySQL.query.await("SELECT id FROM palm6_fightclub_matches WHERE status = 'live'") or {}
            end)
            for _, r in ipairs(live) do
                local id = tonumber(r.id)
                if id and not Active[id] then
                    local st = ms(id)
                    if st and st.roundStarted then startRound(id) end
                end
            end
        end
    end
end)

-- C8: consume the live seam so combat state inits the instant LIVE begins (no ~1s
-- dead-zone at "FIGHT!"). startRound double-init-guards against the discovery poll.
AddEventHandler('fc:combat:live', function(d)
    if type(d) == 'table' and tonumber(d.matchId) then startRound(tonumber(d.matchId)) end
end)

-- Combat tick: stamina regen (skip a fighter mid-swing or blocking) + throttled
-- statebag flush. Runs only over Active matches -> no measurable cost at idle.
CreateThread(function()
    while true do
        Wait(250)
        for matchId in pairs(Active) do
            local nowMs = GetGameTimer()
            local prefix = matchId .. ':'
            for k, f in pairs(Combat) do
                if k:sub(1, #prefix) == prefix then
                    local attacking = f.active and nowMs <= f.active.expiresAt
                    if not f.blocking and not attacking and f.stam < VIT.MaxStamina then
                        f.stam = math.min(VIT.MaxStamina, f.stam + (VIT.StaminaRegenPerSec * 0.25))
                        Dirty[matchId] = true
                    end
                end
            end
        end
        for matchId in pairs(Dirty) do
            flush(matchId)
            Dirty[matchId] = nil
        end
    end
end)

-- Ring confinement (§6, CONFIRMED gap): a fast server coords poll force-resolves
-- a ring-out to a forfeit AND drops that fighter's invincibility this instant
-- (teardown to their own client) — invincibility must not survive a ring-exit.
-- Routes through resolveFight (C1); the explicit teardown to f.src guarantees the
-- exiting client un-hardens immediately even before the resolve settle completes.
CreateThread(function()
    while not TIM do Wait(250) end
    local pollMs = math.floor((TIM.RingPollSec or 0.5) * 1000)
    if pollMs < 250 then pollMs = 250 end
    while true do
        Wait(pollMs)
        for matchId in pairs(Active) do
            local st = ms(matchId)
            if st and st.roundStarted and not st.resolving then
                local prefix = matchId .. ':'
                for k, f in pairs(Combat) do
                    if k:sub(1, #prefix) == prefix and f.src then
                        local d = Bridge.DistToRing(f.src, RING.coords)
                        if d ~= nil and d > RING.radius then     -- real out-of-radius read (nil = skip; DC is T6)
                            local oppCid = (f.cid == st.cidA) and st.cidB or st.cidA
                            TriggerClientEvent('palm6_fc_combat:teardown', f.src, { matchId = matchId })  -- drop invincibility NOW
                            resolveFight(matchId, oppCid, 'forfeit')   -- hub: sets m.resolving, tears down both
                            break
                        end
                    end
                end
            end
        end
    end
end)

-- Cleanup: when any match resolves (T3 fires this after settle, for KO / ring-out
-- forfeit / DC / void), drop all T7 state so nothing is stranded. Safe for a
-- match that never entered Active (a betting-row void has no Combat entries).
AddEventHandler('fc:match:resolved', function(d)
    if type(d) ~= 'table' then return end
    local matchId = tonumber(d.matchId)
    if not matchId then return end
    Active[matchId] = nil
    Dirty[matchId]  = nil
    PveActors[matchId] = nil           -- §19: stop the CPU brain (belt-and-suspenders; the loop also self-exits)
    local prefix = matchId .. ':'
    for k, f in pairs(Combat) do
        if k:sub(1, #prefix) == prefix then
            if f.src then
                Player(f.src).state:set('fc:active', false, true)
                Player(f.src).state:set('fc:slot', nil, true)
            end
            Combat[k] = nil
        end
    end
    GlobalState[mkey(matchId)] = nil
end)

-- ============================================================================
-- Blazin finisher (T8) — server half.
-- Per-client OWN-ped synchronized scene (§7). The SERVER owns: the trigger (a
-- LANDED HEAVY connect at a full meter), the shared scene origin/heading + a
-- start stamp, the mash-to-reduce tally (palm6_fc_combat:break), and the
-- finisher damage applied on scene end -- a NO-OP if the row already resolved
-- (DC / ring-out / KO beat the finisher via the T6 `resolving` flag, §5/§11).
--
-- C2: binds to T7's REAL state model (NOT the draft's fightHp/fightMom/
-- writeMatchState, which never existed). Blazin meter = Combat[ckey(m,cid)].blazin,
-- HP = Combat[ckey(m,cid)].hp; the HUD statebag is pushed via flush(matchId) /
-- Dirty[matchId]; the single teardown hub is resolveFight(matchId, winnerCid, method).
-- All of Combat/ckey/flush/Dirty/matches/resolveFight are declared ABOVE in this
-- same chunk (T6/T7), so this block reaches them directly.
-- ============================================================================
-- F12: fc_core config for the finisher, read LAZILY + guarded (mirrors fcCore()).
-- A bare top-level `exports.palm6_fc_core:Config()` throws at CHUNK LOAD if fc_core
-- is momentarily unavailable (load-order race / reload), which would fail the whole
-- server script registration. finCfg() returns the cached config or nil; every Fin
-- function early-returns on nil so the finisher simply no-ops until fc_core is up.
local FinCfgCache
local function finCfg()
    if FinCfgCache then return FinCfgCache end
    local c = fcCore()
    if c and c.Blazin then FinCfgCache = c end
    return FinCfgCache
end

-- Prototype takedown clip (§7: base-game takedown first). David feel-tests the
-- pose + swaps the clip / adds 180 to heading if it reads wrong (Step 12). The
-- finisher MECHANIC (freeze / damage / mash / teardown) is clip-agnostic.
local FINISHER_DICT          = 'mini@takedowns@front'
local FINISHER_ANIM_ATTACKER = 'plyr_takedown_front'
local FINISHER_ANIM_VICTIM   = 'victim_takedown_front'
local FINISHER_WINDUP_MS      = 800    -- telegraph + mash window BEFORE impact (MUST match client Step 8)
local FINISHER_MAX_REDUCE     = 0.85   -- mash shaves at most 85% off BaseFinisherDamage

Fin = {}                     -- GLOBAL (Bridge/Game convention) so the T7 connect handler can reach Fin.tryTrigger
local finishers = {}         -- [matchId] = { attCid, defCid, mash, done, startAt }

local function headingFromVec(dx, dy)
    -- GTA heading approximation; if fighters face away in feel-test, add 180.0.
    return (math.deg(math.atan(-dx, dy))) % 360.0
end

-- Begins the finisher. Re-guards everything so tryTrigger / the debug command
-- can call it freely. Sends EACH fighter a "run your half on your OWN ped" order
-- at a shared origin (§7 step 1-2); spectators/opponent view the scene via normal
-- ped-anim replication, never tasked here.
function Fin.start(matchId, attCid, defCid)
    local fc = finCfg()                                       -- F12: guarded fc_core read
    if not fc then return end
    local st = matches[matchId]
    if not st or not st.roundStarted or st.resolving then return end
    if finishers[matchId] then return end                     -- one finisher per match
    if st.inFinisher[attCid] or st.inFinisher[defCid] then return end

    local attSrc = (st.cidA == attCid) and st.srcA or st.srcB
    local defSrc = (st.cidA == defCid) and st.srcA or st.srcB
    if not attSrc or not defSrc then return end

    -- C2: the Blazin meter lives on the attacker's T7 Combat record. Require it
    -- (a live round always has one) so the spend is authoritative.
    local att = Combat[ckey(matchId, attCid)]
    if not att then return end

    local ac = Bridge.GetCoords(attSrc)
    local dc = Bridge.GetCoords(defSrc)
    if not ac or not dc then return end

    att.blazin = 0                                            -- C2: spend the Blazin meter (no instant re-chain)
    st.inFinisher[attCid] = true
    st.inFinisher[defCid] = true

    local startAt = GetGameTimer()
    finishers[matchId] = { attCid = attCid, defCid = defCid, mash = 0, done = false, startAt = startAt }

    local origin  = { x = (ac.x + dc.x) * 0.5, y = (ac.y + dc.y) * 0.5, z = ac.z }
    local heading = headingFromVec(dc.x - ac.x, dc.y - ac.y)

    TriggerClientEvent('palm6_fc_combat:finisher', attSrc, {
        matchId = matchId, cid = attCid, startAt = startAt,
        origin = origin, heading = heading,
        sceneDict = FINISHER_DICT, sceneAnim = FINISHER_ANIM_ATTACKER,
    })
    TriggerClientEvent('palm6_fc_combat:finisher', defSrc, {
        matchId = matchId, cid = defCid, startAt = startAt,
        origin = origin, heading = heading,
        sceneDict = FINISHER_DICT, sceneAnim = FINISHER_ANIM_VICTIM,
    })

    flush(matchId)             -- C2: push the spent meter to the HUD (T9) immediately

    -- Server-authoritative damage lands at scene end (after windup + scene).
    SetTimeout(FINISHER_WINDUP_MS + fc.Blazin.SceneDurationMs, function()
        Fin.applyDamage(matchId)
    end)
end

-- Called from the T7 connect handler (anchor, below) right after a LANDED connect
-- adds momentum to the attacker. Fires only on a HEAVY move at a full meter.
function Fin.tryTrigger(matchId, attCid, defCid, moveId)
    local fc = finCfg()                                       -- F12: guarded fc_core read
    if not fc or not fc.Blazin.HeavyQualifies then return end
    local move = exports.palm6_fc_core:GetMove(moveId)
    if not move or move.kind ~= 'heavy' then return end
    local att = Combat[ckey(matchId, attCid)]                 -- C2: meter = T7 Combat record .blazin
    if not att or (att.blazin or 0) < fc.Blazin.FullThreshold then return end
    Fin.start(matchId, attCid, defCid)
end

function Fin.cleanup(matchId)
    local st = matches[matchId]
    local f  = finishers[matchId]
    if st and f then
        st.inFinisher[f.attCid] = nil
        st.inFinisher[f.defCid] = nil
    end
    finishers[matchId] = nil
end

-- Applies the finisher damage authoritatively (§7 step 4). No-op if the match
-- already resolved (DC-beats-finisher precedence, §5) -- never a double flip,
-- never HP mutation on a dead row. C2: HP lives on the defender's T7 Combat record.
function Fin.applyDamage(matchId)
    local f = finishers[matchId]
    if not f or f.done then return end
    f.done = true

    local st = matches[matchId]
    if not st or st.resolving then
        Fin.cleanup(matchId)          -- match already resolved (DC/ring-out/KO): clients already torn down
        return
    end

    local fc = finCfg()                                       -- F12: guarded fc_core read
    if not fc then Fin.cleanup(matchId); return end
    local reduce = math.min(FINISHER_MAX_REDUCE, (f.mash or 0) * fc.Blazin.MashReducePerHit)
    local dmg    = math.floor(fc.Blazin.BaseFinisherDamage * (1.0 - reduce))

    local dk = ckey(matchId, f.defCid)
    local def = Combat[dk]
    if not def then Fin.cleanup(matchId); return end          -- no defender combat state -> nothing to apply
    def.hp = math.max(0, def.hp - dmg)                        -- C2: mutate the REAL HP the KO check reads
    Dirty[matchId] = true

    local attCid, defCid = f.attCid, f.defCid
    Fin.cleanup(matchId)

    if def.hp <= 0 then
        -- KO: victim's OWN client ragdolls (T7 pattern; C6 RagdollSelf unfreezes
        -- first), then the single resolveFight hub flips the row atomically. Do
        -- NOT pre-set m.resolving -- resolveFight guards+sets it itself (C1).
        local defSrc = (st.cidA == defCid) and st.srcA or st.srcB
        if defSrc then
            TriggerClientEvent('palm6_fc_combat:koRagdoll', defSrc, { matchId = matchId })
        end
        resolveFight(matchId, attCid, 'finisher')
    else
        flush(matchId)                                        -- non-KO: publish the HP swing to the HUD now
    end
end

-- Victim mash -> reduces the pending finisher damage (§7 fairness). Only the
-- CURRENT finisher's victim can accrue mashes. Combat-class eventguard budget
-- (T11: drop-not-kick) sits in front of this net event.
RegisterNetEvent('palm6_fc_combat:break', function(d)
    local src = source
    if type(d) ~= 'table' then return end
    local matchId = tonumber(d.matchId)
    if not matchId then return end
    local f = finishers[matchId]
    if not f or f.done then return end
    if Bridge.GetCitizenId(src) ~= f.defCid then return end
    f.mash = (f.mash or 0) + 1
end)

-- Dev: force a finisher on an already-LIVE in-memory match (skips grinding a
-- full meter during a 2-client feel-test). Ace-gated like /fcdebug (T4) --
-- Bridge.RegisterCommand hardcodes restricted=false, so gate IN-handler.
RegisterCommand('fcfin', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'palm6_fc.debug') then return end
    local matchId = tonumber(args[1])
    local attCid  = args[2]
    if not matchId or not attCid then return end
    local st = matches[matchId]
    if not st then return end
    if attCid ~= st.cidA and attCid ~= st.cidB then return end
    local defCid = (st.cidA == attCid) and st.cidB or st.cidA
    Fin.start(matchId, attCid, defCid)
end, false)
