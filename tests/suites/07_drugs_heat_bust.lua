-- ============================================================================
-- palm6_drugs HEAT BUST: the extra police-attention roll, and how it composes
-- with the resource's own, completely separate, pre-existing dealerHeat model.
--
-- TWO MODELS, ONE OUTCOME. Config.Heat is palm6_drugs' own transient
-- `dealerHeat` accumulator (server memory, decays on a 30s sweep, dies on
-- restart). Config.HeatBust is a term layered on top of it that reads
-- palm6_heat's DURABLE per-citizen tier. They are unrelated models and neither
-- feeds the other. The layering rule the code implements is that the durable
-- roll only happens when the dealerHeat model did NOT already flag, so the
-- durable term can push the bust rate UP and can never pull it down, and the
-- same event is never counted twice.
--
-- That rule is a claim about CONTROL FLOW, so it is tested as one: math.random
-- is replaced by a scripted sequence and the DRAWS ARE COUNTED. If the extra
-- roll ever fires after the base model already flagged, the draw count changes
-- and these assertions fail.
--
-- The flag ships DISABLED. Nothing here runs live today.
--
-- HOW THE CODE IS REACHED
-- assessSaleHeat, assessCookHeat and heatBustExtra are `local function`s inside
-- a 2,290-line server file that opens MySQL connections. Their exact production
-- text is lifted by anchor and compiled inside one factory that supplies the
-- three things they read from their enclosing scope: Config, the `dealerHeat`
-- table, and math.random. Nothing is reimplemented.
--
-- NOT TESTED HERE: what a flagged event then DOES (Bridge.PoliceAlert, the
-- palm6_evidence case, the sales-ledger INSERT), the dealerHeat decay sweep
-- thread, and heatTierOf's live export read. README lists them.
-- ============================================================================
T.begin('palm6_drugs heat bust probability and its composition')

local DRUGS = 'resources/[custom]/palm6_drugs/'
local MAIN  = DRUGS .. 'server/main.lua'
local HEATMAIN = 'resources/[custom]/palm6_heat/server/main.lua'

T.loadFile('resources/[custom]/palm6_heat/shared/config.lua')
local heatConfig = Config
local HEAT_TIERS, HEAT_TIER_SET = {}, {}
for _, t in ipairs(heatConfig.Tiers) do
    HEAT_TIERS[#HEAT_TIERS + 1] = t.tier
    HEAT_TIER_SET[t.tier] = true
end
Config = nil

vector3 = function(x, y, z) return { x = x, y = y, z = z } end
T.loadFile(DRUGS .. 'shared/config.lua')

local HB = Config.HeatBust
local CH = Config.Heat

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.isfalse('the extra bust roll still ships dark', HB.Enabled)
T.istrue('and when it is on it covers cooks too', HB.ApplyToCook)
T.near('WARM extra chance', HB.ExtraChance.WARM, 0.04)
T.near('HOT extra chance', HB.ExtraChance.HOT, 0.10)
T.near('WANTED extra chance', HB.ExtraChance.WANTED, 0.20)
T.near('the pre-existing flat witness chance on a sale', CH.WitnessBaseChance, 0.03)
T.near('the pre-existing flat alert chance on a cook', CH.CookAlertChance, 0.18)
T.near('the pre-existing accumulated-heat alert ceiling', CH.AlertChanceMax, 0.50)
T.eq('the dealerHeat alert threshold', CH.AlertThreshold, 50.0)
T.eq('heat added per sale', CH.PerSale, 6.0)
T.eq('heat added per cook', CH.PerCook, 12.0)

-- Every extra chance must already be a probability in the config as shipped.
local outOfRange = {}
for tier, c in pairs(HB.ExtraChance) do
    if not (c >= 0.0 and c <= 1.0) then outOfRange[#outOfRange + 1] = tier end
end
T.list('every shipped ExtraChance is a probability in [0,1]', outOfRange, {})

-- A key that is not a real palm6_heat tier can never match, so the extra risk
-- it describes would silently never apply.
local unknownKeys = {}
for tier in pairs(HB.ExtraChance) do
    if not HEAT_TIER_SET[tier] then unknownKeys[#unknownKeys + 1] = tier end
end
T.list('every ExtraChance key is a real palm6_heat tier name', unknownKeys, {})

-- ---------------------------------------------------------------------------
-- Lift everything, in one factory. `randFn(n)` is called for the n-th draw, so
-- a test scripts the exact sequence of rolls a sale or a cook will see, and
-- `draws()` reports how many the production code actually consumed.
-- ---------------------------------------------------------------------------
local heatBlock  = T.slice(MAIN,
    'local HeatPrice = Config.HeatStreetPrice or {}', 'local function normQuality(q)')
local assessSale = T.slice(MAIN,
    'local function assessSaleHeat(cid, heatTier)', '-- Open/append a palm6_evidence v2 case')
local assessCook = T.slice(MAIN,
    'local function assessCookHeat(cid, heatTier)', '-- Burner snapshot for the client menu')

T.contains('sale slice warms dealerHeat', assessSale, 'dealerHeat[cid] = (dealerHeat[cid] or 0.0) + Config.Heat.PerSale')
T.contains('sale slice rolls the flat witness chance first', assessSale, 'Config.Heat.WitnessBaseChance')
T.contains('sale slice rolls the durable-heat extra last', assessSale, 'local extra = heatBustExtra(heatTier)')
T.contains('cook slice warms dealerHeat', assessCook, 'dealerHeat[cid] = (dealerHeat[cid] or 0.0) + Config.Heat.PerCook')
T.contains('cook slice rolls the flat cook chance first', assessCook, 'Config.Heat.CookAlertChance')
T.contains('cook slice rolls the durable-heat extra last', assessCook, 'local extra = heatBustExtra(heatTier)')
T.notcontains('sale slice pulled in no MySQL', assessSale, 'MySQL')
T.notcontains('sale slice pulled in no Bridge call', assessSale, 'Bridge.')
T.notcontains('cook slice pulled in no MySQL', assessCook, 'MySQL')
T.notcontains('cook slice pulled in no Bridge call', assessCook, 'Bridge.')

-- Structural pin: the ORDER of the three gates is what makes the layering claim
-- true. The durable-heat term must be the LAST thing consulted in both.
local src = T.source(MAIN)
local saleWitnessAt = src:find('if math.random() < Config.Heat.WitnessBaseChance then return true end', 1, true)
local saleExtraAt   = src:find('local extra = heatBustExtra(heatTier)', 1, true)
T.lt('on a sale the pre-existing witness roll runs before the durable-heat roll',
    saleWitnessAt, saleExtraAt)

local buildFactory = T.chunk('palm6_drugs bust assessment', table.concat({
    'local Config, randFn = ...',
    'local __draws = 0',
    'local math = setmetatable({ random = function()',
    '    __draws = __draws + 1',
    '    return randFn(__draws)',
    'end }, { __index = math })',
    'local dealerHeat = {}',
    heatBlock,
    assessSale,
    assessCook,
    'return {',
    '  sale = assessSaleHeat, cook = assessCookHeat, heat = dealerHeat,',
    '  extra = heatBustExtra,',
    '  draws = function() return __draws end,',
    '  reset = function() __draws = 0 end,',
    '}',
}, '\n'))

-- A sequence-driven build: draw n returns seq[n], or 1.0 (a value no `<`
-- comparison against a probability can pass) once the script runs out.
local function withRolls(seq)
    return buildFactory(Config, function(n) return seq[n] or 1.0 end)
end

-- ---------------------------------------------------------------------------
T.section('heatBustExtra: bounded to a probability at every tier')
local M = withRolls({})
local offNonZero = {}
for _, tier in ipairs(HEAT_TIERS) do
    if M.extra(tier) ~= 0.0 then offNonZero[#offNonZero + 1] = tier end
end
T.list('with the flag off every tier adds exactly zero extra risk', offNonZero, {})

Config.HeatBust.Enabled = true
M = withRolls({})
T.near('CLEAN is absent from the table: no extra risk', M.extra('CLEAN'), 0.0)
T.near('COOL is absent from the table: no extra risk', M.extra('COOL'), 0.0)
T.near('WARM adds 4 points of bust chance', M.extra('WARM'), 0.04)
T.near('HOT adds 10 points', M.extra('HOT'), 0.10)
T.near('WANTED adds 20 points', M.extra('WANTED'), 0.20)
T.near('an unreadable tier (nil) adds nothing', M.extra(nil), 0.0)
T.near('a numeric tier adds nothing', M.extra(7), 0.0)
T.near('an unknown tier string adds nothing', M.extra('FRIGID'), 0.0)

-- Every tier, at every heat value from clean to the cap, must land inside
-- [0,1] and must never reach certainty.
local heatPure = T.slice(HEATMAIN,
    'local function decayed(storedHeat, ageSec)', '-- Boot: self-create the table.')
local tierOfRow = T.chunk('palm6_heat tierOf',
    'local Config = ...\n' .. heatPure .. '\nreturn tierOf\n')(heatConfig)
local function tierOf(heat) return tierOfRow(heat).tier end

local badExtra, certain = {}, {}
for heat = 0, heatConfig.HeatCap do
    local e = M.extra(tierOf(heat))
    if not (e >= 0.0 and e <= 1.0) then badExtra[#badExtra + 1] = ('%d'):format(heat) end
    if e >= 1.0 then certain[#certain + 1] = ('%d'):format(heat) end
end
T.list('the extra chance is a valid probability at every heat value', badExtra, {})
T.list('and no heat value makes the extra roll a certainty', certain, {})

-- ---------------------------------------------------------------------------
T.section('extra-chance tier boundaries, from BOTH sides')
T.near('29 heat is the last COOL point: no extra risk', M.extra(tierOf(29)), 0.0)
T.near('30 heat is the first WARM point: risk starts', M.extra(tierOf(30)), 0.04)
T.near('64 heat is the last WARM point', M.extra(tierOf(64)), 0.04)
T.near('65 heat is the first HOT point', M.extra(tierOf(65)), 0.10)
T.near('109 heat is the last HOT point', M.extra(tierOf(109)), 0.10)
T.near('110 heat is the first WANTED point', M.extra(tierOf(110)), 0.20)
T.near('at the heat cap the extra chance is still WANTED', M.extra(tierOf(heatConfig.HeatCap)), 0.20)

-- Monotonic: getting hotter must never LOWER the bust chance.
local fell, prev = {}, nil
for heat = 0, heatConfig.HeatCap do
    local e = M.extra(tierOf(heat))
    if prev ~= nil and e < prev then fell[#fell + 1] = ('%d'):format(heat) end
    prev = e
end
T.list('getting hotter never lowers the extra bust chance', fell, {})

-- ---------------------------------------------------------------------------
T.section('the clamps: no config value can produce a certainty or a negative')
Config.HeatBust.ExtraChance.WANTED = 5.0
M = withRolls({})
T.near('a chance above 1.0 is clamped to 1.0', M.extra('WANTED'), 1.0)
Config.HeatBust.ExtraChance.WANTED = math.huge
M = withRolls({})
T.near('an infinite chance is clamped to 1.0', M.extra('WANTED'), 1.0)
Config.HeatBust.ExtraChance.WANTED = -3.0
M = withRolls({})
T.near('a negative chance is clamped to 0.0', M.extra('WANTED'), 0.0)
Config.HeatBust.ExtraChance.WANTED = '0.35'
M = withRolls({})
T.near('a stringified number is coerced, not rejected', M.extra('WANTED'), 0.35)
Config.HeatBust.ExtraChance.WANTED = {}
M = withRolls({})
T.near('a table is unreadable and adds nothing', M.extra('WANTED'), 0.0)

-- NaN is the one input neither clamp catches. Recorded, not fixed: both call
-- sites gate on `extra > 0.0`, which is false for NaN, so a NaN degrades to
-- "no extra roll" rather than to a wrong probability.
Config.HeatBust.ExtraChance.WANTED = 0.0 / 0.0
M = withRolls({})
T.isnan('a NaN chance survives both clamps', M.extra('WANTED'))
T.isfalse('but the caller gate `extra > 0.0` is false for NaN, so the roll is skipped',
    M.extra('WANTED') > 0.0)

Config.HeatBust.ExtraChance.WANTED = 0.20  -- restore the shipped value

-- ---------------------------------------------------------------------------
T.section('composition: the durable roll only fires when the base model declined')
-- dealerHeat is pre-loaded to 94 so that after the +6 a sale adds it sits at
-- exactly 100: over = 50, chance = min(0.50, 50/50 * 0.50) = 0.50. That makes
-- all three gates live at once, which is the only state where double-counting
-- could show up.
local CID = 'ABC12345'
local function saleWith(seq, preHeat, tier)
    local m = withRolls(seq)
    m.heat[CID] = preHeat
    m.reset()
    local flagged = m.sale(CID, tier)
    return flagged, m.draws(), m.heat[CID]
end

local flagged, draws, after = saleWith({ 0.02 }, 94.0, 'WANTED')
T.istrue('the flat witness roll alone can flag a sale', flagged)
T.eq('and it consumed exactly ONE draw: the durable roll never happened', draws, 1)
T.eq('heat is added regardless of the roll', after, 100.0)

flagged, draws = saleWith({ 0.50, 0.49 }, 94.0, 'WANTED')
T.istrue('the accumulated-dealerHeat roll can flag a sale', flagged)
T.eq('and it consumed exactly TWO draws: the durable roll never happened', draws, 2)

flagged, draws = saleWith({ 0.50, 0.50, 0.19 }, 94.0, 'WANTED')
T.istrue('only after BOTH pre-existing gates decline does the durable roll fire', flagged)
T.eq('which is the third and last draw', draws, 3)

flagged, draws = saleWith({ 0.50, 0.50, 0.20 }, 94.0, 'WANTED')
T.isfalse('and it can decline too: 0.20 is not < 0.20', flagged)
T.eq('still exactly three draws, never a fourth', draws, 3)

-- Below the dealerHeat threshold the middle gate does not exist at all, so the
-- durable roll is the SECOND draw. This is the common case: an occasional
-- seller who is nonetheless WANTED.
flagged, draws = saleWith({ 0.50, 0.19 }, 0.0, 'WANTED')
T.istrue('a cold dealer who is WANTED can still be flagged by the durable roll', flagged)
T.eq('with the dealerHeat gate skipped entirely, that is two draws', draws, 2)

flagged, draws = saleWith({ 0.50, 0.21 }, 0.0, 'WANTED')
T.isfalse('and declines when the roll misses', flagged)
T.eq('two draws', draws, 2)

-- A tier with no entry costs no draw at all: `extra > 0.0` gates the roll.
flagged, draws = saleWith({ 0.50 }, 0.0, 'CLEAN')
T.isfalse('a CLEAN seller is not flagged by a durable roll', flagged)
T.eq('and a zero extra chance does not even spend a draw', draws, 1)

flagged, draws = saleWith({ 0.50 }, 0.0, nil)
T.isfalse('an unreadable tier is not flagged', flagged)
T.eq('and spends no extra draw either', draws, 1)

-- ---------------------------------------------------------------------------
T.section('the durable term can only ever RAISE the bust rate, never lower it')
-- Swept over a grid of every draw sequence the three gates can see. If any
-- sequence flags with the flag OFF but not with it ON, the layering inverted.
local lowered, sequences = {}, 0
local grid = {}
for i = 0, 20 do grid[#grid + 1] = i / 20 end
for _, r1 in ipairs(grid) do
    for _, r2 in ipairs(grid) do
        for _, r3 in ipairs(grid) do
            for _, preHeat in ipairs({ 0.0, 94.0 }) do
                sequences = sequences + 1
                Config.HeatBust.Enabled = false
                local offFlag = select(1, saleWith({ r1, r2, r3 }, preHeat, 'WANTED'))
                Config.HeatBust.Enabled = true
                local onFlag = select(1, saleWith({ r1, r2, r3 }, preHeat, 'WANTED'))
                if offFlag and not onFlag then
                    lowered[#lowered + 1] = ('%.2f/%.2f/%.2f@%.0f'):format(r1, r2, r3, preHeat)
                end
            end
        end
    end
end
T.eq('the sweep really covered every combination', sequences, 21 * 21 * 21 * 2)
T.list('no draw sequence is flagged with the term off but clean with it on', lowered, {})

-- ---------------------------------------------------------------------------
T.section('each gate\'s threshold, measured out of the production code exactly')
-- No statistics here. Each gate is `math.random() < threshold`, so the exact
-- threshold is recoverable by bisecting the draw value that gate sees while
-- holding the other draws at 1.0, which no `<` against a probability can pass.
-- The numbers below are therefore READ OUT of the shipped code, not asserted
-- against a formula this file wrote.
local function bisect(place, preHeat, tier)
    local lo, hi = 0.0, 1.0
    for _ = 1, 60 do
        local mid = (lo + hi) / 2
        local seq = { 1.0, 1.0, 1.0 }
        seq[place] = mid
        local m = withRolls(seq)
        m.heat[CID] = preHeat
        if m.sale(CID, tier) then lo = mid else hi = mid end
    end
    return hi
end
T.near('gate 1 is the flat witness chance', bisect(1, 0.0, 'CLEAN'), CH.WitnessBaseChance, 1e-9)
T.near('gate 2 at a saturated dealer is the AlertChanceMax ceiling',
    bisect(2, 94.0, 'CLEAN'), CH.AlertChanceMax, 1e-9)
T.near('gate 3 for a WANTED seller is the shipped extra chance',
    bisect(3, 94.0, 'WANTED'), HB.ExtraChance.WANTED, 1e-9)
-- Half-saturated: dealerHeat 69 + 6 = 75, over = 25, chance = 25/50 * 0.50 = 0.25.
T.near('gate 2 scales linearly with heat above the threshold',
    bisect(2, 69.0, 'CLEAN'), 0.25, 1e-9)
-- Exactly AT the threshold there is no roll at all: over = 0, chance = 0, and
-- `math.random() < 0` is false for every value math.random can return. Asserted
-- with a direct draw of 0.0 rather than by bisection, which can only ever
-- converge toward zero and never reach it.
local atThreshold = withRolls({ 1.0, 0.0, 1.0 })
atThreshold.heat[CID] = 44.0
T.isfalse('at exactly the dealerHeat threshold gate 2 can never fire, even on a 0.0 roll',
    atThreshold.sale(CID, 'CLEAN'))
T.lt('and bisection confirms its threshold is zero', bisect(2, 44.0, 'CLEAN'), 1e-15)

-- ---------------------------------------------------------------------------
T.section('the composed bust rate is bounded well below certainty')
-- The three gates are independent draws, so the composed rate is
--   P = w + (1-w) * ( a + (1-a) * e )
-- with the three thresholds measured directly above. Sale, dealerHeat
-- saturated, WANTED, term ON:
--   0.03 + 0.97 * (0.50 + 0.50 * 0.20) = 0.03 + 0.582 = 0.612
-- Term OFF the same state is 0.03 + 0.97 * 0.50 = 0.515.
--
-- Measured by running the real production function against a deterministic
-- L'Ecuyer combined generator. Fixed seed and float-only arithmetic, so the
-- result is bit-identical on every run: this cannot go flaky. (fengari's 64-bit
-- integer and bitwise behaviour is unreliable, which rules out the usual
-- xorshift/splitmix generators; every product here stays under 2^53 and is
-- therefore exact in a double.)
local function rng(seed)
    local s1 = 1.0 + (seed % 2147483562.0)
    local s2 = 1.0 + ((seed * 7.0 + 13.0) % 2147483398.0)
    return function()
        s1 = (40014.0 * s1) % 2147483563.0
        s2 = (40692.0 * s2) % 2147483399.0
        local z = (s1 - s2) % 2147483562.0
        return (z + 1.0) / 2147483563.0
    end
end

local N = 60000
local function rate(fn, preHeat, tier)
    local r = rng(20260729.0)
    local m = buildFactory(Config, function() return r() end)
    local hit = 0
    for i = 1, N do
        m.heat[CID] = preHeat
        if fn(m)(CID, tier) then hit = hit + 1 end
    end
    return hit / N
end
local saleFn = function(m) return m.sale end
local cookFn = function(m) return m.cook end

Config.HeatBust.Enabled = true
local onSaturated = rate(saleFn, 94.0, 'WANTED')
Config.HeatBust.Enabled = false
local offSaturated = rate(saleFn, 94.0, 'WANTED')
Config.HeatBust.Enabled = true

T.near('a WANTED seller on a saturated dealer busts at the composed 0.612',
    onSaturated, 0.612, 0.01)
T.near('with the term off the same state is 0.515', offSaturated, 0.515, 0.01)
T.lt('so flipping the flag on strictly raises the rate', offSaturated, onSaturated)
T.lt('and even the worst case is far from a certainty', onSaturated, 0.70)

local onCold = rate(saleFn, 0.0, 'WANTED')
T.near('a WANTED seller with no dealerHeat busts at 0.03 + 0.97*0.20 = 0.224',
    onCold, 0.224, 0.01)
local cleanCold = rate(saleFn, 0.0, 'CLEAN')
T.near('a CLEAN seller with no dealerHeat busts at the flat witness 0.03',
    cleanCold, 0.03, 0.01)
T.lt('being WANTED costs a seller real bust risk', cleanCold, onCold)

-- ---------------------------------------------------------------------------
T.section('cooks: the same layering, a louder base rate')
local cookOn = rate(cookFn, 88.0, 'WANTED')   -- 88 + PerCook 12 = 100, chance 0.50
Config.HeatBust.Enabled = false
local cookOff = rate(cookFn, 88.0, 'WANTED')
Config.HeatBust.Enabled = true
-- 0.18 + 0.82 * (0.50 + 0.50 * 0.20) = 0.18 + 0.492 = 0.672
T.near('a WANTED cook on a saturated lab busts at the composed 0.672', cookOn, 0.672, 0.01)
T.near('with the term off the same cook is 0.18 + 0.82*0.50 = 0.59', cookOff, 0.59, 0.01)
T.lt('the durable term raises the cook rate too', cookOff, cookOn)
T.lt('and the loudest possible cook is still not a certainty', cookOn, 0.75)

local function cookWith(seq, preHeat, tier)
    local m = withRolls(seq)
    m.heat[CID] = preHeat
    m.reset()
    local f = m.cook(CID, tier)
    return f, m.draws(), m.heat[CID]
end
local cf, cd, cafter = cookWith({ 0.17 }, 88.0, 'WANTED')
T.istrue('the flat cook chance alone can flag a cook', cf)
T.eq('and consumes exactly one draw', cd, 1)
T.eq('cook heat is added regardless of the roll', cafter, 100.0)
cf, cd = cookWith({ 0.50, 0.50, 0.19 }, 88.0, 'WANTED')
T.istrue('the durable roll is the cook path\'s last gate too', cf)
T.eq('three draws, never more', cd, 3)

-- ApplyToCook is the sub-flag: with it off the caller passes nil as the tier,
-- so the cook path spends no extra roll. That call site is lifted verbatim.
local cookTierLine = T.line(MAIN,
    'local cookTier = (HeatBust.Enabled and HeatBust.ApplyToCook) and heatTierOf(cid) or nil')
T.contains('the cook tier read is gated on BOTH flags', cookTierLine, 'HeatBust.ApplyToCook')
local cookTierFor = T.chunk('palm6_drugs cook tier gate',
    'local HeatBust, heatTierOf, cid = ...\n' .. cookTierLine .. '\nreturn cookTier\n')
T.isnil('with ApplyToCook off the cook path reads no tier at all',
    cookTierFor({ Enabled = true, ApplyToCook = false }, function() return 'WANTED' end, CID))
T.eq('with both flags on it reads the real tier',
    cookTierFor({ Enabled = true, ApplyToCook = true }, function() return 'WANTED' end, CID), 'WANTED')
T.isnil('with the whole feature off it reads no tier',
    cookTierFor({ Enabled = false, ApplyToCook = true }, function() return 'WANTED' end, CID))
cf, cd = cookWith({ 0.50, 0.50, 0.19 }, 88.0, nil)
T.isfalse('and a nil tier means the third gate never opens', cf)
T.eq('so a cook with ApplyToCook off spends only two draws', cd, 2)

-- ---------------------------------------------------------------------------
T.section('a bust is a pure cost, so there is nothing here to farm')
-- The only two outcomes of a flag are a police alert and an evidence case that
-- names the actor. Neither is something a player can want more of, and the
-- money side of the same sale is covered by 06_drugs_heat_price. This is a
-- structural check that the flagged branch grants nothing.
local sellFlagged = T.slice(MAIN,
    'local flagged = assessSaleHeat(cid, saleTier)',
    'The daily dirty-money faucet cap is enforced by SUMming this table')
T.contains('a flagged sale raises a police alert', sellFlagged, 'Bridge.PoliceAlert')
T.contains('and files an evidence case naming the seller', sellFlagged, 'fileEvidence(cid')
T.notcontains('a flagged sale grants no item', sellFlagged, 'GiveItem')
T.notcontains('a flagged sale grants no money', sellFlagged, 'CreditBank')
T.notcontains('a flagged sale grants no XP', sellFlagged, 'addXp')

T.done()
