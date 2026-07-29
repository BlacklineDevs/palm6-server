-- ============================================================================
-- palm6_heat decay, tier and add-clamp math.
--
-- palm6_heat/server/main.lua cannot be loaded whole: it opens a MySQL
-- connection at boot, registers commands through Bridge and installs event
-- handlers. The pure parts are `local function`s inside it.
--
-- Rather than refactor a deployed resource to make it importable (a real
-- behaviour risk while another agent works in this tree), the two pure blocks
-- are lifted out of the file BY ANCHOR and compiled as-is, so the bytes under
-- test are the bytes that ship. If either block moves, T.slice raises and this
-- suite fails loudly instead of quietly testing nothing.
--
-- WHAT IS NOT TESTED HERE: addHeat's DB path (the atomic settle-and-add INSERT
-- ... ON DUPLICATE KEY UPDATE), getHeat, getTop, sweep and GetSummary. All of
-- them are MySQL round-trips and none is reachable without a database. The
-- README lists them.
-- ============================================================================
T.begin('palm6_heat decay, tiers and add clamp')

local HEAT = 'resources/[custom]/palm6_heat/'
local MAIN = HEAT .. 'server/main.lua'
T.loadFile(HEAT .. 'shared/config.lua')

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.eq('HeatCap', Config.HeatCap, 150)
T.near('DecayPerMin', Config.DecayPerMin, 0.75)
T.eq('MaxAddPerCall', Config.MaxAddPerCall, 60)
T.eq('tier count', #Config.Tiers, 5)
T.eq('lowest tier is the CLEAN fallback at 0', Config.Tiers[#Config.Tiers].min, 0)

-- Tiers must stay sorted descending: tierOf returns the FIRST tier whose
-- threshold the heat meets, so an out-of-order table silently mislabels people.
local prev = nil
local sorted = true
for _, t in ipairs(Config.Tiers) do
    if prev ~= nil and t.min >= prev then sorted = false end
    prev = t.min
end
T.istrue('Config.Tiers is sorted strictly descending by min', sorted)

-- ---------------------------------------------------------------------------
-- Lift the pure helper block (decayed / tierOf / coolMinutes) out of main.lua.
-- ---------------------------------------------------------------------------
local pureBlock = T.slice(MAIN,
    'local function decayed(storedHeat, ageSec)',
    '-- Boot: self-create the table.')
T.contains('slice really contains decayed', pureBlock, 'local function decayed')
T.contains('slice really contains tierOf', pureBlock, 'local function tierOf')
T.contains('slice really contains coolMinutes', pureBlock, 'local function coolMinutes')
T.notcontains('slice pulled in no MySQL', pureBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', pureBlock, 'Bridge.')

local decayed, tierOf, coolMinutes =
    T.chunk('palm6_heat pure helpers', pureBlock .. '\nreturn decayed, tierOf, coolMinutes\n')()

-- ---------------------------------------------------------------------------
T.section('decay: the shape of the curve')
-- eff = stored - floor(ageSeconds / 60 * DecayPerMin), floored at 0.
T.eq('no time passed, nothing lost', decayed(100, 0), 100)
-- At 0.75/min the first whole point is not shed until 80 seconds. That is not a
-- rounding artefact, it is the model: heat is an integer and floor() is applied
-- to the loss, so anything under a full point is not yet lost.
T.eq('60s at 0.75/min sheds nothing yet', decayed(100, 60), 100)
T.eq('79s still sheds nothing', decayed(100, 79), 100)
T.eq('80s sheds the first point', decayed(100, 80), 99)
T.eq('one hour sheds 45', decayed(100, 3600), 55)
T.eq('two hours sheds 90', decayed(100, 7200), 10)

-- The documented full cool-down: 150 at 0.75/min is 200 minutes (3h20m).
T.eq('one second short of a full cool-down', decayed(150, 200 * 60 - 60), 1)
T.eq('exactly the full cool-down', decayed(150, 200 * 60), 0)
T.eq('a day later is still 0, never negative', decayed(150, 86400), 0)
T.eq('a year later is still 0', decayed(150, 365 * 86400), 0)
T.ge('decay never returns a negative', decayed(1, 999999999), 0)

T.eq('zero heat stays zero', decayed(0, 100), 0)
T.eq('cap heat with no age is the cap', decayed(150, 0), 150)

-- ---------------------------------------------------------------------------
T.section('decay: garbage input')
T.eq('nil stored heat is 0', decayed(nil, 60), 0)
T.eq('nil age is treated as 0 elapsed', decayed(100, nil), 100)
T.eq('both nil is 0', decayed(nil, nil), 0)
T.eq('non-numeric stored heat is 0', decayed('abc', 60), 0)
T.eq('non-numeric age is 0 elapsed', decayed(100, 'abc'), 100)
T.eq('numeric strings are honoured (the DB driver may hand back strings)',
    decayed('100', '3600'), 55)
T.eq('a fractional stored heat truncates', decayed(100.9, 0), 100)
-- Stored heat is INT UNSIGNED, so a negative can never come out of the column.
-- The floor still has to hold if one ever did.
T.eq('a negative stored heat floors at 0', decayed(-50, 0), 0)

-- NEGATIVE AGE. TIMESTAMPDIFF(SECOND, updated_at, NOW()) is negative whenever
-- updated_at is in the future, which happens if the DB clock jumps backwards
-- between the write and the read.
--
-- THIS SUITE FOUND A REAL BUG HERE. decayed() had no guard, so `lost` went
-- negative and heat went UP on read: decayed(100, -60) returned 101 and
-- decayed(150, -3600) returned 195 against a cap of 150, with nothing
-- downstream re-clamping before it reached tierOf and GetHeat/GetTop/
-- GetSummary. Fixed by clamping age to 0 in palm6_heat/server/main.lua.
-- These assertions now pin the FIX: a clock that runs backwards must cost a
-- player nothing, and must never mint heat.
T.eq('a negative age decays by nothing rather than inflating', decayed(100, -60), 100)
T.eq('a large negative age still decays by nothing', decayed(100, -3600), 100)
T.eq('and a stored value at the cap stays at the cap', decayed(150, -3600), 150)

-- Infinity and NaN cannot come out of an INT UNSIGNED column. Their behaviour
-- is recorded so that a future caller that computes an age in Lua knows what it
-- would get.
T.eq('an infinite age fully decays to 0', decayed(150, math.huge), 0)
T.isnan('a NaN age produces a NaN heat (no guard)', decayed(150, 0 / 0))
T.eq('an infinite stored heat stays infinite', decayed(math.huge, 0), math.huge)

-- ---------------------------------------------------------------------------
T.section('tiers: every boundary, from both sides')
T.eq('0 is CLEAN', tierOf(0).tier, 'CLEAN')
T.eq('1 is COOL', tierOf(1).tier, 'COOL')
T.eq('29 is still COOL', tierOf(29).tier, 'COOL')
T.eq('30 is WARM', tierOf(30).tier, 'WARM')
T.eq('64 is still WARM', tierOf(64).tier, 'WARM')
T.eq('65 is HOT', tierOf(65).tier, 'HOT')
T.eq('109 is still HOT', tierOf(109).tier, 'HOT')
T.eq('110 is WANTED', tierOf(110).tier, 'WANTED')
T.eq('the cap is WANTED', tierOf(Config.HeatCap).tier, 'WANTED')
T.eq('above the cap is still WANTED', tierOf(9999).tier, 'WANTED')
-- Below zero cannot happen (decayed floors at 0) but the fallback must hold.
T.eq('a negative falls back to CLEAN', tierOf(-5).tier, 'CLEAN')
T.eq('tiers carry a display label', tierOf(110).label, 'WANTED')
T.eq('tiers carry a colour triple', #tierOf(110).color, 3)

-- DispatchPriorityTier is the documented threshold consumers branch on. If the
-- tier strings are ever renamed this catches it before palm6_laundering and
-- palm6_mdt silently stop matching.
T.eq('DispatchPriorityTier names a real tier', Config.DispatchPriorityTier, 'HOT')
local tierExists = false
for _, t in ipairs(Config.Tiers) do
    if t.tier == Config.DispatchPriorityTier then tierExists = true end
end
T.istrue('DispatchPriorityTier exists in Config.Tiers', tierExists)

-- ---------------------------------------------------------------------------
T.section('cool-down estimate shown by /myheat')
T.eq('clean cools in 0 minutes', coolMinutes(0), 0)
T.eq('a negative cools in 0 minutes', coolMinutes(-5), 0)
T.eq('1 point takes 2 minutes (ceil of 1.33)', coolMinutes(1), 2)
T.eq('75 points take 100 minutes', coolMinutes(75), 100)
T.eq('a maxed citizen takes 200 minutes', coolMinutes(Config.HeatCap), 200)
-- Round trip: the estimate must not UNDER-state the wait, or /myheat lies.
for _, h in ipairs({ 1, 2, 7, 30, 65, 110, 149, 150 }) do
    T.eq(('estimate for %d is honest (heat is 0 by then)'):format(h),
        decayed(h, coolMinutes(h) * 60), 0)
end

-- A zero or negative decay rate would make the estimate divide by zero or go
-- negative. The helper guards it; an operator could set it.
local savedRate = Config.DecayPerMin
Config.DecayPerMin = 0
T.eq('a zero decay rate reports 0 rather than dividing by zero', coolMinutes(100), 0)
T.eq('and heat then never decays', decayed(100, 86400), 100)
Config.DecayPerMin = savedRate

-- ---------------------------------------------------------------------------
-- Lift the AddHeat amount-clamp chain out of addHeat. This is the block whose
-- own comments describe the NaN guard, the per-call cap and the HeatCap
-- backstop, so it is the block worth testing.
-- ---------------------------------------------------------------------------
T.section('AddHeat amount clamp')
local clampBlock = T.slice(MAIN,
    'amount = math.floor(tonumber(amount) or 0)',
    'reason = trim(reason ~= nil')
T.contains('slice contains the NaN guard', clampBlock, 'if amount ~= amount then return nil end')
T.contains('slice contains the per-call cap', clampBlock, 'Config.MaxAddPerCall')
T.contains('slice contains the HeatCap backstop', clampBlock, 'Config.HeatCap')
T.notcontains('slice pulled in no MySQL', clampBlock, 'MySQL')

-- `return nil` inside the block means "AddHeat is a no-op", so the wrapper
-- returns nil for a rejected amount and the clamped integer otherwise.
local clampAmount = T.chunk('palm6_heat AddHeat amount clamp',
    'return function(amount)\n' .. clampBlock .. '\nreturn amount\nend\n')()

T.isnil('nil is a no-op', clampAmount(nil))
T.isnil('zero is a no-op', clampAmount(0))
T.isnil('a negative is a no-op', clampAmount(-5))
T.isnil('a non-numeric string is a no-op', clampAmount('abc'))
T.isnil('a boolean is a no-op', clampAmount(true))
T.isnil('a table is a no-op', clampAmount({}))
T.isnil('NaN is a no-op (this is the guard the comment describes)', clampAmount(0 / 0))
T.isnil('negative infinity is a no-op', clampAmount(-math.huge))

T.eq('a normal amount passes through', clampAmount(12), 12)
T.eq('a numeric string is honoured', clampAmount('25'), 25)
T.eq('a fraction truncates down', clampAmount(5.9), 5)
T.eq('0.9 truncates to 0 and becomes a no-op', clampAmount(0.9), nil)
T.eq('exactly 1 is the smallest amount that counts', clampAmount(1), 1)
T.eq('exactly MaxAddPerCall passes unchanged', clampAmount(Config.MaxAddPerCall), 60)
T.eq('one over the per-call cap is clamped', clampAmount(Config.MaxAddPerCall + 1), 60)
T.eq('a huge amount is clamped to the per-call cap', clampAmount(100000), 60)
T.eq('positive infinity is caught by the cap, not by the NaN guard',
    clampAmount(math.huge), 60)
T.eq('the clamped result is an integer', math.type(clampAmount(math.huge)), 'integer')

-- The second clamp is inert under the shipped config (MaxAddPerCall 60 is below
-- HeatCap 150) and its own comment says so. It only matters if an operator
-- raises the per-call cap above the heat cap, so that is the case tested.
local savedMax = Config.MaxAddPerCall
Config.MaxAddPerCall = 500
T.eq('with MaxAddPerCall above HeatCap, the HeatCap backstop fires',
    clampAmount(400), Config.HeatCap)
T.eq('and infinity is caught by it too', clampAmount(math.huge), Config.HeatCap)
Config.MaxAddPerCall = savedMax
T.eq('restoring the config restores the old clamp', clampAmount(100000), 60)

-- ---------------------------------------------------------------------------
T.section('the suggested-weight table stays inside the per-call cap')
-- Every wire is documented as pulling its weight from Config.Suggested. If any
-- entry exceeds MaxAddPerCall the clamp silently rewrites it, so the table and
-- the cap have to agree.
local over = {}
for k, v in pairs(Config.Suggested) do
    if v > Config.MaxAddPerCall then over[#over + 1] = k end
end
table.sort(over)
T.list('no suggested weight exceeds MaxAddPerCall', over, {})
local nonPositive = {}
for k, v in pairs(Config.Suggested) do
    if type(v) ~= 'number' or v <= 0 or math.floor(v) ~= v then
        nonPositive[#nonPositive + 1] = k
    end
end
table.sort(nonPositive)
T.list('every suggested weight is a positive integer', nonPositive, {})
T.eq('the heaviest suggested weight is murder', Config.Suggested.murder, 60)
T.eq('murder sits exactly on the per-call cap', Config.Suggested.murder, Config.MaxAddPerCall)

T.done()
