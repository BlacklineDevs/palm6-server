-- ============================================================================
-- palm6_drugs HEAT STREET PRICE: the dirty-money haircut and, more
-- importantly, the CHANNEL ORDERING it was built to preserve.
--
-- Product turns into dirty cash in exactly two places: the NPC street buyer
-- (server/main.lua sell handler) and the NPC corner dealer (resolveDealer). The
-- street is the risky channel (bust roll, evidence case, durable heat); the
-- dealer stash is the safe one and pays Config.Dealer.playerCut of the same
-- price. Config.HeatStreetPrice discounts BOTH by the same multiplier. If it
-- discounted only the street, at WANTED the street would pay 0.70 while the
-- risk-free stash paid 0.80, and flipping the flag on would have pushed a hot
-- dealer OUT of the channel police can see and INTO the one they cannot, for
-- more money. That inversion is the failure this suite exists to make
-- impossible to reintroduce silently.
--
-- The flag ships DISABLED, so none of this arithmetic runs live today. The
-- point is that it can be flipped on with something behind it.
--
-- HOW THE CODE IS REACHED
-- streetHeatMult is a `local function` inside a 2,290-line server file that
-- opens MySQL connections and registers net events, so the file cannot be
-- loaded. Its exact production text is lifted by anchor along with the two
-- load-time Config aliases it reads, and compiled inside a factory so the
-- alias can be rebuilt after a flag is flipped, exactly as a server restart
-- would rebuild it. The bytes under test are the bytes that ship.
--
-- The tier boundaries are palm6_heat's, so palm6_heat's own tierOf is lifted
-- too and composed with the multiplier. That makes "at 64 heat you are still
-- paid in full, at 65 you are not" a tested statement rather than two separate
-- facts about two resources.
--
-- NOT TESTED HERE: heatTierOf's live path (GetResourceState + the palm6_heat
-- export), the sell handler as a whole (item removal, ox_inventory, the sales
-- ledger INSERT), resolveDealer's stash walk and persistence. README lists them.
-- ============================================================================
T.begin('palm6_drugs heat street price and the channel ordering')

local DRUGS = 'resources/[custom]/palm6_drugs/'
local MAIN  = DRUGS .. 'server/main.lua'
local HEATMAIN = 'resources/[custom]/palm6_heat/server/main.lua'

-- palm6_heat's config first: its tier NAMES are the keys palm6_drugs indexes
-- its Mult table by, and a typo in either file would silently mean "no
-- discount, ever". Captured, then Config is handed over to palm6_drugs.
T.loadFile('resources/[custom]/palm6_heat/shared/config.lua')
local heatConfig = Config
local HEAT_TIERS, HEAT_TIER_SET = {}, {}
for _, t in ipairs(heatConfig.Tiers) do
    HEAT_TIERS[#HEAT_TIERS + 1] = t.tier
    HEAT_TIER_SET[t.tier] = true
end
Config = nil

-- palm6_drugs' config declares station coordinates with vector3, a FiveM
-- native. Stubbed as a plain table: nothing here reads a coordinate, so no
-- world position is invented in this directory.
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
T.loadFile(DRUGS .. 'shared/config.lua')

local HP = Config.HeatStreetPrice

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the street-price haircut still ships dark', HP.Enabled)
T.near('WARM multiplier', HP.Mult.WARM, 1.00)
T.near('HOT multiplier', HP.Mult.HOT, 0.85)
T.near('WANTED multiplier', HP.Mult.WANTED, 0.70)
T.near('the hard floor on any multiplier', HP.Floor, 0.60)
T.near('the dealer keeps a cut below 1.0', Config.Dealer.playerCut, 0.80)
T.eq('the street buyer daily cap is in DOLLARS', Config.Sell.dailyDirtyCap, 40000)
T.eq('the dealer daily cap is in DOLLARS', Config.Dealer.dailyDirtyCap, 30000)

-- Every multiplier must be <= 1.0 in the config as shipped, or the clamp in
-- code is the only thing standing between a typo and "being hot pays better".
local overOne = {}
for tier, m in pairs(HP.Mult) do
    if m > 1.0 then overOne[#overOne + 1] = tier end
end
T.list('no shipped multiplier is above 1.0', overOne, {})

-- A key that is not a real palm6_heat tier can never match, so the discount it
-- describes would silently never apply. This is the cross-resource contract.
local unknownKeys = {}
for tier in pairs(HP.Mult) do
    if not HEAT_TIER_SET[tier] then unknownKeys[#unknownKeys + 1] = tier end
end
T.list('every Mult key is a real palm6_heat tier name', unknownKeys, {})

-- ---------------------------------------------------------------------------
-- Lift the durable-heat READ side of palm6_drugs (the two Config aliases,
-- heatTierOf, streetHeatMult and heatBustExtra) as a FACTORY, so the aliases
-- can be rebuilt after a flag flip the way a resource restart rebuilds them.
-- ---------------------------------------------------------------------------
local heatBlock = T.slice(MAIN,
    'local HeatPrice = Config.HeatStreetPrice or {}',
    'local function normQuality(q)')
T.contains('slice contains the HeatPrice alias', heatBlock, 'local HeatPrice = Config.HeatStreetPrice')
T.contains('slice contains streetHeatMult', heatBlock, 'local function streetHeatMult(tier)')
T.contains('slice contains the upper clamp', heatBlock, 'if m > 1.0 then m = 1.0 end')
T.contains('slice contains the floor clamp', heatBlock, 'if m < floorMult then m = floorMult end')
T.notcontains('slice pulled in no MySQL', heatBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', heatBlock, 'Bridge.')
T.notcontains('slice pulled in no notify', heatBlock, 'Notify')

local buildHeatRead = T.chunk('palm6_drugs durable-heat read side',
    'local Config = ...\n' .. heatBlock .. '\nreturn streetHeatMult, heatBustExtra\n')

local function build()
    return buildHeatRead(Config)
end

-- ---------------------------------------------------------------------------
-- Lift palm6_heat's tierOf so "which tier is 65 heat" is the shipped answer
-- rather than this file's opinion. Config is passed in as a local so the two
-- resources' configs cannot collide in one Lua state.
-- ---------------------------------------------------------------------------
local heatPure = T.slice(HEATMAIN,
    'local function decayed(storedHeat, ageSec)',
    '-- Boot: self-create the table.')
T.contains('palm6_heat slice contains tierOf', heatPure, 'local function tierOf')
local tierOfRow = T.chunk('palm6_heat tierOf',
    'local Config = ...\n' .. heatPure .. '\nreturn tierOf\n')(heatConfig)
-- palm6_heat's tierOf returns the whole tier ROW; the `.tier` field is the
-- string the frozen GetTier export publishes and the string palm6_drugs keys
-- its Mult table by.
local function tierOf(heat) return tierOfRow(heat).tier end
T.eq('tierOf agrees with the shipped WANTED threshold', tierOf(110), 'WANTED')
T.eq('tierOf agrees with the shipped CLEAN floor', tierOf(0), 'CLEAN')

-- ---------------------------------------------------------------------------
T.section('flag off: the disabled path is an exact identity')
local multOff = build()
local notIdentity = {}
for _, tier in ipairs(HEAT_TIERS) do
    if multOff(tier) ~= 1.0 then notIdentity[#notIdentity + 1] = tier end
end
T.list('with the flag off every tier multiplies by exactly 1.0', notIdentity, {})
T.eq('a nil tier multiplies by 1.0 with the flag off', multOff(nil), 1.0)

-- ---------------------------------------------------------------------------
T.section('flag on: the multiplier each tier actually gets')
Config.HeatStreetPrice.Enabled = true
local mult = build()

T.near('CLEAN is absent from the table, so nothing changes', mult('CLEAN'), 1.0)
T.near('COOL is absent from the table, so nothing changes', mult('COOL'), 1.0)
T.near('WARM costs nothing yet', mult('WARM'), 1.00)
T.near('HOT is shorted 15%', mult('HOT'), 0.85)
T.near('WANTED is shorted 30%', mult('WANTED'), 0.70)

-- Failure modes all land on 1.0, i.e. exactly today's behaviour.
T.near('an unreadable tier (nil) falls back to full price', mult(nil), 1.0)
T.near('a numeric tier falls back to full price', mult(42), 1.0)
T.near('a table tier falls back to full price', mult({}), 1.0)
T.near('an unknown tier string falls back to full price', mult('FRIGID'), 1.0)

-- ---------------------------------------------------------------------------
T.section('tier boundaries, from BOTH sides, composed with palm6_heat')
-- These are the moments a player's pay actually changes. Every threshold is
-- checked at the last heat value that is still cheap and the first that is not.
local function multAt(heat) return mult(tierOf(heat)) end

T.near('0 heat is CLEAN: full price', multAt(0), 1.0)
T.near('1 heat is COOL: still full price', multAt(1), 1.0)
T.near('29 heat is the last COOL point: full price', multAt(29), 1.0)
T.near('30 heat is the first WARM point: still full price', multAt(30), 1.00)
T.near('64 heat is the last WARM point: still full price', multAt(64), 1.00)
T.near('65 heat is the first HOT point: the haircut starts', multAt(65), 0.85)
T.near('109 heat is the last HOT point', multAt(109), 0.85)
T.near('110 heat is the first WANTED point: the deepest haircut', multAt(110), 0.70)
T.near('at the heat cap the multiplier is still WANTED', multAt(heatConfig.HeatCap), 0.70)

-- Monotonic: climbing the heat ladder must never raise the price. Swept over
-- every heat value from clean to the cap, not just the boundaries.
local wentUp = {}
local prevMult = nil
for heat = 0, heatConfig.HeatCap do
    local m = multAt(heat)
    if prevMult ~= nil and m > prevMult then
        wentUp[#wentUp + 1] = ('%d'):format(heat)
    end
    prevMult = m
end
T.list('getting hotter never raises the price, at any heat value', wentUp, {})

-- ---------------------------------------------------------------------------
T.section('the clamps are the anti-farm guarantee, in code not in a comment')
-- A config typo that tries to pay a hot dealer MORE is refused by construction.
Config.HeatStreetPrice.Mult.WANTED = 1.5
local typo = build()
T.near('a multiplier above 1.0 is clamped back to 1.0', typo('WANTED'), 1.0)

Config.HeatStreetPrice.Mult.WANTED = 100.0
typo = build()
T.near('an absurd multiplier is still clamped to 1.0', typo('WANTED'), 1.0)

Config.HeatStreetPrice.Mult.WANTED = math.huge
typo = build()
T.near('an infinite multiplier is clamped to 1.0', typo('WANTED'), 1.0)

-- The floor stops the other direction: a typo cannot zero a seller out.
Config.HeatStreetPrice.Mult.WANTED = 0.01
typo = build()
T.near('a multiplier below the floor is raised to the floor', typo('WANTED'), 0.60)

Config.HeatStreetPrice.Mult.WANTED = -5.0
typo = build()
T.near('a negative multiplier is raised to the floor', typo('WANTED'), 0.60)

-- Floor itself is read guarded, so deleting it degrades to the documented 0.60
-- rather than throwing inside a sell handler that is not pcall-wrapped.
local savedFloor = Config.HeatStreetPrice.Floor
Config.HeatStreetPrice.Floor = nil
typo = build()
T.near('a deleted Floor falls back to the documented 0.60', typo('WANTED'), 0.60)
Config.HeatStreetPrice.Floor = savedFloor

-- NaN is the one input neither clamp catches (every comparison against NaN is
-- false). Recorded, not fixed: the two callers both gate on `mult < 1.0`, which
-- is false for NaN, so a NaN multiplier degrades to "no haircut" rather than to
-- a wrong payout. See the README findings list.
Config.HeatStreetPrice.Mult.WANTED = 0.0 / 0.0
typo = build()
T.isnan('a NaN multiplier survives both clamps', typo('WANTED'))
T.isfalse('but the caller gate `mult < 1.0` is false for NaN, so no haircut applies',
    typo('WANTED') < 1.0)

Config.HeatStreetPrice.Mult.WANTED = 0.70   -- restore the shipped value
mult = build()
T.near('the shipped WANTED multiplier is restored', mult('WANTED'), 0.70)

-- ---------------------------------------------------------------------------
-- Lift the two production haircut LINES: one from the street buyer, one from
-- the corner dealer. Composed here in production order.
-- ---------------------------------------------------------------------------
T.section('both cash-out channels apply the identical haircut expression')
local streetLine = T.line(MAIN, 'if hMult < 1.0 then unit = math.max(1, math.floor(unit * hMult)) end')
local dealerLine = T.line(MAIN, 'if dMult < 1.0 then unit = math.max(1, math.floor(unit * dMult)) end')
local dealerCutLine = T.line(MAIN, 'local playerUnit = math.floor(unit * Config.Dealer.playerCut)')
local dealerFloorLine = T.line(MAIN, 'if playerUnit < 1 then playerUnit = 1 end')

-- Structural pin: the two channels must not drift apart. Compared after
-- stripping indentation and renaming the local, so the ONLY difference the two
-- lines are allowed to have is which variable holds the multiplier.
local function normalise(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''):gsub('hMult', 'M'):gsub('dMult', 'M'))
end
T.eq('the street and dealer haircut lines are the same arithmetic',
    normalise(dealerLine), normalise(streetLine))

local streetUnit = T.chunk('palm6_drugs street haircut',
    'return function(unit, hMult)\n' .. streetLine .. '\nreturn unit\nend\n')()
local dealerUnit = T.chunk('palm6_drugs dealer haircut and cut',
    'local Config = ...\nreturn function(unit, dMult)\n'
    .. dealerLine .. '\n' .. dealerCutLine .. '\n' .. dealerFloorLine
    .. '\nreturn playerUnit\nend\n')(Config)

T.eq('street, clean, $100 unit', streetUnit(100, 1.0), 100)
T.eq('street, WANTED, $100 unit', streetUnit(100, 0.70), 70)
T.eq('dealer, clean, $100 unit pays the player 80', dealerUnit(100, 1.0), 80)
T.eq('dealer, WANTED, $100 unit pays the player 56', dealerUnit(100, 0.70), 56)

-- ---------------------------------------------------------------------------
T.section('THE INVARIANT: the street must out-pay the safe stash at every tier')
-- Lift priceOfSlot (and the two pure helpers it calls) so the price range this
-- invariant is swept over is the range the server can actually produce, not a
-- range this test made up.
local pureHelpers = T.slice(MAIN, 'local function normQuality(q)', 'local function hasEffect(list, name)')
local priceSlot = T.slice(MAIN, 'local function priceOfSlot(_, meta)', '-- Dirty dollars this character has already sold')
T.notcontains('priceOfSlot slice pulled in no MySQL', priceSlot, 'MySQL')
T.notcontains('priceOfSlot slice pulled in no Bridge call', priceSlot, 'Bridge.')
local priceOfSlot = T.chunk('palm6_drugs priceOfSlot',
    'local Config = ...\n' .. pureHelpers .. '\n' .. priceSlot .. '\nreturn priceOfSlot\n')(Config)

-- The reachable unit-price band. Walked over every base drug, every quality
-- tier and effect lists of every legal length built from the highest and lowest
-- valued effects, which bracket every other list.
local sortedEffects = {}
for name, v in pairs(Config.Effects) do sortedEffects[#sortedEffects + 1] = { name, v } end
table.sort(sortedEffects, function(a, b)
    if a[2] == b[2] then return a[1] < b[1] end
    return a[2] > b[2]
end)

local minPrice, maxPrice = math.huge, -math.huge
for baseId in pairs(Config.Drugs) do
    for q = 0, 4 do
        for n = 0, Config.MaxEffects do
            local best, worst = {}, {}
            for i = 1, n do
                best[i] = sortedEffects[i][1]
                worst[i] = sortedEffects[#sortedEffects - i + 1][1]
            end
            for _, eff in ipairs({ best, worst }) do
                local p = priceOfSlot(nil, { base = baseId, quality = q, effects = eff })
                if p < minPrice then minPrice = p end
                if p > maxPrice then maxPrice = p end
            end
        end
    end
end
T.eq('the cheapest unit the price engine can mint', minPrice, 23)
T.eq('the dearest unit the price engine can mint', maxPrice, 477)
T.lt('so the $500 MaxUnitPrice ceiling is unreachable with the shipped catalogue',
    maxPrice, Config.MaxUnitPrice)

-- The sweep. Every tier, every unit price the engine can produce.
local inverted, tied = {}, {}
for _, tier in ipairs(HEAT_TIERS) do
    local m = mult(tier)
    for unit = minPrice, maxPrice do
        local street = streetUnit(unit, m)
        local stash  = dealerUnit(unit, m)
        if street < stash then
            inverted[#inverted + 1] = ('%s@%d street %d < stash %d'):format(tier, unit, street, stash)
        elseif street == stash then
            tied[#tied + 1] = ('%s@%d'):format(tier, unit)
        end
    end
end
T.list('the risky street channel NEVER pays less than the safe stash, at any tier or price',
    inverted, {})
T.list('and it is STRICTLY better at every price the engine can mint, at every tier',
    tied, {})

-- Where the strictness would end, and proof it is out of reach. At a $1 unit
-- both channels floor to $1 and tie. The price engine clamps to a minimum of
-- $1 but the cheapest catalogue entry mints $23, so the tie is unreachable.
T.eq('at a $1 unit the street pays 1', streetUnit(1, 0.70), 1)
T.eq('at a $1 unit the stash also pays 1, a tie not an inversion', dealerUnit(1, 0.70), 1)
T.lt('and $1 is below the cheapest unit the catalogue can mint', 1, minPrice)

-- The same ordering has to hold when the flag is OFF, or the dealer would be
-- the better channel today.
local invertedOff = {}
for unit = minPrice, maxPrice do
    if streetUnit(unit, 1.0) <= dealerUnit(unit, 1.0) then
        invertedOff[#invertedOff + 1] = ('%d'):format(unit)
    end
end
T.list('with the flag off the street still strictly out-pays the stash', invertedOff, {})

-- ---------------------------------------------------------------------------
T.section('a haircut can never mint: payouts only ever fall')
local rose = {}
for _, tier in ipairs(HEAT_TIERS) do
    local m = mult(tier)
    for unit = minPrice, maxPrice do
        if streetUnit(unit, m) > streetUnit(unit, 1.0) then
            rose[#rose + 1] = ('street %s@%d'):format(tier, unit)
        end
        if dealerUnit(unit, m) > dealerUnit(unit, 1.0) then
            rose[#rose + 1] = ('stash %s@%d'):format(tier, unit)
        end
    end
end
T.list('no tier pays more than CLEAN on either channel', rose, {})

-- A haircut can never drive a payout to zero or below: both lines floor at 1.
-- Only the haircut BRANCH is claimed here. At mult 1.0 the branch does not run
-- at all (`if hMult < 1.0`), so the street line is a true no-op and a $0 unit
-- stays $0; the dealer line still takes its cut and floors at 1.
local nonPositive = {}
for _, m in ipairs({ 0.85, 0.70, 0.60 }) do
    for unit = 0, 10 do
        if streetUnit(unit, m) < 1 then nonPositive[#nonPositive + 1] = ('street %.2f@%d'):format(m, unit) end
        if dealerUnit(unit, m) < 1 then nonPositive[#nonPositive + 1] = ('stash %.2f@%d'):format(m, unit) end
    end
end
T.list('a haircut can never drive either channel to zero or a negative amount',
    nonPositive, {})
T.eq('at multiplier 1.0 the street haircut branch is skipped entirely, so $0 stays $0',
    streetUnit(0, 1.0), 0)
T.eq('the dealer cut always floors at $1 even on a $0 unit', dealerUnit(0, 1.0), 1)

-- ---------------------------------------------------------------------------
T.section('the daily caps are in DOLLARS, so a hot seller burns more product')
-- Both faucet ceilings are denominated in dollars, so a discounted seller does
-- not get a bigger day, they get a smaller day per unit of product.
local unitsLine = T.line(MAIN, 'local units = math.min(s.count, math.floor(remaining / unit))')
-- `s` is the ox_inventory slot the production line reads `.count` off. Handed
-- in as a plain table so the lifted line is unchanged.
local unitsForRaw = T.chunk('palm6_drugs daily-cap unit count',
    'return function(s, remaining, unit)\n' .. unitsLine .. '\nreturn units\nend\n')()
local function unitsFor(count, remaining, unit)
    return unitsForRaw({ count = count }, remaining, unit)
end

local cleanUnit = streetUnit(100, 1.0)
local hotUnit   = streetUnit(100, mult('WANTED'))
local cap = Config.Sell.dailyDirtyCap
T.eq('clean, a $100 unit fills the $40,000 day in 400 units', unitsFor(9999, cap, cleanUnit), 400)
T.eq('WANTED, the same day costs 571 units of the same product',
    unitsFor(9999, cap, hotUnit), 571)
T.lt('so heat strictly increases the product burned for one full day of cap',
    unitsFor(9999, cap, cleanUnit), unitsFor(9999, cap, hotUnit))

-- Swept: there is no unit price at which being hot buys a cheaper day.
local cheaperDay = {}
for unit = minPrice, maxPrice do
    for _, tier in ipairs({ 'HOT', 'WANTED' }) do
        local m = mult(tier)
        if unitsFor(1e9, cap, streetUnit(unit, m)) < unitsFor(1e9, cap, streetUnit(unit, 1.0)) then
            cheaperDay[#cheaperDay + 1] = ('%s@%d'):format(tier, unit)
        end
    end
end
T.list('at no price does being hot let a seller spend less product on a full day',
    cheaperDay, {})

T.done()
