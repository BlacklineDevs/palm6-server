-- ============================================================================
-- gtarp_drugs/server/main.lua — Schedule I MVP (weed) supply chain.
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- inventory / native access. No direct framework / native calls here (§6 gate).
-- Our own drugs_* SQL is portable, so it stays in the logic (see
-- docs/GTA6-READINESS.md §3).
--
-- Three server-authoritative loops, all driven by ox_target interactions that
-- fire net events (guarded by gtarp_eventguard):
--   GROW  — plant a seed+soil at a plot; DB wall-clock growth + watering
--           resolved on interaction (restart-safe, NO client ticks); harvest
--           buds carrying {strain,quality,effects,dried} metadata.
--   MIX   — pick a base stack + one additive; the SERVER resolves effects
--           (append-if-absent, 8-cap, order kept), recomputes quality + unit
--           price from config, sanitizes the brand, mints one weed_product.
--   SELL  — a rate-limited NPC street-buyer pays DIRTY cash (black_money)
--           priced from the item's REAL metadata (never the client), bounded
--           by a per-character daily faucet cap; logged to gtarp_drugs_sales.
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
    if Config.Debug then print('[gtarp_drugs] ' .. msg) end
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

-- ---------------------------------------------------------------------------
-- Progression (gtarp_drugs_progression)
-- ---------------------------------------------------------------------------
local function rankOfXp(xp)
    return math.min(Config.Progression.maxRank,
        math.floor((tonumber(xp) or 0) / Config.Progression.xpPerRank))
end

local function loadXp(cid)
    if xpCache[cid] ~= nil then return end
    xpCache[cid] = 0
    pcall(function()
        local r = MySQL.single.await('SELECT xp FROM gtarp_drugs_progression WHERE owner_cid = ?', { cid })
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
            'INSERT INTO gtarp_drugs_progression (owner_cid, xp, rank_tier) VALUES (?, ?, ?) \z
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

-- Open/append a gtarp_evidence v2 case for a flagged event. Returns the case id
-- or nil. Uses ONLY the frozen exports (never its tables directly). Every unit
-- carries batch_id+producer so a future seizure ties back here.
local function fileEvidence(cid, kind, detail)
    if not Bridge.ResourceStarted('gtarp_evidence') then return nil end
    local caseId
    pcall(function()
        local incidentKey = ('%s%s-%d'):format(
            Config.Evidence.IncidentKeyPrefix, cid, math.floor(now() / 300))
        caseId = exports.gtarp_evidence:EnsureCase(
            incidentKey, Config.Evidence.CaseTitle, 'gtarp_drugs')
        if caseId then
            exports.gtarp_evidence:AppendEntry(caseId, kind, detail or {}, 'gtarp_drugs')
            exports.gtarp_evidence:LinkSuspect(caseId, cid, nil)
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
            'SELECT * FROM gtarp_drugs_plants WHERE stage = ? \z
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
RegisterNetEvent('gtarp_drugs:plotMenu', function(plotIndex)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
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

    TriggerClientEvent('gtarp_drugs:plotMenuData', src, payload)
end)

RegisterNetEvent('gtarp_drugs:plant', function(plotIndex, strain, additive)
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
            'INSERT INTO gtarp_drugs_plants \z
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

RegisterNetEvent('gtarp_drugs:water', function(plotIndex)
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
            'UPDATE gtarp_drugs_plants SET water_level = 100, watered_at = ?, neglected = ? WHERE id = ?',
            { t, neglected, row.id })
    end)
    Bridge.Notify(src, 'Grow', 'Watered.', 'success')
end)

RegisterNetEvent('gtarp_drugs:harvest', function(plotIndex)
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
            "UPDATE gtarp_drugs_plants SET stage = 'harvested' WHERE id = ? AND stage = 'growing'", { row.id }) or 0
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
            MySQL.update.await("UPDATE gtarp_drugs_plants SET stage = 'growing' WHERE id = ?", { row.id })
        end)
        Bridge.Notify(src, 'Grow', 'Your hands are full — harvest again with room.', 'error')
        return
    end

    pcall(function() MySQL.query.await('DELETE FROM gtarp_drugs_plants WHERE id = ?', { row.id }) end)
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

-- Read a base slot's real metadata into { baseId, effects, quality }. Works for
-- a raw bud (base = strain) or an existing product (base = meta.base).
local function readBase(itemName, meta)
    meta = meta or {}
    if itemName == Config.Items.bud then
        return meta.strain, cloneEffects(meta.effects), normQuality(meta.quality)
    else
        return meta.base, cloneEffects(meta.effects), normQuality(meta.quality)
    end
end

local function loadRecipes(cid)
    local out = {}
    pcall(function()
        local rows = MySQL.query.await(
            'SELECT id, brand, base, steps_json FROM gtarp_drugs_recipes WHERE owner_cid = ? ORDER BY updated_at DESC LIMIT ?',
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
            'INSERT INTO gtarp_drugs_recipes (owner_cid, brand, base, steps_json, effects_json) VALUES (?, ?, ?, ?, ?) \z
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

    -- Locate the base stack (a bud or a product) at the requested slot.
    local baseItem = Config.Items.bud
    local slot = Bridge.GetSlot(src, Config.Items.bud, baseSlot)
    if not slot then
        baseItem = Config.Items.product
        slot = Bridge.GetSlot(src, Config.Items.product, baseSlot)
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
            drug.label or 'Weed', Config.QualityLabel(quality), effectsLine(effects), unit),
    }
    if not Bridge.GiveItem(src, Config.Items.product, count, meta) then
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

RegisterNetEvent('gtarp_drugs:mixMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not near(src, Config.Mix.coords, Config.Mix.radius + Config.Mix.proximitySlack) then
        Bridge.Notify(src, 'Mixing', 'You are not at the mixing station.', 'error')
        return
    end

    local function viewBase(itemName, s)
        local m = s.metadata or {}
        if itemName == Config.Items.bud then
            local d = Config.Drugs[m.strain] or {}
            return {
                slot = s.slot, item = itemName, count = s.count,
                label = d.label or 'Buds', quality = normQuality(m.quality),
                effects = cloneEffects(m.effects), kind = 'bud',
            }
        else
            local d = Config.Drugs[m.base] or {}
            return {
                slot = s.slot, item = itemName, count = s.count,
                label = m.brand or d.label or 'Product', quality = normQuality(m.quality),
                effects = cloneEffects(m.effects), kind = 'product',
            }
        end
    end

    local bases = {}
    for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.bud)) do
        bases[#bases + 1] = viewBase(Config.Items.bud, s)
    end
    for _, s in ipairs(Bridge.ListItemSlots(src, Config.Items.product)) do
        bases[#bases + 1] = viewBase(Config.Items.product, s)
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

    TriggerClientEvent('gtarp_drugs:mixMenuData', src, {
        bases = bases, additives = additives, recipes = loadRecipes(cid),
    })
end)

RegisterNetEvent('gtarp_drugs:mix', function(baseSlot, additiveItem, brand)
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

RegisterNetEvent('gtarp_drugs:mixRecipe', function(baseSlot, recipeId)
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
            'SELECT brand, base, steps_json FROM gtarp_drugs_recipes WHERE id = ? AND owner_cid = ?',
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
-- Returns price, base id, quality, brand — or nil if the buyer won't touch it.
local function priceOfSlot(itemName, meta)
    meta = meta or {}
    local baseId, effects, quality, brand
    if itemName == Config.Items.bud then
        baseId = meta.strain
        brand = nil
    else
        baseId = meta.base
        brand = meta.brand
    end
    local drug = Config.Drugs[baseId]
    if not drug then return nil end
    effects = cloneEffects(meta.effects)
    quality = normQuality(meta.quality)
    return Config.Price(drug.base_value, effects, quality), baseId, quality, brand
end

-- Dirty dollars this character has already sold to the NPC faucet today.
local function dirtySoldToday(cid)
    local used = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(net_dirty),0) AS n FROM gtarp_drugs_sales \z
             WHERE citizenid = ? AND channel = 'npc' AND created_at >= CURDATE()", { cid })
        used = r and tonumber(r.n) or 0
    end)
    return used
end

RegisterNetEvent('gtarp_drugs:sellMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not near(src, Config.Sell.coords, Config.Sell.radius + Config.Sell.proximitySlack) then
        Bridge.Notify(src, Config.Sell.label, 'The buyer is not here.', 'error')
        return
    end

    local offers = {}
    local function addOffers(itemName)
        for _, s in ipairs(Bridge.ListItemSlots(src, itemName)) do
            local unit, _, quality, brand = priceOfSlot(itemName, s.metadata)
            if unit then
                local m = s.metadata or {}
                offers[#offers + 1] = {
                    slot = s.slot, item = itemName, count = s.count,
                    unit = unit, total = unit * s.count,
                    label = brand or (m.strain and (Config.Drugs[m.strain] and Config.Drugs[m.strain].label) or 'Loose buds'),
                    quality = quality,
                }
            end
        end
    end
    addOffers(Config.Items.product)
    addOffers(Config.Items.bud)

    TriggerClientEvent('gtarp_drugs:sellMenuData', src, {
        offers = offers,
        dailyRemaining = math.max(0, Config.Sell.dailyDirtyCap - dirtySoldToday(cid)),
    })
end)

RegisterNetEvent('gtarp_drugs:sell', function(slot, item)
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
    if item ~= Config.Items.product and item ~= Config.Items.bud then return end

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
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO gtarp_drugs_sales \z
             (citizenid, channel, brand, base, quality, units, gross, cut_paid, net_dirty, region, flagged, evidence_case_id) \z
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { cid, 'npc', brand or m.strain or 'buds', base, quality, units, total, 0, total,
              Config.Sell.region, flagged and 1 or 0, caseId })
    end)

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
-- time (a gtarp_drugs_processes row, kind='dry', epoch seconds), resolved on
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
            "SELECT * FROM gtarp_drugs_processes \z
             WHERE kind = 'dry' AND station_id = ? AND status IN ('running','collecting') LIMIT 1",
            { stationId })
    end)
    return row
end

-- Rack snapshot for the client menu (server truth).
RegisterNetEvent('gtarp_drugs:dryMenu', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
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

    TriggerClientEvent('gtarp_drugs:dryMenuData', src, {
        slots = slots, freshBuds = freshBuds,
        dryMinutes = math.max(1, math.floor(Config.Dry.baseDrySeconds / 60)),
    })
end)

RegisterNetEvent('gtarp_drugs:dryStart', function(stationId, budSlot)
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
            'INSERT INTO gtarp_drugs_processes \z
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

RegisterNetEvent('gtarp_drugs:dryCollect', function(stationId)
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
            "UPDATE gtarp_drugs_processes SET status = 'collecting' WHERE id = ? AND status = 'running'",
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
        pcall(function() MySQL.query.await('DELETE FROM gtarp_drugs_processes WHERE id = ?', { row.id }) end)
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
            MySQL.update.await("UPDATE gtarp_drugs_processes SET status = 'running' WHERE id = ?", { row.id })
        end)
        Bridge.Notify(src, Config.Dry.label, 'Your hands are full — collect again with room.', 'error')
        return
    end

    pcall(function() MySQL.query.await('DELETE FROM gtarp_drugs_processes WHERE id = ?', { row.id }) end)
    addXp(cid, Config.Dry.xp)

    Bridge.Notify(src, Config.Dry.label,
        ('Collected %dx %s buds — %s.'):format(count, drug.label or strain, Config.QualityLabel(quality)), 'success')
    dbg(('%s collected %dx dried %s (q%d) from rack slot %d'):format(cid, count, strain, quality, stationId))
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

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Self-disable loudly if a required item isn't registered in ox_inventory
    -- (mirrors gtarp_laundering / gtarp_flashdrop / gtarp_counterfeit).
    local core = {
        Config.Items.seed, Config.Items.soil, Config.Items.wateringcan,
        Config.Items.bud, Config.Items.product, Config.Items.dirty,
    }
    for _, item in ipairs(core) do
        if not Bridge.ItemExists(item) then
            print(('^1[gtarp_drugs] FATAL: required item "%s" is not registered in ox_inventory — '
                .. 'drugs disabled. Add it to ox_inventory_overrides/data/items.lua.^0'):format(item))
            return
        end
    end

    -- Additives are needed for the mixing station; warn (don't disable) per any
    -- that are missing so the operator can patch them in.
    local missing = {}
    for _, id in ipairs(Config.AdditiveOrder) do
        if not Bridge.ItemExists(id) then missing[#missing + 1] = id end
    end
    if #missing > 0 then
        table.sort(missing)
        print(('^3[gtarp_drugs] WARN: %d mix additive item(s) not registered — those additives are unusable until added: %s^0')
            :format(#missing, table.concat(missing, ', ')))
    end

    -- A crash mid-harvest can strand a plant at 'harvested'; free those plots.
    pcall(function()
        MySQL.query.await("DELETE FROM gtarp_drugs_plants WHERE stage = 'harvested'")
    end)

    -- A crash mid-collect can strand a dry process at 'collecting' (its buds
    -- were consumed at load time but never handed back); revert to 'running'
    -- so the owner can collect their Heavenly buds again — never delete these.
    pcall(function()
        MySQL.query.await("UPDATE gtarp_drugs_processes SET status = 'running' WHERE status = 'collecting'")
    end)

    booted = true
    local sales, dirty = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(net_dirty),0) AS s FROM gtarp_drugs_sales')
        sales = r and tonumber(r.c) or 0
        dirty = r and tonumber(r.s) or 0
    end)
    print(('[gtarp_drugs] supply chain online — %d grow plots, %d strains, %d additives; '
        .. '$%d dirty earned all-time across %d NPC sale(s)'):format(
        #Config.Grow.plots, #Config.StrainOrder, #Config.AdditiveOrder, dirty, sales))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalSales = 0, totalDirtyEarned = 0, flaggedSales = 0, activePlants = 0, activeDries = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(net_dirty),0) AS s, COALESCE(SUM(flagged),0) AS f FROM gtarp_drugs_sales')
        if r then
            out.totalSales = tonumber(r.c) or 0
            out.totalDirtyEarned = tonumber(r.s) or 0
            out.flaggedSales = tonumber(r.f) or 0
        end
        local p = MySQL.single.await("SELECT COUNT(*) AS c FROM gtarp_drugs_plants WHERE stage = 'growing'")
        out.activePlants = p and tonumber(p.c) or 0
        local dr = MySQL.single.await(
            "SELECT COUNT(*) AS c FROM gtarp_drugs_processes WHERE kind = 'dry' AND status IN ('running','collecting')")
        out.activeDries = dr and tonumber(dr.c) or 0
    end)
    return out
end)
