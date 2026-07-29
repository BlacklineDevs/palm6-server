-- ============================================================================
-- palm6_bounty HEAT PREMIUM: the one place on this server where durable heat
-- MINTS money instead of taking it away.
--
-- The three other heat consequences (drugs street price, drugs bust, chopshop
-- payout) can only ever subtract. This one adds: a state contract is CITY
-- FUNDED, /capture pays it from nowhere with no escrow and no debit, so every
-- dollar of premium is a new dollar. That makes the CEILING the number that
-- matters, and the ceiling is not the premium cap on its own: /capture
-- multiplies the stored amount by palm6_pulse's "bounty" window modifier at
-- payout time, so the real worst-case mint is (state cap + premium cap) x the
-- pulse ceiling.
--
-- Config.State.HeatBonus's comment sizes that faucet in dollars. An earlier
-- review found an ARITHMETIC ERROR in that sizing, so this suite does not trust
-- the comment: it recomputes every figure from the shipped config of BOTH
-- resources and then asserts the comment's own text contains the recomputed
-- numbers. If anybody retunes Cap, PerTier, MaxModifier or the Bounty Surge
-- modifier without updating the prose, these assertions fail.
--
-- The premium ships DISABLED. The pulse multiplier does not.
--
-- NOT TESTED HERE: syncState's warrant SELECT and the guarded UPDATE/INSERT,
-- cmdCapture's proximity/health gates and the claimSettled race, the boot
-- reconcile, and the private-contract escrow round-trips. README lists them.
-- ============================================================================
T.begin('palm6_bounty heat premium and the bounded faucet')

local BOUNTY = 'resources/[custom]/palm6_bounty/'
local MAIN   = BOUNTY .. 'server/main.lua'
local PULSE  = 'resources/[custom]/palm6_pulse/'
local PULSEMAIN = PULSE .. 'server/main.lua'

T.loadFile('resources/[custom]/palm6_heat/shared/config.lua')
local heatConfig = Config
local HEAT_TIERS, HEAT_TIER_SET = {}, {}
for _, t in ipairs(heatConfig.Tiers) do
    HEAT_TIERS[#HEAT_TIERS + 1] = t.tier
    HEAT_TIER_SET[t.tier] = true
end

T.loadFile(PULSE .. 'shared/config.lua')
local pulseConfig = Config
Config = nil

T.loadFile(BOUNTY .. 'shared/config.lua')
local S  = Config.State
local HB = S.HeatBonus

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the heat premium still ships dark', HB.Enabled)
T.eq('the flat reward for one active warrant', S.BaseAmount, 500)
T.eq('extra per warrant beyond the first', S.PerWarrantExtra, 250)
T.eq('the warrant-count ceiling', S.Cap, 5000)
T.eq('WARM adds nothing', HB.PerTier.WARM, 0)
T.eq('HOT adds $400', HB.PerTier.HOT, 400)
T.eq('WANTED adds $1,200', HB.PerTier.WANTED, 1200)
T.eq('the premium ceiling', HB.Cap, 1200)
T.near('palm6_pulse hard ceiling on any published multiplier', pulseConfig.MaxModifier, 2.0)
T.near('the shipped Bounty Surge modifier', pulseConfig.Windows.bounty_surge.modifier, 1.75)
T.eq('and Bounty Surge publishes on the domain palm6_bounty reads',
    pulseConfig.Windows.bounty_surge.domain, 'bounty')

local unknownKeys = {}
for tier in pairs(HB.PerTier) do
    if not HEAT_TIER_SET[tier] then unknownKeys[#unknownKeys + 1] = tier end
end
T.list('every PerTier key is a real palm6_heat tier name', unknownKeys, {})

local negative = {}
for tier, v in pairs(HB.PerTier) do
    if v < 0 then negative[#negative + 1] = tier end
end
T.list('no shipped premium is negative', negative, {})

-- ---------------------------------------------------------------------------
-- Lift heatPremium and stateReason, with the two cross-resource calls stubbed.
-- ---------------------------------------------------------------------------
local premBlock = T.slice(MAIN, 'local function heatPremium(cid)',
    '-- The board line for a state contract.')
local reasonBlock = T.slice(MAIN, 'local function stateReason(bonus, tier)',
    '-- /postbounty <citizenid> <amount> <reason...>')
T.contains('slice really contains heatPremium', premBlock, 'local function heatPremium(cid)')
T.contains('slice reads the tier only through the frozen export', premBlock, 'exports.palm6_heat:GetTier(cid)')
T.contains('slice floors the premium at zero', premBlock, 'if bonus < 0 then bonus = 0 end')
T.contains('slice caps the premium', premBlock, 'if bonus > cap then bonus = cap end')
T.notcontains('slice pulled in no MySQL', premBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', premBlock, 'Bridge.')
T.notcontains('slice never queries palm6_heat_state directly', premBlock, 'palm6_heat_state')

local buildPremium = T.chunk('palm6_bounty heatPremium', table.concat({
    'local Config, stateFn, tierFn, bump = ...',
    'local GetResourceState = function(res) return stateFn(res) end',
    'local exports = { palm6_heat = { GetTier = function(_, cid) bump() ; return tierFn(cid) end } }',
    premBlock,
    reasonBlock,
    'return heatPremium, stateReason',
}, '\n'))

local exportReads = 0
local function mk(tier, state)
    return buildPremium(Config, function() return state or 'started' end,
        function() if type(tier) == 'function' then return tier() end return tier end,
        function() exportReads = exportReads + 1 end)
end
local function bonusOf(tier, state) return (mk(tier, state)('BNT00001')) end
local function tierOfCall(tier, state) return select(2, mk(tier, state)('BNT00001')) end

-- ---------------------------------------------------------------------------
T.section('flag off: no export call, and a zero premium')
exportReads = 0
local offBad = {}
for _, tier in ipairs(HEAT_TIERS) do
    local b, t = mk(tier)('BNT00001')
    if b ~= 0 or t ~= nil then offBad[#offBad + 1] = tier end
end
T.list('with the flag off every tier returns exactly (0, nil)', offBad, {})
T.eq('and palm6_heat was never asked, so the sweep costs no extra round-trip',
    exportReads, 0)

-- ---------------------------------------------------------------------------
T.section('flag on: the premium each tier actually earns')
S.HeatBonus.Enabled = true
T.eq('CLEAN is absent from the table: no premium', bonusOf('CLEAN'), 0)
T.eq('COOL is absent from the table: no premium', bonusOf('COOL'), 0)
T.eq('WARM is present but worth nothing', bonusOf('WARM'), 0)
T.eq('HOT is worth $400 on your head', bonusOf('HOT'), 400)
T.eq('WANTED is worth $1,200 on your head', bonusOf('WANTED'), 1200)
T.eq('the tier is reported alongside the premium', tierOfCall('WANTED'), 'WANTED')

-- ---------------------------------------------------------------------------
T.section('every soft-guard failure mode lands on the warrant-count amount')
exportReads = 0
T.eq('palm6_heat stopped: no premium', bonusOf('WANTED', 'stopped'), 0)
T.isnil('and no tier is reported', tierOfCall('WANTED', 'stopped'))
T.eq('a non-started palm6_heat is never even asked', exportReads, 0)
T.eq('the export throwing: no premium', bonusOf(function() error('down') end), 0)
T.eq('the export returning nil: no premium', bonusOf(nil), 0)
T.eq('the export returning a number: no premium', bonusOf(99), 0)
T.eq('an unknown tier string: no premium', bonusOf('FRIGID'), 0)
local f = mk('WANTED')
T.eq('a nil citizenid is refused', (f(nil)), 0)
T.eq('an empty citizenid is refused', (f('')), 0)

-- ---------------------------------------------------------------------------
T.section('the premium is bounded: never negative, never above its own Cap')
S.HeatBonus.PerTier.WANTED = -900
T.eq('a negative premium is floored to zero', bonusOf('WANTED'), 0)
S.HeatBonus.PerTier.WANTED = 99999
T.eq('an oversized premium is capped', bonusOf('WANTED'), 1200)
S.HeatBonus.PerTier.WANTED = math.huge
T.eq('an infinite premium is capped', bonusOf('WANTED'), 1200)
S.HeatBonus.PerTier.WANTED = 1200.9
T.eq('a fractional premium is floored to whole dollars', bonusOf('WANTED'), 1200)
S.HeatBonus.PerTier.WANTED = 400.9
T.eq('and floored, not rounded', bonusOf('WANTED'), 400)
S.HeatBonus.PerTier.WANTED = '750'
T.eq('a stringified number is coerced, not rejected', bonusOf('WANTED'), 750)
S.HeatBonus.PerTier.WANTED = {}
T.eq('a table is unreadable and pays nothing', bonusOf('WANTED'), 0)

S.HeatBonus.PerTier.WANTED = 5000
S.HeatBonus.Cap = -50
T.eq('a negative Cap is itself floored to zero, which zeroes the premium',
    bonusOf('WANTED'), 0)
S.HeatBonus.Cap = nil
T.eq('a deleted Cap reads as zero, so the premium collapses to nothing rather than to infinity',
    bonusOf('WANTED'), 0)
S.HeatBonus.Cap = 1200
S.HeatBonus.PerTier.WANTED = 1200   -- restore the shipped value
T.eq('the shipped WANTED premium is restored', bonusOf('WANTED'), 1200)

-- Swept: at every heat value on the ladder the premium stays inside [0, Cap]
-- and never falls as heat rises.
local heatPure = T.slice('resources/[custom]/palm6_heat/server/main.lua',
    'local function decayed(storedHeat, ageSec)', '-- Boot: self-create the table.')
local tierOfRow = T.chunk('palm6_heat tierOf',
    'local Config = ...\n' .. heatPure .. '\nreturn tierOf\n')(heatConfig)
local outOfBand, fell, prev = {}, {}, nil
for heat = 0, heatConfig.HeatCap do
    local b = bonusOf(tierOfRow(heat).tier)
    if b < 0 or b > HB.Cap then outOfBand[#outOfBand + 1] = ('%d'):format(heat) end
    if prev ~= nil and b < prev then fell[#fell + 1] = ('%d'):format(heat) end
    prev = b
end
T.list('the premium is inside [0, Cap] at every heat value', outOfBand, {})
T.list('and getting hotter never lowers the price on your head', fell, {})

-- Boundaries from both sides.
local function bonusAt(heat) return bonusOf(tierOfRow(heat).tier) end
T.eq('29 heat is the last COOL point', bonusAt(29), 0)
T.eq('30 heat is the first WARM point', bonusAt(30), 0)
T.eq('64 heat is the last WARM point', bonusAt(64), 0)
T.eq('65 heat is the first HOT point: the premium starts', bonusAt(65), 400)
T.eq('109 heat is the last HOT point', bonusAt(109), 400)
T.eq('110 heat is the first WANTED point', bonusAt(110), 1200)
T.eq('at the heat cap the premium is still WANTED', bonusAt(heatConfig.HeatCap), 1200)

-- ---------------------------------------------------------------------------
T.section('the board line names the tier, so the price never moves in silence')
local _, stateReason = mk('WANTED')
T.eq('with no premium the reason is the exact literal the INSERT always wrote',
    stateReason(0, nil), 'Active warrant(s) on file')
T.eq('a zero premium at a real tier still prints the plain literal',
    stateReason(0, 'WARM'), 'Active warrant(s) on file')
T.eq('a real premium names the tier that caused it',
    stateReason(1200, 'WANTED'), 'Active warrant(s) on file · WANTED heat')
T.eq('a premium with an unreadable tier falls back to the plain literal',
    stateReason(400, nil), 'Active warrant(s) on file')

-- ---------------------------------------------------------------------------
-- Lift the amount ladder and the premium addition, in production order.
-- ---------------------------------------------------------------------------
T.section('the warrant-count ladder')
local amountLine = T.line(MAIN,
    'local amount = math.min(S.Cap, S.BaseAmount + S.PerWarrantExtra * math.max(0, n - 1))')
local postedLine = T.line(MAIN, 'local posted = amount + bonus')
local amountFor = T.chunk('palm6_bounty warrant ladder',
    'local S = ...\nreturn function(n)\n' .. amountLine .. '\nreturn amount\nend\n')(S)
local postedFor = T.chunk('palm6_bounty posted amount',
    'return function(amount, bonus)\n' .. postedLine .. '\nreturn posted\nend\n')()

T.eq('one warrant is the flat base', amountFor(1), 500)
T.eq('two warrants', amountFor(2), 750)
T.eq('three warrants', amountFor(3), 1000)
T.eq('eighteen warrants is $4,750', amountFor(18), 4750)
T.eq('nineteen warrants is exactly the cap', amountFor(19), 5000)
T.eq('twenty warrants is still the cap', amountFor(20), 5000)
T.eq('a thousand warrants is still the cap', amountFor(1000), 5000)
-- The SELECT is a COUNT(*) over live rows so n >= 1, but the max(0, n-1) guard
-- means a zero or negative count degrades to the base rather than going under it.
T.eq('a zero count degrades to the base, never below it', amountFor(0), 500)
T.eq('a negative count degrades to the base too', amountFor(-5), 500)

local underBase, overCap = {}, {}
for n = -5, 100 do
    local a = amountFor(n)
    if a < S.BaseAmount then underBase[#underBase + 1] = ('%d'):format(n) end
    if a > S.Cap then overCap[#overCap + 1] = ('%d'):format(n) end
end
T.list('no warrant count pays below the base', underBase, {})
T.list('no warrant count pays above the cap', overCap, {})

-- ---------------------------------------------------------------------------
T.section('the STORED amount ceiling: the ladder cap plus the premium cap')
T.eq('the most a state contract can ever store', postedFor(S.Cap, HB.Cap), 6200)
-- `posted` is deliberately NOT re-clamped to S.Cap; the premium rides on top.
-- That is the design (the premium is additive to an amount the warrant table
-- already justified), and it is why the faucet must be sized off 6200 and not
-- off 5000.
T.lt('which is strictly above the warrant-count cap on its own', S.Cap, 6200)

local storedOver = {}
for n = 1, 40 do
    for _, tier in ipairs(HEAT_TIERS) do
        local p = postedFor(amountFor(n), bonusOf(tier))
        if p > S.Cap + HB.Cap then
            storedOver[#storedOver + 1] = ('%d warrants @ %s'):format(n, tier)
        end
    end
end
T.list('no warrant count at any tier can store more than Cap + HeatBonus.Cap',
    storedOver, {})

-- ---------------------------------------------------------------------------
T.section('the PAYOUT ceiling: the pulse modifier on top')
-- palm6_pulse's own clamp, lifted from its frozen export so the ceiling under
-- test is the ceiling that ships.
local pulseClamp = T.line(PULSEMAIN, 'return math.min(Config.MaxModifier, w.modifier or 1.0)')
local clampFor = T.chunk('palm6_pulse modifier clamp',
    'local Config = ...\nreturn function(w)\n' .. pulseClamp .. '\nend\n')(pulseConfig)
T.near('the shipped Bounty Surge publishes 1.75',
    clampFor(pulseConfig.Windows.bounty_surge), 1.75)
T.near('a window configured above the ceiling is clamped to 2.0',
    clampFor({ modifier = 9.0 }), 2.0)
T.near('a window with no modifier publishes a no-op 1.0', clampFor({}), 1.0)

-- /capture's payout line, lifted verbatim.
local mintLine = T.line(MAIN, "if type(m) == 'number' and m > 1 then amount = math.floor(amount * m) end")
local mintFor = T.chunk('palm6_bounty capture payout',
    'return function(amount, m)\n' .. mintLine .. '\nreturn amount\nend\n')()

T.eq('with no window open the payout is the stored amount', mintFor(6200, 1.0), 6200)
T.eq('a modifier of exactly 1 is a no-op, not a multiply', mintFor(6200, 1), 6200)
T.eq('a modifier below 1 can never SHRINK a payout', mintFor(6200, 0.5), 6200)
T.eq('a nil modifier is ignored', mintFor(6200, nil), 6200)
T.eq('a stringified modifier is ignored (the type guard is strict)', mintFor(6200, '1.75'), 6200)

-- THE FOUR NUMBERS. Every one recomputed from the two resources' shipped
-- config, never copied out of the comment.
local ceilingStored  = postedFor(S.Cap, HB.Cap)                    -- 6200
local shippedWithHeat = mintFor(ceilingStored, clampFor(pulseConfig.Windows.bounty_surge))
local ceilingWithHeat = mintFor(ceilingStored, clampFor({ modifier = math.huge }))
local shippedNoHeat   = mintFor(S.Cap, clampFor(pulseConfig.Windows.bounty_surge))
local ceilingNoHeat   = mintFor(S.Cap, clampFor({ modifier = math.huge }))

T.eq('worst-case single mint in a shipped Bounty Surge, premium ON', shippedWithHeat, 10850)
T.eq('worst-case single mint at the structural pulse ceiling, premium ON', ceilingWithHeat, 12400)
T.eq('the same two numbers with the premium OFF, shipped surge', shippedNoHeat, 8750)
T.eq('the same two numbers with the premium OFF, structural ceiling', ceilingNoHeat, 10000)
T.eq('so flipping the flag raises the shipped worst case by $2,100',
    shippedWithHeat - shippedNoHeat, 2100)
T.eq('and the structural worst case by $2,400', ceilingWithHeat - ceilingNoHeat, 2400)
-- The trap the earlier review caught: the premium cap is $1,200, but the mint
-- it unlocks is nearly TWICE that, because the pulse multiplier lands on top.
T.lt('the real increase is strictly larger than the premium cap itself',
    HB.Cap, shippedWithHeat - shippedNoHeat)
T.eq('by a factor of exactly the shipped surge modifier',
    shippedWithHeat - shippedNoHeat, math.floor(HB.Cap * 1.75))

-- ---------------------------------------------------------------------------
T.section('the config comment states these numbers, and must keep stating them')
-- The comment is prose about money, so it is pinned to the arithmetic. If Cap,
-- PerTier, MaxModifier or the surge modifier is retuned without updating the
-- prose, these fail.
local function comma(n)
    local s = tostring(n)
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end
T.eq('the comma helper is right', comma(10850), '10,850')

local cfgSrc = T.source(BOUNTY .. 'shared/config.lua')
local commentStart = cfgSrc:find('SIZING THE FAUCET', 1, true)
local commentEnd = cfgSrc:find('Cap     = 1200', 1, true)
T.lt('the sizing comment sits directly above the Cap it sizes', commentStart, commentEnd)
local sizing = cfgSrc:sub(commentStart, commentEnd)

T.contains('the comment states the stored ceiling', sizing, tostring(ceilingStored))
T.contains('the comment states the shipped worst-case mint', sizing, '$' .. comma(shippedWithHeat))
T.contains('the comment states the structural worst-case mint', sizing, '$' .. comma(ceilingWithHeat))
T.contains('the comment states the shipped figure with the premium off', sizing, '$' .. comma(shippedNoHeat))
T.contains('the comment states the structural figure with the premium off', sizing, '$' .. comma(ceilingNoHeat))
T.contains('the comment states the shipped increase', sizing, '$' .. comma(shippedWithHeat - shippedNoHeat))
T.contains('the comment states the structural increase', sizing, '$' .. comma(ceilingWithHeat - ceilingNoHeat))
T.contains('and warns against reading the premium cap as the increase',
    sizing, 'not by $' .. comma(HB.Cap))
T.contains('the comment quotes the real shipped surge modifier', sizing,
    tostring(pulseConfig.Windows.bounty_surge.modifier))
T.contains('the comment quotes the real pulse ceiling', sizing,
    'Config.MaxModifier = ' .. tostring(pulseConfig.MaxModifier))
T.contains('and says to size the faucet off the biggest of them', sizing,
    'off $' .. comma(ceilingWithHeat))

-- ---------------------------------------------------------------------------
T.section('private contracts: the cancel fee cannot mint or lose a dollar')
-- Not heat-related, but it is untested money arithmetic in the same file: a
-- refund that did not sum back to the escrow would be a faucet or a sink.
local feeLine    = T.line(MAIN, 'local fee = math.floor(amount * Config.Private.CancelFeePct)')
local refundLine = T.line(MAIN, 'local refund = amount - fee')
local cancelFor = T.chunk('palm6_bounty cancel refund',
    'local Config = ...\nreturn function(amount)\n' .. feeLine .. '\n' .. refundLine
    .. '\nreturn refund, fee\nend\n')(Config)

local P = Config.Private
T.near('the cancel fee percentage', P.CancelFeePct, 0.10)
T.eq('the minimum private contract', P.MinAmount, 100)
T.eq('the maximum private contract', P.MaxAmount, 10000)

local r, fe = cancelFor(1000)
T.eq('a $1,000 contract refunds $900', r, 900)
T.eq('and the board keeps $100', fe, 100)

local unbalanced, negativeFee, freeCancel = {}, {}, {}
for amount = P.MinAmount, P.MaxAmount do
    local refund, fee = cancelFor(amount)
    if refund + fee ~= amount then unbalanced[#unbalanced + 1] = ('%d'):format(amount) end
    if fee < 0 or refund < 0 then negativeFee[#negativeFee + 1] = ('%d'):format(amount) end
    if fee == 0 then freeCancel[#freeCancel + 1] = ('%d'):format(amount) end
end
T.list('refund plus fee always sums back to the escrow, at every legal amount',
    unbalanced, {})
T.list('neither half is ever negative', negativeFee, {})
T.list('and no legal amount can be cancelled for free', freeCancel, {})

-- Below $10 the fee floors to zero and cancelling is free. MinAmount is $100 so
-- that is unreachable; recorded because it is the boundary a future MinAmount
-- change would cross.
T.eq('a $9 contract would refund in full, fee-free', (cancelFor(9)), 9)
T.eq('a $10 contract is the first that costs anything to cancel', select(2, cancelFor(10)), 1)
T.lt('and $10 is well below the shipped minimum', 10, P.MinAmount)

-- The boot reconcile recomputes the same refund. The two must not drift.
local reconcileLine = T.line(MAIN,
    'local refund = amount - math.floor(amount * Config.Private.CancelFeePct)')
local reconcileFor = T.chunk('palm6_bounty reconcile refund',
    'local Config = ...\nreturn function(amount)\n' .. reconcileLine .. '\nreturn refund\nend\n')(Config)
local drift = {}
for amount = P.MinAmount, P.MaxAmount, 7 do
    if reconcileFor(amount) ~= cancelFor(amount) then drift[#drift + 1] = ('%d'):format(amount) end
end
T.list('the boot reconcile refunds exactly what /cancelbounty refunds', drift, {})

T.done()
