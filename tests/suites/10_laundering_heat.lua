-- ============================================================================
-- palm6_laundering PLAYER HEAT and the HeatScrutiny cut.
--
-- THIS ONE IS LIVE. Unlike the drugs, chopshop and bounty heat effects, both
-- blocks in this file ship ON: Config.HeatScrutiny.Enabled = true, and the
-- amount-proportional Config.PlayerHeat replaced a flat per-run charge as a
-- default-on balance change. There is no flag to flip and no safety net; this
-- arithmetic is in players' hands today.
--
-- THE BUG THE RESHAPE EXISTED TO FIX
-- The old charge was flat per run (Base 5, +8 flagged), so per-run heat did not
-- move with the size of the wash and the CHEAPEST way to move a haul was the
-- fewest, largest runs. Against the $75,000 daily cap, three $25,000 runs cost
-- 15 heat while the same money through 150 minimum-size runs cost 750. That is
-- the exact inverse of the design intent stated at the top of the config file
-- ("laundering small and slow is the safe play"). The reshape made the charge
-- amount-proportional with a Base floor. The property that fix bought is:
--
--   SPLITTING A HAUL INTO MORE RUNS MUST NEVER COST LESS TOTAL HEAT.
--
-- That is pinned here by sweep, and then PROVED FALLIBLE by zeroing Base and
-- showing the invariant inverts again, which also demonstrates that the Base
-- floor is the load-bearing term rather than decoration.
--
-- HOW THE CODE IS REACHED
-- playerHeatFor, heatScrutiny and assessHeat are `local function`s inside a
-- server file that opens MySQL connections and registers chat commands. Their
-- exact production text is lifted by anchor. heatScrutiny's two cross-resource
-- calls (GetResourceState and the frozen exports.palm6_heat:GetTier) are
-- stubbed; assessHeat's math.random is scripted so the roll is an input.
--
-- NOT TESTED HERE: cmdLaunder as a whole (the warrant gate, ox_inventory item
-- removal, Bridge.CreditBank, the runs INSERT, the evidence case), the
-- dirtyWashedToday daily sum, and the front-heat decay thread. README lists them.
-- ============================================================================
T.begin('palm6_laundering player heat and the scrutiny cut')

local LAUN = 'resources/[custom]/palm6_laundering/'
local MAIN = LAUN .. 'server/main.lua'

T.loadFile('resources/[custom]/palm6_heat/shared/config.lua')
local heatConfig = Config
local HEAT_TIERS, HEAT_TIER_SET = {}, {}
for _, t in ipairs(heatConfig.Tiers) do
    HEAT_TIERS[#HEAT_TIERS + 1] = t.tier
    HEAT_TIER_SET[t.tier] = true
end
Config = nil

-- The laundromat coords are declared with vector3, a FiveM native. Stubbed as a
-- plain table: nothing here reads a coordinate.
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
T.loadFile(LAUN .. 'shared/config.lua')

local PH = Config.PlayerHeat
local HS = Config.HeatScrutiny

-- ---------------------------------------------------------------------------
T.section('shipped config is what these tests assume')
T.istrue('the scrutiny cut ships ON, unlike every other heat consequence', HS.Enabled)
T.near('the standing laundering fee', Config.Cut, 0.30)
T.eq('the smallest wash worth doing', Config.MinPerRun, 500)
T.eq('the largest single wash', Config.MaxPerRun, 25000)
T.eq('the daily ceiling', Config.DailyCap, 75000)
T.near('HOT pays an extra 10 points of skim', HS.ExtraCut.HOT, 0.10)
T.near('WANTED pays an extra 20 points', HS.ExtraCut.WANTED, 0.20)
T.near('WARM pays nothing extra yet', HS.ExtraCut.WARM, 0.0)
T.eq('the Refuse list ships empty, so nobody is turned away at the door',
    next(HS.Refuse), nil)
T.eq('player heat base floor per run', PH.Base, 1)
T.near('player heat per $1,000 washed', PH.PerThousand, 0.5)
T.eq('the per-run player-heat safety rail', PH.MaxPerRun, 15)
T.eq('the extra when the law actually noticed', PH.FlaggedBonus, 8)
T.near('front heat added per $1,000', Config.Heat.PerThousand, 3.0)
T.eq('a run this large always trips an alert', Config.Heat.BigRunAlways, 20000)
T.eq('front heat alert threshold', Config.Heat.AlertThreshold, 60.0)
T.near('front heat alert ceiling', Config.Heat.AlertChanceMax, 0.60)

local unknownKeys = {}
for tier in pairs(HS.ExtraCut) do
    if not HEAT_TIER_SET[tier] then unknownKeys[#unknownKeys + 1] = tier end
end
T.list('every ExtraCut key is a real palm6_heat tier name', unknownKeys, {})

-- ---------------------------------------------------------------------------
-- Lift heatScrutiny with the two cross-resource calls stubbed.
-- ---------------------------------------------------------------------------
local scrutinyBlock = T.slice(MAIN, 'local function heatScrutiny(cid)',
    '-- Persistent police attention this run earns its launderer')
T.contains('slice really contains heatScrutiny', scrutinyBlock, 'local function heatScrutiny(cid)')
T.contains('slice reads the tier only through the frozen export', scrutinyBlock, 'exports.palm6_heat:GetTier(cid)')
T.notcontains('slice pulled in no MySQL', scrutinyBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', scrutinyBlock, 'Bridge.')
T.notcontains('slice never queries palm6_heat_state directly', scrutinyBlock, 'palm6_heat_state')

local buildScrutiny = T.chunk('palm6_laundering heatScrutiny', table.concat({
    'local Config, stateFn, tierFn, bump = ...',
    'local GetResourceState = function(res) return stateFn(res) end',
    'local exports = { palm6_heat = { GetTier = function(_, cid) bump() ; return tierFn(cid) end } }',
    scrutinyBlock,
    'return heatScrutiny',
}, '\n'))

local exportReads = 0
local function mkScrutiny(tier, state)
    return buildScrutiny(Config, function() return state or 'started' end,
        function() if type(tier) == 'function' then return tier() end return tier end,
        function() exportReads = exportReads + 1 end)
end
local function extraOf(tier, state) return (mkScrutiny(tier, state)('LDR00001')) end
local function refusedOf(tier, state) return select(3, mkScrutiny(tier, state)('LDR00001')) end

-- ---------------------------------------------------------------------------
T.section('the extra skim each tier pays')
T.near('CLEAN is absent from the table: no surcharge', extraOf('CLEAN'), 0.0)
T.near('COOL is absent from the table: no surcharge', extraOf('COOL'), 0.0)
T.near('WARM is present but costs nothing', extraOf('WARM'), 0.0)
T.near('HOT pays 10 points more', extraOf('HOT'), 0.10)
T.near('WANTED pays 20 points more', extraOf('WANTED'), 0.20)
T.isfalse('and nobody is refused, because Refuse ships empty', refusedOf('WANTED'))

T.section('every soft-guard failure mode lands on the flat 30% fee')
exportReads = 0
T.near('palm6_heat stopped: no surcharge', extraOf('WANTED', 'stopped'), 0.0)
T.near('palm6_heat still starting: no surcharge', extraOf('WANTED', 'starting'), 0.0)
T.eq('a non-started palm6_heat is never even asked', exportReads, 0)
T.near('the export throwing: no surcharge', extraOf(function() error('down') end), 0.0)
T.near('the export returning nil: no surcharge', extraOf(nil), 0.0)
T.near('the export returning a number: no surcharge', extraOf(3), 0.0)
T.near('an unknown tier string: no surcharge', extraOf('FRIGID'), 0.0)
T.isnil('and an unreadable tier is reported as no tier at all',
    select(2, mkScrutiny(nil)('LDR00001')))

Config.HeatScrutiny.Enabled = false
T.near('the whole block can be switched off wholesale', extraOf('WANTED'), 0.0)
T.isnil('and reports no tier when off', select(2, mkScrutiny('WANTED')('LDR00001')))
Config.HeatScrutiny.Enabled = true

T.section('the Refuse list turns a tier away instead of surcharging it')
Config.HeatScrutiny.Refuse.WANTED = true
T.istrue('a listed tier is refused at the door', refusedOf('WANTED'))
T.near('and is charged no surcharge, because there is no wash', extraOf('WANTED'), 0.0)
T.eq('the tier is still reported so the refusal message can name it',
    select(2, mkScrutiny('WANTED')('LDR00001')), 'WANTED')
T.isfalse('an unlisted tier is still served', refusedOf('HOT'))
Config.HeatScrutiny.Refuse.WANTED = nil
T.isfalse('and restoring the empty list serves everyone again', refusedOf('WANTED'))

-- ---------------------------------------------------------------------------
T.section('heatScrutiny reads its sub-tables UNGUARDED, unlike its three siblings')
-- palm6_drugs, palm6_chopshop and palm6_bounty all read their heat sub-tables
-- through `or {}` so that deleting the block degrades to "disabled". This one
-- does not, and it is the only one of the four that ships ENABLED. Recorded, not
-- fixed: reaching it needs a config edit, and the README writes it up.
local savedRefuse, savedExtra = Config.HeatScrutiny.Refuse, Config.HeatScrutiny.ExtraCut
Config.HeatScrutiny.Refuse = nil
T.raises('deleting Refuse makes heatScrutiny throw rather than degrade',
    function() return mkScrutiny('WANTED')('LDR00001') end)
Config.HeatScrutiny.Refuse = savedRefuse
Config.HeatScrutiny.ExtraCut = nil
T.raises('deleting ExtraCut makes heatScrutiny throw rather than degrade',
    function() return mkScrutiny('WANTED')('LDR00001') end)
Config.HeatScrutiny.ExtraCut = savedExtra
T.near('and with both restored it behaves again', extraOf('WANTED'), 0.20)

-- ---------------------------------------------------------------------------
-- Lift the cut and payout lines. The cut line appears TWICE in the file (once
-- in /launder, once in /dirtymoney) which is exactly the point: the quote and
-- the charge must be the same expression. T.line would refuse an ambiguous
-- anchor, so the charge side is taken as a slice from its unique comment.
-- ---------------------------------------------------------------------------
T.section('the cut and the clean payout')
local cutSlice = T.slice(MAIN, 'Total skim = the standing fee plus whatever the heat surcharge added',
    "if not Bridge.CreditBank(src, cleanOut, 'laundering') then")
T.contains('slice clamps the total cut', cutSlice, 'local cut = math.min(0.90, Config.Cut + extraCut)')
T.contains('slice floors the clean payout', cutSlice, 'local cleanOut = math.floor(amount * (1.0 - cut))')
T.notcontains('cut slice pulled in no MySQL', cutSlice, 'MySQL')

local washFor = T.chunk('palm6_laundering wash payout',
    'local Config = ...\nreturn function(amount, extraCut)\n' .. cutSlice
    .. '\nreturn cleanOut, cut\nend\n')(Config)

-- The quote path must compute the fee identically or a hot launderer is quoted
-- 30% and charged 40%, which reads as a bug rather than as a consequence.
local cutOccurrences = select(2,
    T.source(MAIN):gsub('local cut = math%.min%(0%.90, Config%.Cut %+ extraCut%)', ''))
T.eq('the cut expression appears in exactly two places: the charge and the quote',
    cutOccurrences, 2)

local clean, cut = washFor(10000, 0.0)
T.eq('a clean launderer washing $10,000 keeps $7,000', clean, 7000)
T.near('at the standing 30% fee', cut, 0.30)
clean, cut = washFor(10000, extraOf('HOT'))
T.eq('a HOT launderer keeps $6,000', clean, 6000)
T.near('at 40%', cut, 0.40)
clean, cut = washFor(10000, extraOf('WANTED'))
T.eq('a WANTED launderer keeps $5,000', clean, 5000)
T.near('at 50%', cut, 0.50)

T.eq('the smallest legal wash still pays out', (washFor(Config.MinPerRun, 0.0)), 350)
T.eq('and still pays out at the deepest shipped surcharge',
    (washFor(Config.MinPerRun, extraOf('WANTED'))), 250)
T.eq('the largest legal wash, clean', (washFor(Config.MaxPerRun, 0.0)), 17500)
T.eq('the largest legal wash, WANTED', (washFor(Config.MaxPerRun, extraOf('WANTED'))), 12500)

-- The 0.90 clamp is what stops a wash paying out nothing.
T.near('a surcharge that would take everything is clamped to 90%', select(2, washFor(1000, 0.95)), 0.90)
T.near('and an absurd surcharge is clamped the same way', select(2, washFor(1000, 50.0)), 0.90)
-- 1.0 - 0.90 is 0.09999999999999998 in IEEE double, not 0.1, so the clamped
-- payout lands one dollar under the decimal answer. Pinned rather than rounded
-- away: the shortfall goes to the house, the same direction every other
-- truncation in this file goes, and the clamp is unreachable at shipped values
-- (the deepest surcharge is 0.20, giving a 0.50 cut).
T.eq('at the clamp a $1,000 wash returns $99, not $100, thanks to binary floating point',
    (washFor(1000, 5.0)), 99)
T.eq('and the minimum legal wash returns $49 at the clamp',
    (washFor(Config.MinPerRun, 5.0)), 49)
T.eq('while the deepest SHIPPED surcharge lands exactly',
    (washFor(1000, extraOf('WANTED'))), 500)

-- Swept: a payout is never negative and never exceeds what was handed over.
local negativeOut, overIn, zeroOut = {}, {}, {}
for _, extra in ipairs({ 0.0, 0.10, 0.20, 0.60, 5.0 }) do
    for amount = 0, Config.MaxPerRun, 25 do
        local out = washFor(amount, extra)
        if out < 0 then negativeOut[#negativeOut + 1] = ('%.2f@%d'):format(extra, amount) end
        if out > amount then overIn[#overIn + 1] = ('%.2f@%d'):format(extra, amount) end
        if amount >= Config.MinPerRun and out <= 0 then
            zeroOut[#zeroOut + 1] = ('%.2f@%d'):format(extra, amount)
        end
    end
end
T.list('a wash never pays out a negative amount', negativeOut, {})
T.list('a wash never pays out more than was handed over', overIn, {})
T.list('and no legal wash ever pays out nothing', zeroOut, {})
T.eq('a $0 wash pays $0, which the MinPerRun gate makes unreachable',
    (washFor(0, 0.20)), 0)

-- The ledger records the cut that was actually charged, in basis points.
local bpsLine = T.line(MAIN, "{ cid, amount, cleanOut, math.floor(cut * 10000 + 0.5), flagged and 1 or 0, caseId })")
T.contains('the run row stores the real cut in basis points', bpsLine, 'math.floor(cut * 10000 + 0.5)')
local bpsFor = T.chunk('palm6_laundering fee bps',
    'return function(cut) return math.floor(cut * 10000 + 0.5) end')()
T.eq('a clean wash is recorded as 3000 bps', bpsFor(select(2, washFor(1000, 0.0))), 3000)
T.eq('a HOT wash is recorded as 4000 bps', bpsFor(select(2, washFor(1000, extraOf('HOT')))), 4000)
T.eq('a WANTED wash is recorded as 5000 bps', bpsFor(select(2, washFor(1000, extraOf('WANTED')))), 5000)

-- ---------------------------------------------------------------------------
-- Lift playerHeatFor.
-- ---------------------------------------------------------------------------
T.section('the amount-proportional player heat charge')
local phBlock = T.slice(MAIN, 'local function playerHeatFor(amount, flagged)',
    '-- Open/append an evidence case for a flagged run')
T.contains('slice really contains playerHeatFor', phBlock, 'local function playerHeatFor(amount, flagged)')
T.contains('slice reads every key guarded', phBlock, 'tonumber(H.Base) or 0')
T.contains('slice scales with the amount', phBlock, "(amount / 1000.0) * (tonumber(H.PerThousand) or 0)")
T.notcontains('slice pulled in no MySQL', phBlock, 'MySQL')
T.notcontains('slice pulled in no Bridge call', phBlock, 'Bridge.')

-- Config is read INSIDE the function on every call, so a config mutation takes
-- effect without rebuilding. That is what makes the falsification below honest.
local playerHeatFor = T.chunk('palm6_laundering playerHeatFor',
    'local Config = ...\n' .. phBlock .. '\nreturn playerHeatFor\n')(Config)

-- floor(1 + amount/1000 * 0.5)
T.eq('the minimum wash scores 1', playerHeatFor(500, false), 1)
T.eq('a $1,000 wash still scores 1 (1 + 0.5 floors to 1)', playerHeatFor(1000, false), 1)
T.eq('a $2,000 wash scores 2', playerHeatFor(2000, false), 2)
T.eq('a $10,000 wash scores 6', playerHeatFor(10000, false), 6)
T.eq('the largest legal wash scores 13', playerHeatFor(Config.MaxPerRun, false), 13)
T.eq('a flagged run adds the bonus on top', playerHeatFor(Config.MaxPerRun, true), 21)
T.eq('a flagged minimum wash', playerHeatFor(500, true), 9)
T.eq('a zero wash still scores the Base floor', playerHeatFor(0, false), 1)

-- The config comment calls MaxPerRun a safety rail rather than an active guard.
-- Verified rather than believed.
T.lt('at the largest legal wash the cap does not bind',
    playerHeatFor(Config.MaxPerRun, false), PH.MaxPerRun)
T.eq('$28,000 would reach the cap exactly, still without binding',
    playerHeatFor(28000, false), 15)
T.eq('$30,000 is the first size the cap actually holds down',
    playerHeatFor(30000, false), 15)
T.eq('without the cap $30,000 would have scored 16',
    math.floor(PH.Base + (30000 / 1000.0) * PH.PerThousand), 16)
T.lt('and $30,000 is above the per-run dollar ceiling, so the cap is unreachable today',
    Config.MaxPerRun, 30000)
-- FlaggedBonus rides ON TOP of the cap: "the law noticed" is a separate fact
-- from size, so it is added after the clamp.
T.eq('the flagged bonus is added after the cap, so it can exceed it',
    playerHeatFor(30000, true), 23)
T.lt('which is above the per-run cap', PH.MaxPerRun, playerHeatFor(30000, true))

-- Never negative, always a whole number, always at least Base.
local belowBase, notWhole = {}, {}
for amount = 0, Config.MaxPerRun, 10 do
    local h = playerHeatFor(amount, false)
    if h < PH.Base then belowBase[#belowBase + 1] = ('%d'):format(amount) end
    if math.type(h) ~= 'integer' then notWhole[#notWhole + 1] = ('%d'):format(amount) end
end
T.list('no wash size scores below the Base floor', belowBase, {})
T.list('and every charge is a whole number of heat', notWhole, {})

-- ---------------------------------------------------------------------------
T.section('THE DESIGN INTENT: many small runs must not be the cheap way')
-- Total heat to move D dollars in k equal runs, each of a legal size.
local function totalHeat(D, k) return k * playerHeatFor(D / k, false) end

-- The two strategies the config comment names, recomputed from the production
-- function rather than copied out of the prose.
T.eq('three $25,000 runs cost 39 heat in total', totalHeat(75000, 3), 39)
T.eq('the same $75,000 through 150 minimum runs costs 150', totalHeat(75000, 150), 150)
T.lt('so minimum-size splitting is far more expensive, as intended',
    totalHeat(75000, 3), totalHeat(75000, 150))

-- The old flat model made 150 small runs cost 750 against 15 for three big
-- ones, a 50x penalty for doing it the loud way. The reshape inverted that
-- ordering. Pinned as a ratio so a retune that quietly erodes it is visible.
T.ge('minimum-size splitting costs at least 3x the fewest-runs strategy',
    totalHeat(75000, 150) / totalHeat(75000, 3), 3.0)

-- Swept over every haul the daily cap allows: dumping it in minimum-size runs
-- must always cost strictly more than dumping it in the fewest possible runs.
-- This is the property the reshape existed to buy.
local minSizeCheaper, hauls = {}, 0
for D = 1000, Config.DailyCap, 500 do
    if D % Config.MinPerRun == 0 then
        hauls = hauls + 1
        local fewestK = math.ceil(D / Config.MaxPerRun)
        local fewest = fewestK * playerHeatFor(D / fewestK, false)
        local allSmall = (D / Config.MinPerRun) * playerHeatFor(Config.MinPerRun, false)
        if allSmall <= fewest then
            minSizeCheaper[#minSizeCheaper + 1] = ('$%d: %d vs %d'):format(D, allSmall, fewest)
        end
    end
end
T.lt('the sweep really covered a lot of hauls', 100, hauls)
T.list('at no haul size is minimum-run splitting as cheap as the fewest-runs play',
    minSizeCheaper, {})

-- ---------------------------------------------------------------------------
T.section('but the guarantee is NOT monotone: a residual splitting leak (FINDING)')
-- The charge is FLOORED per run, and the discarded fraction is per run, so a
-- run size just under a $2,000 boundary is more heat-efficient per dollar than
-- a maximum-size run. That means "more runs" is not always "more heat", and
-- there are haul sizes where splitting FURTHER costs strictly LESS.
--
-- This is not the old bug back (that was a 50x inversion and it is gone), but
-- it is a real residual and the README writes it up. Pinned with exact
-- witnesses so the size of the leak cannot grow unnoticed.
T.eq('a $60,000 haul in the fewest runs (3 x $20,000) costs 33 heat',
    totalHeat(60000, 3), 33)
T.eq('the same haul in FOUR runs of $15,000 costs 32', totalHeat(60000, 4), 32)
T.eq('and in SIXTEEN runs of $3,750 it also costs 32', totalHeat(60000, 16), 32)
T.lt('so at $60,000 splitting further is strictly cheaper, which the intent says it should not be',
    totalHeat(60000, 4), totalHeat(60000, 3))
-- The smallest witness, for a reader who wants to reproduce it by hand:
-- $4,500 as 2 x $2,250 charges floor(1+1.125)=2 twice; as 3 x $1,500 it charges
-- floor(1+0.75)=1 three times.
T.eq('the smallest witness: $4,500 in two runs costs 4', totalHeat(4500, 2), 4)
T.eq('and in three runs costs 3', totalHeat(4500, 3), 3)

-- HOW BIG IS THE LEAK. An adversary search over the whole daily cap: the run
-- sizes are discovered by scanning the PRODUCTION function for the largest
-- amount that still charges each heat value (the cheapest dollar-per-heat run
-- of each cost), then a shortest-path pass finds the cheapest possible way to
-- move every haul. Nothing here re-derives the formula; it only asks the
-- shipped function which sizes are cheap.
local cheapestAtCost = {}
for size = Config.MinPerRun, Config.MaxPerRun do
    local c = playerHeatFor(size, false)
    if cheapestAtCost[c] == nil or size > cheapestAtCost[c] then cheapestAtCost[c] = size end
end
local alphabet = {}
for c, size in pairs(cheapestAtCost) do alphabet[#alphabet + 1] = size end
table.sort(alphabet)
T.lt('the search found several distinct cheap run sizes', 5, #alphabet)
T.eq('the cheapest big run is a dollar under a $24,000 boundary, not the $25,000 maximum',
    alphabet[#alphabet - 1], 23999)

local INF = math.huge
local best = { [0] = 0 }
for d = 1, Config.DailyCap do
    local b = INF
    if d >= Config.MinPerRun and d <= Config.MaxPerRun then b = playerHeatFor(d, false) end
    for _, size in ipairs(alphabet) do
        if size <= d then
            local prev = best[d - size]
            if prev ~= INF then
                local cand = prev + playerHeatFor(size, false)
                if cand < b then b = cand end
            end
        end
    end
    best[d] = b
end

local function fewestRuns(D)
    local k = math.ceil(D / Config.MaxPerRun)
    return k * playerHeatFor(D / k, false)
end

-- The per-thousand term can never be evaded, whatever the split: every run
-- charges strictly more than its own amount/2000, so every total does too.
local underFloor = {}
for D = Config.MinPerRun, Config.DailyCap do
    if best[D] ~= INF and best[D] <= D / 2000 then
        underFloor[#underFloor + 1] = ('%d'):format(D)
    end
end
T.list('no split of any haul can get below the per-thousand term', underFloor, {})

-- And the leak is bounded. The best possible split never beats the obvious
-- fewest-runs play by more than this, across every haul the daily cap allows.
local worstSaving, witness = 0.0, nil
for D = Config.MinPerRun, Config.DailyCap do
    if best[D] ~= INF then
        local f = fewestRuns(D)
        local saving = (f - best[D]) / f
        if saving > worstSaving then worstSaving, witness = saving, D end
    end
end
T.eq('the worst haul for this leak', witness, 25001)
T.eq('where the obvious play costs 14 heat', fewestRuns(25001), 14)
T.eq('and the cleverest possible split costs 13', best[25001], 13)
T.lt('so the leak is real', 0.0, worstSaving)
T.lt('and bounded to under 8% of the heat a straightforward launderer pays',
    worstSaving, 0.08)
T.eq('over the full daily cap the leak is one point of heat',
    fewestRuns(Config.DailyCap) - best[Config.DailyCap], 1)

-- ---------------------------------------------------------------------------
T.section('proving these checks can FAIL: Base is the load-bearing term')
-- A check that cannot fail is worse than none. Zeroing Base removes the floor
-- and the model reverts to the pre-reshape shape, where minimum-size runs cost
-- NOTHING. The same comparisons are re-run and are REQUIRED to break.
local savedBase = Config.PlayerHeat.Base
Config.PlayerHeat.Base = 0
T.eq('with Base 0 a minimum wash scores nothing at all', playerHeatFor(500, false), 0)
T.eq('while a full-size wash still scores 12', playerHeatFor(25000, false), 12)
T.eq('so 150 minimum runs of the daily cap would cost zero heat',
    totalHeat(75000, 150), 0)
T.lt('which is strictly cheaper than three big runs, inverting the design intent',
    totalHeat(75000, 150), totalHeat(75000, 3))
local nowCheaper = {}
for D = 1000, Config.DailyCap, 500 do
    if D % Config.MinPerRun == 0 then
        local fewestK = math.ceil(D / Config.MaxPerRun)
        local fewest = fewestK * playerHeatFor(D / fewestK, false)
        if (D / Config.MinPerRun) * playerHeatFor(Config.MinPerRun, false) <= fewest then
            nowCheaper[#nowCheaper + 1] = ('%d'):format(D)
        end
    end
end
T.lt('and the sweep above finds violations at every haul size, so it CAN fail',
    100, #nowCheaper)
Config.PlayerHeat.Base = savedBase
T.eq('Base restored, the minimum wash scores 1 again', playerHeatFor(500, false), 1)
T.eq('and the sweep is clean again',
    #(function()
        local v = {}
        for D = 1000, Config.DailyCap, 500 do
            if D % Config.MinPerRun == 0 then
                local k = math.ceil(D / Config.MaxPerRun)
                if (D / Config.MinPerRun) * playerHeatFor(Config.MinPerRun, false)
                    <= k * playerHeatFor(D / k, false) then v[#v + 1] = D end
            end
        end
        return v
    end)(), 0)

-- ---------------------------------------------------------------------------
T.section('the documented config-only reversal really does restore the old model')
-- The config file says the reshape can be reverted by pasting back
-- `{ Base = 5, FlaggedBonus = 8 }` with no code edit. Every key is read guarded
-- precisely so that paste is safe. Verified.
local shipped = Config.PlayerHeat
Config.PlayerHeat = { Base = 5, FlaggedBonus = 8 }
T.eq('the old flat charge is exactly 5 on the smallest wash', playerHeatFor(500, false), 5)
T.eq('and exactly 5 on the largest', playerHeatFor(25000, false), 5)
T.eq('and 13 when flagged', playerHeatFor(25000, true), 13)
local varied = {}
for amount = 0, 25000, 250 do
    if playerHeatFor(amount, false) ~= 5 then varied[#varied + 1] = ('%d'):format(amount) end
end
T.list('the reverted model is genuinely flat: no wash size changes it', varied, {})

-- The other documented degradations.
Config.PlayerHeat = { PerThousand = 0.5, MaxPerRun = 15, FlaggedBonus = 8 }
T.eq('an absent Base charges nothing at the floor, silently', playerHeatFor(500, false), 0)
T.eq('but still scales with size', playerHeatFor(25000, false), 12)
Config.PlayerHeat = { Base = 1, PerThousand = 0.5, FlaggedBonus = 8 }
T.eq('an absent MaxPerRun means no cap at all', playerHeatFor(100000, false), 51)
Config.PlayerHeat = shipped
T.eq('and the shipped table is restored', playerHeatFor(25000, false), 13)

-- ---------------------------------------------------------------------------
-- Lift assessHeat: the FRONT's own transient bust model, which is a completely
-- separate thing from the durable player heat above.
-- ---------------------------------------------------------------------------
T.section('front heat: the bust roll, and why small-and-slow is genuinely safer')
local assessBlock = T.slice(MAIN, 'local function assessHeat(amount)',
    '-- Persistent-heat scrutiny at the front')
T.contains('slice really contains assessHeat', assessBlock, 'local function assessHeat(amount)')
T.contains('slice warms the front proportionally to the amount', assessBlock,
    'frontHeat = frontHeat + (amount / 1000.0) * Config.Heat.PerThousand')
T.contains('slice has an always-trips size', assessBlock, 'Config.Heat.BigRunAlways')
T.notcontains('assessHeat slice pulled in no MySQL', assessBlock, 'MySQL')
T.notcontains('assessHeat slice pulled in no Bridge call', assessBlock, 'Bridge.')

local buildAssess = T.chunk('palm6_laundering assessHeat', table.concat({
    'local Config, randFn = ...',
    'local frontHeat = 0.0',
    'local math = setmetatable({ random = function() return randFn() end }, { __index = math })',
    assessBlock,
    'return assessHeat, function() return frontHeat end, function(v) frontHeat = v end',
}, '\n'))
local function mkAssess(roll)
    return buildAssess(Config, function() return roll end)
end

local assess, getFront, setFront = mkAssess(0.99)
T.isfalse('a small wash on a cold front does not trip', assess(500))
T.near('but it does warm the front', getFront(), 1.5)

assess, getFront, setFront = mkAssess(0.99)
T.isfalse('$19,999 is one dollar under the always-trips size', assess(19999))
assess, getFront, setFront = mkAssess(0.99)
T.istrue('$20,000 always trips, whatever the roll says', assess(20000))
assess, getFront, setFront = mkAssess(0.99)
T.istrue('and so does the largest legal wash', assess(Config.MaxPerRun))

-- The front-heat gate itself, isolated. 20 + 0.5*3 warms to 21.5, below the
-- threshold, so no roll happens at all.
assess, getFront, setFront = mkAssess(0.0)
setFront(20.0)
T.isfalse('below the front-heat threshold a 0.0 roll still cannot trip', assess(500))
assess, getFront, setFront = mkAssess(0.0)
setFront(120.0)   -- 120 + 1.5 = 121.5, over = 61.5, chance = min(0.60, 0.615) = 0.60
T.istrue('well past the threshold a 0.0 roll trips', assess(500))
assess, getFront, setFront = mkAssess(0.60)
setFront(120.0)
T.isfalse('and a roll at the ceiling does not: 0.60 is not < 0.60', assess(500))
assess, getFront, setFront = mkAssess(0.599)
setFront(120.0)
T.istrue('a roll just under the ceiling does', assess(500))
-- Exactly AT the threshold there is no chance at all.
assess, getFront, setFront = mkAssess(0.0)
setFront(58.5)    -- 58.5 + 1.5 = 60.0 exactly, over = 0, chance = 0
T.isfalse('at exactly the threshold the chance is zero, so even a 0.0 roll misses',
    assess(500))

-- Front heat is LINEAR in the amount with no flooring, so a haul warms the
-- front by the same total however it is split. Splitting is safer only because
-- it avoids BigRunAlways and gives the decay sweep time to work, which is
-- exactly what the design intent at the top of the config file claims.
assess, getFront, setFront = mkAssess(0.99)
assess(25000)
local oneBigRun = getFront()
assess, getFront, setFront = mkAssess(0.99)
for _ = 1, 50 do assess(500) end
local fiftySmallRuns = getFront()
T.near('one $25,000 run warms the front by 75', oneBigRun, 75.0)
T.eq('and fifty $500 runs warm it by exactly the same amount', fiftySmallRuns, oneBigRun)

-- The two heat models pull in OPPOSITE directions on splitting, and that is
-- deliberate: the durable charge punishes many runs, the front's always-trips
-- size punishes one big one. Stated as an assertion so neither can quietly
-- change without the other being reconsidered.
T.lt('durable heat: three big runs are cheaper than 150 small ones',
    totalHeat(75000, 3), totalHeat(75000, 150))
assess = mkAssess(0.99)
T.istrue('front heat: each of those three big runs is an automatic bust', assess(25000))
assess = mkAssess(0.99)
T.isfalse('while a minimum run on a cold front is not', assess(500))

T.done()
