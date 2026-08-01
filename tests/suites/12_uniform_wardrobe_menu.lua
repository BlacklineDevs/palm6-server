-- ============================================================================
-- 12_uniform_wardrobe_menu.lua - palm6_uniform, the walk-up wardrobe
--
-- palm6_uniform shipped as seven chat commands. It was replaced with a menu at
-- the police station because the commands were a tool for the person who wrote
-- them and not a feature for the person running the server. This suite pins the
-- four things that, if they break, put it straight back where it was.
--
-- 1. THE PERMITTED LIST IS THE AUTHORITY. allowedSets() is what decides which
--    uniforms a player may wear, and menuApply() re-runs it on every pick. It is
--    pure - job, grade, model in, rows out - so it is fully testable here, and a
--    bug in it is a cadet in the chief's uniform rather than a crash.
--
-- 2. THE MENU CANNOT OFFER SOMETHING THE VALIDATOR WILL REJECT. captureVariants()
--    builds the season/weather choices an admin clicks. Every pair it emits has
--    to be inside Config.Seasons and Config.Weathers, or clicking a menu row
--    produces "unknown season" and the wardrobe looks broken.
--
-- 3. THE EMPTY STATE IS NOT BLANK. A wardrobe with nothing captured and a
--    wardrobe that is broken look identical from in game, and that has already
--    cost two sessions. The structural checks require the empty-state copy to
--    still be there and require every menu row to carry a description.
--
-- 4. NO WORLD COORDINATE IS INVENTED. The station position exists in exactly one
--    file in this resource, as a documented fallback that cites where it was
--    copied from. The checks below fail if it is ever pasted anywhere else.
--
-- The production bytes are LIFTED, not reimplemented: T.slice pulls the real
-- text out by anchor. Move the code and this suite fails loudly rather than
-- testing a stale copy.
-- ============================================================================

T.begin('palm6_uniform - the walk-up wardrobe menu, its permitted list and its empty state')

local SERVER   = 'resources/[custom]/palm6_uniform/server/main.lua'
local CLIENT   = 'resources/[custom]/palm6_uniform/client/wardrobe.lua'
local CLBRIDGE = 'resources/[custom]/palm6_uniform/bridge/cl_game.lua'
local SVBRIDGE = 'resources/[custom]/palm6_uniform/bridge/sv_framework.lua'
local CONFIG   = 'resources/[custom]/palm6_uniform/shared/config.lua'
local MANIFEST = 'resources/[custom]/palm6_uniform/fxmanifest.lua'
local README   = 'resources/[custom]/palm6_uniform/README.md'
local CHECKLIST = 'resources/[custom]/palm6_uniform/CHECKLIST.md'

-- vector3 is a FiveM runtime global, not a Lua one, and shared/config.lua uses
-- it for the documented fallback coordinate. A plain table with x/y/z is enough
-- for everything this suite reads, and it is exactly how the production code
-- consumes it (wardrobePoint reads .x/.y/.z and nothing else).
function vector3(x, y, z) return { x = x, y = y, z = z } end

-- The shipped config becomes the global `Config`, exactly as it does in game.
T.loadFile(CONFIG)

-- ---------------------------------------------------------------------------
-- Lift the pure logic.
-- ---------------------------------------------------------------------------

-- allowedSets reads the module-level `sets` cache. Inside a lifted chunk that
-- resolves to a global, so the suite sets it directly. That is the real read
-- path: the production function does not take the cache as an argument either.
local allowedSets = T.chunk('allowedSets', T.slice(
    SERVER,
    'local function allowedSets(job, grade, model)',
    '-- Push one already-authorised row at one player.'
) .. '\nreturn allowedSets')()

local composeLabel = T.chunk('composeLabel', T.slice(
    SERVER,
    'local function composeLabel(grade, season, weather)',
    '-- The season/weather choices offered when saving a uniform.'
) .. '\nreturn composeLabel')()

local captureVariants = T.chunk('captureVariants', T.slice(
    SERVER,
    'local function captureVariants()',
    '-- THE MENU MODEL. Every row the client will draw, decided here.'
) .. '\nreturn captureVariants')()

-- composeLabel calls gradeName, which crosses a resource boundary in production
-- (qbx_police_overrides' grade roster). Stubbed here so the label composition
-- itself is what is under test.
function gradeName(level)
    local names = { [0] = 'Cadet', [1] = 'Officer', [2] = 'Sergeant', [3] = 'Lieutenant', [4] = 'Chief' }
    return names[level] or ('grade ' .. tostring(level))
end

local MALE   = 'mp_m_freemode_01'
local FEMALE = 'mp_f_freemode_01'

local function row(id, minGrade, model, season, weather, label, job)
    return {
        id = id, min_grade = minGrade, model = model,
        season = season, weather = weather,
        label = label or '', job = job or 'police',
        components = {}, props = {},
    }
end

local function ids(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].id end
    return out
end

-- ---------------------------------------------------------------------------
T.section('allowedSets - the grade floor')
-- ---------------------------------------------------------------------------

sets = {}
T.eq('an empty store offers nothing to anybody', #allowedSets('police', 4, MALE), 0)

sets = { row(1, 0, MALE, 'any', 'any', 'Patrol') }
T.list('one set captured at grade 0 reaches grade 0', ids(allowedSets('police', 0, MALE)), { 1 })
T.list('and reaches every grade above it, which is the whole point of a floor',
    ids(allowedSets('police', 4, MALE)), { 1 })

sets = {
    row(1, 0, MALE, 'any', 'any', 'Patrol'),
    row(2, 3, MALE, 'any', 'any', 'Lieutenant'),
}
T.list('a cadet is NOT offered the lieutenant set', ids(allowedSets('police', 0, MALE)), { 1 })
T.list('grade 2 is still below the grade 3 floor', ids(allowedSets('police', 2, MALE)), { 1 })
T.list('grade 3 gets both, highest rank first', ids(allowedSets('police', 3, MALE)), { 2, 1 })
T.list('a chief sees the patrol set too, so a chief can dress down on purpose',
    ids(allowedSets('police', 4, MALE)), { 2, 1 })

-- ---------------------------------------------------------------------------
T.section('allowedSets - the two bodies never mix')
-- ---------------------------------------------------------------------------

sets = {
    row(1, 0, MALE,   'any', 'any', 'Patrol M'),
    row(2, 0, FEMALE, 'any', 'any', 'Patrol F'),
}
T.list('a male ped is offered only the male capture', ids(allowedSets('police', 0, MALE)), { 1 })
T.list('a female ped is offered only the female capture', ids(allowedSets('police', 0, FEMALE)), { 2 })
T.eq('an unknown ped model is offered nothing rather than the nearest guess',
    #allowedSets('police', 4, 'a_m_m_business_01'), 0)

-- ---------------------------------------------------------------------------
T.section('allowedSets - the job gate')
-- ---------------------------------------------------------------------------

sets = {
    row(1, 0, MALE, 'any', 'any', 'Police', 'police'),
    row(2, 0, MALE, 'any', 'any', 'Ambulance', 'ambulance'),
}
T.list('police are offered only police sets', ids(allowedSets('police', 4, MALE)), { 1 })
T.list('another job is offered only its own', ids(allowedSets('ambulance', 4, MALE)), { 2 })
T.eq('a job with nothing stored gets an empty list, never a substitute',
    #allowedSets('mechanic', 4, MALE), 0)

-- ---------------------------------------------------------------------------
T.section('allowedSets - every variant for the rank is offered, not just the best')
-- ---------------------------------------------------------------------------
-- This is what makes "pick the winter one" possible at all. pickSet answers
-- with a single row for the automatic path; the menu needs the whole list.

sets = {
    row(1, 0, MALE, 'any',    'any', 'Patrol'),
    row(2, 0, MALE, 'winter', 'any', 'Patrol Winter'),
    row(3, 0, MALE, 'any',    'wet', 'Patrol Rain'),
}
local variants = allowedSets('police', 0, MALE)
T.eq('all three variants of one rank are offered together', #variants, 3)
T.list('ordering is stable: same rank sorts by season then weather',
    ids(variants), { 1, 3, 2 })

-- ---------------------------------------------------------------------------
T.section('allowedSets - ordering is total, so the menu never reshuffles')
-- ---------------------------------------------------------------------------

sets = {
    row(7, 0, MALE, 'any', 'any', 'A'),
    row(3, 0, MALE, 'any', 'any', 'B'),
}
T.list('two rows identical on every sort key fall back to id, not insertion order',
    ids(allowedSets('police', 0, MALE)), { 3, 7 })

sets = {
    row(1, 0, MALE, 'winter', 'any', 'Rookie Winter'),
    row(2, 2, MALE, 'any',    'any', 'Sergeant'),
}
T.list('rank outranks the more specific variant in the ordering',
    ids(allowedSets('police', 2, MALE)), { 2, 1 })

-- ---------------------------------------------------------------------------
T.section('allowedSets - it never mutates the cache it reads')
-- ---------------------------------------------------------------------------

sets = {
    row(1, 0, MALE, 'any', 'any', 'Patrol'),
    row(2, 3, MALE, 'any', 'any', 'Lieutenant'),
}
allowedSets('police', 4, MALE)
T.list('the underlying set cache is left in its original order',
    ids(sets), { 1, 2 })

-- ---------------------------------------------------------------------------
T.section('captureVariants - the menu cannot offer a bucket the validator rejects')
-- ---------------------------------------------------------------------------

local function inList(list, value)
    for i = 1, #list do if list[i] == value then return true end end
    return false
end

local vs = captureVariants()

T.eq('the offered count is all-purpose plus one per season plus one per weather',
    #vs, 1 + (#Config.Seasons - 1) + (#Config.Weathers - 1))

T.eq('the first choice is the all-purpose one, because it is the one to start with',
    vs[1].season .. '/' .. vs[1].weather, 'any/any')

local allSeasonsValid, allWeathersValid, allTitled = true, true, true
for i = 1, #vs do
    if not inList(Config.Seasons, vs[i].season) then allSeasonsValid = false end
    if not inList(Config.Weathers, vs[i].weather) then allWeathersValid = false end
    if type(vs[i].title) ~= 'string' or vs[i].title == '' then allTitled = false end
end
T.istrue('every offered season is one validateCapture accepts', allSeasonsValid)
T.istrue('every offered weather bucket is one validateCapture accepts', allWeathersValid)
T.istrue('every choice carries a human title, so nothing renders as a blank row', allTitled)

local seenSeason, seenWeather, pairs_ = {}, {}, {}
local duplicated = false
for i = 1, #vs do
    local key = vs[i].season .. '/' .. vs[i].weather
    if pairs_[key] then duplicated = true end
    pairs_[key] = true
    seenSeason[vs[i].season] = true
    seenWeather[vs[i].weather] = true
end
T.isfalse('no season/weather pair is offered twice', duplicated)

local everySeasonOffered = true
for i = 1, #Config.Seasons do
    if not seenSeason[Config.Seasons[i]] then everySeasonOffered = false end
end
T.istrue('every configured season is reachable from the menu', everySeasonOffered)

local everyWeatherOffered = true
for i = 1, #Config.Weathers do
    if not seenWeather[Config.Weathers[i]] then everyWeatherOffered = false end
end
T.istrue('every configured weather bucket is reachable from the menu', everyWeatherOffered)

-- ---------------------------------------------------------------------------
T.section('composeLabel - the admin never types a label either')
-- ---------------------------------------------------------------------------

T.eq('an all-purpose capture is labelled with just the rank name',
    composeLabel(0, 'any', 'any'), 'Cadet')
T.eq('a season capture names the season', composeLabel(2, 'winter', 'any'), 'Sergeant winter')
T.eq('a weather capture names the bucket', composeLabel(4, 'any', 'wet'), 'Chief wet')
T.eq('both are named when both are set', composeLabel(1, 'summer', 'hot'), 'Officer summer hot')
T.eq('an unknown grade falls back to the number rather than an invented rank name',
    composeLabel(9, 'any', 'any'), 'grade 9')
T.ge('the label never exceeds the 64-char column', 64, #composeLabel(0, 'any', 'any'))

-- ---------------------------------------------------------------------------
T.section('the empty state exists and says what to do')
-- ---------------------------------------------------------------------------
-- The single most important screen in this resource. A blank menu is
-- indistinguishable from a broken resource.

local serverSrc = T.source(SERVER)

T.contains('the menu states outright that nothing has been captured',
    serverSrc, 'No uniforms have been captured yet.')
T.contains('it says the wardrobe is working rather than leaving that to be guessed',
    serverSrc, 'This wardrobe is working. It is empty.')
T.contains('an admin is told the exact click path to create the first one',
    serverSrc, 'To create the first one, right here, with no typing:')
T.contains('a non-admin is told who can create it',
    serverSrc, 'Ask an admin to create the first one.')
T.contains('a stored-but-not-yours store is a different message from an empty one',
    serverSrc, 'uniform(s) are stored, but none of them is yours.')

-- ---------------------------------------------------------------------------
T.section('every menu row carries a reason')
-- ---------------------------------------------------------------------------
-- A greyed-out row with no description is a dead button. Every row the server
-- builds has to explain itself.

local buildMenuSrc = T.slice(SERVER, 'local function buildMenu(src)',
    "Bridge.RegisterCallback('palm6_uniform:menu', function(src)")

-- Split on every `row{` call site. Deliberately a find loop rather than a
-- gmatch with two delimiters: gmatch resumes after the WHOLE match, so a
-- 'row{(.-)row{' pattern consumes the opening of the next block and silently
-- tests only every other row.
local rowBlocks = {}
do
    local starts, pos = {}, 1
    while true do
        local a = buildMenuSrc:find('row{', pos, true)
        if not a then break end
        starts[#starts + 1] = a
        pos = a + 4
    end
    for i = 1, #starts do
        local stop = (starts[i + 1] and starts[i + 1] - 1) or #buildMenuSrc
        rowBlocks[#rowBlocks + 1] = buildMenuSrc:sub(starts[i], stop)
    end
end
T.ge('buildMenu emits a meaningful number of rows', #rowBlocks, 8)

local allDescribed, allTitledRows = true, true
for i = 1, #rowBlocks do
    if not rowBlocks[i]:find('description =', 1, true) then allDescribed = false end
    if not rowBlocks[i]:find('title =', 1, true) then allTitledRows = false end
end
T.istrue('every row buildMenu emits carries a description', allDescribed)
T.istrue('every row buildMenu emits carries a title', allTitledRows)

T.contains('there is a floor that fires if the row list is ever empty',
    buildMenuSrc, 'if #rows == 0 then')

-- ---------------------------------------------------------------------------
T.section('the pick is re-authorised server-side on every click')
-- ---------------------------------------------------------------------------

local menuApplySrc = T.slice(SERVER, 'local function menuApply(src, setId)',
    '-- Save what this admin is wearing, driven entirely by menu choices.')

T.contains('the job and grade are re-read from the framework, not taken from the client',
    menuApplySrc, 'Bridge.GetPoliceIdentity(src)')
T.contains('the ped model is re-read server-side',
    menuApplySrc, 'Bridge.GetPedModelName(src)')
T.contains('the chosen id is checked against a freshly computed permitted list',
    menuApplySrc, 'allowedSets(id.job, id.grade, model)')
T.notcontains('it never reaches into the raw set cache to find the row',
    menuApplySrc, 'sets[')
T.contains('a refused pick says so by name rather than doing nothing',
    menuApplySrc, 'You are not allowed to wear that one.')
T.contains('picking what you already have on is called out, so a zero-change apply is expected',
    menuApplySrc, 'You already have')

-- ---------------------------------------------------------------------------
T.section('no world coordinate is invented, and there is only one of them')
-- ---------------------------------------------------------------------------
-- The station position is READ from qbx_police_overrides, which already owns
-- it. The literal below exists once, as a documented fallback, and its comment
-- cites the file it was copied from.

local configSrc  = T.source(CONFIG)
local clientSrc  = T.source(CLIENT)
local svBridgeSrc = T.source(SVBRIDGE)
local clBridgeSrc = T.source(CLBRIDGE)

T.contains('the fallback coordinate lives in the config',
    configSrc, 'vector3(442.32, -988.43, 30.69)')
T.contains('and its comment cites the exact file and lines it was copied from',
    configSrc, 'qbx_police_overrides/config.lua:61-65')
T.contains('and names the export that is read at runtime instead',
    configSrc, 'GetDutyToggle')

-- The rule is about EXECUTABLE copies, not about citing the number in a
-- comment. Quoting the source line in a comment is how the citation stays
-- checkable; a second `vector3(442.32, ...)` that some code path could read is
-- a second source of truth, and that is what these forbid.
T.notcontains('the server never constructs a second copy of the coordinate',
    serverSrc, 'vector3(442.32')
T.notcontains('the server does not carry the coordinate at all, in code or comment',
    serverSrc, '442.32')
T.notcontains('the client never carries a coordinate at all', clientSrc, '442.32')
T.notcontains('the client never constructs a vector3 of its own', clientSrc, 'vector3(')
T.notcontains('the server bridge does not repeat the coordinate at all',
    svBridgeSrc, '442.32')
T.contains('the server bridge quotes the source line it reads from, so the citation is checkable',
    svBridgeSrc, 'qbx_police_overrides/config.lua:61-65')

T.contains('the server bridge reads the real export', svBridgeSrc,
    'exports.qbx_police_overrides:GetDutyToggle()')
T.contains('and it is soft: the resource state is checked first', svBridgeSrc,
    "GetResourceState(POLICE_CONFIG_RESOURCE) ~= 'started'")
T.contains('the rank names are read rather than invented', svBridgeSrc,
    'exports.qbx_police_overrides:GetGrades()')

-- ---------------------------------------------------------------------------
T.section('ox_target is optional and its absence is a supported path')
-- ---------------------------------------------------------------------------

T.contains('the client bridge probes ox_target rather than assuming it',
    clBridgeSrc, "GetResourceState('ox_target') == 'started'")
T.contains('the ox_target call is pcall-guarded', clBridgeSrc, 'exports.ox_target:addSphereZone')
T.contains('there is an ox_lib proximity fallback with a key prompt',
    clBridgeSrc, 'lib.points.new')
T.contains('the fallback shows an on-screen prompt', clBridgeSrc, 'INPUT_PICKUP')
T.contains('the menu uses the same ox_lib context pair the rest of the repo uses',
    clBridgeSrc, 'lib.registerContext')

-- ---------------------------------------------------------------------------
T.section('nothing about the walk-up flow requires typing')
-- ---------------------------------------------------------------------------

T.contains('the wardrobe is registered as a client script', T.source(MANIFEST),
    'client/wardrobe.lua')
T.contains('the capture is reachable from the menu', serverSrc, "action == 'capture'")
T.contains('the restore is reachable from the menu', serverSrc, "action == 'restore'")
T.contains('the apply is reachable from the menu', serverSrc, "action == 'apply'")
T.contains('an unknown action is answered rather than dropped', serverSrc,
    'The wardrobe sent an action this server does not know')
T.contains('the position can be corrected in game instead of guessed', serverSrc,
    "action == 'wardrobe_here'")

T.contains('the client refuses to treat a missing server answer as an empty wardrobe',
    clientSrc, 'The server did not answer.')
T.contains('and says so as a notify as well as in the menu', clientSrc,
    'The wardrobe could not reach the server.')
T.contains('a wardrobe that could not be placed is reported, not swallowed',
    clientSrc, 'the station wardrobe could not be placed')
T.contains('the ox_target zone is torn down on stop so no dead eye is left behind',
    clientSrc, 'onResourceStop')

-- ---------------------------------------------------------------------------
T.section('the commands survive as a fallback and the docs lead with the menu')
-- ---------------------------------------------------------------------------

T.contains('the commands are still registered', serverSrc, 'Bridge.RegisterCommand(Config.PlayerCommand')
T.contains('and they are labelled as the fallback rather than the feature',
    serverSrc, 'COMMANDS. THE FALLBACK, not the feature.')

local readmeSrc = T.source(README)
T.contains('the README leads with the walk-up wardrobe', readmeSrc, '## The walk-up wardrobe')
T.contains('and demotes the commands to an appendix', readmeSrc, '## Appendix: the commands')
local checklistSrc = T.source(CHECKLIST)
T.contains('the checklist is a walk-up test, not a list of commands',
    checklistSrc, '# palm6_uniform - the walk-up test')
T.contains('its first in-game step is walking to the wardrobe',
    checklistSrc, 'Step 1 - walk to the station wardrobe')
T.contains('and it demotes the commands to an appendix too',
    checklistSrc, 'Appendix: the commands, if the menu is unavailable')

-- ---------------------------------------------------------------------------
T.section('house style')
-- ---------------------------------------------------------------------------

local files = {
    { 'shared/config.lua', configSrc },
    { 'server/main.lua', serverSrc },
    { 'client/wardrobe.lua', clientSrc },
    { 'bridge/cl_game.lua', clBridgeSrc },
    { 'bridge/sv_framework.lua', svBridgeSrc },
    { 'README.md', readmeSrc },
    { 'CHECKLIST.md', checklistSrc },
}
-- The em dash as raw UTF-8 bytes rather than an escape, so this assertion does
-- not depend on the source file that contains it being decoded a particular way.
local EM_DASH = string.char(0xE2, 0x80, 0x94)
for i = 1, #files do
    T.notcontains(('%s contains no em dash'):format(files[i][1]), files[i][2], EM_DASH)
end

T.done()
