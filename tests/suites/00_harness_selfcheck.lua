-- ============================================================================
-- Harness self-check.
--
-- A suite that passes silently when the code is wrong is worse than no suite,
-- so before any production logic is asserted on, every assertion helper is
-- proved capable of FAILING. T.expectFailure runs an assertion that must fail,
-- suppresses its output, and records a pass only if the failure was actually
-- counted.
--
-- The source-extraction helpers are proved too: a moved or duplicated anchor
-- must raise, not silently return the wrong block, because the whole value of
-- lifting production text is lost if the lift can go wrong quietly.
-- ============================================================================
T.begin('harness self-check')

T.section('equality')
T.eq('eq passes on a match', 1 + 1, 2)
T.expectFailure('eq fails on a mismatch', function() T.eq('x', 1, 2) end)
T.expectFailure('eq fails on a type mismatch', function() T.eq('x', '2', 2) end)
T.expectFailure('eq fails on nil vs a value', function() T.eq('x', nil, 2) end)
T.eq('eq treats NaN as equal to NaN', 0 / 0, 0 / 0)
T.expectFailure('eq fails on NaN vs a number', function() T.eq('x', 0 / 0, 1) end)
T.expectFailure('eq fails on 1 vs 1.5', function() T.eq('x', 1, 1.5) end)
-- Lua compares 2 and 2.0 as equal; the harness inherits that, and the repr
-- helper is what makes the distinction visible in a failure message.
T.eq('integer 2 and float 2.0 compare equal, as in Lua', 2, 2.0)
T.eq('repr distinguishes them anyway', T.repr(2.0), '2 (float)')
T.eq('repr names NaN', T.repr(0 / 0), 'nan')
T.eq('repr names infinity', T.repr(math.huge), 'inf')

T.section('inequality and ordering')
T.ne('ne passes when values differ', 1, 2)
T.expectFailure('ne fails when they match', function() T.ne('x', 2, 2) end)
T.lt('lt passes', 1, 2)
T.expectFailure('lt fails when equal', function() T.lt('x', 2, 2) end)
T.expectFailure('lt fails when greater', function() T.lt('x', 3, 2) end)
T.expectFailure('lt fails on a non-number', function() T.lt('x', 'a', 2) end)
T.ge('ge passes when equal', 2, 2)
T.ge('ge passes when greater', 3, 2)
T.expectFailure('ge fails when less', function() T.ge('x', 1, 2) end)

T.section('booleans and nil')
T.istrue('istrue passes on true', true)
T.expectFailure('istrue fails on false', function() T.istrue('x', false) end)
T.expectFailure('istrue is strict: a truthy value is not true',
    function() T.istrue('x', 1) end)
T.isfalse('isfalse passes on false', false)
T.expectFailure('isfalse fails on nil', function() T.isfalse('x', nil) end)
T.isnil('isnil passes on nil', nil)
T.expectFailure('isnil fails on false', function() T.isnil('x', false) end)
T.isnan('isnan passes on NaN', 0 / 0)
T.expectFailure('isnan fails on a real number', function() T.isnan('x', 1) end)
T.expectFailure('isnan fails on infinity', function() T.isnan('x', math.huge) end)

T.section('floats')
T.near('near passes inside the tolerance', 0.1 + 0.2, 0.3)
T.expectFailure('near fails outside it', function() T.near('x', 1.0, 2.0) end)
T.expectFailure('near fails on NaN', function() T.near('x', 0 / 0, 1.0) end)
T.expectFailure('near respects an explicit tolerance',
    function() T.near('x', 1.0, 1.5, 0.1) end)

T.section('lists')
T.list('list passes on identical arrays', { 1, 2, 3 }, { 1, 2, 3 })
T.list('list passes on two empties', {}, {})
T.expectFailure('list fails on a different length',
    function() T.list('x', { 1, 2 }, { 1, 2, 3 }) end)
T.expectFailure('list fails on a different element',
    function() T.list('x', { 1, 9, 3 }, { 1, 2, 3 }) end)
T.expectFailure('list fails on a different order',
    function() T.list('x', { 3, 2, 1 }, { 1, 2, 3 }) end)
T.expectFailure('list fails on a non-table', function() T.list('x', 'no', {}) end)

T.section('substrings')
T.contains('contains passes', 'hello world', 'lo wo')
T.expectFailure('contains fails when absent',
    function() T.contains('x', 'hello', 'zzz') end)
T.notcontains('notcontains passes when absent', 'hello', 'zzz')
T.expectFailure('notcontains fails when present',
    function() T.notcontains('x', 'hello', 'ell') end)
-- Matching is PLAIN, not pattern-based, so a Lua pattern character in an anchor
-- means what it looks like.
T.contains('matching is plain text, not a Lua pattern', 'a.b', '.')
T.notcontains('so a pattern class does not match arbitrary text', 'abc', '%w')

T.section('error expectation')
T.raises('raises passes when the call errors', function() error('boom') end)
T.expectFailure('raises fails when the call succeeds',
    function() T.raises('x', function() return 1 end) end)
local got = T.noraise('noraise returns the value', function() return 42 end)
T.eq('and that value is the real one', got, 42)
T.expectFailure('noraise fails when the call errors',
    function() T.noraise('x', function() error('boom') end) end)

T.section('expectFailure is itself strict')
T.expectFailure('expectFailure fails when the inner assertion PASSES', function()
    T.expectFailure('inner', function() T.eq('ok', 1, 1) end)
end)

T.section('source extraction refuses to guess')
local REAL = 'resources/[custom]/palm6_mdt/shared/sentencing.lua'
T.contains('a real file can be read', T.source(REAL), 'function Sentencing.Calculate')
T.raises('a missing file raises', function() T.source('resources/nope/nope.lua') end)
T.raises('a missing start anchor raises', function()
    T.slice(REAL, 'this text is not in the file', 'function Sentencing.Calculate')
end)
T.raises('a missing end anchor raises', function()
    T.slice(REAL, 'function Sentencing.Calculate', 'this text is not in the file')
end)
T.raises('an ambiguous anchor raises rather than picking one', function()
    T.slice(REAL, 'local function', 'return result')
end)
T.raises('an end anchor before the start anchor raises', function()
    T.slice(REAL, 'return result', 'function Sentencing.Calculate')
end)
T.raises('T.line raises on an ambiguous anchor', function()
    T.line(REAL, 'local function')
end)

local sliced = T.slice(REAL, 'function Sentencing.Failure(reason)', 'return {')
T.contains('a good slice starts at the start anchor', sliced, 'function Sentencing.Failure')
T.notcontains('and stops before the end anchor', sliced, 'return {')

local oneLine = T.line(REAL, 'local function roundX10000(v)')
T.eq('T.line returns exactly one line', select(2, oneLine:gsub('\n', '')), 0)
T.contains('and it is the right one', oneLine, 'roundX10000')

T.section('chunk compilation')
local f = T.chunk('good', 'return 1 + 1')
T.eq('a valid chunk runs', f(), 2)
T.raises('a syntactically broken chunk raises at compile time', function()
    T.chunk('bad', 'this is not lua')
end)
-- Two fixtures under tests/fixtures exist only for these two checks. Nothing
-- the server runs ever loads them.
T.raises('loadFile raises when the file errors while executing', function()
    T.loadFile('tests/fixtures/raises_at_load.lua')
end)
T.raises('loadFile raises when the file does not compile', function()
    T.loadFile('tests/fixtures/syntax_error.lua')
end)
T.raises('loadFile raises on a missing file', function()
    T.loadFile('tests/fixtures/does_not_exist.lua')
end)

T.done()
