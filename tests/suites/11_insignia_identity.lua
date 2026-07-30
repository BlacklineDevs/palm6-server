-- ============================================================================
-- 11_insignia_identity.lua — palm6_insignia
--
-- Three things are pinned here, and each of them is a thing that fails
-- SILENTLY on a live server if it breaks.
--
-- 1. BADGE ALLOCATION. lowestFree decides which number an officer wears for the
--    rest of their character's life. A wrong answer is not a crash, it is two
--    officers with the same number (or a number outside the department range)
--    and an MDT record that points at the wrong person. It is pure — no clock,
--    no PRNG, no DB — so it is fully testable here.
--
-- 2. TAPE TEXT SANITISATION. The client draws the name with
--    AddTextComponentSubstringPlayerName, which PARSES tilde markup. Surnames
--    are player-typed at character creation. A tilde surviving sanitisation
--    means a player can render arbitrary coloured text above their own ped, on
--    everyone else's screen. That is the security-relevant assertion in this
--    file and it is asserted from several directions.
--
-- 3. THE ASSET INVARIANT. palm6_insignia exists because palm6_threads
--    overwrote a base-game drawable and made every police outfit render as
--    nothing. The structural checks at the end require that this resource never
--    grows a clothing native, a texture-replacement native, or a data_file
--    line. They are cheap and they are the exact regression that already cost
--    this server a day.
--
-- The production bytes are LIFTED, not reimplemented: T.slice pulls the real
-- text out of server/main.lua by anchor. Move the code and this suite fails
-- loudly rather than testing a stale copy.
-- ============================================================================

T.begin('palm6_insignia — badge allocation, tape text, and the no-asset invariant')

local SERVER = 'resources/[custom]/palm6_insignia/server/main.lua'
local CLBRIDGE = 'resources/[custom]/palm6_insignia/bridge/cl_game.lua'
local MANIFEST = 'resources/[custom]/palm6_insignia/fxmanifest.lua'

-- The shipped config becomes the global `Config`, exactly as it does in game.
T.loadFile('resources/[custom]/palm6_insignia/shared/config.lua')

-- ---------------------------------------------------------------------------
-- Lift the pure logic.
-- ---------------------------------------------------------------------------
local lowestFree = T.chunk('lowestFree', T.slice(
    SERVER,
    'local function lowestFree(taken, minv, maxv)',
    '-- Assign (or return the existing) badge for a citizenid.'
) .. '\nreturn lowestFree')()

local sanitise, nameLine, badgeLine = T.chunk('tapeText', T.slice(
    SERVER,
    'local function sanitiseTapeText(s, maxChars)',
    '-- ROSTER'
) .. '\nreturn sanitiseTapeText, nameLine, badgeLine')()

-- ---------------------------------------------------------------------------
T.section('lowestFree — badge allocation')
-- ---------------------------------------------------------------------------

T.eq('an empty department issues the first number in the range',
    lowestFree({}, 100, 999), 100)

T.eq('the next hire gets the next number',
    lowestFree({ [100] = 'A' }, 100, 999), 101)

T.eq('a run of five taken numbers skips to the sixth',
    lowestFree({ [100] = 'A', [101] = 'B', [102] = 'C', [103] = 'D', [104] = 'E' }, 100, 999), 105)

T.eq('a HOLE in the middle is filled before extending the top',
    lowestFree({ [100] = 'A', [102] = 'C', [103] = 'D' }, 100, 999), 101)

T.eq('the range floor is respected, not zero and not one',
    lowestFree({}, 500, 999), 500)

T.isnil('an exhausted range returns nil rather than a number outside it',
    lowestFree({ [1] = 'A', [2] = 'B', [3] = 'C' }, 1, 3))

T.isnil('an inverted range (min > max) returns nil rather than looping',
    lowestFree({}, 999, 100))

T.eq('a single-slot range issues that one number',
    lowestFree({}, 7, 7), 7)

T.isnil('a single-slot range already taken is exhausted',
    lowestFree({ [7] = 'A' }, 7, 7))

-- Numbers ABOVE the ceiling in the taken set must not affect the answer: they
-- can exist after an admin /setbadge on an older, wider range.
T.eq('a taken number above the ceiling does not shift the answer',
    lowestFree({ [5000] = 'A' }, 100, 999), 100)

-- The whole point of lowest-free over max+1: allocation is a pure function of
-- the taken set, so two boots of the same database issue the same numbers.
do
    local taken = { [100] = 'A', [101] = 'B' }
    local a = lowestFree(taken, 100, 999)
    local b = lowestFree(taken, 100, 999)
    T.eq('allocation is deterministic — same set, same answer', a, b)
end

-- Structural: the allocator must not read a clock or a PRNG, or the number an
-- officer gets would depend on WHEN they joined.
do
    local src = T.slice(SERVER,
        'local function lowestFree(taken, minv, maxv)',
        '-- Assign (or return the existing) badge for a citizenid.')
    T.notcontains('lowestFree reads no PRNG', src, 'math.random')
    T.notcontains('lowestFree reads no clock', src, 'os.time')
    T.notcontains('lowestFree touches no database', src, 'MySQL')
end

-- ---------------------------------------------------------------------------
T.section('sanitiseTapeText — what a player-typed name may not smuggle onto a tape')
-- ---------------------------------------------------------------------------

-- THE ONE THAT MATTERS. AddTextComponentSubstringPlayerName parses '~r~' as a
-- colour code, so a tilde reaching the draw is arbitrary markup rendered above
-- a player's own ped on every other player's screen.
T.eq('a tilde markup token is stripped, not escaped', sanitise('~r~WANTED'), 'rWANTED')
T.notcontains('no tilde survives, in any position', sanitise('~a~b~c~'), '~')
T.notcontains('a doubled tilde does not survive either', sanitise('~~n~~'), '~')

T.eq('a newline cannot break the tape onto another line', sanitise('Olv\nerson'), 'Olv erson')
T.eq('a carriage return is treated the same', sanitise('Olv\rerson'), 'Olv erson')
T.eq('a tab collapses to a single space', sanitise('Olv\terson'), 'Olv erson')
T.eq('a percent sign is stripped', sanitise('100%Cop'), '100Cop')
T.eq('angle brackets and braces are stripped', sanitise('<b>{x}</b>'), 'bxb')

T.eq('a legitimate hyphenated surname survives intact', sanitise('Olverson-Smith'), 'Olverson-Smith')
T.eq('a legitimate apostrophe survives intact', sanitise("O'Brien"), "O'Brien")
T.eq('a legitimate initial with a dot survives intact', sanitise('D. Olverson'), 'D. Olverson')
T.eq('digits survive (some players use them)', sanitise('Unit7'), 'Unit7')

T.eq('runs of whitespace collapse to one space', sanitise('D     Olverson'), 'D Olverson')
T.eq('leading and trailing whitespace is trimmed', sanitise('   Olverson   '), 'Olverson')
T.eq('nil becomes an empty string rather than raising', sanitise(nil), '')
T.eq('a number is accepted and stringified', sanitise(415), '415')
T.eq('an all-markup name collapses to empty', sanitise('~~~'), '')

T.eq('truncation cuts at exactly maxChars', sanitise('ABCDEFGHIJ', 4), 'ABCD')
T.eq('truncation leaves a short string alone', sanitise('ABC', 10), 'ABC')
T.eq('truncation does not leave a trailing space', sanitise('AB CDEFGH', 3), 'AB')

-- Accented names are kept (bytes >= 128 are allowed through) and truncation is
-- UTF-8 aware, so a cut never leaves half a character behind.
do
    local jose = 'Jos\195\169'                   -- "José" in UTF-8, 5 bytes
    T.eq('an accented surname is preserved, not flattened', sanitise(jose), jose)
    T.eq('truncating mid-sequence drops the whole character', sanitise(jose, 4), 'Jos')
    T.eq('truncating on a clean boundary keeps the character', sanitise(jose, 5), jose)
end

-- ---------------------------------------------------------------------------
T.section('nameLine — the first tape line')
-- ---------------------------------------------------------------------------

local function ident(first, last, rank)
    return { first = first, last = last, gradeName = rank }
end

Config.Name.Format = 'initial_last'
T.eq('initial_last is the shipped default shape',
    nameLine(ident('David', 'Olverson')), 'D. OLVERSON')
T.eq('a missing first name degrades to the surname alone',
    nameLine(ident(nil, 'Olverson')), 'OLVERSON')

Config.Name.Format = 'last'
T.eq('last prints only the surname', nameLine(ident('David', 'Olverson')), 'OLVERSON')

Config.Name.Format = 'first_last'
T.eq('first_last prints both', nameLine(ident('David', 'Olverson')), 'DAVID OLVERSON')

Config.Name.Format = 'initial_last'
T.eq('a nameless character never renders a blank tape',
    nameLine(ident(nil, nil)), 'OFFICER')
T.eq('a whitespace-only name is also caught by the blank guard',
    nameLine(ident('   ', '   ')), 'OFFICER')

T.notcontains('markup in a first name cannot reach the tape',
    nameLine(ident('~r~D', 'Olverson')), '~')
T.notcontains('markup in a surname cannot reach the tape',
    nameLine(ident('David', '~b~Olverson')), '~')

Config.Name.Uppercase = false
T.eq('uppercase can be turned off', nameLine(ident('David', 'Olverson')), 'D. Olverson')
Config.Name.Uppercase = true

do
    -- A very long surname must be bounded, or the plate stretches off screen.
    local long = nameLine(ident('Bartholomew', 'Featherstonehaughshireman'))
    T.ge('a long name is still non-empty', #long, 1)
    T.eq('a long name is bounded by Config.Name.MaxChars', #long <= Config.Name.MaxChars, true)
end

-- ---------------------------------------------------------------------------
T.section('badgeLine — the second tape line')
-- ---------------------------------------------------------------------------

T.eq('brand, number and rank',
    badgeLine(ident('David', 'Olverson', 'Sergeant'), 415), 'PBPD #415  -  SERGEANT')
T.eq('no rank label still prints brand and number',
    badgeLine(ident('David', 'Olverson', nil), 415), 'PBPD #415')
T.eq('an unbadged officer still gets a department line',
    badgeLine(ident('David', 'Olverson', 'Cadet'), nil), 'PBPD  -  CADET')
T.notcontains('a rank label cannot smuggle markup either',
    badgeLine(ident('D', 'O', '~r~Chief'), 1), '~')

-- ---------------------------------------------------------------------------
T.section('the no-asset invariant (the palm6_threads regression guard)')
-- ---------------------------------------------------------------------------
--
-- These assert on the CALL form (name followed by an open paren) rather than
-- the bare name, because the comments in these files deliberately NAME the
-- natives they refuse to use, and a check that banned the word would ban its
-- own documentation.

local serverSrc = T.source(SERVER)
local bridgeSrc = T.source(CLBRIDGE)
local manifest  = T.source(MANIFEST)

T.notcontains('the client bridge calls no texture-replacement native', bridgeSrc, 'AddReplaceTexture(')
T.notcontains('the client bridge creates no DUI', bridgeSrc, 'CreateDui(')
T.notcontains('the client bridge creates no runtime txd', bridgeSrc, 'CreateRuntimeTxd(')
T.notcontains('the client bridge sets no ped component', bridgeSrc, 'SetPedComponentVariation(')
T.notcontains('the client bridge sets no collection component', bridgeSrc, 'SetPedCollectionComponentVariation(')
T.notcontains('the client bridge sets no ped prop', bridgeSrc, 'SetPedPropIndex(')

-- The bridge is the ONLY file allowed to call natives, so a per-player scan
-- could only appear here. The render budget depends on iterating the roster.
T.notcontains('the client bridge never enumerates every player', bridgeSrc, 'GetActivePlayers')

T.notcontains('the manifest declares no data_file at all (so no clothing meta)', manifest, 'data_file')
T.notcontains('the manifest streams nothing', manifest, "'stream/")

-- Server-authoritative identity: exactly one inbound net event, and it takes
-- no arguments. If a second one appears, or this one grows a payload, the
-- client can start asserting its own identity.
T.contains('the one inbound net event is the roster request', serverSrc,
    "RegisterNetEvent('palm6_insignia:requestRoster', function()")
do
    local n = select(2, serverSrc:gsub('RegisterNetEvent%(', ''))
    T.eq('there is exactly ONE RegisterNetEvent on the server', n, 1)
end

-- Teardown safety: no onResourceStop at all here, so no MySQL .await can be
-- reachable from one.
T.notcontains('the server file registers no teardown handler', serverSrc, "AddEventHandler('onResourceStop'")

T.done()
