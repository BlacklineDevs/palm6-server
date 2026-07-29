-- ============================================================================
-- palm6_legal /sentence lookup budget, audit de-dup and citizenid comparison.
--
-- /sentence is a READ command that pulls someone else's criminal record and, if
-- Config.Sentencing.Audit is on, posts to a Discord webhook each time. The
-- rolling budget below is the only thing standing between a patient loop and
-- both (a) harvesting other players' identities and (b) turning the audit
-- channel into the flood. The 5-second cooldown in Config.RateLimits does not
-- stop a patient loop; this does. It is new code and nothing has tested it.
--
-- Everything under test here is pure apart from os.time(), which the resource
-- reads through a one-line `now()` helper. The wrapper shadows that helper so
-- the clock is an input, and the budget's own ledger table is lifted with it.
--
-- NOT TESTED HERE: sentenceGate (four Bridge job/ace calls), cmdSentence,
-- cmdExpunge, cmdRecord and every DB helper in the file. README lists them.
-- ============================================================================
T.begin('palm6_legal /sentence lookup budget')

local LEGAL = 'resources/[custom]/palm6_legal/'
local MAIN = LEGAL .. 'server/main.lua'
T.loadFile(LEGAL .. 'shared/config.lua')

local S = Config.Sentencing

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the /sentence command still ships dark', S.Enabled)
T.eq('MaxPerWindow', S.MaxPerWindow, 8)
T.eq('WindowSec', S.WindowSec, 300)
T.eq('the filing fee is unchanged', Config.Expunge.Fee, 2500)
-- The budget only bounds the audit posts if it is tighter than the webhook
-- ceiling the config's own comment cites (~30/min).
T.lt('worst-case audit rate stays well under one post per second',
    S.MaxPerWindow / S.WindowSec, 1.0)

-- ---------------------------------------------------------------------------
-- Lift the budget, its ledger and the audit de-dup.
-- ---------------------------------------------------------------------------
local budgetBlock = T.slice(MAIN,
    'local sentenceWindow = {}',
    '-- Citizenids are typed in chat.')
T.contains('slice contains the ledger', budgetBlock, 'local sentenceWindow = {}')
T.contains('slice contains the budget', budgetBlock, 'local function sentenceBudget(src)')
T.contains('slice contains the audit de-dup', budgetBlock, 'local function auditFirstSeen(src, bookingId)')
T.notcontains('slice pulled in no MySQL', budgetBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', budgetBlock, 'Bridge.')

local sameBlock = T.slice(MAIN,
    'local function sameCitizen(a, b)',
    'local function cmdSentence(src, args)')

-- `now()` in the resource is `local function now() return os.time() end`. It is
-- shadowed here so the clock is an input rather than a dependency.
local wrapped = table.concat({
    'local __t = 0',
    'local function now() return __t end',
    budgetBlock,
    sameBlock,
    'return function(t) __t = t end, sentenceBudget, auditFirstSeen, sameCitizen, sentenceWindow',
}, '\n')
local setClock, sentenceBudget, auditFirstSeen, sameCitizen, ledger =
    T.chunk('palm6_legal sentence budget', wrapped)()

-- ---------------------------------------------------------------------------
T.section('the server console is exempt')
setClock(1000)
for i = 1, 50 do
    if i == 50 then
        T.istrue('50 console lookups in a row are all allowed', (sentenceBudget(0)))
    else
        sentenceBudget(0)
    end
end
T.isnil('and the console leaves no ledger entry', ledger[0])
T.istrue('the console is never audit-deduped either', auditFirstSeen(0, 77))
T.istrue('not even for a booking it already saw', auditFirstSeen(0, 77))

-- ---------------------------------------------------------------------------
T.section('a player gets exactly MaxPerWindow lookups per window')
setClock(2000)
local allowed = 0
for _ = 1, S.MaxPerWindow do
    if sentenceBudget(7) then allowed = allowed + 1 end
end
T.eq('the first MaxPerWindow lookups are allowed', allowed, S.MaxPerWindow)

local ok, retryIn = sentenceBudget(7)
T.isfalse('the next one is refused', ok)
T.eq('and it is told the full window remains', retryIn, S.WindowSec)

-- Spending nothing on a refusal: a blocked caller must not extend its own
-- lockout by hammering.
setClock(2100)
local ok2, retryIn2 = sentenceBudget(7)
T.isfalse('still refused 100s into the window', ok2)
T.eq('and the countdown has moved with the clock, not with the attempts',
    retryIn2, S.WindowSec - 100)
sentenceBudget(7); sentenceBudget(7); sentenceBudget(7)
local _, retryIn3 = sentenceBudget(7)
T.eq('four more refused attempts do not move the countdown',
    retryIn3, S.WindowSec - 100)

-- ---------------------------------------------------------------------------
T.section('the window boundary')
setClock(2000 + S.WindowSec - 1)
local okEdge, retryEdge = sentenceBudget(7)
T.isfalse('one second before the window ends, still refused', okEdge)
T.eq('with one second left on the clock', retryEdge, 1)

setClock(2000 + S.WindowSec)
T.istrue('exactly at the window length, the budget resets', (sentenceBudget(7)))
T.eq('and the ledger restarts from this moment', ledger[7].start, 2000 + S.WindowSec)
T.eq('with one lookup already spent', ledger[7].n, 1)

-- The refund case the countdown formula guards: math.max(1, ...) means the
-- caller is never told to retry in 0 seconds.
setClock(2000 + S.WindowSec)
for _ = 1, S.MaxPerWindow do sentenceBudget(7) end
local _, waitFor = sentenceBudget(7)
T.ge('the retry hint is never below 1 second', waitFor, 1)

-- ---------------------------------------------------------------------------
T.section('budgets are per source')
setClock(5000)
for _ = 1, S.MaxPerWindow do sentenceBudget(11) end
T.isfalse('source 11 is spent', (sentenceBudget(11)))
T.istrue('source 12 is untouched', (sentenceBudget(12)))
T.eq('and has its own ledger', ledger[12].n, 1)
T.ne('with its own window start', ledger[12], ledger[11])

-- ---------------------------------------------------------------------------
T.section('audit de-dup keeps a read command off the webhook')
setClock(9000)
sentenceBudget(21)
T.istrue('the first sight of a booking logs', auditFirstSeen(21, 501))
T.isfalse('the same booking again in the same window does not', auditFirstSeen(21, 501))
T.isfalse('and not on the third try either', auditFirstSeen(21, 501))
T.istrue('a different booking logs', auditFirstSeen(21, 502))
T.isfalse('and is then deduped too', auditFirstSeen(21, 502))
T.istrue('a different source logging the same booking is not deduped',
    auditFirstSeen(22, 501))

-- The ledger cannot grow without bound: `logged` can hold at most MaxPerWindow
-- keys because the budget refuses the caller past that, and the whole record is
-- replaced on the next window.
setClock(9000 + S.WindowSec)
sentenceBudget(21)
T.istrue('after the window resets, the same booking logs again', auditFirstSeen(21, 501))
local loggedKeys = 0
for _ in pairs(ledger[21].logged) do loggedKeys = loggedKeys + 1 end
T.eq('and the logged set was wiped, not appended to', loggedKeys, 1)

-- A source that has never spent budget has no ledger record, and the de-dup
-- has to fail OPEN in that case rather than index a nil.
T.istrue('an unknown source is not deduped', auditFirstSeen(999, 1))

-- Booking ids are keyed by tostring, so a numeric and a string id must collide
-- rather than log twice for the same record.
setClock(20000)
sentenceBudget(30)
T.istrue('numeric booking id logs', auditFirstSeen(30, 42))
T.isfalse('the same id as a string is deduped, not logged twice',
    auditFirstSeen(30, '42'))

-- ---------------------------------------------------------------------------
T.section('config fallbacks when an operator blanks a value')
local savedMax, savedWin = S.MaxPerWindow, S.WindowSec
S.MaxPerWindow, S.WindowSec = nil, nil
setClock(30000)
local n = 0
for _ = 1, 20 do if sentenceBudget(40) then n = n + 1 end end
T.eq('a nil MaxPerWindow falls back to 8', n, 8)
local _, fallbackWait = sentenceBudget(40)
T.eq('a nil WindowSec falls back to 300', fallbackWait, 300)
S.MaxPerWindow, S.WindowSec = savedMax, savedWin

-- ---------------------------------------------------------------------------
T.section('citizenid comparison is normalised but never empty-matches')
T.istrue('exact match', sameCitizen('ABC12345', 'ABC12345'))
T.istrue('case is ignored', sameCitizen('abc12345', 'ABC12345'))
T.istrue('whitespace is stripped from both sides', sameCitizen('  abc 12345 ', 'ABC12345'))
T.istrue('a number compares as its string form', sameCitizen(12345, '12345'))
T.isfalse('different ids do not match', sameCitizen('ABC12345', 'ABC12346'))
-- The empty guard is the one that matters: without it a caller who typed
-- nothing would match a record whose citizenid failed to load.
T.isfalse('empty never matches empty', sameCitizen('', ''))
T.isfalse('nil never matches nil', sameCitizen(nil, nil))
T.isfalse('whitespace-only never matches empty', sameCitizen('   ', ''))
T.isfalse('a real id never matches nil', sameCitizen('ABC12345', nil))
T.isfalse('nil never matches a real id', sameCitizen(nil, 'ABC12345'))

T.done()
