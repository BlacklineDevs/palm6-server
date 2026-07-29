-- ============================================================================
-- palm6_turf contest progress accounting.
--
-- This is the newest and least reviewed money-adjacent logic on the server: it
-- decides when a zone changes hands, which decides gang reputation and who gets
-- charged heat. It ships behind Config.Conflict.Enabled = false, so nothing
-- here runs live today, and the whole point of this suite is that the flag can
-- be flipped with something other than hope behind it.
--
-- HOW IT IS REACHED
-- The accounting is not a function. It is a block inside the ticker's
-- CreateThread closure in server/main.lua, which also does DB reads, notifies
-- players and resolves gangs. Refactoring a deployed resource to make it
-- callable is a real behaviour risk, so instead the exact production text of
-- the accounting block is lifted out by anchor and wrapped in a function whose
-- only additions are the parameters the block already reads. `os.time` is
-- shadowed by a local so the wall clock is an input rather than a dependency.
--
-- The two things the block reads that are NOT parameters are Config (loaded
-- from the shipped shared/config.lua) and maxStep, which is itself lifted from
-- the two production lines that compute it.
--
-- NOT TESTED HERE: presenceInZone (server-side coordinate reads through
-- Bridge), finishCapture (MySQL UPDATE, palm6_gangs and palm6_heat exports),
-- closeContest (player notifications) and every cooldown gate in
-- contestBlocked (os.time plus module-level ledgers). README lists them.
-- ============================================================================
T.begin('palm6_turf contest progress accounting')

local TURF = 'resources/[custom]/palm6_turf/'
local MAIN = TURF .. 'server/main.lua'

-- shared/config.lua declares zone coordinates with vector3, a FiveM native.
-- Stubbed as a plain table: nothing in this suite reads a coordinate, and the
-- stub means no world position is ever invented here.
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
T.loadFile(TURF .. 'shared/config.lua')
local CF = Config.Conflict

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the conflict engine still ships dark', CF.Enabled)
T.eq('TickSeconds', CF.TickSeconds, 5)
T.eq('MaxCatchupTicks', CF.MaxCatchupTicks, 4)
T.eq('HoldSeconds', CF.HoldSeconds, 120)
T.eq('AbandonSeconds', CF.AbandonSeconds, 60)
T.eq('ContestSeconds', CF.ContestSeconds, 300)
T.near('DefenderDecayMult', CF.DefenderDecayMult, 2.0)
T.eq('DisplaceAfterStallSec', CF.DisplaceAfterStallSec, 5)
T.lt('a contest window is long enough to contain a hold', CF.HoldSeconds, CF.ContestSeconds)

-- ---------------------------------------------------------------------------
-- Lift the catch-up cap out of the ticker rather than recomputing it here, so
-- the cap under test is the cap that ships.
-- ---------------------------------------------------------------------------
-- Two single lines rather than a slice: they are separated by a long comment
-- and the only line after them ("while true do") is not unique in the file.
local capBlock = T.line(MAIN, 'local tick = math.max(1, Config.Conflict.TickSeconds or 5)')
    .. '\n' .. T.line(MAIN, 'local maxStep = tick * math.max(1, Config.Conflict.MaxCatchupTicks or 4)')
T.contains('cap slice contains the tick line', capBlock, 'Config.Conflict.TickSeconds')
T.contains('cap slice contains the catch-up line', capBlock, 'Config.Conflict.MaxCatchupTicks')
local tick, maxStep = T.chunk('palm6_turf catch-up cap', capBlock .. '\nreturn tick, maxStep\n')()
T.eq('tick resolves to 5 seconds', tick, 5)
T.eq('the catch-up cap is 20 seconds', maxStep, 20)
T.lt('one capped sample cannot on its own bank a capture', maxStep, CF.HoldSeconds)
T.lt('one capped sample cannot on its own abandon a contest', maxStep, CF.AbandonSeconds)

-- ---------------------------------------------------------------------------
-- Lift the accounting block itself.
-- ---------------------------------------------------------------------------
local body = T.slice(MAIN,
    'local tnow = os.time()',
    'if ct.progress >= (Config.Conflict.HoldSeconds or 120) then')
T.contains('accounting slice measures elapsed', body, 'local elapsed = tnow - (ct.lastTickAt or tnow)')
T.contains('accounting slice caps the step', body, 'if elapsed > maxStep then elapsed = maxStep end')
T.contains('accounting slice floors negative elapsed', body, 'if elapsed < 0 then elapsed = 0 end')
T.contains('accounting slice applies the defender multiplier', body, 'DefenderDecayMult')
T.contains('accounting slice floors progress at zero', body, 'if ct.progress < 0 then ct.progress = 0 end')
T.contains('accounting slice keeps the stall clock', body, 'ct.stalledFor = ct.stalledFor + elapsed')
T.notcontains('accounting slice pulled in no MySQL', body, 'MySQL')
T.notcontains('accounting slice pulled in no Bridge call', body, 'Bridge.')
T.notcontains('accounting slice pulled in no notify', body, 'Notify')

-- `os` is shadowed by a local table so the block's own os.time() call reads the
-- time this test hands it. Everything else in the wrapper is a parameter the
-- production block already reads from its enclosing scope.
local stepSrc = table.concat({
    'local __now = 0',
    'local os = { time = function() return __now end }',
    'local maxStep = ...',
    'return function(ct, atk, def, cids, nowSeconds)',
    '    __now = nowSeconds',
    body,
    '    return ct',
    'end',
}, '\n')
local step = T.chunk('palm6_turf contest accounting', stepSrc)(maxStep)

-- ---------------------------------------------------------------------------
-- A contest in the shape openContest builds. Checked against the production
-- initialiser below so this model cannot silently drift from it.
-- ---------------------------------------------------------------------------
local function newContest(now)
    return {
        presentCids  = {},
        presentSec   = {},
        openedAt     = now,
        lastTickAt   = now,
        endsAt       = now + CF.ContestSeconds,
        progress     = 0,
        peak         = 0,
        stalledFor   = 0,
        defenderSeen = false,
    }
end

T.section('the modelled contest matches the production initialiser')
local init = T.slice(MAIN, 'contests[z.id] = {', 'gangOpenAt[gang.id] = now')
for _, field in ipairs({ 'presentCids', 'presentSec', 'openedAt', 'lastTickAt',
                         'endsAt', 'progress', 'peak', 'stalledFor', 'defenderSeen' }) do
    T.contains('openContest still initialises ' .. field, init, field .. ' ')
end
T.contains('openContest starts progress at zero', init, 'progress       = 0')
T.contains('openContest starts peak at zero', init, 'peak           = 0')
T.contains('openContest starts the stall clock at zero', init, 'stalledFor     = 0')
T.contains('openContest starts with no defender seen', init, 'defenderSeen   = false')

-- ---------------------------------------------------------------------------
T.section('a normal attacker-only tick')
local ct = newContest(1000)
step(ct, 1, 0, { 'ATK1' }, 1005)
T.eq('one 5s tick banks 5s of progress', ct.progress, 5)
T.eq('peak follows progress up', ct.peak, 5)
T.eq('the stall clock is reset while gaining', ct.stalledFor, 0)
T.eq('lastTickAt is re-anchored', ct.lastTickAt, 1005)
T.eq('presence is measured per attacker', ct.presentSec.ATK1, 5)
T.isfalse('no defender has been seen', ct.defenderSeen)
T.eq('the acting citizen is the first present', ct.actorCid, 'ATK1')

step(ct, 1, 0, { 'ATK1' }, 1010)
T.eq('a second tick accumulates', ct.progress, 10)
T.eq('and so does the presence ledger', ct.presentSec.ATK1, 10)

-- ---------------------------------------------------------------------------
T.section('a full uncontested capture takes exactly HoldSeconds of presence')
ct = newContest(0)
local t = 0
local ticksToHold = 0
while ct.progress < CF.HoldSeconds do
    t = t + tick
    step(ct, 2, 0, { 'ATK1', 'ATK2' }, t)
    ticksToHold = ticksToHold + 1
    if ticksToHold > 200 then break end
end
T.eq('24 five-second ticks reach the hold threshold', ticksToHold, 24)
T.eq('and the elapsed wall time is exactly HoldSeconds', t, CF.HoldSeconds)
T.eq('progress lands exactly on the threshold', ct.progress, CF.HoldSeconds)
T.eq('both attackers banked the full window', ct.presentSec.ATK1, CF.HoldSeconds)
T.eq('the second attacker too', ct.presentSec.ATK2, CF.HoldSeconds)
T.eq('the stall clock never ran', ct.stalledFor, 0)

-- ---------------------------------------------------------------------------
T.section('a delayed tick banks the time it actually measured')
ct = newContest(500)
step(ct, 1, 0, { 'ATK1' }, 512)      -- 12s, under the 20s cap
T.eq('a 12s gap banks 12s, not the 5s loop period', ct.progress, 12)
T.eq('presence matches', ct.presentSec.ATK1, 12)
step(ct, 1, 0, { 'ATK1' }, 532)      -- exactly the cap
T.eq('a gap of exactly the cap banks the cap', ct.progress, 32)

-- ---------------------------------------------------------------------------
T.section('a pathological stall is capped and cannot bank a capture')
ct = newContest(0)
step(ct, 3, 0, { 'ATK1', 'ATK2', 'ATK3' }, 3600)   -- the server froze for an hour
T.eq('one hour of wall time banks only the catch-up cap', ct.progress, maxStep)
T.ne('it does not bank the full hour', ct.progress, 3600)
T.lt('so a single sample cannot reach the hold threshold', ct.progress, CF.HoldSeconds)
T.eq('the presence ledger is capped identically', ct.presentSec.ATK1, maxStep)
T.eq('lastTickAt still jumps to real now, so the stall is not re-banked',
    ct.lastTickAt, 3600)
step(ct, 3, 0, { 'ATK1' }, 3605)
T.eq('the next tick is a normal 5s again', ct.progress, maxStep + 5)

-- The same cap has to protect the ABANDON clock, or a freeze would silently
-- end contests that nobody walked away from.
ct = newContest(0)
step(ct, 1, 0, { 'ATK1' }, 5)          -- gain, peak = 5
step(ct, 0, 0, {}, 5 + 86400)          -- a full day of nothing
T.eq('a day-long stall adds only the capped step to the stall clock',
    ct.stalledFor, maxStep)
T.lt('so one freeze cannot abandon a contest by itself', ct.stalledFor, CF.AbandonSeconds)

-- ---------------------------------------------------------------------------
T.section('defenders')
ct = newContest(0)
ct.progress, ct.peak = 50, 50
step(ct, 0, 2, {}, 5)
T.near('defenders alone bleed progress at DefenderDecayMult', ct.progress, 40)
T.istrue('seeing a defender latches defenderSeen', ct.defenderSeen)
T.eq('the stall clock runs while losing ground', ct.stalledFor, 5)
T.eq('peak does not fall with progress', ct.peak, 50)

step(ct, 0, 0, {}, 10)
T.istrue('defenderSeen stays latched once the defenders leave', ct.defenderSeen)

-- Outnumbered attackers still gain: the rule is strictly "more attackers than
-- defenders", not "no defenders".
ct = newContest(0)
step(ct, 3, 1, { 'A', 'B', 'C' }, 5)
T.eq('3 attackers against 1 defender gain normally', ct.progress, 5)
T.istrue('but the defender was still seen', ct.defenderSeen)

ct = newContest(0)
ct.progress, ct.peak = 30, 30
step(ct, 1, 3, { 'A' }, 5)
T.near('1 attacker against 3 defenders loses ground at 2x', ct.progress, 20)

-- TIES GO TO THE DEFENDER. `atk > 0 and atk > def` is false at equal numbers,
-- so the next branch (def > 0) runs and progress bleeds at the full defender
-- rate. Equal numbers is a stalemate the attacker loses.
ct = newContest(0)
ct.progress, ct.peak = 60, 60
step(ct, 2, 2, { 'A', 'B' }, 5)
T.near('an even 2v2 bleeds at the defender rate', ct.progress, 50)
ct = newContest(0)
ct.progress, ct.peak = 60, 60
step(ct, 5, 5, { 'A', 'B', 'C', 'D', 'E' }, 5)
T.near('an even 5v5 bleeds at the defender rate too', ct.progress, 50)

-- ---------------------------------------------------------------------------
T.section('an empty zone bleeds at 1x, not the defender rate')
ct = newContest(0)
ct.progress, ct.peak = 50, 50
step(ct, 0, 0, {}, 5)
T.eq('nobody present sheds 1s per second', ct.progress, 45)
T.eq('and the stall clock runs', ct.stalledFor, 5)
T.eq('no citizen is credited with presence', next(ct.presentSec), nil)
T.isfalse('an empty zone never latches defenderSeen', ct.defenderSeen)
T.list('presentCids is emptied', ct.presentCids, {})

-- An empty zone bleeds strictly slower than a defended one. If these two ever
-- became equal, holding a zone would be worth nothing.
local empty = newContest(0); empty.progress, empty.peak = 100, 100
local held  = newContest(0); held.progress,  held.peak  = 100, 100
step(empty, 0, 0, {}, 5)
step(held, 0, 1, {}, 5)
T.lt('a defended zone bleeds faster than an abandoned one', held.progress, empty.progress)

-- ---------------------------------------------------------------------------
T.section('progress floors at zero and never goes negative')
ct = newContest(0)
ct.progress, ct.peak = 3, 40
step(ct, 0, 2, {}, 5)     -- would be 3 - 10 = -7
T.eq('an over-shoot floors at 0', ct.progress, 0)
step(ct, 0, 2, {}, 10)
T.eq('and stays at 0', ct.progress, 0)
T.eq('the stall clock keeps running at the floor', ct.stalledFor, 10)

-- ---------------------------------------------------------------------------
T.section('the anti-lock stall clock measures the high-water mark, not presence')
-- An attacker who steps in and out of the radius resets nothing: what resets
-- the clock is BEATING their own best, and progress lost while away has to be
-- re-earned before the clock moves again.
ct = newContest(0)
local now = 0
for _ = 1, 4 do now = now + 5; step(ct, 1, 0, { 'A' }, now) end
T.eq('four ticks of presence', ct.progress, 20)
T.eq('peak matches', ct.peak, 20)
T.eq('clock at zero while gaining', ct.stalledFor, 0)

now = now + 5; step(ct, 0, 0, {}, now)      -- steps out
T.eq('progress drops', ct.progress, 15)
T.eq('peak holds', ct.peak, 20)
T.eq('clock starts', ct.stalledFor, 5)

now = now + 5; step(ct, 1, 0, { 'A' }, now) -- steps back in
T.eq('progress recovers but has not beaten peak', ct.progress, 20)
T.eq('so the clock keeps running rather than resetting', ct.stalledFor, 10)

now = now + 5; step(ct, 1, 0, { 'A' }, now)
T.eq('only now is peak beaten', ct.progress, 25)
T.eq('and only now does the clock reset', ct.stalledFor, 0)

-- Equality is deliberately NOT a reset: progress == peak means no headway.
ct = newContest(0)
ct.progress, ct.peak, ct.stalledFor = 40, 40, 12
step(ct, 0, 0, {}, 0)   -- zero elapsed, nothing changes
T.eq('a zero-length tick does not reset the clock', ct.stalledFor, 12)
T.eq('and does not move progress', ct.progress, 40)

-- A pinned attacker: defenders present, attacker never gains. The clock must
-- reach AbandonSeconds so the zone cannot be locked out indefinitely.
ct = newContest(0)
now = 0
for _ = 1, 3 do now = now + 5; step(ct, 2, 0, { 'A', 'B' }, now) end
T.eq('the attacker built a foothold', ct.progress, 15)
local pinnedTicks = 0
while ct.stalledFor < CF.AbandonSeconds do
    now = now + 5
    step(ct, 1, 1, { 'A' }, now)
    pinnedTicks = pinnedTicks + 1
    if pinnedTicks > 100 then break end
end
T.eq('a pinned attacker hits the abandon threshold in 12 ticks', pinnedTicks, 12)
T.eq('which is exactly AbandonSeconds of measured time', ct.stalledFor, CF.AbandonSeconds)
T.istrue('and the defenders were seen, so this closes as a DEFENCE not a walk-away',
    ct.defenderSeen)

-- The same clock with nobody there at all: a walk-away. The distinction the
-- ticker draws between 'defended' and 'aborted' is exactly defenderSeen.
ct = newContest(0)
now = 0
for _ = 1, 3 do now = now + 5; step(ct, 1, 0, { 'A' }, now) end
while ct.stalledFor < CF.AbandonSeconds do
    now = now + 5
    step(ct, 0, 0, {}, now)
end
T.eq('a walk-away reaches the same threshold', ct.stalledFor, CF.AbandonSeconds)
T.isfalse('but with no defender seen, so it is a quiet abort', ct.defenderSeen)
T.eq('and progress has bled all the way out', ct.progress, 0)

-- ---------------------------------------------------------------------------
T.section('displacement threshold')
-- A contest is displaceable once stalledFor >= DisplaceAfterStallSec. A brand
-- new contest must never be displaceable, or the check-and-set in openContest
-- stops protecting anything.
ct = newContest(0)
T.lt('a fresh contest is below the displacement threshold',
    ct.stalledFor, CF.DisplaceAfterStallSec)
step(ct, 1, 0, { 'A' }, 5)
T.lt('an attacker who is gaining stays undisplaceable',
    ct.stalledFor, CF.DisplaceAfterStallSec)
step(ct, 0, 0, {}, 10)
T.ge('one stalled tick already reaches it', ct.stalledFor, CF.DisplaceAfterStallSec)

-- ---------------------------------------------------------------------------
T.section('clock going backwards')
-- os.time() can move backwards across an NTP correction. A negative measured
-- elapsed must be a no-op, never a refund of progress.
ct = newContest(1000)
ct.progress, ct.peak, ct.stalledFor = 40, 60, 7
step(ct, 1, 0, { 'A' }, 900)
T.eq('a backwards clock does not move progress', ct.progress, 40)
T.eq('nor the stall clock', ct.stalledFor, 7)
T.eq('nor the presence ledger', ct.presentSec.A, 0)
T.eq('but lastTickAt still re-anchors to the new now', ct.lastTickAt, 900)

-- A contest whose lastTickAt is missing must measure zero, not `now`.
ct = newContest(1000)
ct.lastTickAt = nil
step(ct, 1, 0, { 'A' }, 5000)
T.eq('a missing lastTickAt measures zero elapsed', ct.progress, 0)
T.eq('and anchors from this tick on', ct.lastTickAt, 5000)

-- ---------------------------------------------------------------------------
T.section('the presence ledger that decides who pays heat')
-- finishCapture ranks heat recipients by these seconds, so a latecomer must not
-- rank alongside someone who was there the whole time.
ct = newContest(0)
now = 0
for _ = 1, 10 do now = now + 5; step(ct, 1, 0, { 'EARLY' }, now) end
for _ = 1, 2 do now = now + 5; step(ct, 2, 0, { 'EARLY', 'LATE' }, now) end
T.eq('the attacker present throughout banks 60s', ct.presentSec.EARLY, 60)
T.eq('the latecomer banks only 10s', ct.presentSec.LATE, 10)
T.lt('so the ranking separates them', ct.presentSec.LATE, ct.presentSec.EARLY)
T.eq('HeatMinPresenceSec is the floor a bystander must clear', CF.HeatMinPresenceSec, 60)
T.lt('the latecomer is below the floor and pays no heat', ct.presentSec.LATE, CF.HeatMinPresenceSec)
T.ge('the attacker present throughout clears it exactly', ct.presentSec.EARLY, CF.HeatMinPresenceSec)
-- HeatMinPresenceSec (60) is HALF of HoldSeconds (120), so on the fastest
-- possible capture an attacker has to have been there for at least half of it.
T.eq('the floor is half the hold window', CF.HeatMinPresenceSec * 2, CF.HoldSeconds)

-- Somebody who is only ever present during a capped catch-up window is credited
-- with the capped seconds, not the wall time. Recorded because it means a
-- player who arrived during a server freeze can be credited with up to maxStep
-- seconds they were not actually standing there for.
ct = newContest(0)
step(ct, 1, 0, { 'ARRIVED_LATE' }, 3600)
T.eq('a catch-up window credits at most the cap', ct.presentSec.ARRIVED_LATE, maxStep)
T.lt('which stays below the heat presence floor', ct.presentSec.ARRIVED_LATE,
    CF.HeatMinPresenceSec)

-- ---------------------------------------------------------------------------
T.section('determinism: the same tick sequence gives the same numbers')
local function replay()
    local c = newContest(0)
    local n = 0
    for i = 1, 30 do
        n = n + 5
        if i % 4 == 0 then step(c, 0, 1, {}, n)
        elseif i % 7 == 0 then step(c, 0, 0, {}, n)
        else step(c, 2, 1, { 'A', 'B' }, n) end
    end
    return c
end
local runA, runB = replay(), replay()
T.near('same progress', runB.progress, runA.progress)
T.eq('same peak', runB.peak, runA.peak)
T.eq('same stall clock', runB.stalledFor, runA.stalledFor)
T.eq('same presence for A', runB.presentSec.A, runA.presentSec.A)
T.eq('same presence for B', runB.presentSec.B, runA.presentSec.B)
T.eq('same defenderSeen', runB.defenderSeen, runA.defenderSeen)

T.done()
