-- ============================================================================
-- palm6_drugs/server/main.lua — Schedule I MVP (weed) supply chain.
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- inventory / native access. No direct framework / native calls here (§6 gate).
-- Our own drugs_* SQL is portable, so it stays in the logic (see
-- docs/GTA6-READINESS.md §3).
--
-- Three server-authoritative loops, all driven by ox_target interactions that
-- fire net events (guarded by palm6_eventguard):
--   GROW  — plant a seed+soil at a plot; DB wall-clock growth + watering
--           resolved on interaction (restart-safe, NO client ticks); harvest
--           buds carrying {strain,quality,effects,dried} metadata.
--   MIX   — pick a base stack + one additive; the SERVER resolves effects
--           (append-if-absent, 8-cap, order kept), recomputes quality + unit
--           price from config, sanitizes the brand, mints one weed_product.
--   SELL  — a rate-limited NPC street-buyer pays DIRTY cash (black_money)
--           priced from the item's REAL metadata (never the client), bounded
--           by a per-character daily faucet cap; logged to palm6_drugs_sales.
--
-- ANTI-EXPLOIT (spec §12): never trust client price/effects/quality/amount;
-- recompute from config + item metadata every time; proximity re-derived from
-- the caller's ped; inputs consumed before outputs granted; 8-effect cap;
-- per-unit price ceiling; per-player cooldowns; daily NPC faucet cap; all SQL
-- parameterized; every unit carries batch_id+producer for a laundering/evidence
-- audit trail.
-- ============================================================================

local xpCache    = {}   -- [cid] = xp (bounded to online players)
local last       = {}   -- [src] = { [key] = ts } per-player action cooldowns
local dealerHeat = {}   -- [cid] = heat (server-only, decays)
local booted     = false

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_drugs] ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local UID_CHARS = '0123456789abcdef'
local function makeUid()
    local out = {}
    for i = 1, 16 do
        local k = math.random(#UID_CHARS)
        out[i] = UID_CHARS:sub(k, k)
    end
    return table.concat(out)
end

local function cooldownOk(src, key, seconds)
    last[src] = last[src] or {}
    local t = now()
    if t - (last[src][key] or 0) < seconds then return false end
    last[src][key] = t
    return true
end

local function near(src, coords, radius)
    local c = Bridge.GetCoords(src)
    if not c or not coords then return false end
    return Bridge.Distance(c, coords) <= radius
end

local function normQuality(q)
    q = tonumber(q)
    if not q then return Config.DefaultQuality end
    q = math.floor(q)
    if q < 0 then return 0 end
    if q > 4 then return 4 end
    return q
end

local function cloneEffects(list)
    local out = {}
    if type(list) == 'table' then
        for _, e in ipairs(list) do
            if type(e) == 'string' then out[#out + 1] = e end
        end
    end
    return out
end

local function hasEffect(list, name)
    for _, e in ipairs(list) do
        if e == name then return true end
    end
    return false
end

-- Append an effect if absent and under the 8-cap. Returns true if appended.
local function appendEffect(list, name)
    if not name or hasEffect(list, name) then return false end
    if #list >= Config.MaxEffects then return false end
    list[#list + 1] = name
    return true
end

-- Apply an additive's ORDER-DEPENDENT reactions (Config.Reactions) to the
-- CURRENT effect set: every existing effect with a rule for this additive is
-- transformed, in a SINGLE pass over the incoming list, so a freshly-produced
-- effect is not itself re-transformed by the same additive. Order is preserved
-- (walked in ipairs order); a transform that would duplicate an existing effect
-- collapses to the first occurrence, so the list never grows here (the 8-cap is
-- untouched — only appendEffect adds the additive's base effect afterwards).
-- Returns a NEW list; the caller reassigns. Purely deterministic, server-side.
local function reactEffects(list, additiveKey)
    local rules = Config.Reactions and Config.Reactions[additiveKey]
    if not rules then return list end
    local out, seen = {}, {}
    for _, name in ipairs(list) do
        local mapped = rules[name] or name
        if not seen[mapped] then
            seen[mapped] = true
            out[#out + 1] = mapped
        end
    end
    return out
end

local function effectsLine(effects)
    if type(effects) ~= 'table' or #effects == 0 then return 'No effects' end
    return table.concat(effects, ', ')
end

-- Base-family lookup sets, built once from the config generalization maps so
-- the mix/sell/dealer scans stay base-agnostic (weed AND meth). `plantable` is
-- the weed-only strain set (StrainOrder) — meth is a Config.Drugs key but is
-- deliberately NOT plantable, so the plant handler must reject it here even
-- though a modified client could name it.
local plantable, rawSet, productSet, sellableSet = {}, {}, {}, {}
for _, id in ipairs(Config.StrainOrder) do plantable[id] = true end
for _, it in ipairs(Config.RawItems) do rawSet[it] = true; sellableSet[it] = true end
for _, it in ipairs(Config.ProductItems) do productSet[it] = true; sellableSet[it] = true end

-- ---------------------------------------------------------------------------
-- Progression (palm6_drugs_progression)
-- ---------------------------------------------------------------------------
local function rankOfXp(xp)
    return math.min(Config.Progression.maxRank,
        math.floor((tonumber(xp) or 0) / Config.Progression.xpPerRank))
end

local function loadXp(cid)
    if xpCache[cid] ~= nil then return end
    xpCache[cid] = 0
    pcall(function()
        local r = MySQL.single.await('SELECT xp FROM palm6_drugs_progression WHERE owner_cid = ?', { cid })
        if r then xpCache[cid] = tonumber(r.xp) or 0 end
    end)
end

local function rankOf(cid)
    loadXp(cid)
    return rankOfXp(xpCache[cid])
end

local function addXp(cid, amount)
    loadXp(cid)
    local xp = xpCache[cid] + amount
    xpCache[cid] = xp
    local rank = rankOfXp(xp)
    pcall(function()
        MySQL.query.await(
            'INSERT INTO palm6_drugs_progression (owner_cid, xp, rank_tier) VALUES (?, ?, ?) \z
             ON DUPLICATE KEY UPDATE xp = VALUES(xp), rank_tier = VALUES(rank_tier)',
            { cid, xp, rank })
    end)
end

-- ---------------------------------------------------------------------------
-- Heat / evidence
-- ---------------------------------------------------------------------------

-- Warm the dealer and decide whether THIS sale trips police. Heat is added
-- regardless; the roll (plus a flat witness chance) only decides the alert.
local function assessSaleHeat(cid)
    dealerHeat[cid] = (dealerHeat[cid] or 0.0) + Config.Heat.PerSale
    if math.random() < Config.Heat.WitnessBaseChance then return true end
    if dealerHeat[cid] >= Config.Heat.AlertThreshold then
        local over = dealerHeat[cid] - Config.Heat.AlertThreshold
        local chance = math.min(Config.Heat.AlertChanceMax,
            (over / Config.Heat.AlertThreshold) * Config.Heat.AlertChanceMax)
        if math.random() < chance then return true end
    end
    return false
end

-- Open/append a palm6_evidence v2 case for a flagged event. Returns the case id
-- or nil. Uses ONLY the frozen exports (never its tables directly). Every unit
-- carries batch_id+producer so a future seizure ties back here.
local function fileEvidence(cid, kind, detail)
    if not Bridge.ResourceStarted('palm6_evidence') then return nil end
    local caseId
    pcall(function()
        local incidentKey = ('%s%s-%d'):format(
            Config.Evidence.IncidentKeyPrefix, cid, math.floor(now() / 300))
        caseId = exports.palm6_evidence:EnsureCase(
            incidentKey, Config.Evidence.CaseTitle, 'palm6_drugs')
        if caseId then
            exports.palm6_evidence:AppendEntry(caseId, kind, detail or {}, 'palm6_drugs')
            exports.palm6_evidence:LinkSuspect(caseId, cid, nil)
        end
    end)
    return caseId
end

-- ===========================================================================
-- GROW
-- ===========================================================================

-- Validate a client plot index and the caller's real proximity to it. Returns
-- the plot coords, or nil (fails CLOSED on a bad index).
local function validPlot(src, plotIndex)
    plotIndex = tonumber(plotIndex)
    local plot = plotIndex and Config.Grow.plots[plotIndex] or nil
    if not plot then return nil end
    if not near(src, plot, Config.Grow.plotRadius + Config.Grow.proximitySlack) then return nil end
    return plot
end

-- The active plant row at a plot (matched on stored coords), or nil.
local function plantAtPlot(plot)
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT * FROM palm6_drugs_plants WHERE stage = ? \z
             AND ABS(coord_x - ?) < 0.05 AND ABS(coord_y - ?) < 0.05 AND ABS(coord_z - ?) < 0.05 LIMIT 1',
            { 'growing', plot.x, plot.y, plot.z })
    end)
    return row
end

-- Effective water (0-100) after wall-clock decay since it was last topped up.
local function effectiveWater(row, t)
    local w = (tonumber(row.water_level) or 0) - Config.Grow.waterDecayPerSec * (t - (tonumber(row.watered_at) or t))
    if w < 0 then return 0 end
    if w > 100 then return 100 end
    return w
end

-- Plot state snapshot for the client menu (server truth).
RegisterNetEvent('palm6_drugs:plotMenu', function(plotIndex)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:plot', 1) then return end  -- per-menu throttle (DoS); distinct key so moving between stations isn't blocked
    local plot = validPlot(src, plotIndex)
    if not plot then
        Bridge.Notify(src, 'Grow', 'You are not at a grow plot.', 'error')
        return
    end

    local row = plantAtPlot(plot)
    local payload = { plotIndex = tonumber(plotIndex) }

    if not row then
        -- Empty: offer the strains this grower has unlocked + any grow additive held.
        local rank = rankOf(cid)
        local strains = {}
        for _, id in ipairs(Config.StrainOrder) do
            local d = Config.Drugs[id]
            if d and d.unlock_rank <= rank then
                strains[#strains + 1] = { id = id, label = d.label }
            end
        end
        local additives = {}
        for _, id in ipairs(Config.GrowAdditiveOrder) do
            local c = Bridge.CountItem(src, id)
            if c > 0 then
                additives[#additives + 1] = { id = id, label = Config.GrowAdditives[id].label, count = c }
            end
        end
        payload.state = 'empty'
        payload.strains = strains
        payload.growAdditives = additives
        payload.hasSeed = Bridge.CountItem(src, Config.Items.seed)
        payload.hasSoil = Bridge.CountItem(src, Config.Items.soil)
    else
        local t = now()
        local ready = t >= (tonumber(row.ready_at) or 0)
        payload.state = ready and 'ready' or 'growing'
        payload.owner = (row.owner_cid == cid)
        payload.waterPct = math.floor(effectiveWater(row, t) + 0.5)
        payload.secondsLeft = ready and 0 or math.max(0, (tonumber(row.ready_at) or 0) - t)
        local d = Config.Drugs[row.strain]
        payload.strainLabel = d and d.label or row.strain
    end

    TriggerClientEvent('palm6_drugs:plotMenuData', src, payload)
end)

RegisterNetEvent('palm6_drugs:plant', function(plotIndex, strain, additive)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'plant', 2) then return end

    local plot = validPlot(src, plotIndex)
    if not plot then
        Bridge.Notify(src, 'Grow', 'You are not at a grow plot.', 'error')
        return
    end

    local drug = Config.Drugs[strain]
    if not drug then return end
    if not plantable[strain] then return end  -- meth (a cook base) is never plantable
    if drug.unlock_rank > rankOf(cid) then
        Bridge.Notify(src, 'Grow', 'You are not experienced enough to grow that strain yet.', 'error')
        return
    end

    local ga = nil
    if additive ~= nil then
        ga = Config.GrowAdditives[additive]
        if not ga then return end
    end

    if plantAtPlot(plot) then
        Bridge.Notify(src, 'Grow', 'Something is already growing here.', 'error')
        return
    end

    if not Bridge.HasItem(src, Config.Items.seed, 1) or not Bridge.HasItem(src, Config.Items.soil, 1) then
        Bridge.Notify(src, 'Grow', 'You need a seed and a bag of soil to plant.', 'error')
        return
    end
    if additive and not Bridge.HasItem(src, additive, 1) then
        Bridge.Notify(src, 'Grow', 'You do not have that grow additive.', 'error')
        return
    end

    -- Consume inputs BEFORE creating the plant; refund anything already taken
    -- if a later removal fails so a plant is never a partial loss.
    if not Bridge.RemoveItem(src, Config.Items.seed, 1) then
        Bridge.Notify(src, 'Grow', 'Could not plant — try again.', 'error')
        return
    end
    if not Bridge.RemoveItem(src, Config.Items.soil, 1) then
        Bridge.GiveItem(src, Config.Items.seed, 1)
        Bridge.Notify(src, 'Grow', 'Could not plant — try again.', 'error')
        return
    end
    if additive then
        if not Bridge.RemoveItem(src, additive, 1) then
            Bridge.GiveItem(src, Config.Items.seed, 1)
            Bridge.GiveItem(src, Config.Items.soil, 1)
            Bridge.Notify(src, 'Grow', 'Could not plant — try again.', 'error')
            return
        end
    end

    local t = now()
    local growMult = ga and ga.growMult or 1.0
    local ready = t + math.floor(Config.Grow.baseGrowSeconds * growMult)
    local soilTier = ga and ga.quality or Config.DefaultQuality

    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_plants \z
             (owner_cid, coord_x, coord_y, coord_z, strain, soil_tier, planted_at, ready_at, water_level, watered_at, additives, neglected, stage) \z
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { cid, plot.x, plot.y, plot.z, strain, soilTier, t, ready, 100, t,
              json.encode(additive and { additive } or {}), 0, 'growing' })
    end)
    if not ok then
        -- DB failed — hand the inputs back.
        Bridge.GiveItem(src, Config.Items.seed, 1)
        Bridge.GiveItem(src, Config.Items.soil, 1)
        if additive then Bridge.GiveItem(src, additive, 1) end
        Bridge.Notify(src, 'Grow', 'The soil would not take — try again.', 'error')
        return
    end

    Bridge.Notify(src, 'Grow',
        ('Planted %s. It will be ready in ~%d min — keep it watered.'):format(
            drug.label, math.max(1, math.floor((ready - t) / 60))), 'success')
    dbg(('%s planted %s at plot (%.1f,%.1f)'):format(cid, strain, plot.x, plot.y))
end)

RegisterNetEvent('palm6_drugs:water', function(plotIndex)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'water', 2) then return end

    local plot = validPlot(src, plotIndex)
    if not plot then return end
    local row = plantAtPlot(plot)
    if not row then
        Bridge.Notify(src, 'Grow', 'Nothing is planted here.', 'error')
        return
    end
    if row.owner_cid ~= cid then
        Bridge.Notify(src, 'Grow', 'This is not your plant.', 'error')
        return
    end
    if not Bridge.HasItem(src, Config.Items.wateringcan, 1) then
        Bridge.Notify(src, 'Grow', 'You need a watering can.', 'error')
        return
    end

    local t = now()
    local neglected = tonumber(row.neglected) or 0
    if effectiveWater(row, t) <= 0 and t < (tonumber(row.ready_at) or 0) then
        neglected = 1  -- it dried out at least once — quality takes a hit at harvest
    end
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_drugs_plants SET water_level = 100, watered_at = ?, neglected = ? WHERE id = ?',
            { t, neglected, row.id })
    end)
    Bridge.Notify(src, 'Grow', 'Watered.', 'success')
end)

RegisterNetEvent('palm6_drugs:harvest', function(plotIndex)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'harvest', 3) then return end

    local plot = validPlot(src, plotIndex)
    if not plot then return end
    local row = plantAtPlot(plot)
    if not row then
        Bridge.Notify(src, 'Grow', 'Nothing is planted here.', 'error')
        return
    end
    if row.owner_cid ~= cid then
        Bridge.Notify(src, 'Grow', 'This is not your plant.', 'error')
        return
    end

    local t = now()
    if t < (tonumber(row.ready_at) or 0) then
        Bridge.Notify(src, 'Grow',
            ('Not ready yet — about %d min to go.'):format(
                math.max(1, math.ceil(((tonumber(row.ready_at) or t) - t) / 60))), 'error')
        return
    end

    -- Atomic claim: flip growing -> harvested so a double-fire can't harvest
    -- the same plant twice. Only the winner proceeds.
    local claimed = 0
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_drugs_plants SET stage = 'harvested' WHERE id = ? AND stage = 'growing'", { row.id }) or 0
    end)
    if claimed == 0 then return end

    -- Quality: grow additive / soil tier, minus a neglect penalty.
    local quality = normQuality(row.soil_tier)
    local neglected = (tonumber(row.neglected) or 0) == 1 or effectiveWater(row, t) <= 0
    if neglected then quality = math.max(0, quality - 1) end

    -- Yield: base range + grow-additive bonus, minus a neglect penalty.
    local yieldBonus = 0
    local okAdd, adds = pcall(function() return json.decode(row.additives or '[]') end)
    if okAdd and type(adds) == 'table' then
        for _, a in ipairs(adds) do
            local g = Config.GrowAdditives[a]
            if g then yieldBonus = yieldBonus + (g.yieldBonus or 0) end
        end
    end
    local n = math.random(Config.Grow.yieldMin, Config.Grow.yieldMax) + yieldBonus
    if neglected then n = math.max(1, n - 1) end

    local drug = Config.Drugs[row.strain] or {}
    local effects = drug.default_effect and { drug.default_effect } or {}
    local meta = {
        strain = row.strain,
        quality = quality,
        effects = effects,
        dried = false,
        label = ('%s Buds [%s]'):format(drug.label or row.strain, Config.QualityLabel(quality)),
        description = ('%s • %s • %s'):format(drug.label or 'Weed', Config.QualityLabel(quality), effectsLine(effects)),
    }

    if not Bridge.CanCarry(src, Config.Items.bud, n) or not Bridge.GiveItem(src, Config.Items.bud, n, meta) then
        -- Couldn't take it — put the plant back so nothing is lost.
        pcall(function()
            MySQL.update.await("UPDATE palm6_drugs_plants SET stage = 'growing' WHERE id = ?", { row.id })
        end)
        Bridge.Notify(src, 'Grow', 'Your hands are full — harvest again with room.', 'error')
        return
    end

    pcall(function() MySQL.query.await('DELETE FROM palm6_drugs_plants WHERE id = ?', { row.id }) end)
    addXp(cid, Config.Grow.xp)

    -- Basic heat: a big harvest is occasionally spotted.
    if math.random() < Config.Heat.HarvestAlertChance then
        Bridge.PoliceAlert(src, 'Possible cannabis cultivation reported')
        fileEvidence(cid, 'harvest', { strain = row.strain, units = n, quality = quality })
    end

    Bridge.Notify(src, 'Grow',
        ('Harvested %dx %s buds (%s).'):format(n, drug.label or row.strain, Config.QualityLabel(quality)), 'success')
    dbg(('%s harvested %dx %s (q%d)'):format(cid, n, row.strain, quality))
end)

-- ===========================================================================
-- MIX (the branding station)
-- ===========================================================================

-- Sanitize a player-supplied brand: strip control/disallowed chars, collapse
-- whitespace, enforce the length limit. Returns nil for an empty result.
local function sanitizeBrand(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('%c', '')
    s = s:gsub('%s+', ' ')
    s = s:gsub("[^%w%s%-%._!&']", '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if #s == 0 then return nil end
    if #s > Config.Mix.brandMaxLen then s = s:sub(1, Config.Mix.brandMaxLen) end
    -- s:sub can leave a trailing space after truncation; trim again.
    s = s:gsub('%s+$', '')
    if #s == 0 then return nil end
    return s
end

-- Read a base slot's real metadata into { baseId, effects, quality }. Base-
-- agnostic: a raw bud carries meta.strain (a weed strain key), crystal /
-- products carry meta.base ('meth' or a weed strain) — both valid Config.Drugs
-- keys, so `meta.base or meta.strain` unifies them.
local function readBase(_, meta)
    meta = meta or {}
    return meta.base or meta.strain, cloneEffects(meta.effects), normQuality(meta.quality)
end

local function loadRecipes(cid)
    local out = {}
    pcall(function()
        local rows = MySQL.query.await(
            'SELECT id, brand, base, steps_json FROM palm6_drugs_recipes WHERE owner_cid = ? ORDER BY updated_at DESC LIMIT ?',
            { cid, Config.Mix.maxRecipes })
        for _, r in ipairs(rows or {}) do
            local okS, steps = pcall(function() return json.decode(r.steps_json or '[]') end)
            local d = Config.Drugs[r.base]
            out[#out + 1] = {
                id = r.id, brand = r.brand, base = r.base,
                baseLabel = d and d.label or r.base,
                steps = okS and steps or {},
            }
        end
    end)
    return out
end

local function saveRecipe(cid, brand, base, steps, effects)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_recipes (owner_cid, brand, base, steps_json, effects_json) VALUES (?, ?, ?, ?, ?) \z
             ON DUPLICATE KEY UPDATE base = VALUES(base), steps_json = VALUES(steps_json), \z
             effects_json = VALUES(effects_json), updated_at = CURRENT_TIMESTAMP',
            { cid, brand, base, json.encode(steps or {}), json.encode(effects or {}) })
    end)
end

-- Core mix routine (shared by the ad-hoc mix and the saved-recipe repeat). All
-- values are re-derived here from config + the base slot's REAL metadata.
local function doMix(src, cid, baseSlot, additiveItem, brand)
    local additive = Config.Additives[additiveItem]
    if not additive then
        Bridge.Notify(src, 'Mixing', 'Unknown additive.', 'error')
        return
    end

    -- Locate the base stack (a raw output or a product) at the requested slot.
    -- Scan the raw items first (loose buds, crystal) then the products; only one
    -- item type can occupy a given slot, so the first hit is the base.
    local baseItem, slot
    for _, it in ipairs(Config.RawItems) do
        slot = Bridge.GetSlot(src, it, baseSlot)
        if slot then baseItem = it break end
    end
    if not slot then
        for _, it in ipairs(Config.ProductItems) do
            slot = Bridge.GetSlot(src, it, baseSlot)
            if slot then baseItem = it break end
        end
    end
    if not slot then
        Bridge.Notify(src, 'Mixing', 'Pick a base product you actually have.', 'error')
        return
    end

    if not Bridge.HasItem(src, additiveItem, 1) then
        Bridge.Notify(src, 'Mixing', ('You do not have %s.'):format(additive.label), 'error')
        return
    end

    local origMeta = slot.metadata or {}
    local baseId, effects, quality = readBase(baseItem, origMeta)
    local drug = Config.Drugs[baseId]
    if not drug then
        Bridge.Notify(src, 'Mixing', 'That base cannot be mixed.', 'error')
        return
    end

    -- Resolve effects: FIRST transform matching existing effects via this
    -- additive's order-dependent reactions (Schedule I), THEN append the
    -- additive's own base effect if absent. Order preserved, 8-cap respected.
    local beforeMix = table.concat(effects, '\0')
    effects = reactEffects(effects, additiveItem)
    local reacted = table.concat(effects, '\0') ~= beforeMix
    local addedMain = appendEffect(effects, additive.effect)

    -- Bad-mix roll (server-side, never the client's skill result): a careless
    -- batch can pick up a junk effect if there is room.
    local badMix = false
    if math.random() < Config.Mix.badChance then
        local junk = Config.JunkEffects[math.random(#Config.JunkEffects)]
        if appendEffect(effects, junk) then badMix = true end
    end

    if not addedMain and not reacted and not badMix and #effects >= Config.MaxEffects then
        Bridge.Notify(src, 'Mixing', 'This product is already maxed out on effects.', 'error')
        return
    end

    brand = sanitizeBrand(brand)
    if not brand then
        Bridge.Notify(src, 'Mixing', 'Give it a valid name.', 'error')
        return
    end

    local unit = Config.Price(drug.base_value, effects, quality)
    local count = slot.count
    local productItem = Config.ProductOf[baseItem] or Config.Items.product

    -- Consume inputs FIRST (the whole base stack + one additive), then mint.
    if not Bridge.RemoveItemFromSlot(src, baseItem, count, baseSlot) then
        Bridge.Notify(src, 'Mixing', 'Could not process that — try again.', 'error')
        return
    end
    if not Bridge.RemoveItem(src, additiveItem, 1) then
        Bridge.GiveItem(src, baseItem, count, origMeta)  -- restore the base stack
        Bridge.Notify(src, 'Mixing', 'Could not process that — try again.', 'error')
        return
    end

    local meta = {
        brand = brand,
        base = baseId,
        effects = effects,
        quality = quality,
        unit_value = unit,
        batch_id = makeUid(),
        producer = cid,
        label = ('%s [%s]'):format(brand, Config.QualityLabel(quality)),
        description = ('%s • %s • %s • ~$%d/u'):format(
            drug.label or 'Product', Config.QualityLabel(quality), effectsLine(effects), unit),
    }
    if not Bridge.GiveItem(src, productItem, count, meta) then
        -- No room for the product — hand the inputs back.
        Bridge.GiveItem(src, baseItem, count, origMeta)
        Bridge.GiveItem(src, additiveItem, 1)
        Bridge.Notify(src, 'Mixing', 'No room for the product — nothing was used.', 'error')
        return
    end

    saveRecipe(cid, brand, baseId, { additiveItem }, effects)
    addXp(cid, Config.Mix.xp)

    if badMix then
        Bridge.Notify(src, 'Mixing',
            ('Batch of "%s" came out off — it picked up a bad trait. ($%d/u)'):format(brand, unit), 'warning')
    else
        Bridge.Notify(src, 'Mixing',
            ('Cooked up %dx "%s" — %s. ($%d/u)'):format(count, brand, effectsLine(effects), unit), 'success')
    end
    dbg(('%s mixed %dx "%s" (%s) @ $%d/u'):format(cid, count, brand, effectsLine(effects), unit))
end

RegisterNetEvent('palm6_drugs:mixMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:mix', 1) then return end  -- per-menu throttle (DoS)
    if not near(src, Config.Mix.coords, Config.Mix.radius + Config.Mix.proximitySlack) then
        Bridge.Notify(src, 'Mixing', 'You are not at the mixing station.', 'error')
        return
    end

    local function viewBase(itemName, s)
        local m = s.metadata or {}
        local d = Config.Drugs[m.base or m.strain] or {}
        if rawSet[itemName] then
            return {
                slot = s.slot, item = itemName, count = s.count,
                label = d.label or 'Buds', quality = normQuality(m.quality),
                effects = cloneEffects(m.effects), kind = 'bud',
            }
        else
            return {
                slot = s.slot, item = itemName, count = s.count,
                label = m.brand or d.label or 'Product', quality = normQuality(m.quality),
                effects = cloneEffects(m.effects), kind = 'product',
            }
        end
    end

    local bases = {}
    for _, it in ipairs(Config.RawItems) do
        for _, s in ipairs(Bridge.ListItemSlots(src, it)) do
            bases[#bases + 1] = viewBase(it, s)
        end
    end
    for _, it in ipairs(Config.ProductItems) do
        for _, s in ipairs(Bridge.ListItemSlots(src, it)) do
            bases[#bases + 1] = viewBase(it, s)
        end
    end

    local additives = {}
    for _, id in ipairs(Config.AdditiveOrder) do
        local c = Bridge.CountItem(src, id)
        if c > 0 then
            additives[#additives + 1] = {
                id = id, label = Config.Additives[id].label,
                effect = Config.Additives[id].effect, count = c,
            }
        end
    end

    TriggerClientEvent('palm6_drugs:mixMenuData', src, {
        bases = bases, additives = additives, recipes = loadRecipes(cid),
    })
end)

RegisterNetEvent('palm6_drugs:mix', function(baseSlot, additiveItem, brand)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'mix', 3) then return end
    if not near(src, Config.Mix.coords, Config.Mix.radius + Config.Mix.proximitySlack) then
        Bridge.Notify(src, 'Mixing', 'You are not at the mixing station.', 'error')
        return
    end
    baseSlot = tonumber(baseSlot)
    if not baseSlot then return end
    doMix(src, cid, baseSlot, additiveItem, brand)
end)

RegisterNetEvent('palm6_drugs:mixRecipe', function(baseSlot, recipeId)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'mix', 3) then return end
    if not near(src, Config.Mix.coords, Config.Mix.radius + Config.Mix.proximitySlack) then
        Bridge.Notify(src, 'Mixing', 'You are not at the mixing station.', 'error')
        return
    end
    baseSlot = tonumber(baseSlot)
    recipeId = tonumber(recipeId)
    if not baseSlot or not recipeId then return end

    local recipe
    pcall(function()
        recipe = MySQL.single.await(
            'SELECT brand, base, steps_json FROM palm6_drugs_recipes WHERE id = ? AND owner_cid = ?',
            { recipeId, cid })
    end)
    if not recipe then
        Bridge.Notify(src, 'Mixing', 'Recipe not found.', 'error')
        return
    end
    local okS, steps = pcall(function() return json.decode(recipe.steps_json or '[]') end)
    local additiveItem = okS and type(steps) == 'table' and steps[1] or nil
    if not additiveItem then
        Bridge.Notify(src, 'Mixing', 'That recipe has no step to repeat.', 'error')
        return
    end
    doMix(src, cid, baseSlot, additiveItem, recipe.brand)
end)

-- ===========================================================================
-- SELL (NPC street-buyer)
-- ===========================================================================

-- Recompute the per-unit dirty price of a slot from config + its REAL metadata.
-- Base-agnostic (weed AND meth): the base id is `meta.base or meta.strain`, the
-- brand is meta.brand (nil for raw buds/crystal). Returns price, base id,
-- quality, brand — or nil if the buyer won't touch it. itemName is unused (kept
-- for call-site symmetry); the price only ever comes from the real metadata.
local function priceOfSlot(_, meta)
    meta = meta or {}
    local baseId = meta.base or meta.strain
    local drug = Config.Drugs[baseId]
    if not drug then return nil end
    local effects = cloneEffects(meta.effects)
    local quality = normQuality(meta.quality)
    return Config.Price(drug.base_value, effects, quality), baseId, quality, meta.brand
end

-- Dirty dollars this character has already sold to the NPC faucet today.
local function dirtySoldToday(cid)
    local used = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(net_dirty),0) AS n FROM palm6_drugs_sales \z
             WHERE citizenid = ? AND channel = 'npc' AND created_at >= CURDATE()", { cid })
        used = r and tonumber(r.n) or 0
    end)
    return used
end

RegisterNetEvent('palm6_drugs:sellMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:sell', 1) then return end  -- per-menu throttle (DoS)
    if not near(src, Config.Sell.coords, Config.Sell.radius + Config.Sell.proximitySlack) then
        Bridge.Notify(src, Config.Sell.label, 'The buyer is not here.', 'error')
        return
    end

    local offers = {}
    local function addOffers(itemName)
        for _, s in ipairs(Bridge.ListItemSlots(src, itemName)) do
            local unit, baseId, quality, brand = priceOfSlot(itemName, s.metadata)
            if unit then
                local d = Config.Drugs[baseId]
                offers[#offers + 1] = {
                    slot = s.slot, item = itemName, count = s.count,
                    unit = unit, total = unit * s.count,
                    label = brand or (d and d.label) or 'Loose product',
                    quality = quality,
                }
            end
        end
    end
    for _, it in ipairs(Config.ProductItems) do addOffers(it) end
    for _, it in ipairs(Config.RawItems) do addOffers(it) end

    TriggerClientEvent('palm6_drugs:sellMenuData', src, {
        offers = offers,
        dailyRemaining = math.max(0, Config.Sell.dailyDirtyCap - dirtySoldToday(cid)),
    })
end)

RegisterNetEvent('palm6_drugs:sell', function(slot, item)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'sell', Config.Sell.cooldownSec) then
        Bridge.Notify(src, Config.Sell.label, 'Give it a second before the next sale.', 'error')
        return
    end
    if not near(src, Config.Sell.coords, Config.Sell.radius + Config.Sell.proximitySlack) then
        Bridge.Notify(src, Config.Sell.label, 'The buyer is not here.', 'error')
        return
    end

    slot = tonumber(slot)
    if not slot then return end
    -- Base-agnostic gate: any sellable raw output (buds, crystal) or finished
    -- product (weed_product, meth_product). Was hardcoded to product/bud, which
    -- silently rejected meth even though sellMenu offers it (§9 refactor).
    if not sellableSet[item] then return end

    local s = Bridge.GetSlot(src, item, slot)
    if not s then
        Bridge.Notify(src, Config.Sell.label, 'You are not holding that.', 'error')
        return
    end

    local unit, base, quality, brand = priceOfSlot(item, s.metadata)
    if not unit then
        Bridge.Notify(src, Config.Sell.label, 'The buyer will not take that.', 'error')
        return
    end

    -- Daily NPC faucet cap: sell only up to the remaining budget (spec §12).
    local remaining = math.max(0, Config.Sell.dailyDirtyCap - dirtySoldToday(cid))
    if remaining < unit then
        Bridge.Notify(src, Config.Sell.label, 'The buyer is tapped out for today — come back tomorrow.', 'error')
        return
    end
    local units = math.min(s.count, math.floor(remaining / unit))
    if units <= 0 then return end
    local total = units * unit

    -- Take the product first; pay only against product actually removed.
    if not Bridge.RemoveItemFromSlot(src, item, units, slot) then
        Bridge.Notify(src, Config.Sell.label, 'The deal fell through.', 'error')
        return
    end
    if not Bridge.GiveItem(src, Config.Items.dirty, total) then
        Bridge.GiveItem(src, item, units, s.metadata)  -- refund the product
        Bridge.Notify(src, Config.Sell.label, 'No room for the cash — deal cancelled.', 'error')
        return
    end

    addXp(cid, Config.Sell.xp)

    local flagged = assessSaleHeat(cid)
    local caseId
    if flagged then
        Bridge.PoliceAlert(src, 'Suspected drug dealing reported')
        caseId = fileEvidence(cid, 'street_sale', {
            region = Config.Sell.region, units = units, dirty = total, brand = brand,
        })
    end

    local m = s.metadata or {}
    -- The daily dirty-money faucet cap is enforced by SUMming this table, so a
    -- silently-dropped INSERT would let the cap drift upward over time. Payout
    -- already happened (no dupe), but log a warning on failure so the miss is
    -- reconcilable rather than invisible.
    local logged = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_sales \z
             (citizenid, channel, brand, base, quality, units, gross, cut_paid, net_dirty, region, flagged, evidence_case_id) \z
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { cid, 'npc', brand or m.strain or 'buds', base, quality, units, total, 0, total,
              Config.Sell.region, flagged and 1 or 0, caseId })
    end)
    if not logged then
        print(('^3[palm6_drugs] WARN: sale ledger INSERT failed for %s ($%d dirty, %d units) — daily cap accounting may under-count^0')
            :format(cid, total, units))
    end

    local msg = ('Sold %dx for $%d dirty.'):format(units, total)
    if units < s.count then
        msg = msg .. ' (Daily buyer limit hit — the rest keeps.)'
    end
    Bridge.Notify(src, Config.Sell.label, msg, flagged and 'warning' or 'success')
    dbg(('%s sold %dx %s for $%d (flagged=%s)'):format(cid, units, item, total, tostring(flagged)))
end)

-- ===========================================================================
-- DRY (the drying rack → Heavenly quality)
-- ===========================================================================
-- Load fresh (undried) weed_bud into a rack slot; it dries over wall-clock
-- time (a palm6_drugs_processes row, kind='dry', epoch seconds), resolved on
-- interaction like the grow timers. On collect the whole stack comes back
-- bumped to Heavenly (tier 4) with dried=true, so the price engine applies the
-- ×1.30 markup on any later mix/sell. One drying run per slot; the process is
-- server-owned by its starter; collect is an atomic claim so it can't double.

-- Validate a client rack-slot index (fails CLOSED on a bad index).
local function validDrySlot(stationId)
    stationId = tonumber(stationId)
    if not stationId then return nil end
    if stationId < 1 or stationId > Config.Dry.slots then return nil end
    return math.floor(stationId)
end

-- The live drying process at a rack slot (running/collecting), or nil.
local function processAtSlot(stationId)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT * FROM palm6_drugs_processes \z
             WHERE kind = 'dry' AND station_id = ? AND status IN ('running','collecting') LIMIT 1",
            { stationId })
    end)
    return row
end

-- Rack snapshot for the client menu (server truth).
RegisterNetEvent('palm6_drugs:dryMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:dry', 1) then return end  -- per-menu throttle (DoS)
    if not near(src, Config.Dry.coords, Config.Dry.radius + Config.Dry.proximitySlack) then
        Bridge.Notify(src, Config.Dry.label, 'You are not at the drying rack.', 'error')
        return
    end

    local t = now()
    local slots = {}
    for i = 1, Config.Dry.slots do
        local row = processAtSlot(i)
        if not row then
            slots[i] = { index = i, state = 'empty' }
        else
            local ready = t >= (tonumber(row.finish_at) or 0)
            local strain
            local okI, input = pcall(function() return json.decode(row.input_json or '{}') end)
            if okI and type(input) == 'table' then strain = input.strain end
            local d = Config.Drugs[strain]
            slots[i] = {
                index = i,
                state = ready and 'ready' or 'drying',
                owner = (row.owner_cid == cid),
                secondsLeft = ready and 0 or math.max(0, (tonumber(row.finish_at) or 0) - t),
                strainLabel = d and d.label or strain or 'Buds',
            }
        end
    end

    -- Fresh (undried) bud stacks the player can hang.
    local freshBuds = {}
    for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.bud)) do
        local m = s.metadata or {}
        if not m.dried then
            local d = Config.Drugs[m.strain] or {}
            freshBuds[#freshBuds + 1] = {
                slot = s.slot, count = s.count,
                label = d.label or 'Buds', quality = normQuality(m.quality),
            }
        end
    end

    TriggerClientEvent('palm6_drugs:dryMenuData', src, {
        slots = slots, freshBuds = freshBuds,
        dryMinutes = math.max(1, math.floor(Config.Dry.baseDrySeconds / 60)),
    })
end)

RegisterNetEvent('palm6_drugs:dryStart', function(stationId, budSlot)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dry', 2) then return end
    if not near(src, Config.Dry.coords, Config.Dry.radius + Config.Dry.proximitySlack) then
        Bridge.Notify(src, Config.Dry.label, 'You are not at the drying rack.', 'error')
        return
    end

    stationId = validDrySlot(stationId)
    if not stationId then return end
    budSlot = tonumber(budSlot)
    if not budSlot then return end

    if processAtSlot(stationId) then
        Bridge.Notify(src, Config.Dry.label, 'That rack slot is already in use.', 'error')
        return
    end

    -- Re-read the base slot's REAL metadata; only fresh (undried) buds qualify.
    local s = Bridge.GetSlot(src, Config.Items.bud, budSlot)
    if not s then
        Bridge.Notify(src, Config.Dry.label, 'Pick fresh buds you actually have.', 'error')
        return
    end
    local m = s.metadata or {}
    if m.dried then
        Bridge.Notify(src, Config.Dry.label, 'Those buds are already dried.', 'error')
        return
    end
    local strain = m.strain
    if not Config.Drugs[strain] then
        Bridge.Notify(src, Config.Dry.label, 'The rack cannot dry those.', 'error')
        return
    end

    local count = s.count
    local effects = cloneEffects(m.effects)

    -- Consume the whole fresh stack FIRST; if the DB insert fails (or the slot
    -- was taken in a race → UNIQUE(kind,station_id) dup), hand the buds back.
    if not Bridge.RemoveItemFromSlot(src, Config.Items.bud, count, budSlot) then
        Bridge.Notify(src, Config.Dry.label, 'Could not load the rack — try again.', 'error')
        return
    end

    local t = now()
    local finish = t + math.floor(Config.Dry.baseDrySeconds)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_processes \z
             (owner_cid, station_id, kind, input_json, started_at, finish_at, status) \z
             VALUES (?, ?, ?, ?, ?, ?, ?)',
            { cid, stationId, 'dry',
              json.encode({ strain = strain, effects = effects, count = count }),
              t, finish, 'running' })
    end)
    if not ok then
        Bridge.GiveItem(src, Config.Items.bud, count, m)  -- restore the fresh stack
        Bridge.Notify(src, Config.Dry.label, 'That slot would not take — try again.', 'error')
        return
    end

    Bridge.Notify(src, Config.Dry.label,
        ('Hung %dx buds to dry — Heavenly in ~%d min.'):format(
            count, math.max(1, math.floor((finish - t) / 60))), 'success')
    dbg(('%s started drying %dx %s at rack slot %d'):format(cid, count, strain, stationId))
end)

RegisterNetEvent('palm6_drugs:dryCollect', function(stationId)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dryCollect', 3) then return end
    if not near(src, Config.Dry.coords, Config.Dry.radius + Config.Dry.proximitySlack) then
        Bridge.Notify(src, Config.Dry.label, 'You are not at the drying rack.', 'error')
        return
    end

    stationId = validDrySlot(stationId)
    if not stationId then return end

    local row = processAtSlot(stationId)
    if not row then
        Bridge.Notify(src, Config.Dry.label, 'Nothing is drying here.', 'error')
        return
    end
    if row.owner_cid ~= cid then
        Bridge.Notify(src, Config.Dry.label, 'These are not your buds.', 'error')
        return
    end

    local t = now()
    if t < (tonumber(row.finish_at) or 0) then
        Bridge.Notify(src, Config.Dry.label,
            ('Not dry yet — about %d min to go.'):format(
                math.max(1, math.ceil(((tonumber(row.finish_at) or t) - t) / 60))), 'error')
        return
    end

    -- Atomic claim: flip running -> collecting so a double-fire can't collect
    -- the same rack slot twice. Only the winner proceeds.
    local claimed = 0
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_drugs_processes SET status = 'collecting' WHERE id = ? AND status = 'running'",
            { row.id }) or 0
    end)
    if claimed == 0 then return end

    local okI, input = pcall(function() return json.decode(row.input_json or '{}') end)
    if not okI or type(input) ~= 'table' then input = {} end
    local strain = input.strain
    local drug = Config.Drugs[strain]
    local count = math.max(1, math.floor(tonumber(input.count) or 1))
    local effects = cloneEffects(input.effects)
    if not drug then
        -- Config drifted out from under a stored strain — free the slot, no grant.
        pcall(function() MySQL.query.await('DELETE FROM palm6_drugs_processes WHERE id = ?', { row.id }) end)
        Bridge.Notify(src, Config.Dry.label, 'The rack could not resolve those buds.', 'error')
        return
    end

    -- Bump to Heavenly (tier 4); the price engine applies ×1.30 on mix/sell.
    local quality = Config.HeavenlyTier
    local meta = {
        strain = strain,
        quality = quality,
        effects = effects,
        dried = true,
        label = ('%s Buds [%s]'):format(drug.label or strain, Config.QualityLabel(quality)),
        description = ('%s • %s • %s'):format(
            drug.label or 'Weed', Config.QualityLabel(quality), effectsLine(effects)),
    }

    if not Bridge.CanCarry(src, Config.Items.bud, count) or not Bridge.GiveItem(src, Config.Items.bud, count, meta) then
        -- No room — put the process back so nothing is lost.
        pcall(function()
            MySQL.update.await("UPDATE palm6_drugs_processes SET status = 'running' WHERE id = ?", { row.id })
        end)
        Bridge.Notify(src, Config.Dry.label, 'Your hands are full — collect again with room.', 'error')
        return
    end

    pcall(function() MySQL.query.await('DELETE FROM palm6_drugs_processes WHERE id = ?', { row.id }) end)
    addXp(cid, Config.Dry.xp)

    Bridge.Notify(src, Config.Dry.label,
        ('Collected %dx %s buds — %s.'):format(count, drug.label or strain, Config.QualityLabel(quality)), 'success')
    dbg(('%s collected %dx dried %s (q%d) from rack slot %d'):format(cid, count, strain, quality, stationId))
end)

-- ===========================================================================
-- COOK (the meth lab) — §9
-- ===========================================================================
-- Load precursors (pseudo[grade] + acid + red_phosphorus) into one of the
-- burners; the cook runs over WALL-CLOCK time (a palm6_drugs_processes row,
-- kind='cook', epoch seconds) exactly like the drying rack, resolved on
-- interaction (restart-safe, NO client ticks, offline-safe). Unlike dry (which
-- just bumps quality on collect), the OUTCOME (success / quality / yield / a
-- junk effect on a bad cook) is ROLLED and STORED in input_json AT START, so
-- re-collecting can never re-roll it; collect is an atomic running->collecting
-- claim so a double-fire can't collect twice. Cooking is LOUD — a far higher
-- flat police-alert chance than a street sale. Disabled unless
-- Config.Cook.enabled (flipped true at boot iff all five meth items exist).

-- Validate a client burner index (fails CLOSED on a bad index).
local function validCookSlot(stationId)
    stationId = tonumber(stationId)
    if not stationId then return nil end
    if stationId < 1 or stationId > Config.Cook.slots then return nil end
    return math.floor(stationId)
end

-- The live cook process at a burner (running/collecting), or nil. Namespaced by
-- kind, so cook burners 1..3 coexist with dry racks 1..N via UNIQUE(kind,station_id).
local function cookAtSlot(stationId)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT * FROM palm6_drugs_processes \z
             WHERE kind = 'cook' AND station_id = ? AND status IN ('running','collecting') LIMIT 1",
            { stationId })
    end)
    return row
end

-- How many live cooks THIS character is running (the per-char concurrency gate).
local function liveCooksFor(cid)
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS c FROM palm6_drugs_processes \z
             WHERE kind = 'cook' AND owner_cid = ? AND status IN ('running','collecting')", { cid })
        n = r and tonumber(r.c) or 0
    end)
    return n
end

-- Normalize a pseudo grade to a gradeFloor key (1..2); default grade 1.
local function normGrade(g)
    g = math.floor(tonumber(g) or 1)
    if g < 1 then return 1 end
    if g > 2 then return 2 end
    return g
end

-- Warm cook heat and decide whether THIS cook trips police. Flat CookAlertChance
-- (loud) plus the same accumulated-heat escalation as sales; heat is added
-- regardless of the roll (mirrors assessSaleHeat).
local function assessCookHeat(cid)
    dealerHeat[cid] = (dealerHeat[cid] or 0.0) + Config.Heat.PerCook
    if math.random() < Config.Heat.CookAlertChance then return true end
    if dealerHeat[cid] >= Config.Heat.AlertThreshold then
        local over = dealerHeat[cid] - Config.Heat.AlertThreshold
        local chance = math.min(Config.Heat.AlertChanceMax,
            (over / Config.Heat.AlertThreshold) * Config.Heat.AlertChanceMax)
        if math.random() < chance then return true end
    end
    return false
end

-- Burner snapshot for the client menu (server truth).
RegisterNetEvent('palm6_drugs:cookMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:cook', 1) then return end  -- per-menu throttle (DoS)
    if not Config.Cook.enabled then
        Bridge.Notify(src, Config.Cook.label, 'The lab is not operational.', 'error'); return
    end
    if not near(src, Config.Cook.coords, Config.Cook.radius + Config.Cook.proximitySlack) then
        Bridge.Notify(src, Config.Cook.label, 'You are not at the cook station.', 'error'); return
    end

    local t = now()
    local slots = {}
    for i = 1, Config.Cook.slots do
        local row = cookAtSlot(i)
        if not row then
            slots[i] = { index = i, state = 'empty' }
        else
            local ready = t >= (tonumber(row.finish_at) or 0)
            slots[i] = {
                index = i,
                state = ready and 'ready' or 'cooking',
                owner = (row.owner_cid == cid),
                secondsLeft = ready and 0 or math.max(0, (tonumber(row.finish_at) or 0) - t),
            }
        end
    end

    -- Pseudo stacks (per graded slot) the player can load, plus the flat precursors.
    local pseudo = {}
    for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.pseudo)) do
        local m = s.metadata or {}
        pseudo[#pseudo + 1] = { slot = s.slot, count = s.count, grade = normGrade(m.grade) }
    end

    local meth = Config.Drugs.meth
    TriggerClientEvent('palm6_drugs:cookMenuData', src, {
        slots       = slots,
        rankOk      = rankOf(cid) >= (meth and meth.unlock_rank or 0),
        liveCooks   = liveCooksFor(cid),
        maxCooks    = Config.Cook.maxConcurrentPerChar,
        pseudo      = pseudo,
        acid        = Bridge.CountItem(src, Config.Items.acid),
        redP        = Bridge.CountItem(src, Config.Items.red_phosphorus),
        cookMinutes = math.max(1, math.floor(Config.Cook.baseCookSeconds / 60)),
    })
end)

RegisterNetEvent('palm6_drugs:cookStart', function(stationId, pseudoSlot)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not Config.Cook.enabled then return end
    if not cooldownOk(src, 'cook', 2) then return end
    if not near(src, Config.Cook.coords, Config.Cook.radius + Config.Cook.proximitySlack) then
        Bridge.Notify(src, Config.Cook.label, 'You are not at the cook station.', 'error'); return
    end

    stationId = validCookSlot(stationId)
    if not stationId then return end

    local meth = Config.Drugs.meth
    if not meth then return end
    if rankOf(cid) < (meth.unlock_rank or 0) then
        Bridge.Notify(src, Config.Cook.label, 'You do not know how to cook yet.', 'error'); return
    end
    -- Soft cap: this read is not atomic with the INSERT below, so under heavy DB
    -- lag two starts >2s apart (past the cooldown) could both read the same
    -- pre-INSERT count and exceed the cap. Bounded and harmless — total live
    -- cooks are already hard-capped at Config.Cook.slots (3) by the burner
    -- UNIQUE(kind,station_id), and every cook costs real precursors (no dupe).
    if liveCooksFor(cid) >= Config.Cook.maxConcurrentPerChar then
        Bridge.Notify(src, Config.Cook.label, 'You already have too many cooks going.', 'error'); return
    end
    if cookAtSlot(stationId) then
        Bridge.Notify(src, Config.Cook.label, 'That burner is already in use.', 'error'); return
    end

    -- Resolve the pseudo slot: honour a valid client-picked slot, else auto-pick
    -- the LOWEST-grade pseudo the player holds (don't waste a grade-2 stack).
    local pslot, grade
    pseudoSlot = tonumber(pseudoSlot)
    if pseudoSlot then
        local s = Bridge.GetSlot(src, Config.Items.pseudo, pseudoSlot)
        if s then pslot = pseudoSlot; grade = normGrade((s.metadata or {}).grade) end
    end
    if not pslot then
        for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.pseudo)) do
            local g = normGrade((s.metadata or {}).grade)
            if not grade or g < grade then pslot = s.slot; grade = g end
        end
    end
    if not pslot then
        Bridge.Notify(src, Config.Cook.label, 'You need pseudo to cook.', 'error'); return
    end

    local needPseudo = Config.Cook.precursors.pseudo or 1
    local needAcid   = Config.Cook.precursors.acid or 1
    local needRedP   = Config.Cook.precursors.red_phosphorus or 1

    -- Everything present before consuming anything.
    if not Bridge.HasItem(src, Config.Items.pseudo, needPseudo)
        or not Bridge.HasItem(src, Config.Items.acid, needAcid)
        or not Bridge.HasItem(src, Config.Items.red_phosphorus, needRedP) then
        Bridge.Notify(src, Config.Cook.label,
            'You are missing precursors (pseudo, acid, red phosphorus).', 'error'); return
    end

    -- Consume precursors FIRST, with a full refund ladder if any removal fails so
    -- a cook is never a partial loss (mirrors the plant/dry consume-then-mint order).
    if not Bridge.RemoveItemFromSlot(src, Config.Items.pseudo, needPseudo, pslot) then
        Bridge.Notify(src, Config.Cook.label, 'Could not load the burner — try again.', 'error'); return
    end
    if not Bridge.RemoveItem(src, Config.Items.acid, needAcid) then
        Bridge.GiveItem(src, Config.Items.pseudo, needPseudo, { grade = grade })
        Bridge.Notify(src, Config.Cook.label, 'Could not load the burner — try again.', 'error'); return
    end
    if not Bridge.RemoveItem(src, Config.Items.red_phosphorus, needRedP) then
        Bridge.GiveItem(src, Config.Items.pseudo, needPseudo, { grade = grade })
        Bridge.GiveItem(src, Config.Items.acid, needAcid)
        Bridge.Notify(src, Config.Cook.label, 'Could not load the burner — try again.', 'error'); return
    end

    -- Roll + STORE the outcome NOW (never re-rolled on collect). Server-only:
    -- success scales with rank (clamped), quality floors on the pseudo grade, a
    -- failed cook drops a tier and may pick up a junk effect; yield ranges with a
    -- per-4-ranks bonus and a failed cook loses one unit.
    local rank = rankOf(cid)
    local success = math.random() < math.min(0.9, Config.Cook.successChance + rank * Config.Cook.successRankBonus)
    local floorQ  = Config.Cook.gradeFloor[grade] or Config.DefaultQuality
    local quality, effects
    if success then
        quality = normQuality(floorQ)
        effects = {}
    else
        quality = normQuality(math.max(0, floorQ - 1))
        effects = {}
        if math.random() < Config.Cook.badChance then
            effects[1] = Config.JunkEffects[math.random(#Config.JunkEffects)]
        end
    end
    local yieldN = math.random(Config.Cook.yieldMin, Config.Cook.yieldMax)
        + math.floor(rank / 4) * Config.Cook.rankYieldBonus
    if not success then yieldN = math.max(1, yieldN - 1) end

    local t = now()
    local finish = t + math.floor(Config.Cook.baseCookSeconds)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_processes \z
             (owner_cid, station_id, kind, input_json, started_at, finish_at, status) \z
             VALUES (?, ?, ?, ?, ?, ?, ?)',
            { cid, stationId, 'cook',
              json.encode({ base = 'meth', grade = grade, success = success,
                            quality = quality, effects = effects, yield = yieldN }),
              t, finish, 'running' })
    end)
    if not ok then
        -- Burner taken in a race (UNIQUE(kind,station_id)) or DB down — refund all.
        Bridge.GiveItem(src, Config.Items.pseudo, needPseudo, { grade = grade })
        Bridge.GiveItem(src, Config.Items.acid, needAcid)
        Bridge.GiveItem(src, Config.Items.red_phosphorus, needRedP)
        Bridge.Notify(src, Config.Cook.label, 'That burner would not light — try again.', 'error'); return
    end

    -- Cooking is loud: warm heat and maybe trip police AT START (not just on sale).
    if assessCookHeat(cid) then
        Bridge.PoliceAlert(src, 'Possible clandestine drug lab reported')
        fileEvidence(cid, 'cook', { grade = grade })
    end

    Bridge.Notify(src, Config.Cook.label,
        ('Cooking started — crystal in ~%d min. Keep an eye out.'):format(
            math.max(1, math.floor((finish - t) / 60))), 'success')
    dbg(('%s started a cook (grade %d) at burner %d'):format(cid, grade, stationId))
end)

RegisterNetEvent('palm6_drugs:cookCollect', function(stationId)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not Config.Cook.enabled then return end
    if not cooldownOk(src, 'cookCollect', 3) then return end
    if not near(src, Config.Cook.coords, Config.Cook.radius + Config.Cook.proximitySlack) then
        Bridge.Notify(src, Config.Cook.label, 'You are not at the cook station.', 'error'); return
    end

    stationId = validCookSlot(stationId)
    if not stationId then return end

    local row = cookAtSlot(stationId)
    if not row then
        Bridge.Notify(src, Config.Cook.label, 'Nothing is cooking here.', 'error'); return
    end
    if row.owner_cid ~= cid then
        Bridge.Notify(src, Config.Cook.label, 'This is not your cook.', 'error'); return
    end

    local t = now()
    if t < (tonumber(row.finish_at) or 0) then
        Bridge.Notify(src, Config.Cook.label,
            ('Not done yet — about %d min to go.'):format(
                math.max(1, math.ceil(((tonumber(row.finish_at) or t) - t) / 60))), 'error'); return
    end

    -- Atomic claim: running -> collecting so a double-fire can't collect twice.
    local claimed = 0
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_drugs_processes SET status = 'collecting' WHERE id = ? AND status = 'running'",
            { row.id }) or 0
    end)
    if claimed == 0 then return end

    local okI, input = pcall(function() return json.decode(row.input_json or '{}') end)
    if not okI or type(input) ~= 'table' then input = {} end
    local quality = normQuality(input.quality)
    local effects = cloneEffects(input.effects)
    local yieldN  = math.max(1, math.floor(tonumber(input.yield) or 1))
    local meth = Config.Drugs.meth
    if not meth then
        -- Config drifted out from under a stored cook — free the burner, no grant.
        pcall(function() MySQL.query.await('DELETE FROM palm6_drugs_processes WHERE id = ?', { row.id }) end)
        Bridge.Notify(src, Config.Cook.label, 'The lab could not resolve that batch.', 'error'); return
    end

    -- Crystal carries meta.base='meth' (weed_bud carries meta.strain); the mix/
    -- sell/dealer loops price it via `meta.base or meta.strain`. Not "dried".
    local meta = {
        base = 'meth',
        quality = quality,
        effects = effects,
        dried = false,
        label = ('%s [%s]'):format(meth.label or 'Meth', Config.QualityLabel(quality)),
        description = ('%s • %s • %s'):format(
            meth.label or 'Meth', Config.QualityLabel(quality), effectsLine(effects)),
    }

    if not Bridge.CanCarry(src, Config.Items.meth_raw, yieldN) or not Bridge.GiveItem(src, Config.Items.meth_raw, yieldN, meta) then
        -- No room — put the process back so nothing is lost.
        pcall(function()
            MySQL.update.await("UPDATE palm6_drugs_processes SET status = 'running' WHERE id = ?", { row.id })
        end)
        Bridge.Notify(src, Config.Cook.label, 'Your hands are full — collect again with room.', 'error'); return
    end

    pcall(function() MySQL.query.await('DELETE FROM palm6_drugs_processes WHERE id = ?', { row.id }) end)
    addXp(cid, Config.Cook.xp)

    Bridge.Notify(src, Config.Cook.label,
        ('Collected %dx crystal (%s)%s.'):format(
            yieldN, Config.QualityLabel(quality), (#effects > 0) and ' — came out dirty' or ''), 'success')
    dbg(('%s collected %dx meth (q%d) from burner %d'):format(cid, yieldN, quality, stationId))
end)

-- ===========================================================================
-- Housekeeping
-- ===========================================================================

-- Heat decay sweep.
CreateThread(function()
    while true do
        Wait(Config.Heat.SweepSec * 1000)
        local dec = Config.Heat.DecayPerMin * (Config.Heat.SweepSec / 60.0)
        for cid, h in pairs(dealerHeat) do
            local nh = h - dec
            if nh <= 0 then dealerHeat[cid] = nil else dealerHeat[cid] = nh end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    last[src] = nil
    local cid = Bridge.GetCitizenId(src)
    if cid then xpCache[cid] = nil end  -- reloaded fresh from DB next session
    -- dealerHeat is keyed by cid and left to decay on its own sweep, so heat
    -- can't be shed by reconnecting mid-spree.
end)

-- ---------------------------------------------------------------------------
-- §8 NPC DEALER — passive, HARD-CAPPED dirty-cash faucet. Sales resolve LAZILY
-- on interaction over wall-clock time (like the grow/dry timers): no thread, no
-- client tick, offline- and restart-safe. Every unit is priced SERVER-SIDE from
-- its stored base/quality/effects (never client input); the player accrues
-- playerCut as owed black_money, collected only when online + able to carry it,
-- all bounded by a per-character daily faucet cap.
-- ---------------------------------------------------------------------------
local function dealerDayKey() return os.date('!%Y-%m-%d') end

local function stashUnits(stash)
    local n = 0
    for _, lot in ipairs(stash or {}) do n = n + (tonumber(lot.u) or 0) end
    return n
end

-- Load one dealer row with stash decoded, or nil.
local function loadDealer(cid)
    local row
    pcall(function()
        row = MySQL.single.await('SELECT * FROM palm6_drugs_dealers WHERE owner_cid = ?', { cid })
    end)
    if not row then return nil end
    local okS, stash = pcall(function() return json.decode(row.stash_json or '[]') end)
    row.stash            = (okS and type(stash) == 'table') and stash or {}
    row.dirty_owed       = tonumber(row.dirty_owed) or 0
    row.day_dirty        = tonumber(row.day_dirty) or 0
    row.dirty_earned_total = tonumber(row.dirty_earned_total) or 0
    row.last_tick_at     = tonumber(row.last_tick_at) or now()
    return row
end

-- Returns true only if the row actually persisted — callers that mutate money
-- gate the payout/consumption on a durable write (see dealerStock/dealerCollect).
local function saveDealer(row)
    local ok = pcall(function()
        MySQL.update.await(
            'UPDATE palm6_drugs_dealers SET stash_json = ?, dirty_owed = ?, dirty_earned_total = ?, \z
             last_tick_at = ?, day_key = ?, day_dirty = ? WHERE owner_cid = ?',
            { json.encode(row.stash or {}), row.dirty_owed, row.dirty_earned_total,
              row.last_tick_at, row.day_key or dealerDayKey(), row.day_dirty, row.owner_cid })
    end)
    return ok
end

-- Resolve elapsed wall-clock into sales. Sells up to unitsPerTick per elapsed
-- tick, each unit priced SERVER-SIDE from its stored lot, accruing playerCut as
-- owed dirty and charging the per-character daily faucet cap. Mutates the row;
-- persists it UNLESS persist==false. Idempotent per instant (a second call in the
-- same second is a no-op). The read-only dealerMenu MUST pass persist=false: if
-- the menu persisted a stale snapshot it could clobber a concurrent dealerCollect
-- that just zeroed + paid dirty_owed, resurrecting already-paid cash (dupe).
local function resolveDealer(row, persist)
    local t = now()
    local elapsed = t - row.last_tick_at
    if elapsed < Config.Dealer.tickSeconds then return 0 end
    local rawTicks = math.floor(elapsed / Config.Dealer.tickSeconds)
    local ticks    = math.min(rawTicks, Config.Dealer.maxTicksPerResolve)

    local dayKey = dealerDayKey()
    if row.day_key ~= dayKey then row.day_key = dayKey; row.day_dirty = 0 end
    local dailyRemaining = math.max(0, Config.Dealer.dailyDirtyCap - row.day_dirty)

    local toSell  = ticks * Config.Dealer.unitsPerTick
    local accrued = 0
    for _, lot in ipairs(row.stash) do
        if toSell <= 0 or dailyRemaining <= 0 then break end
        lot.u = tonumber(lot.u) or 0
        local meta = { base = lot.b, quality = lot.q, effects = lot.e, brand = lot.brand }
        local unit = priceOfSlot(Config.Items.product, meta)
        if not unit then
            lot.u = 0  -- config drifted under this lot — drop it, don't wedge the queue
        else
            local playerUnit = math.floor(unit * Config.Dealer.playerCut)
            if playerUnit < 1 then playerUnit = 1 end
            while lot.u > 0 and toSell > 0 and dailyRemaining >= playerUnit do
                lot.u          = lot.u - 1
                toSell         = toSell - 1
                accrued        = accrued + playerUnit
                dailyRemaining = dailyRemaining - playerUnit
            end
        end
    end

    -- compact: drop emptied lots
    local kept = {}
    for _, lot in ipairs(row.stash) do
        if (tonumber(lot.u) or 0) > 0 then kept[#kept + 1] = lot end
    end
    row.stash = kept

    row.dirty_owed = row.dirty_owed + accrued
    row.day_dirty  = row.day_dirty + accrued
    -- Advance the clock. Normal resolve: keep the sub-tick remainder so frequent
    -- checks still accumulate. Long absence past the catch-up cap: reset to now,
    -- so idle time can never bank into a burst.
    if rawTicks > Config.Dealer.maxTicksPerResolve then
        row.last_tick_at = t
    else
        row.last_tick_at = row.last_tick_at + ticks * Config.Dealer.tickSeconds
    end
    if persist ~= false then saveDealer(row) end
    return accrued
end

local function dealerProx(src)
    return near(src, Config.Dealer.coords, Config.Dealer.radius + Config.Dealer.proximitySlack)
end

RegisterNetEvent('palm6_drugs:dealerMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'menu:dealer', 1) then return end  -- per-menu throttle (DoS)
    if not dealerProx(src) then
        Bridge.Notify(src, Config.Dealer.label, 'The dealer is not here.', 'error'); return
    end
    local row = loadDealer(cid)
    -- persist=false: the menu is read-only. Persisting here could clobber a
    -- concurrent dealerCollect that just paid out (owed-cash dupe).
    if row then resolveDealer(row, false) end
    local held = {}
    for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.product)) do
        local unit, _, quality, brand = priceOfSlot(Config.Items.product, s.metadata)
        if unit then
            held[#held + 1] = { slot = s.slot, count = s.count, unit = unit,
                label = brand or 'Product', quality = quality }
        end
    end
    TriggerClientEvent('palm6_drugs:dealerMenuData', src, {
        hired          = row ~= nil,
        stashUnits     = row and stashUnits(row.stash) or 0,
        maxStash       = Config.Dealer.maxStash,
        owed           = row and row.dirty_owed or 0,
        hireCost       = Config.Dealer.hireCost,
        held           = held,
        dailyRemaining = row and math.max(0, Config.Dealer.dailyDirtyCap - row.day_dirty) or Config.Dealer.dailyDirtyCap,
    })
end)

RegisterNetEvent('palm6_drugs:dealerHire', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dealer', 2) then return end
    if not dealerProx(src) then
        Bridge.Notify(src, Config.Dealer.label, 'The dealer is not here.', 'error'); return
    end
    if loadDealer(cid) then
        Bridge.Notify(src, Config.Dealer.label, 'You already run a dealer.', 'error'); return
    end
    -- Hire fee paid in DIRTY money (a criminal front — no bank call).
    if not Bridge.RemoveItem(src, Config.Items.dirty, Config.Dealer.hireCost) then
        Bridge.Notify(src, Config.Dealer.label, ('You need $%d dirty on hand to hire.'):format(Config.Dealer.hireCost), 'error'); return
    end
    local t = now()
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_dealers (owner_cid, hired_at, last_tick_at, stash_json, day_key) \z
             VALUES (?, ?, ?, ?, ?)',
            { cid, t, t, '[]', dealerDayKey() })
    end)
    if not ok then
        Bridge.GiveItem(src, Config.Items.dirty, Config.Dealer.hireCost)  -- refund on failure
        Bridge.Notify(src, Config.Dealer.label, 'Could not hire right now — your money was returned.', 'error'); return
    end
    Bridge.Notify(src, Config.Dealer.label, 'Dealer hired. Stock him product and he moves it over time.', 'success')
end)

RegisterNetEvent('palm6_drugs:dealerStock', function(slot, units)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dealer', 1) then return end
    if not dealerProx(src) then
        Bridge.Notify(src, Config.Dealer.label, 'The dealer is not here.', 'error'); return
    end
    local row = loadDealer(cid)
    if not row then Bridge.Notify(src, Config.Dealer.label, 'Hire a dealer first.', 'error'); return end
    resolveDealer(row)

    slot = tonumber(slot)
    if not slot then return end
    local s = Bridge.GetSlot(src, Config.Items.product, slot)
    if not s then Bridge.Notify(src, Config.Dealer.label, 'You are not holding that.', 'error'); return end
    local unit, base, quality, brand = priceOfSlot(Config.Items.product, s.metadata)
    if not unit then Bridge.Notify(src, Config.Dealer.label, 'The dealer will not push that.', 'error'); return end

    local headroom = Config.Dealer.maxStash - stashUnits(row.stash)
    if headroom <= 0 then Bridge.Notify(src, Config.Dealer.label, 'The dealer is fully stocked.', 'error'); return end
    units = math.floor(tonumber(units) or 0)
    if units ~= units or units < 1 then units = s.count end   -- default whole stack (NaN-safe)
    units = math.min(units, s.count, headroom)
    if units < 1 then return end

    -- Consume before store — nothing enters the stash we didn't actually take.
    if not Bridge.RemoveItemFromSlot(src, Config.Items.product, units, slot) then
        Bridge.Notify(src, Config.Dealer.label, 'Could not hand over the product.', 'error'); return
    end
    row.stash[#row.stash + 1] = {
        b = base, q = quality, brand = brand,
        e = cloneEffects(s.metadata and s.metadata.effects), u = units,
    }
    if not saveDealer(row) then
        -- Persist failed after we already took the product — hand it straight
        -- back (with its metadata) so nothing is lost.
        Bridge.GiveItem(src, Config.Items.product, units, s.metadata)
        Bridge.Notify(src, Config.Dealer.label, 'Could not stock the dealer — your product was returned.', 'error'); return
    end
    Bridge.Notify(src, Config.Dealer.label,
        ('Stocked %d unit(s). He now holds %d/%d.'):format(units, stashUnits(row.stash), Config.Dealer.maxStash), 'success')
end)

RegisterNetEvent('palm6_drugs:dealerCollect', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dealer', 2) then return end
    if not dealerProx(src) then
        Bridge.Notify(src, Config.Dealer.label, 'The dealer is not here.', 'error'); return
    end
    local row = loadDealer(cid)
    if not row then Bridge.Notify(src, Config.Dealer.label, 'You have no dealer.', 'error'); return end
    resolveDealer(row)
    local owed = row.dirty_owed
    if owed < 1 then Bridge.Notify(src, Config.Dealer.label, 'Nothing to collect yet.', 'inform'); return end
    if not Bridge.CanCarry(src, Config.Items.dirty, owed) then
        Bridge.Notify(src, Config.Dealer.label, 'Make room — that is a lot of cash to carry.', 'error'); return
    end
    -- Debit owed and PERSIST IT DURABLY before granting: if the write fails we
    -- abort without paying, so the same owed cash can never be collected twice
    -- (a best-effort save + a successful grant would otherwise leave the debt in
    -- the DB). Restore + best-effort re-save on grant failure so money is never
    -- created or destroyed.
    row.dirty_owed = 0
    row.dirty_earned_total = row.dirty_earned_total + owed
    if not saveDealer(row) then
        row.dirty_owed = owed
        row.dirty_earned_total = row.dirty_earned_total - owed
        Bridge.Notify(src, Config.Dealer.label, 'The books are busy — try again in a moment.', 'error'); return
    end
    if not Bridge.GiveItem(src, Config.Items.dirty, owed) then
        row.dirty_owed = owed
        row.dirty_earned_total = row.dirty_earned_total - owed
        saveDealer(row)
        Bridge.Notify(src, Config.Dealer.label, 'Could not hand over the cash — try again.', 'error'); return
    end
    addXp(cid, Config.Dealer.xpPerCollect)
    local logged = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_drugs_sales \z
             (citizenid, channel, brand, base, quality, units, gross, cut_paid, net_dirty, region, flagged, evidence_case_id) \z
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { cid, 'dealer', 'street', 'mixed', 0, 0, owed, 0, owed, 'Davis', 0, nil })
    end)
    if not logged then
        print(('^3[palm6_drugs] WARN: dealer-collect ledger INSERT failed for %s ($%d) — economy under-count^0'):format(cid, owed))
    end
    Bridge.Notify(src, Config.Dealer.label, ('Collected $%d dirty from the dealer.'):format(owed), 'success')
end)

RegisterNetEvent('palm6_drugs:dealerFire', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not cooldownOk(src, 'dealer', 2) then return end
    if not dealerProx(src) then
        Bridge.Notify(src, Config.Dealer.label, 'The dealer is not here.', 'error'); return
    end
    local row = loadDealer(cid)
    if not row then return end
    resolveDealer(row)
    -- Hand back unsold product + owed dirty (best-effort) before deleting, so
    -- nothing is destroyed. Anything that can't fit keeps the dealer alive.
    local returned = 0
    for _, lot in ipairs(row.stash) do
        local u = tonumber(lot.u) or 0
        if u > 0 then
            local meta = { base = lot.b, quality = lot.q, effects = lot.e, brand = lot.brand }
            if Bridge.CanCarry(src, Config.Items.product, u) and Bridge.GiveItem(src, Config.Items.product, u, meta) then
                returned = returned + u
                lot.u = 0
            end
        end
    end
    if row.dirty_owed > 0 and Bridge.CanCarry(src, Config.Items.dirty, row.dirty_owed)
        and Bridge.GiveItem(src, Config.Items.dirty, row.dirty_owed) then
        row.dirty_owed = 0
    end
    if stashUnits(row.stash) > 0 or row.dirty_owed > 0 then
        saveDealer(row)   -- couldn't return everything — keep him so nothing is lost
        Bridge.Notify(src, Config.Dealer.label, 'Make room to reclaim your product/cash, then fire him again.', 'error')
        return
    end
    pcall(function() MySQL.update.await('DELETE FROM palm6_drugs_dealers WHERE owner_cid = ?', { cid }) end)
    Bridge.Notify(src, Config.Dealer.label,
        ('Dealer fired.%s'):format(returned > 0 and (' Reclaimed %d unit(s).'):format(returned) or ''), 'inform')
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Self-disable loudly if a required item isn't registered in ox_inventory
    -- (mirrors palm6_laundering / palm6_flashdrop / palm6_counterfeit).
    local core = {
        Config.Items.seed, Config.Items.soil, Config.Items.wateringcan,
        Config.Items.bud, Config.Items.product, Config.Items.dirty,
    }
    for _, item in ipairs(core) do
        if not Bridge.ItemExists(item) then
            print(('^1[palm6_drugs] FATAL: required item "%s" is not registered in ox_inventory — '
                .. 'drugs disabled. Add it to ox_inventory_overrides/data/items.lua.^0'):format(item))
            return
        end
    end

    -- §9 Meth cook chain: a SOFT gate. Weed keeps running if the meth items are
    -- not registered; the cook station just stays dark (Config.Cook.enabled)
    -- until all five exist, so cookMenu/Start/Collect refuse cleanly.
    local methItems = {
        Config.Items.pseudo, Config.Items.acid, Config.Items.red_phosphorus,
        Config.Items.meth_raw, Config.Items.meth_product,
    }
    local methMissing = {}
    for _, item in ipairs(methItems) do
        if not Bridge.ItemExists(item) then methMissing[#methMissing + 1] = item end
    end
    if #methMissing == 0 then
        Config.Cook.enabled = true
    else
        table.sort(methMissing)
        print(('^3[palm6_drugs] NOTE: meth cook chain disabled — %d meth item(s) not registered: %s^0')
            :format(#methMissing, table.concat(methMissing, ', ')))
    end

    -- Additives are needed for the mixing station; warn (don't disable) per any
    -- that are missing so the operator can patch them in.
    local missing = {}
    for _, id in ipairs(Config.AdditiveOrder) do
        if not Bridge.ItemExists(id) then missing[#missing + 1] = id end
    end
    if #missing > 0 then
        table.sort(missing)
        print(('^3[palm6_drugs] WARN: %d mix additive item(s) not registered — those additives are unusable until added: %s^0')
            :format(#missing, table.concat(missing, ', ')))
    end

    -- A crash mid-harvest can strand a plant at 'harvested'; free those plots.
    pcall(function()
        MySQL.query.await("DELETE FROM palm6_drugs_plants WHERE stage = 'harvested'")
    end)

    -- A crash mid-collect can strand a dry process at 'collecting'. The output
    -- Heavenly buds may or may not have been handed back before the crash, and
    -- the row state alone can't tell us — reverting to 'running' would let a
    -- player who already received their buds collect a SECOND free Heavenly
    -- stack (a high-value dirty-money dupe). Err toward loss instead of dupe:
    -- delete the stranded rows, exactly as the harvest recovery above does.
    pcall(function()
        MySQL.query.await("DELETE FROM palm6_drugs_processes WHERE status = 'collecting'")
    end)

    booted = true
    local sales, dirty = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(net_dirty),0) AS s FROM palm6_drugs_sales')
        sales = r and tonumber(r.c) or 0
        dirty = r and tonumber(r.s) or 0
    end)
    print(('[palm6_drugs] supply chain online — %d grow plots, %d strains, %d additives, cook %s; '
        .. '$%d dirty earned all-time across %d NPC sale(s)'):format(
        #Config.Grow.plots, #Config.StrainOrder, #Config.AdditiveOrder,
        Config.Cook.enabled and 'ON' or 'off', dirty, sales))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalSales = 0, totalDirtyEarned = 0, flaggedSales = 0, activePlants = 0, activeDries = 0, activeCooks = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(net_dirty),0) AS s, COALESCE(SUM(flagged),0) AS f FROM palm6_drugs_sales')
        if r then
            out.totalSales = tonumber(r.c) or 0
            out.totalDirtyEarned = tonumber(r.s) or 0
            out.flaggedSales = tonumber(r.f) or 0
        end
        local p = MySQL.single.await("SELECT COUNT(*) AS c FROM palm6_drugs_plants WHERE stage = 'growing'")
        out.activePlants = p and tonumber(p.c) or 0
        local dr = MySQL.single.await(
            "SELECT COUNT(*) AS c FROM palm6_drugs_processes WHERE kind = 'dry' AND status IN ('running','collecting')")
        out.activeDries = dr and tonumber(dr.c) or 0
        local ck = MySQL.single.await(
            "SELECT COUNT(*) AS c FROM palm6_drugs_processes WHERE kind = 'cook' AND status IN ('running','collecting')")
        out.activeCooks = ck and tonumber(ck.c) or 0
    end)
    return out
end)
