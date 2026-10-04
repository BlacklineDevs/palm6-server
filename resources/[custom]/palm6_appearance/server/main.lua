-- ============================================================================
-- palm6_appearance/server/main.lua
-- Logic only. Every framework/DB call routes through Bridge.* (bridge/sv_framework.lua).
-- ============================================================================

local READY = false            -- flips true once the table is confirmed present

-- ---------------------------------------------------------------------------
-- Boot: self-create the table. Idempotent, guarded — palm6_heat's precedent.
-- CI never touches the DB, so a fresh box or restored backup must be able to
-- boot this resource cold.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_appearance_data` (
                `citizenid`       VARCHAR(50)  NOT NULL,
                `appearance_json` LONGTEXT     NOT NULL,
                `updated_at`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if ok then
        READY = true
        print('[palm6_appearance] schema ready (palm6_appearance_data)')
    else
        print(('[palm6_appearance] FATAL: could not create palm6_appearance_data (%s). Resource is inert until the DB is reachable.'):format(tostring(err)))
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ensureSchema()
end)

-- ---------------------------------------------------------------------------
-- Payload validation.
--
-- This existed as a COMMENT ("server-side re-validation mirrors client clamps
-- — never trust the client for ranges") above a check that was only
-- `type(payload) == 'table'`. Everything else the client sent was encoded and
-- stored verbatim, and the stored row is read back and applied to a ped on the
-- next join - so the event was an arbitrary-write into what a player looks
-- like, bounded by nothing.
--
-- What this can and cannot do: it cannot confirm a drawable index exists,
-- because that is only knowable with a live ped in a game context (the client
-- re-checks every one with IsPedCollection*Valid before applying, which is the
-- gate that actually protects against invalid component data). What it CAN do
-- is enforce shape, numeric ranges, and - the one that matters most - that the
-- model is one of the two allowlisted freemode peds, since that value ends up
-- at SET_PLAYER_MODEL on the client.
-- ---------------------------------------------------------------------------

local function isNumberInRange(value, min, max)
    return type(value) == 'number' and value == value and value >= min and value <= max
end

local function isAllowedModel(name)
    for _, allowed in pairs(Config.PreviewModelNames) do
        if allowed == name then return true end
    end
    return false
end

--- Returns a cleaned copy of the payload, or nil if it is not storable.
--- Unknown keys are dropped rather than passed through: what gets stored is
--- exactly what this function chose to keep.
local function sanitizeAppearance(payload)
    if type(payload) ~= 'table' then return nil end
    if not isAllowedModel(payload.model) then return nil end
    if payload.gender ~= 'male' and payload.gender ~= 'female' then return nil end

    local clean = {
        version = Config.AppearanceSchemaVersion,
        model = payload.model,
        gender = payload.gender,
        faceFeatures = {},
        overlays = {},
        components = {},
        props = {},
    }

    local blend = payload.headBlend
    if type(blend) == 'table' then
        local hb = { min = Config.HeadBlendRange.min, max = Config.HeadBlendRange.max }
        clean.headBlend = {
            shapeFirst  = isNumberInRange(blend.shapeFirst, hb.min, hb.max) and blend.shapeFirst or 0,
            shapeSecond = isNumberInRange(blend.shapeSecond, hb.min, hb.max) and blend.shapeSecond or 0,
            shapeThird  = isNumberInRange(blend.shapeThird, hb.min, hb.max) and blend.shapeThird or 0,
            skinFirst   = isNumberInRange(blend.skinFirst, hb.min, hb.max) and blend.skinFirst or 0,
            skinSecond  = isNumberInRange(blend.skinSecond, hb.min, hb.max) and blend.skinSecond or 0,
            skinThird   = isNumberInRange(blend.skinThird, hb.min, hb.max) and blend.skinThird or 0,
            shapeMix    = isNumberInRange(blend.shapeMix, 0.0, 1.0) and blend.shapeMix or 0.5,
            skinMix     = isNumberInRange(blend.skinMix, 0.0, 1.0) and blend.skinMix or 0.5,
            thirdMix    = isNumberInRange(blend.thirdMix, 0.0, 1.0) and blend.thirdMix or 0.0,
        }
    end

    if type(payload.faceFeatures) == 'table' then
        local fr = Config.FaceFeatureRange
        for index, value in pairs(payload.faceFeatures) do
            local i = tonumber(index)
            if i and i >= 0 and i < Config.FaceFeatureCount and isNumberInRange(value, fr.min, fr.max) then
                clean.faceFeatures[tostring(math.floor(i))] = value
            end
        end
    end

    if type(payload.overlays) == 'table' then
        for overlayId, ov in pairs(payload.overlays) do
            local id = tonumber(overlayId)
            -- Head overlay ids are 0-12 on every build; opacity is 0..1.
            if id and id >= 0 and id <= 12 and type(ov) == 'table' then
                clean.overlays[tostring(math.floor(id))] = {
                    index = isNumberInRange(ov.index, -1, 255) and ov.index or 255,
                    opacity = isNumberInRange(ov.opacity, 0.0, 1.0) and ov.opacity or 0.0,
                    color1 = isNumberInRange(ov.color1, 0, 63) and ov.color1 or nil,
                    color2 = isNumberInRange(ov.color2, 0, 63) and ov.color2 or nil,
                }
            end
        end
    end

    clean.hairColor     = isNumberInRange(payload.hairColor, 0, 63) and payload.hairColor or 0
    clean.hairHighlight = isNumberInRange(payload.hairHighlight, 0, 63) and payload.hairHighlight or clean.hairColor
    clean.eyeColor      = isNumberInRange(payload.eyeColor, 0, 31) and payload.eyeColor or 0

    -- Wardrobe. Component ids 0-11, prop ids 0-7; drawable/texture indices are
    -- bounded generously here and re-validated for real against the live ped
    -- (IsPedCollectionComponentVariationValid) before anything is applied.
    -- A worn slot: a real collection name ('' is legitimate and means the base
    -- game's own collection) plus indices inside sane bounds.
    local function isWornState(s)
        return type(s) == 'table'
            and type(s.collectionName) == 'string' and #s.collectionName <= 64
            and isNumberInRange(s.drawableId, 0, 4096)
            and isNumberInRange(s.textureId, 0, 256)
    end

    local function entryId(entry, maxId)
        local id = tonumber(entry and entry.id)
        if not id or id < 0 or id > maxId then return nil end
        return math.floor(id)
    end

    -- KEYED BY ID, THEN FLATTENED - the count cap is structural, not a counter.
    --
    -- Both of these lists were appended to with no cap and no de-dup, while
    -- every other field in this payload is bounded by construction
    -- (faceFeatures and overlays are keyed writes; the scalars are range
    -- checks). 50,000 valid-looking entries all carrying id 4 survived every
    -- check here and landed in `appearance_json LONGTEXT`, via a blocking
    -- json.encode on the server thread, at the 8-writes-per-minute the
    -- eventguard budget allows.
    --
    -- A duplicate id is meaningless anyway: applySavedAppearance applies them
    -- in order and the last one wins, which is exactly what assigning into a
    -- keyed table gives - the same result, in at most 12 and 8 entries.
    local componentsById = {}
    if type(payload.components) == 'table' then
        for _, entry in ipairs(payload.components) do
            local id = entryId(entry, 11)   -- component ids 0-11, docs/CUSTOM-CLOTHING.md §5
            if id and isWornState(entry.state) then
                componentsById[id] = {
                    id = id,
                    state = {
                        collectionName = entry.state.collectionName,
                        drawableId = math.floor(entry.state.drawableId),
                        textureId = math.floor(entry.state.textureId),
                    },
                }
            end
        end
    end
    for id = 0, 11 do
        if componentsById[id] then clean.components[#clean.components + 1] = componentsById[id] end
    end

    local propsById = {}
    if type(payload.props) == 'table' then
        for _, entry in ipairs(payload.props) do
            local id = entryId(entry, 7)    -- prop ids 0 head, 1 eyes, 2 ears, 6 watch, 7 bracelet
            local s = entry and entry.state
            if id and type(s) == 'table' then
                -- "No prop" is a real, storable state: Wardrobe.CaptureCurrentProp
                -- reports a cleared prop as active=false with a nil collection
                -- and drawableId -1. Dropping those entries would silently turn
                -- "deliberately no hat" into "nothing was recorded".
                if s.active and isWornState(s) then
                    propsById[id] = {
                        id = id,
                        state = {
                            collectionName = s.collectionName,
                            drawableId = math.floor(s.drawableId),
                            textureId = math.floor(s.textureId),
                            active = true,
                        },
                    }
                else
                    propsById[id] = { id = id, state = { active = false } }
                end
            end
        end
    end
    for id = 0, 7 do
        if propsById[id] then clean.props[#clean.props + 1] = propsById[id] end
    end

    return clean
end

RegisterNetEvent('palm6_appearance:server:save', function(appearancePayload)
    local source = source
    if not READY then return end
    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then return end

    local clean = sanitizeAppearance(appearancePayload)
    if not clean then
        Bridge.Notify(source, 'That appearance could not be saved.', 'error')
        return
    end

    local encoded = json.encode(clean)
    Bridge.SaveAppearance(citizenid, encoded)
    Bridge.Notify(source, 'Appearance saved.', 'success')
end)

-- Server-to-server export for palm6_charselect's character-select ped
-- previews. Server-only: nothing client-facing can reach an export, so this
-- never becomes a way for a client to read another player's appearance. The
-- CALLER is responsible for proving the requester owns every citizenid it
-- asks about (palm6_charselect does, against qbx_core's `players` table).
---@param citizenids string[]
---@return table<string, table> citizenid -> decoded appearance payload
exports('GetAppearanceForCitizenIds', function(citizenids)
    local out = {}
    if not READY or type(citizenids) ~= 'table' then return out end

    -- Bounded: a qbx_core account holds a handful of characters. A caller
    -- asking for hundreds is either broken or probing; answer the first few
    -- and ignore the rest rather than building an unbounded IN() list.
    local capped = {}
    for i = 1, math.min(#citizenids, 16) do
        if type(citizenids[i]) == 'string' then capped[#capped + 1] = citizenids[i] end
    end

    for citizenid, raw in pairs(Bridge.GetAppearanceBatch(capped)) do
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then out[citizenid] = decoded end
    end
    return out
end)

-- Admin-only QA entry point for the editor. Registered HERE, on the server,
-- with restricted = true, precisely because the client cannot gate itself: an
-- ACE check only means anything server-side. The client half is a plain net
-- event that this handler is the only legitimate sender of.
--
-- Note the event it triggers is a CLIENT event sent to one source - a client
-- can technically raise its own local event, but doing so only opens that
-- player's own editor, which is exactly what an admin would have granted them
-- anyway; nothing here writes to another player. The value of the gate is that
-- the COMMAND no longer advertises a free barbershop to every player who reads
-- a command list.
RegisterCommand('palm6appearance', function(source, args)
    if source == 0 then
        print('[palm6_appearance] /palm6appearance must be run by a player, not the console.')
        return
    end
    local genderKey = args[1] == 'female' and 'female' or 'male'
    TriggerClientEvent('palm6_appearance:client:openEditor', source, genderKey)
end, true) -- restricted=true: requires the command.palm6appearance ACE

-- ---------------------------------------------------------------------------
-- Rate limit for the load callback, in-handler, because palm6_eventguard
-- structurally cannot express it.
--
-- Every other client-reachable entry point in these three resources has an
-- eventguard budget (palm6_eventguard/config.lua). This one cannot: eventguard
-- keys on literal net-event NAMES and hooks them with AddEventHandler, while an
-- ox_lib callback arrives on a fixed transport event registered by a recipe
-- resource that starts BEFORE custom.cfg - the exact load-order failure
-- eventguard's own config documents about itself.
--
-- Without a limit this is one MySQL.single.await per call, looped as fast as
-- the network allows. It is read-only and correctly scoped to the caller, so
-- the risk is exhaustion, not disclosure.
--
-- 5 per 60s clips nothing legitimate: the real callers are one restore per
-- spawn and one load per editor open.
local LOAD_LIMIT_WINDOW_SECONDS = 60
local LOAD_LIMIT_PER_WINDOW = 5
local loadHits = {}   -- src -> { windowStart = os.time(), count = n }

local function loadCallAllowed(src)
    local now = os.time()
    local hit = loadHits[src]
    if not hit or (now - hit.windowStart) >= LOAD_LIMIT_WINDOW_SECONDS then
        loadHits[src] = { windowStart = now, count = 1 }
        return true
    end
    hit.count = hit.count + 1
    if hit.count > LOAD_LIMIT_PER_WINDOW then
        -- Logged once at the threshold, not on every rejected call - the point
        -- of the limit is to stop a flood, not to replace it with a log flood.
        if hit.count == LOAD_LIMIT_PER_WINDOW + 1 then
            print(('[palm6_appearance] rate-limited appearance loads from src %s'):format(tostring(src)))
        end
        return false
    end
    return true
end

AddEventHandler('playerDropped', function()
    loadHits[source] = nil
end)

lib.callback.register('palm6_appearance:server:load', function(source)
    if not READY then return nil end
    if not loadCallAllowed(source) then return nil end
    local citizenid = Bridge.GetCitizenId(source)
    if not citizenid then return nil end

    local stored = Bridge.GetAppearance(citizenid)
    if not stored then return nil end

    local ok, decoded = pcall(json.decode, stored)
    if not ok then return nil end
    return decoded
end)
