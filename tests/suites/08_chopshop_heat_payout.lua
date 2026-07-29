-- ============================================================================
-- palm6_chopshop HEAT PAYOUT: the fence's haircut on a stolen-car sale.
--
-- The WRITE side of this wire (Config.HeatOnSale / HeatStolenBonus, the heat a
-- chop ADDS) already ships live. This block is the READ side: what a chopper
-- pays for the heat they have been earning. It ships DISABLED, so /sellstolen
-- pays exactly Config.ClassPayout[class] today.
--
-- WHAT THIS PINS
-- A payout that can go negative, or that can exceed the flat class price, is a
-- money bug in a command any player can run. heatPayoutMult's [Floor, 1.0]
-- clamp is the anti-farm guarantee written in code rather than in a comment,
-- and the one line that applies it floors at $1. Both are swept here across
-- every shipped vehicle class, every palm6_heat tier, and the edge inputs the
-- class table cannot currently produce.
--
-- HOW THE CODE IS REACHED
-- heatPayoutMult is a `local function` inside a server file that opens MySQL
-- connections and registers chat commands, so the file cannot be loaded. Its
-- exact production text is lifted by anchor and compiled with the two things it
-- reaches for outside itself stubbed: GetResourceState and the frozen
-- exports.palm6_heat:GetTier. That makes the SOFT-GUARD path testable too: a
-- stopped, booting or throwing palm6_heat has to land on today's flat payout,
-- and here it is proved to.
--
-- NOT TESTED HERE: cmdSellStolen as a whole (ownership SELECT, the stolen-report
-- lookup, the sale INSERT, the player_vehicles retire, Bridge.CreditBank, the
-- evidence case) and cmdReportStolen. README lists them.
-- ============================================================================
T.begin('palm6_chopshop fence payout under heat')

local CHOP = 'resources/[custom]/palm6_chopshop/'
local MAIN = CHOP .. 'server/main.lua'

T.loadFile('resources/[custom]/palm6_heat/shared/config.lua')
local heatConfig = Config
local HEAT_TIERS, HEAT_TIER_SET = {}, {}
for _, t in ipairs(heatConfig.Tiers) do
    HEAT_TIERS[#HEAT_TIERS + 1] = t.tier
    HEAT_TIER_SET[t.tier] = true
end
Config = nil

T.loadFile(CHOP .. 'shared/config.lua')
local HP = Config.HeatPayout

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the fence haircut still ships dark', HP.Enabled)
T.near('WARM multiplier', HP.Mult.WARM, 1.00)
T.near('HOT multiplier', HP.Mult.HOT, 0.85)
T.near('WANTED multiplier', HP.Mult.WANTED, 0.70)
T.near('the hard floor on any multiplier', HP.Floor, 0.50)
T.eq('base heat a chop adds', Config.HeatOnSale, 10)
T.eq('extra heat when the plate was reported stolen', Config.HeatStolenBonus, 6)

local overOne = {}
for tier, m in pairs(HP.Mult) do
    if m > 1.0 then overOne[#overOne + 1] = tier end
end
T.list('no shipped multiplier is above 1.0', overOne, {})

local unknownKeys = {}
for tier in pairs(HP.Mult) do
    if not HEAT_TIER_SET[tier] then unknownKeys[#unknownKeys + 1] = tier end
end
T.list('every Mult key is a real palm6_heat tier name', unknownKeys, {})

-- Every class price must be a positive whole number of dollars, or the floor in
-- the haircut line below is doing more than backstopping.
local badPrice = {}
for class, price in pairs(Config.ClassPayout) do
    if math.type(price) ~= 'integer' or price < 1 then
        badPrice[#badPrice + 1] = ('class %d'):format(class)
    end
end
T.list('every class price is a whole number of dollars, at least $1', badPrice, {})

-- ---------------------------------------------------------------------------
-- Lift heatPayoutMult, with the two cross-resource calls stubbed. The stubs are
-- the honest shape of the real thing: GetResourceState returns a state string,
-- and the export is called as a METHOD (exports.palm6_heat:GetTier(cid)), so
-- the stub takes self.
-- ---------------------------------------------------------------------------
local multBlock = T.slice(MAIN, 'local function heatPayoutMult(cid)', 'local function atDropPoint(src)')
T.contains('slice really contains heatPayoutMult', multBlock, 'local function heatPayoutMult(cid)')
T.contains('slice reads the tier only through the frozen export', multBlock, 'exports.palm6_heat:GetTier(cid)')
T.contains('slice contains the upper clamp', multBlock, 'if m > 1.0 then m = 1.0 end')
T.contains('slice contains the floor clamp', multBlock, 'if m < floorMult then m = floorMult end')
T.notcontains('slice pulled in no MySQL', multBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', multBlock, 'Bridge.')
T.notcontains('slice never queries palm6_heat_state directly', multBlock, 'palm6_heat_state')

local buildMult = T.chunk('palm6_chopshop heatPayoutMult', table.concat({
    'local Config, stateFn, tierFn, bump = ...',
    'local GetResourceState = function(res) return stateFn(res) end',
    'local exports = { palm6_heat = { GetTier = function(_, cid) bump() ; return tierFn(cid) end } }',
    multBlock,
    'return heatPayoutMult',
}, '\n'))

-- Build a heatPayoutMult bound to a given palm6_heat state and tier answer.
-- `reads()` counts how many times the export was actually called, so "no export
-- call while the flag is off" is a tested claim and not a comment.
local exportReads = 0
local function mkMult(tier, state)
    return buildMult(Config, function() return state or 'started' end,
        function() if type(tier) == 'function' then return tier() end return tier end,
        function() exportReads = exportReads + 1 end)
end

-- ---------------------------------------------------------------------------
T.section('flag off: no export call, and an exact identity multiplier')
exportReads = 0
local offBad = {}
for _, tier in ipairs(HEAT_TIERS) do
    local m, t = mkMult(tier)('CHOP0001')
    if m ~= 1.0 or t ~= nil then offBad[#offBad + 1] = tier end
end
T.list('with the flag off every tier returns exactly (1.0, nil)', offBad, {})
T.eq('and palm6_heat was never asked, so not one DB round-trip was spent', exportReads, 0)

-- ---------------------------------------------------------------------------
T.section('flag on: the multiplier each tier actually gets')
Config.HeatPayout.Enabled = true

local function multOf(tier, state) return (mkMult(tier, state)('CHOP0001')) end
local function tierOfCall(tier, state) return select(2, mkMult(tier, state)('CHOP0001')) end

T.near('CLEAN is absent from the table, so the payout is unchanged', multOf('CLEAN'), 1.0)
T.eq('but the tier is still reported, for the message the caller would print',
    tierOfCall('CLEAN'), 'CLEAN')
T.near('COOL is absent from the table too', multOf('COOL'), 1.0)
T.near('WARM costs nothing yet', multOf('WARM'), 1.00)
T.near('HOT is held back 15%', multOf('HOT'), 0.85)
T.near('WANTED is held back 30%', multOf('WANTED'), 0.70)

-- ---------------------------------------------------------------------------
T.section('every soft-guard failure mode lands on today\'s flat payout')
exportReads = 0
T.near('palm6_heat stopped: full payout', multOf('WANTED', 'stopped'), 1.0)
T.isnil('and no tier is reported', tierOfCall('WANTED', 'stopped'))
T.near('palm6_heat still starting: full payout', multOf('WANTED', 'starting'), 1.0)
T.eq('a non-started palm6_heat is never even asked', exportReads, 0)

T.near('the export throwing: full payout',
    multOf(function() error('palm6_heat blew up') end), 1.0)
T.isnil('and no tier is reported after a throw',
    tierOfCall(function() error('palm6_heat blew up') end))
T.near('the export returning nil: full payout', multOf(nil), 1.0)
T.near('the export returning a number: full payout', multOf(42), 1.0)
T.near('the export returning a table: full payout', multOf({}), 1.0)
T.near('an unknown tier string: full payout', multOf('FRIGID'), 1.0)

-- The citizenid guard. Every caller passes Bridge.GetCitizenId's output.
local mm = mkMult('WANTED')
T.near('a nil citizenid is refused before any export call', (mm(nil)), 1.0)
T.near('an empty citizenid is refused too', (mm('')), 1.0)
T.near('a numeric citizenid is refused too', (mm(1234)), 1.0)

-- ---------------------------------------------------------------------------
T.section('the clamps: no config value can make being hot pay BETTER')
Config.HeatPayout.Mult.WANTED = 1.4
T.near('a multiplier above 1.0 is clamped back to 1.0', multOf('WANTED'), 1.0)
Config.HeatPayout.Mult.WANTED = math.huge
T.near('an infinite multiplier is clamped to 1.0', multOf('WANTED'), 1.0)
Config.HeatPayout.Mult.WANTED = 0.01
T.near('a multiplier below the floor is raised to the floor', multOf('WANTED'), 0.50)
Config.HeatPayout.Mult.WANTED = -2.0
T.near('a negative multiplier is raised to the floor', multOf('WANTED'), 0.50)
Config.HeatPayout.Mult.WANTED = '0.66'
T.near('a stringified number is coerced, not rejected', multOf('WANTED'), 0.66)

local savedFloor = Config.HeatPayout.Floor
Config.HeatPayout.Floor = nil
Config.HeatPayout.Mult.WANTED = 0.01
T.near('a deleted Floor falls back to the documented 0.50', multOf('WANTED'), 0.50)
Config.HeatPayout.Floor = savedFloor

-- Deleting the whole block must degrade to "disabled", not throw inside a chat
-- command that is not pcall-wrapped.
local savedBlock = Config.HeatPayout
Config.HeatPayout = nil
T.near('deleting the whole HeatPayout block degrades to disabled', multOf('WANTED'), 1.0)
Config.HeatPayout = savedBlock
Config.HeatPayout.Mult.WANTED = 0.70   -- restore the shipped value
T.near('the shipped WANTED multiplier is restored', multOf('WANTED'), 0.70)

-- ---------------------------------------------------------------------------
-- Lift the payout lines themselves, in production order.
-- ---------------------------------------------------------------------------
T.section('the payout line')
local payoutSlice = T.slice(MAIN, 'local cleanPayout = payout',
    'Record the sale FIRST (durable audit trail)')
T.contains('the clean payout is captured before the haircut', payoutSlice, 'local cleanPayout = payout')
T.contains('the haircut floors at $1', payoutSlice, 'payout = math.max(1, math.floor(payout * hMult))')
T.notcontains('payout slice pulled in no MySQL', payoutSlice, 'MySQL')

-- Driven through the REAL heatPayoutMult, so what is under test is the whole
-- call site: read the tier, decide the multiplier, apply it. The only thing
-- handed in is which heatPayoutMult the line calls.
local buildApply = T.chunk('palm6_chopshop payout haircut',
    'local heatPayoutMult = ...\nreturn function(payout, cid)\n' .. payoutSlice
    .. '\nreturn payout, cleanPayout, hMult, hTier\nend\n')

-- Fixed multiplier, for the arithmetic cases.
local function applyPayout(payout, mult)
    return buildApply(function() return mult, nil end)(payout, 'CHOP0001')
end
-- Real tier read, precompiled per tier so the sweeps below stay cheap.
local byTier = {}
for _, tier in ipairs(HEAT_TIERS) do byTier[tier] = buildApply(mkMult(tier)) end
local function applyTier(payout, tier) return byTier[tier](payout, 'CHOP0001') end

T.eq('the whole call site end to end: a WANTED chopper on a $2,600 Muscle',
    (applyTier(2600, 'WANTED')), 1819)
T.eq('a CLEAN chopper on the same car is untouched', (applyTier(2600, 'CLEAN')), 2600)

T.eq('clean, a $2,600 Muscle', (applyPayout(2600, 1.0)), 2600)
T.eq('HOT, the same car', (applyPayout(2600, 0.85)), 2210)
T.eq('at the Floor, the same car', (applyPayout(2600, 0.50)), 1300)

-- $2,600 x 0.70 is $1,820 in decimal but 1819.9999999999998 in IEEE double,
-- because 0.70 has no exact binary representation. math.floor then takes $1,819.
-- The extra dollar goes to the house, the same direction every other truncation
-- in this file goes, and the seller is told the real figure because the message
-- prints cleanPayout - payout rather than a recomputed number. Pinned so a
-- future switch to rounding is a deliberate decision and not a surprise.
T.eq('a 0.70 multiplier loses one extra dollar to binary floating point',
    (applyPayout(2600, 0.70)), 1819)
T.eq('while 0.85 on the same price lands exactly', (applyPayout(2600, 0.85)), 2210)

-- Truncation is real money and it always favours the house, never the seller.
T.eq('a fractional result truncates DOWN', (applyPayout(1500, 0.85)), 1275)
T.eq('and truncates down again on an odd price', (applyPayout(901, 0.85)), 765)  -- 765.85

-- ---------------------------------------------------------------------------
T.section('THE INVARIANT: a payout never goes negative and never beats the base')
local negative, overBase, notWhole = {}, {}, {}
for class, base in pairs(Config.ClassPayout) do
    for _, tier in ipairs(HEAT_TIERS) do
        local paid = applyTier(base, tier)
        if paid < 0 then negative[#negative + 1] = ('class %d %s'):format(class, tier) end
        if paid > base then overBase[#overBase + 1] = ('class %d %s'):format(class, tier) end
        if math.type(paid) ~= 'integer' then notWhole[#notWhole + 1] = ('class %d %s'):format(class, tier) end
    end
end
T.list('no class at any tier can be paid a negative amount', negative, {})
T.list('no class at any tier can be paid more than its flat class price', overBase, {})
T.list('and every payout is a whole number of dollars', notWhole, {})

-- The same two claims, swept over every dollar value from $0 up past the most
-- expensive class, and over every multiplier the clamps can produce. This is
-- the "any input value including 0" case.
local sweepNeg, sweepOver, sweepZero = {}, {}, {}
for _, m in ipairs({ 1.0, 0.85, 0.70, 0.50 }) do
    for base = 0, 8100 do
        local paid = applyPayout(base, m)
        if paid < 0 then sweepNeg[#sweepNeg + 1] = ('%.2f@%d'):format(m, base) end
        -- The $1 floor lives INSIDE the `hMult < 1.0` branch, so it only
        -- backstops a discounted sale. At 1.0 the branch is skipped and the
        -- flat class price passes through untouched, $0 included.
        if m < 1.0 and paid < 1 then sweepZero[#sweepZero + 1] = ('%.2f@%d'):format(m, base) end
        if paid > math.max(1, base) then sweepOver[#sweepOver + 1] = ('%.2f@%d'):format(m, base) end
    end
end
T.list('no base value and no multiplier produces a negative payout', sweepNeg, {})
T.list('and no DISCOUNTED sale ever produces a zero payout', sweepZero, {})
T.list('and none pays more than max($1, the base price)', sweepOver, {})
T.eq('at multiplier 1.0 the branch is skipped, so a $0 base stays $0',
    (applyPayout(0, 1.0)), 0)

-- The one place the "never exceeds the base" claim needs its exact wording: a
-- $0 base. The $1 floor turns it into $1, a $1 mint. RECORDED, NOT A LIVE BUG:
-- Config.ClassPayout has no zero entry and an unmapped class is refused
-- outright before this line is reached, so $0 is unreachable today. It would
-- become reachable the moment an operator added a `[13] = 0` line.
T.eq('a $0 base with a haircut floors UP to $1', (applyPayout(0, 0.70)), 1)
T.eq('a $1 base with a haircut stays $1, not $0', (applyPayout(1, 0.70)), 1)
local zeroClasses = {}
for class, base in pairs(Config.ClassPayout) do
    if base < 1 then zeroClasses[#zeroClasses + 1] = ('class %d'):format(class) end
end
T.list('no shipped class pays $0, so the $1 floor cannot mint today', zeroClasses, {})

-- A negative base can never produce a negative payout either.
T.eq('a negative base is floored to $1, never paid out negative', (applyPayout(-5000, 0.70)), 1)

-- ---------------------------------------------------------------------------
T.section('monotonic: getting hotter never pays a chopper more')
local rose = {}
for class, base in pairs(Config.ClassPayout) do
    local prev = nil
    for _, tier in ipairs(HEAT_TIERS) do   -- HEAT_TIERS is WANTED..CLEAN, hottest first
        local paid = applyTier(base, tier)
        if prev ~= nil and paid < prev then
            rose[#rose + 1] = ('class %d at %s'):format(class, tier)
        end
        prev = paid
    end
end
T.list('walking DOWN the heat ladder never lowers the payout, for any class', rose, {})

-- And the whole point: at the top of the ladder a chopper is strictly worse off
-- on every car the shop buys.
local notWorse = {}
for class, base in pairs(Config.ClassPayout) do
    if applyTier(base, 'WANTED') >= base then
        notWorse[#notWorse + 1] = ('class %d'):format(class)
    end
end
T.list('a WANTED chopper is strictly worse off on every shipped class', notWorse, {})

-- The shortfall the seller is told about must be the real one, and never
-- negative (which would read as the fence paying a bonus).
T.section('the shortfall the seller is shown is the real one')
local paid, clean = applyTier(2600, 'WANTED')
T.eq('the clean price is preserved for the message', clean, 2600)
T.eq('and the shortfall named is exactly what was withheld', clean - paid, 781)
local badShortfall = {}
for class, base in pairs(Config.ClassPayout) do
    for _, tier in ipairs(HEAT_TIERS) do
        local p, c = applyTier(base, tier)
        if c - p < 0 then badShortfall[#badShortfall + 1] = ('class %d %s'):format(class, tier) end
    end
end
T.list('the shortfall is never negative, at any class or tier', badShortfall, {})

T.done()
