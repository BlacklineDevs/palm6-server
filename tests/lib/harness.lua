-- ============================================================================
-- tests/lib/harness.lua - assertions and production-source extraction.
--
-- Loaded into every suite's Lua state before the suite itself, so `T` is a
-- global the suites use directly.
--
-- TWO JOBS
-- 1. Assertions that FAIL LOUDLY. Every failure prints the test name, the
--    expected value and the actual value. A silent pass on wrong code is the
--    failure mode this whole directory exists to avoid, so there is no
--    "assert(x)" style check anywhere: every assertion carries both values.
-- 2. Source extraction. Most of the pure logic on this server is a `local
--    function` inside a server file that also opens MySQL connections and
--    registers events, so it cannot be require'd. Rather than REFACTOR a live
--    resource to make it testable (a real behaviour risk on a deployed server),
--    T.slice() lifts the exact production text of a block out of the file by
--    anchor lines and T.chunk() compiles it. The bytes under test are the bytes
--    that ship. If somebody moves the code, the anchor stops matching and the
--    suite fails loudly rather than testing nothing.
-- ============================================================================

T = {
    passed = 0,
    failed = 0,
    group = '',
}

-- ---------------------------------------------------------------------------
-- Value formatting. Numbers are the point of these tests, so NaN, infinity and
-- the integer/float distinction all have to be visible in a failure message.
-- ---------------------------------------------------------------------------
local function repr(v)
    local t = type(v)
    if t == 'nil' then return 'nil' end
    if t == 'string' then return ('%q'):format(v) end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v ~= v then return 'nan' end
        if v == math.huge then return 'inf' end
        if v == -math.huge then return '-inf' end
        if math.type(v) == 'float' then
            return ('%.10g (float)'):format(v)
        end
        return ('%d'):format(v)
    end
    if t == 'table' then
        local parts = {}
        local n = 0
        for i, x in ipairs(v) do
            parts[#parts + 1] = repr(x)
            n = i
        end
        local keys = {}
        for k in pairs(v) do
            if not (math.type(k) == 'integer' and k >= 1 and k <= n) then
                keys[#keys + 1] = tostring(k)
            end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. '=' .. repr(v[k])
        end
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    return '<' .. t .. '>'
end
T.repr = repr

local function name(what)
    if T.group ~= '' then return T.group .. ' / ' .. what end
    return what
end

local function pass(what)
    T.passed = T.passed + 1
end

local function fail(what, expected, actual, extra)
    T.failed = T.failed + 1
    -- _quiet is a DEPTH counter raised only by T.expectFailure, which
    -- deliberately provokes a failure to prove an assertion is capable of
    -- failing. A depth counter rather than a flag so a nested expectFailure
    -- cannot un-mute its parent. Nothing else may touch it, or a real failure
    -- would go unprinted.
    if (T._quiet or 0) > 0 then return end
    print('  FAIL  ' .. name(what))
    print('        expected: ' .. expected)
    print('        actual:   ' .. actual)
    if extra then print('        note:     ' .. extra) end
end

---Start a named group. Purely cosmetic: it prefixes failure messages so a
---failing assertion says which behaviour broke, not just which line.
function T.section(s)
    T.group = s
end

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

---Exact equality. NaN is handled explicitly because NaN ~= NaN, and several of
---the guards under test exist specifically to catch NaN.
function T.eq(what, actual, expected)
    local same
    if type(actual) == 'number' and type(expected) == 'number'
        and actual ~= actual and expected ~= expected then
        same = true   -- both NaN
    else
        same = (actual == expected)
    end
    if same then pass(what) else fail(what, repr(expected), repr(actual)) end
end

---Inequality, for "this must have changed" style checks.
function T.ne(what, actual, notExpected)
    if actual ~= notExpected then pass(what)
    else fail(what, 'anything other than ' .. repr(notExpected), repr(actual)) end
end

---Float comparison with an explicit tolerance. Used only where the production
---code itself uses a float (turf's DefenderDecayMult, insurance percentages).
function T.near(what, actual, expected, tol)
    tol = tol or 1e-9
    if type(actual) ~= 'number' or actual ~= actual then
        fail(what, ('%s +/- %s'):format(repr(expected), tostring(tol)), repr(actual))
        return
    end
    if math.abs(actual - expected) <= tol then pass(what)
    else fail(what, ('%s +/- %s'):format(repr(expected), tostring(tol)), repr(actual)) end
end

function T.istrue(what, actual)
    if actual == true then pass(what) else fail(what, 'true', repr(actual)) end
end

function T.isfalse(what, actual)
    if actual == false then pass(what) else fail(what, 'false', repr(actual)) end
end

function T.isnil(what, actual)
    if actual == nil then pass(what) else fail(what, 'nil', repr(actual)) end
end

function T.isnan(what, actual)
    if type(actual) == 'number' and actual ~= actual then pass(what)
    else fail(what, 'nan', repr(actual)) end
end

---a < b, reported with both values so a failing ordering claim is readable.
function T.lt(what, a, b)
    if type(a) == 'number' and type(b) == 'number' and a < b then pass(what)
    else fail(what, ('a value less than %s'):format(repr(b)), repr(a)) end
end

function T.ge(what, a, b)
    if type(a) == 'number' and type(b) == 'number' and a >= b then pass(what)
    else fail(what, ('a value >= %s'):format(repr(b)), repr(a)) end
end

---Array (ipairs) comparison, element by element.
function T.list(what, actual, expected)
    if type(actual) ~= 'table' then
        fail(what, repr(expected), repr(actual))
        return
    end
    if #actual ~= #expected then
        fail(what, repr(expected), repr(actual),
            ('length %d, expected %d'):format(#actual, #expected))
        return
    end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then
            fail(what, repr(expected), repr(actual),
                ('first difference at index %d'):format(i))
            return
        end
    end
    pass(what)
end

---Substring presence. Used to assert on breakdown lines and on production
---source text (for example "this file contains no math.random").
function T.contains(what, haystack, needle)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then pass(what)
    else fail(what, ('a string containing %q'):format(needle), repr(haystack)) end
end

function T.notcontains(what, haystack, needle)
    if type(haystack) ~= 'string' then
        fail(what, ('a string not containing %q'):format(needle), repr(haystack))
    elseif haystack:find(needle, 1, true) then
        local upto = haystack:sub(1, haystack:find(needle, 1, true) - 1)
        local line = select(2, upto:gsub('\n', '')) + 1
        fail(what, ('no occurrence of %q'):format(needle), ('found at line %d'):format(line))
    else
        pass(what)
    end
end

---Call `fn` and assert it raised. Used for the guards that are supposed to
---blow up rather than return a wrong number.
function T.raises(what, fn)
    local ok, err = pcall(fn)
    if ok then fail(what, 'an error', 'no error, call returned normally')
    else pass(what) end
end

---Call `fn` and assert it did NOT raise. Returns whatever fn returned so a
---suite can keep asserting on the result.
---
---On failure it returns an EMPTY TABLE rather than nil, so the assertions that
---follow fail one by one with readable messages instead of aborting the whole
---suite on an index-a-nil error and hiding every later test.
function T.noraise(what, fn)
    local ok, a, b, c = pcall(fn)
    if ok then pass(what); return a, b, c end
    fail(what, 'no error', 'error: ' .. tostring(a))
    return {}
end

---Run `fn`, which must itself perform exactly one assertion, and require that
---the assertion FAILED. Used by the self-check suite to prove every assertion
---helper is capable of failing, because a helper that always passes is worse
---than no helper at all.
---
---The provoked failure is not printed and does not count toward the tally: the
---counters are snapshotted and restored, and only this wrapper's own verdict is
---recorded.
function T.expectFailure(what, fn)
    local p0, f0 = T.passed, T.failed
    T._quiet = (T._quiet or 0) + 1
    local ok, err = pcall(fn)
    T._quiet = T._quiet - 1
    local gained = T.failed - f0
    T.passed, T.failed = p0, f0
    if not ok then
        fail(what, 'a recorded assertion failure', 'a raised error: ' .. tostring(err))
        return
    end
    if gained >= 1 then pass(what)
    else fail(what, 'the assertion to FAIL', 'it passed, so this check cannot detect a bug') end
end

-- ---------------------------------------------------------------------------
-- Production source access
-- ---------------------------------------------------------------------------

---Read a file, relative to the repo root. Raises loudly if it is missing,
---because a suite silently testing nothing is the failure this avoids.
function T.source(rel)
    local full = REPO .. '/' .. rel
    local s, err = __readFile(full)
    if not s then
        error(('cannot read production source %s (%s)'):format(full, tostring(err)), 2)
    end
    return s
end

local function splitLines(s)
    local out = {}
    for line in (s .. '\n'):gmatch('([^\n]*)\n') do out[#out + 1] = line end
    return out
end

local function findUnique(lines, anchor, label, rel)
    local hits = {}
    for i, l in ipairs(lines) do
        if l:find(anchor, 1, true) then hits[#hits + 1] = i end
    end
    if #hits == 0 then
        error(('%s anchor %q not found in %s. The production code moved; fix the anchor rather than deleting the test.')
            :format(label, anchor, rel), 3)
    end
    if #hits > 1 then
        error(('%s anchor %q is ambiguous in %s (%d matches, lines %s). Pick a unique anchor.')
            :format(label, anchor, rel, #hits, table.concat(hits, ', ')), 3)
    end
    return hits[1]
end

---Lift the production text between two anchor lines out of a file.
---
---Returns everything from the line containing `startAnchor` up to but NOT
---including the line containing `endAnchor`. Both anchors must match exactly
---one line each; anything else is an error, so a rename or a copy-paste that
---duplicates the anchor cannot silently change what is under test.
---@param rel string        repo-relative path
---@param startAnchor string plain (non-pattern) substring of the first line
---@param endAnchor string   plain substring of the first line AFTER the block
---@return string
function T.slice(rel, startAnchor, endAnchor)
    local lines = splitLines(T.source(rel))
    local a = findUnique(lines, startAnchor, 'start', rel)
    local b = findUnique(lines, endAnchor, 'end', rel)
    if b <= a then
        error(('end anchor %q appears at line %d, before the start anchor at line %d, in %s')
            :format(endAnchor, b, a, rel), 2)
    end
    local out = {}
    for i = a, b - 1 do out[#out + 1] = lines[i] end
    return table.concat(out, '\n')
end

---Lift ONE production line out of a file. Same uniqueness rule as T.slice: the
---anchor must match exactly one line, so a rename or a duplicate is an error
---rather than a silently different test.
---@param rel string
---@param anchor string plain substring of the line
---@return string
function T.line(rel, anchor)
    local lines = splitLines(T.source(rel))
    return lines[findUnique(lines, anchor, 'line', rel)]
end

---Compile Lua text and return the chunk. Compile failure is fatal and names
---the chunk, so a broken slice reads as a broken slice.
function T.chunk(label, text)
    local f, err = load(text, '@' .. label)
    if not f then
        error(('could not compile %s: %s'):format(label, tostring(err)), 2)
    end
    return f
end

---Load a whole production Lua file into this state and run it. Only safe for
---files that touch nothing outside their own globals (the shared/config.lua
---files, and palm6_mdt/shared/sentencing.lua).
function T.loadFile(rel)
    local ok, err = pcall(T.chunk(rel, T.source(rel)))
    if not ok then
        error(('%s failed to execute: %s'):format(rel, tostring(err)), 2)
    end
end

-- ---------------------------------------------------------------------------
-- Suite lifecycle
-- ---------------------------------------------------------------------------

function T.begin(title)
    T.title = title
    print('')
    print('--- ' .. title .. ' (' .. SUITE_FILE .. ')')
end

function T.done()
    print(('    %d passed, %d failed'):format(T.passed, T.failed))
    __report(T.title or SUITE_FILE, T.passed, T.failed)
end
