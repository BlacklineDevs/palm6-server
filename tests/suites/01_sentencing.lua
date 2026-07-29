-- ============================================================================
-- palm6_mdt sentence calculator.
--
-- shared/sentencing.lua is a deliberately pure file (its own header says so) so
-- it is loaded directly, together with the SHIPPED shared/config.lua. Every
-- number asserted below is therefore the number the live catalogue produces,
-- not a number invented for a test.
--
-- The worked examples in the file's own header are checked here: integer
-- hundredths, one rounding at the end, half up.
-- ============================================================================
T.begin('palm6_mdt sentence calculator')

local MDT = 'resources/[custom]/palm6_mdt/'
T.loadFile(MDT .. 'shared/config.lua')
T.loadFile(MDT .. 'shared/sentencing.lua')

local CH = Config.Charges

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
-- If an operator retunes the catalogue these five lines fail first and say so,
-- rather than twenty arithmetic assertions failing with no explanation.
T.eq('ConcurrentPct', CH.ConcurrentPct, 50)
T.eq('PriorsStepPct', CH.PriorsStepPct, 10)
T.eq('PriorsCap', CH.PriorsCap, 5)
T.eq('MinSentence', CH.MinSentence, 1)
T.eq('MaxSentence', CH.MaxSentence, 120)
T.eq('MaxFine', CH.MaxFine, 250000)
T.eq('MaxCodes', CH.MaxCodes, 10)
T.eq('SentenceUnit', CH.SentenceUnit, 'months')

-- ---------------------------------------------------------------------------
T.section('no randomness anywhere in the source')
-- The determinism claim is structural, so it is checked structurally as well as
-- behaviourally. A sentence calculator that reads a clock or a PRNG cannot be
-- reproduced on paper by the player it sentenced.
local src = T.source(MDT .. 'shared/sentencing.lua')
T.notcontains('no math.random', src, 'math.random')
T.notcontains('no os.time', src, 'os.time')
T.notcontains('no os.clock', src, 'os.clock')
T.notcontains('no os.date', src, 'os.date')
T.notcontains('no GetGameTimer', src, 'GetGameTimer')
-- 'MySQL.' with the dot: the word MySQL appears in the header comment claiming
-- there is none, so the bare word would match its own disclaimer.
T.notcontains('no MySQL call', src, 'MySQL.')
T.notcontains('no exports call', src, 'exports.')

-- ---------------------------------------------------------------------------
T.section('lookup')
T.eq('exact code resolves', Sentencing.Lookup('murder_1').sentence, 90)
T.eq('uppercase resolves', Sentencing.Lookup('MURDER_1').code, 'murder_1')
T.eq('surrounding whitespace stripped', Sentencing.Lookup('  gta  ').code, 'gta')
T.eq('inner whitespace stripped', Sentencing.Lookup('bank robbery'), nil)
T.isnil('unknown code is nil', Sentencing.Lookup('not_a_code'))
T.isnil('empty string is nil', Sentencing.Lookup(''))
T.isnil('nil is nil', Sentencing.Lookup(nil))
T.eq('number argument does not crash', Sentencing.Lookup(12345), nil)
T.eq('catalogue size', #Sentencing.Codes(), 17)
T.eq('codes are sorted', Sentencing.Codes()[1], 'assault')

-- ---------------------------------------------------------------------------
T.section('empty and unknown input')
local r = Sentencing.Calculate({}, 0)
T.isfalse('empty list is not ok', r.ok)
T.eq('empty list reason', r.reason, 'no known charge codes')
T.eq('empty list sentence', r.sentence, 0)
T.eq('empty list fine', r.fine, 0)
T.eq('empty list multiplier', r.multPct, 100)
T.eq('empty list unit is carried', r.unit, 'months')

r = Sentencing.Calculate(nil, 0)
T.isfalse('nil codes is not ok', r.ok)
T.eq('nil codes sentence', r.sentence, 0)

r = Sentencing.Calculate('murder_1', 0)
T.isfalse('a bare string is not a code list', r.ok)

r = Sentencing.Calculate({ 'not_a_code', 'also_bogus' }, 0)
T.isfalse('all-unknown is not ok', r.ok)
T.list('unknown codes are reported verbatim', r.unknown, { 'not_a_code', 'also_bogus' })
T.eq('unknown codes score nothing', r.sentence, 0)

r = Sentencing.Calculate({ 'not_a_code', 'gta' }, 0)
T.istrue('one known code among unknowns is ok', r.ok)
T.list('the unknown one is still reported', r.unknown, { 'not_a_code' })
T.eq('only the known one counts', r.sentence, 15)

-- ---------------------------------------------------------------------------
T.section('single charge, no priors')
-- murder_1 is 90 months / $60000. 90 * 100 hundredths * 100% = 900000
-- ten-thousandths, +5000, // 10000 = 90.
r = Sentencing.Calculate({ 'murder_1' }, 0)
T.istrue('ok', r.ok)
T.eq('sentence', r.sentence, 90)
T.eq('fine', r.fine, 60000)
T.eq('one charge applied', #r.applied, 1)
T.istrue('it is the primary', r.applied[1].primary)
T.eq('primary is served at 100%', r.applied[1].pct, 100)
T.eq('multiplier with no priors', r.multPct, 100)
T.isfalse('not capped', r.capped)
T.eq('result is an integer', math.type(r.sentence), 'integer')
T.eq('fine is an integer', math.type(r.fine), 'integer')

-- ---------------------------------------------------------------------------
T.section('concurrent stacking')
-- murder_1 (90) primary in full, trespass (1) at 50% = 0.5.
-- 9000 + 50 = 9050 hundredths -> 905000 ten-thousandths -> (905000+5000)//10000 = 91.
r = Sentencing.Calculate({ 'trespass', 'murder_1' }, 0)
T.eq('most serious charge is primary regardless of input order', r.applied[1].code, 'murder_1')
T.eq('secondary served at ConcurrentPct', r.applied[2].pct, 50)
T.eq('90 + half of 1 rounds to 91', r.sentence, 91)
T.eq('fines are cumulative at full value', r.fine, 60500)

-- The headline promise: six petty charges must not out-sentence one murder.
local petty = { 'trespass', 'disorder', 'obstruct', 'theft_petty', 'evade', 'poss_ctrl' }
local pettyR = Sentencing.Calculate(petty, 0)
-- evade (5) primary = 500; poss_ctrl 5*50=250; theft_petty 4*50=200;
-- obstruct 2*50=100; disorder 1*50=50; trespass 1*50=50. Total 1150 hundredths
-- -> 115000 ten-thousandths -> 12.
T.eq('six petty charges', pettyR.sentence, 12)
T.eq('six petty charges fine', pettyR.fine, 500 + 750 + 1000 + 1500 + 2500 + 2000)
T.lt('six petty charges lose to one murder', pettyR.sentence,
    Sentencing.Calculate({ 'murder_1' }, 0).sentence)

-- Tiebreak: evade and poss_ctrl are both 5 months, so the higher FINE wins the
-- primary slot. This is the rule that makes the sort total and the result
-- order-independent.
T.eq('equal sentences tiebreak on fine', pettyR.applied[1].code, 'evade')
T.eq('second place on the tiebreak', pettyR.applied[2].code, 'poss_ctrl')

-- ---------------------------------------------------------------------------
T.section('de-duplication')
local once = Sentencing.Calculate({ 'murder_1' }, 0)
local twice = Sentencing.Calculate({ 'murder_1', 'murder_1', 'MURDER_1', ' murder_1 ' }, 0)
T.eq('a repeated code does not double the sentence', twice.sentence, once.sentence)
T.eq('a repeated code does not double the fine', twice.fine, once.fine)
T.eq('only one row applied', #twice.applied, 1)

-- ---------------------------------------------------------------------------
T.section('priors')
r = Sentencing.Calculate({ 'murder_1' }, 3)
T.eq('3 priors -> 130%', r.multPct, 130)
T.eq('9000 x 130% = 117', r.sentence, 117)
T.eq('priors do not touch the fine', r.fine, 60000)

r = Sentencing.Calculate({ 'murder_1' }, 5)
T.eq('5 priors is the cap', r.priors, 5)
T.eq('5 priors -> 150%', r.multPct, 150)
T.eq('135 months clamps to the ceiling', r.sentence, 120)
T.istrue('and reports capped', r.capped)
T.istrue('specifically capped high', r.cappedHigh)
T.isfalse('not capped low', r.cappedLow)

r = Sentencing.Calculate({ 'murder_1' }, 40)
T.eq('40 priors still counts only 5', r.priors, 5)
T.eq('but priorsGiven records the truth', r.priorsGiven, 40)
T.eq('multiplier tops out', r.multPct, 150)

r = Sentencing.Calculate({ 'gta' }, -7)
T.eq('negative priors floor at 0', r.priors, 0)
T.eq('negative priors do not reduce the sentence', r.sentence, 15)

r = Sentencing.Calculate({ 'gta' }, 2.7)
T.eq('fractional priors truncate', r.priors, 2)
T.eq('fractional priors multiplier', r.multPct, 120)

r = Sentencing.Calculate({ 'gta' }, 'four')
T.eq('non-numeric priors count as 0', r.priors, 0)
r = Sentencing.Calculate({ 'gta' }, nil)
T.eq('nil priors count as 0', r.priors, 0)
r = Sentencing.Calculate({ 'gta' }, '3')
T.eq('numeric string priors are honoured', r.priors, 3)

-- The in-repo path (palm6_mdt's priorsFor) is a SELECT COUNT(*), which is
-- always a non-negative integer, so the three below are about the exported
-- surface: exports('CalculateSentence', codes, priors) lets any other resource
-- pass whatever it likes.
--
-- NaN is absorbed safely, because math.max(0, nan) returns 0 in Lua 5.3
-- (comparisons against NaN are false, so the first argument wins).
r = T.noraise('NaN priors does not raise', function()
    return Sentencing.Calculate({ 'gta' }, 0 / 0)
end)
T.eq('NaN priors counts as 0', r.priors, 0)
T.eq('NaN priors gives the un-multiplied sentence', r.sentence, 15)
T.eq('NaN priors keeps an integer result', math.type(r.sentence), 'integer')

-- THIS SUITE FOUND A REAL BUG HERE. math.huge is not absorbed the way NaN is:
-- it survives math.floor and math.max as a float with no integer
-- representation. The ARITHMETIC was always fine (min(inf, 5) = 5), but the
-- breakdown line formats `priorsGiven` with %d, and in Lua 5.3+
-- string.format('%d', math.huge) RAISES. That broke this file's contract of
-- never throwing at a caller (Sentencing.Failure exists precisely so it can
-- refuse without raising), and CalculateSentence is exported, so any resource
-- could hand it anything. Fixed by normalising a non-integer-representable
-- count to the cap. These assertions now pin the FIX.
r = Sentencing.Calculate({ 'gta' }, math.huge)
T.eq('infinite priors returns a result instead of raising', type(r), 'table')
T.eq('infinite priors counts as the cap', r.priors, 5)
T.eq('infinite priors keeps an integer sentence', math.type(r.sentence), 'integer')
r = Sentencing.Calculate({ 'gta' }, 1e300)
T.eq('a float too large for an integer also returns a result', type(r), 'table')
T.eq('and also counts as the cap', r.priors, 5)
-- A large but ordinary integer is fine, which pins the fault to the %d format
-- of a non-integer-representable float and not to the arithmetic itself.
r = Sentencing.Calculate({ 'gta' }, 1000000)
T.eq('a million priors still caps at 5', r.priors, 5)
T.eq('a million priors sentence', r.sentence, 23)
T.eq('a million priors is reported honestly', r.priorsGiven, 1000000)

-- ---------------------------------------------------------------------------
T.section('rounding is half up, exactly once, at the end')
-- disorder (1, $750) and trespass (1, $500): equal sentence, disorder wins the
-- fine tiebreak and is primary. 100 + 50 = 150 hundredths = 1.50 months.
r = Sentencing.Calculate({ 'trespass', 'disorder' }, 0)
T.eq('1.50 rounds up to 2', r.sentence, 2)

-- trespass alone with 4 priors: 100 x 140% = 14000 ten-thousandths = 1.40.
r = Sentencing.Calculate({ 'trespass' }, 4)
T.eq('1.40 rounds down to 1', r.sentence, 1)
-- ...and with 5 priors: 100 x 150% = 15000 = exactly 1.50, the half-up boundary.
r = Sentencing.Calculate({ 'trespass' }, 5)
T.eq('exactly 1.50 rounds up to 2', r.sentence, 2)

-- ---------------------------------------------------------------------------
T.section('the charge limit cuts the least serious, never the last typed')
local eleven = {
    'trespass', 'disorder', 'obstruct', 'theft_petty', 'evade', 'poss_ctrl',
    'weapon_unlic', 'assault', 'burglary', 'gta', 'murder_1',
}
r = Sentencing.Calculate(eleven, 0)
T.eq('exactly MaxCodes charges applied', #r.applied, 10)
T.eq('the murder typed LAST is still the primary', r.applied[1].code, 'murder_1')
T.list('the mildest charge is what got dropped', r.dropped, { 'trespass' })
T.contains('the breakdown says so', table.concat(r.breakdown, '\n'), 'least serious dropped first')

-- Order independence: reverse the same eleven codes and nothing about the
-- numeric result may change.
local reversed = {}
for i = #eleven, 1, -1 do reversed[#reversed + 1] = eleven[i] end
local rr = Sentencing.Calculate(reversed, 0)
T.eq('reversed input, same sentence', rr.sentence, r.sentence)
T.eq('reversed input, same fine', rr.fine, r.fine)
T.eq('reversed input, same primary', rr.applied[1].code, r.applied[1].code)
T.list('reversed input, same dropped list', rr.dropped, r.dropped)

-- ---------------------------------------------------------------------------
T.section('determinism')
local a = Sentencing.Calculate({ 'murder_2', 'gta', 'evade', 'assault' }, 2)
local b = Sentencing.Calculate({ 'murder_2', 'gta', 'evade', 'assault' }, 2)
local c = Sentencing.Calculate({ 'assault', 'evade', 'gta', 'murder_2' }, 2)
T.eq('run 1 == run 2 sentence', a.sentence, b.sentence)
T.eq('run 1 == run 2 fine', a.fine, b.fine)
T.eq('run 1 == run 2 breakdown', table.concat(a.breakdown, '|'), table.concat(b.breakdown, '|'))
T.eq('shuffled input, same sentence', c.sentence, a.sentence)
T.eq('shuffled input, same fine', c.fine, a.fine)
T.eq('shuffled input, same breakdown', table.concat(c.breakdown, '|'), table.concat(a.breakdown, '|'))

-- ---------------------------------------------------------------------------
T.section('integer coercion at the config boundary')
-- The header claims a mistyped float cannot reach the arithmetic. Prove it by
-- mistyping one: 50.9 must behave exactly as 50.
local baseline = Sentencing.Calculate({ 'murder_1', 'gta', 'assault' }, 1)
CH.ConcurrentPct = 50.9
local coerced = Sentencing.Calculate({ 'murder_1', 'gta', 'assault' }, 1)
CH.ConcurrentPct = 50
T.eq('ConcurrentPct 50.9 truncates to 50', coerced.sentence, baseline.sentence)
T.eq('and the applied percentage is an integer', coerced.applied[2].pct, 50)
T.eq('sentence stays an integer', math.type(coerced.sentence), 'integer')

CH.PriorsStepPct = 10.7
local stepped = Sentencing.Calculate({ 'murder_1' }, 2)
CH.PriorsStepPct = 10
T.eq('PriorsStepPct 10.7 truncates to 10', stepped.multPct, 120)

-- ---------------------------------------------------------------------------
T.section('bounds that the shipped catalogue cannot reach')
-- With MinSentence = 1 and no zero-month charge in the catalogue, the floor can
-- never bite, and with MaxCodes = 10 the biggest possible fine is $198,500,
-- below the $250,000 ceiling. Both clamps are therefore exercised by moving the
-- bound rather than by inventing a charge, so the clamp logic is still covered.
CH.MinSentence = 40
r = Sentencing.Calculate({ 'trespass' }, 0)
CH.MinSentence = 1
T.eq('MinSentence floor raises the result', r.sentence, 40)
T.istrue('and reports capped low', r.cappedLow)
T.istrue('capped is the union of both directions', r.capped)
T.isfalse('not capped high', r.cappedHigh)
T.contains('the breakdown names the range', table.concat(r.breakdown, '\n'), 'clamped to the configured range')

CH.MaxFine = 1000
r = Sentencing.Calculate({ 'murder_1' }, 0)
CH.MaxFine = 250000
T.eq('fine ceiling clamps', r.fine, 1000)
T.istrue('a clamped fine sets capped', r.capped)
T.contains('the breakdown names the fine ceiling', table.concat(r.breakdown, '\n'), 'fine clamped')

-- The biggest fine the shipped catalogue can actually produce, stated as a
-- number so a future catalogue edit that crosses MaxFine is noticed here.
local topTen = {
    'murder_1', 'murder_2', 'bank_robbery', 'kidnap', 'traff_ctrl',
    'robbery_armed', 'leo_assault', 'gta', 'burglary', 'weapon_unlic',
}
r = Sentencing.Calculate(topTen, 5)
T.eq('worst realistic sheet: fine', r.fine, 198500)
T.lt('worst realistic sheet stays under MaxFine', r.fine, CH.MaxFine)
T.eq('worst realistic sheet: sentence is the ceiling', r.sentence, 120)
T.istrue('and it says the ceiling flattens the sheet', r.capped)
T.contains('ceiling warning is printed', table.concat(r.breakdown, '\n'),
    'extra charges and priors no longer change the time')

-- ---------------------------------------------------------------------------
T.section('failure result shape matches the success result shape')
local f = Sentencing.Failure('because')
local s = Sentencing.Calculate({ 'gta' }, 0)
local missing = {}
for k in pairs(f) do
    -- `reason` is documented as string|nil and is deliberately absent on the
    -- success path, so it is the one field that may differ.
    if k ~= 'reason' and s[k] == nil then missing[#missing + 1] = k end
end
table.sort(missing)
T.list('every failure field also exists on a success', missing, {})
T.isnil('a successful result carries no reason', s.reason)
T.eq('failure carries its reason', f.reason, 'because')
T.isfalse('failure is not ok', f.ok)

-- ---------------------------------------------------------------------------
T.section('free-text scanning is literal, and says so')
local found = Sentencing.CodesInText('assault on a peace officer during a bank robbery')
T.list('prose finds only the single-word charge', found, { 'assault' })
-- The tokenizer is [%w_]+, so `leo_assault` is ONE token and does not also
-- register as a bare `assault`. That is the correct behaviour and it is pinned
-- here because the opposite would silently add a charge nobody typed.
T.list('the underscore form matches only itself', Sentencing.CodesInText('leo_assault bank_robbery'),
    { 'leo_assault', 'bank_robbery' })
T.list('empty text finds nothing', Sentencing.CodesInText(''), {})
T.list('nil text finds nothing', Sentencing.CodesInText(nil), {})
local compound = Sentencing.CompoundCodes()
T.eq('compound codes are the severe ones', #compound, 9)
T.eq('compound list is sorted', compound[1], 'bank_robbery')

-- Order independence of the scan: the same codes in a different order in the
-- prose must produce the same list, because the output follows catalogue order.
T.list('scan output follows catalogue order, not prose order',
    Sentencing.CodesInText('murder_1 trespass gta'), { 'trespass', 'gta', 'murder_1' })

T.done()
