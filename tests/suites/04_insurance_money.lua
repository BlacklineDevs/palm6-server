-- ============================================================================
-- palm6_insurance premium / coverage / deductible and claim assessment.
--
-- This is the money arithmetic behind Mors Mutual: what a policy costs, what it
-- covers, and what a claim pays. It ships LIVE (no Config flag guards it), so
-- unlike the two suites above these numbers are in players' hands today.
--
-- quoteFor() is the shared quote-and-charge function: doInsure and the /quote
-- display both call it, which is what stops a quote disagreeing with the charge.
-- It is a `local function` inside server/main.lua and is lifted out by anchor.
--
-- The CLAIM assessment is not a function at all. It is a set of assignments
-- interleaved with Bridge calls, notifications and early returns inside
-- doClaim, so the individual money LINES are lifted by anchor and composed here
-- in production order. Every arithmetic line under test is production text; the
-- composition is the test's, and it is asserted against the source order below.
--
-- NOT TESTED HERE: scoreClaim (three MySQL reads plus a resource-state check),
-- clampedValue (Bridge.GetVehicleValue), the total-loss vehicle consumption,
-- the payout release sweep and creditClaim's idempotency. README lists them.
-- ============================================================================
T.begin('palm6_insurance premiums, coverage and claim payouts')

local INS = 'resources/[custom]/palm6_insurance/'
local MAIN = INS .. 'server/main.lua'
T.loadFile(INS .. 'shared/config.lua')

local U = Config.Underwriting
local C = Config.Claims

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.eq('MinValue', U.MinValue, 5000)
T.eq('MaxValue', U.MaxValue, 300000)
T.eq('MinPremium', U.MinPremium, 250)
T.near('basic premium rate', Config.Tiers.basic.PremiumPct, 0.03)
T.near('standard premium rate', Config.Tiers.standard.PremiumPct, 0.05)
T.near('premium premium rate', Config.Tiers.premium.PremiumPct, 0.08)
T.near('MinDamageFrac', C.MinDamageFrac, 0.25)
T.near('TotalLossFrac', C.TotalLossFrac, 0.85)
T.near('DamageRepairPct', C.DamageRepairPct, 0.12)
T.eq('DamageMaxPayout', C.DamageMaxPayout, 15000)
T.near('DamageOwnerSharePct', C.DamageOwnerSharePct, 0.20)
T.near('DamagePayoutVsPremiumPct', C.DamagePayoutVsPremiumPct, 0.80)
T.lt('the damage payout ceiling is below the premium paid',
    C.DamagePayoutVsPremiumPct, 1.0)

-- Tiers must be monotonic in every direction they claim to be, or the plan
-- ladder sells a worse product for more money at some value.
local b, s, p = Config.Tiers.basic, Config.Tiers.standard, Config.Tiers.premium
T.lt('premium rate rises basic -> standard', b.PremiumPct, s.PremiumPct)
T.lt('premium rate rises standard -> premium', s.PremiumPct, p.PremiumPct)
T.lt('coverage rises basic -> standard', b.CoveragePct, s.CoveragePct)
T.lt('coverage rises standard -> premium', s.CoveragePct, p.CoveragePct)
T.lt('deductible falls standard -> basic', s.DeductibleP, b.DeductibleP)
T.lt('deductible falls premium -> standard', p.DeductibleP, s.DeductibleP)
T.lt('processing gets faster standard -> premium', p.ProcessingSec, s.ProcessingSec)
T.lt('term gets longer basic -> standard', b.TermHours, s.TermHours)

-- ---------------------------------------------------------------------------
-- Lift quoteFor.
-- ---------------------------------------------------------------------------
local quoteBlock = T.slice(MAIN,
    'local function quoteFor(value, tier)',
    'local function doInsure(src, plate, tierKey)')
T.contains('quote slice really contains quoteFor', quoteBlock, 'local function quoteFor')
T.notcontains('quote slice pulled in no MySQL', quoteBlock, 'MySQL')
T.notcontains('quote slice pulled in no Bridge call', quoteBlock, 'Bridge.')
T.notcontains('quote slice pulled in no notify', quoteBlock, 'Notify')
local quoteFor = T.chunk('palm6_insurance quoteFor', quoteBlock .. '\nreturn quoteFor\n')()

-- ---------------------------------------------------------------------------
T.section('quotes at the shipped rates')
local function q(value, tierKey)
    local prem, cov, ded = quoteFor(value, Config.Tiers[tierKey])
    return prem, cov, ded
end

local prem, cov, ded = q(100000, 'standard')
T.eq('standard on a $100k car: premium', prem, 5000)
T.eq('standard on a $100k car: coverage', cov, 60000)
T.eq('standard on a $100k car: deductible', ded, 6000)

prem, cov, ded = q(100000, 'basic')
T.eq('basic on a $100k car: premium', prem, 3000)
T.eq('basic on a $100k car: coverage', cov, 40000)
T.eq('basic on a $100k car: deductible', ded, 6000)

prem, cov, ded = q(100000, 'premium')
T.eq('premium on a $100k car: premium', prem, 8000)
T.eq('premium on a $100k car: coverage', cov, 85000)
T.eq('premium on a $100k car: deductible', ded, 4250)

-- The band edges. These are the only two values clampedValue can ever produce
-- outside the catalogue range, so they are the ones worth pinning.
prem, cov, ded = q(U.MinValue, 'basic')
T.eq('at MinValue the premium floor bites', prem, U.MinPremium)
T.eq('at MinValue basic coverage', cov, 2000)
T.eq('at MinValue basic deductible', ded, 300)

prem, cov, ded = q(U.MaxValue, 'premium')
T.eq('at MaxValue premium tier: premium', prem, 24000)
T.eq('at MaxValue premium tier: coverage', cov, 255000)
T.eq('at MaxValue premium tier: deductible', ded, 12750)

-- Truncation is real money: 0.6 of $8,333 is $4,999.80 and the policy issues
-- $4,999 of cover. Pinned so a future change to floor/round is deliberate.
prem, cov, ded = q(8333, 'standard')
T.eq('fractional coverage truncates down', cov, 4999)
T.eq('fractional premium truncates down', prem, 416)
T.eq('fractional deductible truncates down', ded, 499)

-- Edge inputs. quoteFor is only ever called with clampedValue's output today,
-- so these describe what would happen if that ever stopped being true.
prem, cov, ded = q(0, 'standard')
T.eq('a zero value still charges the minimum premium', prem, U.MinPremium)
T.eq('a zero value covers nothing', cov, 0)
T.eq('a zero value has no deductible', ded, 0)
-- A policy that costs $250 and covers $0 is a pure loss. clampedValue makes it
-- unreachable, which is exactly why the floor lives there and not here.
T.lt('which would be a pure loss if it were reachable', cov, prem)

-- ---------------------------------------------------------------------------
T.section('quote invariants across the whole underwritable band')
local badDeductible, badCoverage, badPremium, unbuyable = {}, {}, {}, {}
for _, tk in ipairs(Config.TierOrder) do
    local tier = Config.Tiers[tk]
    for value = U.MinValue, U.MaxValue, 2500 do
        local pr, cv, dd = quoteFor(value, tier)
        if dd > cv then badDeductible[#badDeductible + 1] = tk .. '@' .. value end
        if cv > value then badCoverage[#badCoverage + 1] = tk .. '@' .. value end
        if pr < U.MinPremium then badPremium[#badPremium + 1] = tk .. '@' .. value end
        -- Buying cover must be worth it: the most a theft claim can pay has to
        -- beat what the policy cost, or the product is a trap at that price.
        local theftPayout = math.floor(cv * tier.TheftPayoutPct) - dd
        if theftPayout <= pr then unbuyable[#unbuyable + 1] = tk .. '@' .. value end
    end
end
T.list('a deductible never exceeds the coverage it applies to', badDeductible, {})
T.list('coverage never exceeds the vehicle value', badCoverage, {})
T.list('the premium floor is never breached', badPremium, {})
T.list('a theft payout always beats the premium paid, at every tier and value',
    unbuyable, {})

-- Same quote, same answer, every time: quoteFor is called separately by the
-- display path and the charge path, so a disagreement between two calls would
-- be a player charged something other than what they were shown.
local p1, c1, d1 = q(77777, 'premium')
local p2, c2, d2 = q(77777, 'premium')
T.eq('repeat quote: premium', p2, p1)
T.eq('repeat quote: coverage', c2, c1)
T.eq('repeat quote: deductible', d2, d1)

-- ---------------------------------------------------------------------------
-- Lift the claim assessment lines. Each is a single unique production line (or
-- a short slice), composed here in the order doClaim runs them.
-- ---------------------------------------------------------------------------
T.section('claim assessment lines are lifted from production, in production order')
local theftLine = T.line(MAIN, 'assessed = math.floor(coverage * tier.TheftPayoutPct) - deductible')
local totalLine = T.line(MAIN, 'assessed = math.floor(coverage * frac) - deductible')
local valueLine = T.line(MAIN, 'local value = tonumber(policy.vehicle_value) or 0')
local repairSlice = T.slice(MAIN,
    'local repairBill = math.min(',
    'assessed = repairBill - math.floor(repairBill')
local ownerLine = T.line(MAIN, 'assessed = repairBill - math.floor(repairBill * Config.Claims.DamageOwnerSharePct)')
local premCapLine = T.line(MAIN, 'local premCap = math.floor((tonumber(policy.premium_paid) or 0) * Config.Claims.DamagePayoutVsPremiumPct)')
local premClampLine = T.line(MAIN, 'if assessed > premCap then assessed = premCap end')
local coverClampLine = T.line(MAIN, 'if assessed > coverage then assessed = coverage end')

T.contains('theft line uses the tier theft percentage', theftLine, 'TheftPayoutPct')
T.contains('total-loss line scales by damage fraction', totalLine, 'coverage * frac')
T.contains('repair bill is capped absolutely', repairSlice, 'DamageMaxPayout')
T.contains('the owner pays a share', ownerLine, 'DamageOwnerSharePct')
T.contains('the payout is capped against the premium paid', premCapLine, 'DamagePayoutVsPremiumPct')

-- Order check: the coverage clamp must come after every branch, or a branch
-- could pay out more than the policy covers.
local src = T.source(MAIN)
local theftAt = src:find('assessed = math.floor(coverage * tier.TheftPayoutPct)', 1, true)
local totalAt = src:find('assessed = math.floor(coverage * frac)', 1, true)
local premAt = src:find('if assessed > premCap then', 1, true)
local coverAt = src:find('if assessed > coverage then', 1, true)
T.lt('the theft branch runs before the coverage clamp', theftAt, coverAt)
T.lt('the total-loss branch runs before the coverage clamp', totalAt, coverAt)
T.lt('the premium cap runs before the coverage clamp', premAt, coverAt)

local theftAssessed = T.chunk('theft assessment',
    'return function(coverage, deductible, tier)\n  local assessed\n  '
    .. theftLine .. '\n  ' .. coverClampLine .. '\n  return assessed\nend')()
local totalAssessed = T.chunk('total-loss assessment',
    'return function(coverage, deductible, frac)\n  local assessed\n  '
    .. totalLine .. '\n  ' .. coverClampLine .. '\n  return assessed\nend')()
local damageAssessed = T.chunk('damage assessment',
    'return function(policy, frac, coverage)\n  local assessed\n  '
    .. valueLine .. '\n' .. repairSlice .. '\n' .. ownerLine .. '\n'
    .. premCapLine .. '\n' .. premClampLine .. '\n  ' .. coverClampLine
    .. '\n  return assessed\nend')()

-- ---------------------------------------------------------------------------
T.section('theft claims')
T.eq('standard, $100k car: full coverage less the deductible',
    theftAssessed(60000, 6000, Config.Tiers.standard), 54000)
T.eq('basic pays only 70% of coverage',
    theftAssessed(40000, 6000, Config.Tiers.basic), 22000)
T.eq('premium pays full coverage',
    theftAssessed(85000, 4250, Config.Tiers.premium), 80750)
T.eq('a deductible larger than the payout goes negative and is refused upstream',
    theftAssessed(1000, 5000, Config.Tiers.standard), -4000)
T.eq('a zero-coverage policy pays nothing',
    theftAssessed(0, 0, Config.Tiers.standard), 0)

-- ---------------------------------------------------------------------------
T.section('total-loss claims')
T.eq('at exactly the total-loss threshold (0.85)',
    totalAssessed(60000, 6000, C.TotalLossFrac), 45000)
T.eq('at complete destruction (1.0)', totalAssessed(60000, 6000, 1.0), 54000)
T.eq('at 0.9', totalAssessed(60000, 6000, 0.9), 48000)
T.lt('a more damaged car pays more',
    totalAssessed(60000, 6000, 0.85), totalAssessed(60000, 6000, 1.0))
-- The coverage clamp is the backstop if a damage fraction above 1.0 ever
-- reached this line. Bridge.GetVehicleDamageFrac is documented as 0..1, so this
-- is defence in depth rather than a reachable case.
T.eq('a damage fraction above 1.0 is clamped to the coverage',
    totalAssessed(60000, 6000, 2.0), 60000)

-- ---------------------------------------------------------------------------
T.section('repairable damage claims: self-inflicting must never pay')
-- The claim is a repair SUBSIDY, capped at DamagePayoutVsPremiumPct of the
-- premium the owner already paid, because they keep the car.
local pol = { vehicle_value = 100000, premium_paid = 5000 }
T.eq('a half-wrecked $100k car on a standard policy',
    damageAssessed(pol, 0.5, 60000), 4000)
T.lt('which is less than the premium that bought the policy',
    damageAssessed(pol, 0.5, 60000), pol.premium_paid)

-- The absolute repair-bill cap. A $300k car at 84% damage would compute a
-- $30,240 repair bill; DamageMaxPayout holds it at $15,000 before the owner
-- share and the premium cap are applied.
local rich = { vehicle_value = 300000, premium_paid = 24000 }
T.eq('the repair bill cap binds on an expensive car',
    damageAssessed(rich, 0.84, 255000), 12000)
T.lt('still under the premium paid', damageAssessed(rich, 0.84, 255000), rich.premium_paid)

-- The cheapest possible policy: the premium cap is what binds.
local cheap = { vehicle_value = 5000, premium_paid = 250 }
T.eq('a cheap policy pays at most 80% of its own premium',
    damageAssessed(cheap, 1.0, 3000), 200)

-- THE INVARIANT THAT MATTERS. Ram your own car, claim, and you must always be
-- down money. Swept across the whole value band, all three tiers, and every
-- claimable damage fraction.
local profitable = {}
for _, tk in ipairs(Config.TierOrder) do
    local tier = Config.Tiers[tk]
    for value = U.MinValue, U.MaxValue, 5000 do
        local pr, cv = quoteFor(value, tier)
        local policy = { vehicle_value = value, premium_paid = pr }
        local f = C.MinDamageFrac
        while f < C.TotalLossFrac do
            local payout = damageAssessed(policy, f, cv)
            if payout >= pr then
                profitable[#profitable + 1] = ('%s@%d frac %.2f pays %d for %d'):format(tk, value, f, payout, pr)
            end
            f = f + 0.05
        end
    end
end
T.list('a repairable-damage claim never pays back the premium, at any tier, value or damage level',
    profitable, {})

-- And it never exceeds the coverage cap either.
local overCover = {}
for _, tk in ipairs(Config.TierOrder) do
    local tier = Config.Tiers[tk]
    for value = U.MinValue, U.MaxValue, 5000 do
        local pr, cv = quoteFor(value, tier)
        local policy = { vehicle_value = value, premium_paid = pr }
        if damageAssessed(policy, 0.84, cv) > cv then
            overCover[#overCover + 1] = tk .. '@' .. value
        end
    end
end
T.list('a damage payout never exceeds the coverage', overCover, {})

-- Monotonic in damage: more damage must never pay LESS, or a player is
-- rewarded for repairing before claiming.
local nonMonotonic = {}
local mono = { vehicle_value = 200000, premium_paid = 10000 }
local prevPay = -1
local f = C.MinDamageFrac
while f < C.TotalLossFrac do
    local pay = damageAssessed(mono, f, 120000)
    if pay < prevPay then nonMonotonic[#nonMonotonic + 1] = ('%.2f'):format(f) end
    prevPay = pay
    f = f + 0.01
end
T.list('the damage payout never decreases as damage rises', nonMonotonic, {})

-- The claim floor and the total-loss threshold must not overlap or invert.
T.lt('the claim floor is below the total-loss threshold', C.MinDamageFrac, C.TotalLossFrac)
T.lt('and the total-loss threshold is below complete destruction', C.TotalLossFrac, 1.0)

T.done()
