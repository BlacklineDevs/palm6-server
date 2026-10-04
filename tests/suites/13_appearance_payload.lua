-- ============================================================================
-- 13_appearance_payload.lua — palm6_appearance
--
-- What is pinned here, and why each one matters on a live server.
--
-- 1. THE MODEL ALLOWLIST. A saved appearance is client-supplied data: it
--    arrives on the palm6_appearance:server:save net event, is stored, and is
--    read back on the next join and handed to SET_PLAYER_MODEL. If the stored
--    `model` were whatever the client sent, a modified client could persist any
--    model string and be spawned as it forever. sanitizeAppearance is the gate,
--    and this suite asserts it from several directions. This is the
--    security-relevant half of the file.
--
-- 2. THE GENDER INVARIANT. docs/CUSTOM-CLOTHING.md §5: male and female drawable
--    index spaces are completely disjoint, so a capture must carry the model it
--    was taken on and must be refused against any other. The payload had NO
--    model field at all before this pass, which is the exact "do not guess and
--    do not fall back" case that document is about.
--
-- 3. "NO PROP" IS A REAL STATE. A cleared hat is stored as active=false with no
--    collection; dropping those entries as malformed would silently turn
--    "deliberately no hat" into "nothing was recorded".
--
-- The production bytes are LIFTED, not reimplemented: T.slice pulls the real
-- sanitizer out of server/main.lua by anchor, so moving or rewriting it fails
-- this suite loudly instead of leaving it testing a stale copy.
-- ============================================================================

T.begin('palm6_appearance — saved-payload sanitisation and the model allowlist')

local SERVER = 'resources/[custom]/palm6_appearance/server/main.lua'
local CLIENT = 'resources/[custom]/palm6_appearance/client/main.lua'

-- The shipped config becomes the global `Config`, exactly as it does in game -
-- with ONE mechanical substitution. Config.AllowedPreviewModels uses CFX's
-- backtick hash literal (`mp_m_freemode_01`), which is a FiveM extension to
-- Lua and not something a standard 5.3 VM can parse, so fengari rejects the
-- file outright. Rewriting the literals into a joaat() call and stubbing joaat
-- as identity keeps every real value in this suite (the config is still the
-- shipped file, read at test time) while making it loadable. The stub means a
-- "hash" here is the model name itself, which is exactly as opaque to these
-- assertions as a real hash would be - nothing below cares what the number is,
-- only that the SAME entry comes back.
-- vec3 is a CFX global too (camera region offsets). The sanitiser under test
-- never touches those values; a plain table keeps the config loadable without
-- pretending to model FiveM's vector type.
joaat = function(name) return name end
vec3 = function(x, y, z) return { x = x, y = y, z = z } end
T.chunk('appearance config',
    (T.source('resources/[custom]/palm6_appearance/shared/config.lua')
        :gsub('`([%w_]+)`', "joaat('%1')")))()

local sanitize = T.chunk('sanitizeAppearance', T.slice(
    SERVER,
    'local function isNumberInRange(value, min, max)',
    "RegisterNetEvent('palm6_appearance:server:save'"
) .. '\nreturn sanitizeAppearance')()

local allowlistedModelHash = T.chunk('allowlistedModelHash', T.slice(
    CLIENT,
    'local function allowlistedModelHash(payload)',
    'local function applyToRealPlayer(payload)'
) .. '\nreturn allowlistedModelHash')()

-- A minimal payload that SHOULD survive, so every rejection test below differs
-- from a passing one by exactly the thing it is about.
local function validPayload(overrides)
    local p = {
        version = 1,
        model = 'mp_m_freemode_01',
        gender = 'male',
        headBlend = {
            shapeFirst = 3, shapeSecond = 12, shapeThird = 0,
            skinFirst = 3, skinSecond = 12, skinThird = 0,
            shapeMix = 0.5, skinMix = 0.5, thirdMix = 0.0,
        },
        faceFeatures = { ['0'] = 0.25, ['19'] = -0.5 },
        overlays = { ['1'] = { index = 4, opacity = 0.8, color1 = 3, color2 = 3 } },
        hairColor = 5, hairHighlight = 5, eyeColor = 2,
        components = {
            { id = 11, state = { collectionName = '', drawableId = 14, textureId = 2 } },
        },
        props = {
            { id = 0, state = { collectionName = '', drawableId = 8, textureId = 0, active = true } },
            { id = 1, state = { active = false } },
        },
    }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end

-- ---------------------------------------------------------------------------
T.section('the model allowlist — the value that reaches SET_PLAYER_MODEL')
-- ---------------------------------------------------------------------------

T.eq('a male freemode capture is stored with its model intact',
    sanitize(validPayload()).model, 'mp_m_freemode_01')

T.eq('a female freemode capture is stored with its model intact',
    sanitize(validPayload({ model = 'mp_f_freemode_01', gender = 'female' })).model, 'mp_f_freemode_01')

T.isnil('an arbitrary ped model is refused outright',
    sanitize(validPayload({ model = 'a_c_chop' })))

T.isnil('a cutscene/story ped model is refused outright',
    sanitize(validPayload({ model = 'player_zero' })))

-- Removed explicitly rather than via the overrides table: assigning nil into a
-- Lua table is the same as never setting the key, so `{ model = nil }` would
-- have silently tested the untouched valid payload instead.
local noModel = validPayload()
noModel.model = nil
T.isnil('a payload with NO model at all is refused (the pre-v1 shape)', sanitize(noModel))

T.isnil('a non-string model is refused',
    sanitize(validPayload({ model = 1234 })))

T.isnil('a model that merely CONTAINS an allowed name is refused, not matched loosely',
    sanitize(validPayload({ model = 'mp_m_freemode_01_evil' })))

T.isnil('a gender outside male/female is refused',
    sanitize(validPayload({ gender = 'other' })))

T.isnil('a non-table payload is refused',
    sanitize('mp_m_freemode_01'))

-- The client-side resolver is the second half of the same gate: it decides
-- which hash is actually passed to SET_PLAYER_MODEL.
T.eq('the client resolves an allowed male model to the config hash',
    allowlistedModelHash({ model = 'mp_m_freemode_01' }), Config.AllowedPreviewModels.male)

T.eq('the client resolves an allowed female model to the config hash',
    allowlistedModelHash({ model = 'mp_f_freemode_01' }), Config.AllowedPreviewModels.female)

T.isnil('the client refuses to resolve anything outside the allowlist',
    allowlistedModelHash({ model = 'a_c_chop' }))

T.isnil('the client refuses a payload with no model',
    allowlistedModelHash({}))

-- ---------------------------------------------------------------------------
T.section('version stamping')
-- ---------------------------------------------------------------------------

T.eq('the stored version is the SERVER config value, not the client claim',
    sanitize(validPayload({ version = 99 })).version, Config.AppearanceSchemaVersion)

-- ---------------------------------------------------------------------------
T.section('numeric ranges are clamped to defaults, never stored as sent')
-- ---------------------------------------------------------------------------

local out = sanitize(validPayload())
T.eq('a legitimate face feature survives', out.faceFeatures['0'], 0.25)
T.eq('a legitimate negative face feature survives', out.faceFeatures['19'], -0.5)

local wild = sanitize(validPayload({ faceFeatures = { ['0'] = 99.0, ['3'] = -99.0, ['99'] = 0.5 } }))
T.isnil('a face feature above the allowed range is dropped', wild.faceFeatures['0'])
T.isnil('a face feature below the allowed range is dropped', wild.faceFeatures['3'])
T.isnil('a face feature index outside 0..FaceFeatureCount is dropped', wild.faceFeatures['99'])

local blend = sanitize(validPayload({
    headBlend = { shapeFirst = 999, skinFirst = -1, shapeMix = 5.0, skinMix = 0.25 },
})).headBlend
T.eq('an out-of-range head-blend parent falls back to 0', blend.shapeFirst, 0)
T.eq('a negative head-blend parent falls back to 0', blend.skinFirst, 0)
T.eq('an out-of-range blend mix falls back to 0.5', blend.shapeMix, 0.5)
T.eq('an in-range blend mix is preserved exactly', blend.skinMix, 0.25)

local colors = sanitize(validPayload({ hairColor = 500, eyeColor = -3 }))
T.eq('an out-of-range hair colour falls back to 0', colors.hairColor, 0)
T.eq('an out-of-range eye colour falls back to 0', colors.eyeColor, 0)

local ov = sanitize(validPayload({
    overlays = {
        ['1'] = { index = 4, opacity = 9.0, color1 = 900 },
        ['99'] = { index = 1, opacity = 0.5 },
    },
})).overlays
T.eq('an out-of-range overlay opacity falls back to 0', ov['1'].opacity, 0.0)
T.isnil('an out-of-range overlay colour is dropped rather than clamped', ov['1'].color1)
T.isnil('an overlay id outside 0..12 is dropped entirely', ov['99'])

-- ---------------------------------------------------------------------------
T.section('wardrobe entries — component and prop shape')
-- ---------------------------------------------------------------------------

T.eq('a valid component survives', #out.components, 1)
T.eq('...with its component id', out.components[1].id, 11)
T.eq('...its collection name (empty string means the base game)', out.components[1].state.collectionName, '')
T.eq('...and its drawable index', out.components[1].state.drawableId, 14)

T.eq('a component id above 11 is dropped', #sanitize(validPayload({
    components = { { id = 40, state = { collectionName = '', drawableId = 1, textureId = 0 } } },
})).components, 0)

T.eq('a component with a non-string collection is dropped', #sanitize(validPayload({
    components = { { id = 4, state = { collectionName = 7, drawableId = 1, textureId = 0 } } },
})).components, 0)

T.eq('a component with a negative drawable is dropped', #sanitize(validPayload({
    components = { { id = 4, state = { collectionName = '', drawableId = -1, textureId = 0 } } },
})).components, 0)

T.eq('both props are kept, worn and cleared alike', #out.props, 2)
T.istrue('the worn prop stays active', out.props[1].state.active)
T.eq('...with its drawable index', out.props[1].state.drawableId, 8)
T.isfalse('the CLEARED prop is preserved as an explicit "no prop", not dropped',
    out.props[2].state.active)

-- A cleared prop as Wardrobe.CaptureCurrentProp actually reports it: no
-- collection at all and drawableId -1. This is the shape that would be thrown
-- away by a naive "must look worn" check.
local cleared = sanitize(validPayload({
    props = { { id = 0, state = { collectionName = nil, drawableId = -1, textureId = 0, active = false } } },
})).props
T.eq('a real captured "no prop" state is kept', #cleared, 1)
T.isfalse('...and stays inactive', cleared[1].state.active)

-- ---------------------------------------------------------------------------
T.section('unknown keys are dropped, not passed through')
-- ---------------------------------------------------------------------------

local injected = sanitize(validPayload({ evil = 'payload', model = 'mp_m_freemode_01' }))
T.isnil('a key the sanitiser does not know about never reaches the database',
    injected.evil)

-- ---------------------------------------------------------------------------
T.section('structural invariants')
-- ---------------------------------------------------------------------------

-- The whole point of the appearance rewrite: persistence that is written and
-- never read is not persistence. If the restore call disappears again, the
-- editor silently goes back to saving into a hole.
T.contains('the client still CALLS the load callback it registers',
    T.source(CLIENT), "lib.callback.await, 'palm6_appearance:server:load'")

T.contains('the finished appearance is still applied to the real player ped',
    T.source(CLIENT), 'applyToRealPlayer(resolveValue)')

-- palm6_threads' legacy: paletteId is ALWAYS 0.
T.notcontains('no palette id other than 0 is ever passed to a component variation',
    T.source('resources/[custom]/palm6_appearance/bridge/cl_game.lua'),
    'textureId, 2)')

T.done()
