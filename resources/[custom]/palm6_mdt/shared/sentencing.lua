-- ============================================================================
-- palm6_mdt/shared/sentencing.lua — the sentence calculator.
--
-- PURE. This file calls no native, no framework export, no MySQL, and no
-- Bridge function. It reads Config.Charges and its arguments, and returns a
-- table. It writes nothing, notifies nobody, and has no side effects at all.
-- That is why it lives in its own file rather than in server/main.lua: the
-- claim "deterministic and side-effect free" should be checkable by reading
-- one short file, not by auditing a 1200-line command module.
--
-- DETERMINISM, AND WHY THERE IS NO FLOATING POINT
-- A sentence a player cannot reproduce on paper is worse than no sentence, so
-- the arithmetic is exact. Every intermediate value is an integer:
--   * base sentences and fines are coerced to non-negative integers as they
--     leave the catalogue, so a mistyped `7.5` cannot reach the arithmetic
--   * the concurrent factor and the priors step are integer PERCENTAGES
--   * the running subtotal is kept in HUNDREDTHS (sentence * 100)
--   * the priors multiplier is applied as an integer percent, leaving the
--     total in ten-thousandths
--   * exactly one rounding happens, at the very end, as integer division:
--       result = (totalX10000 + 5000) // 10000        (round half up)
-- No float ever enters the computation, so there is no platform-dependent
-- rounding and no accumulated error. The only division by a non-power-of-ten
-- is in the DISPLAY strings, which are cosmetic and never fed back in.
--
-- THE MODEL, IN ONE PARAGRAPH
-- The most serious charge is served in full. Every other charge in the same
-- booking is served at Config.Charges.ConcurrentPct of its base (concurrent
-- sentencing), which is what stops six loitering charges out-sentencing a
-- murder. Fines are the opposite: cumulative at full value, and never touched
-- by the priors multiplier, so the money side stays a fixed published
-- schedule a player can predict exactly. Priors — prior UNSEALED bookings —
-- raise the time subtotal by an integer percent each, capped, then the result
-- is clamped to the configured floor and ceiling.
--
-- Because sealed (expunged) bookings do not count as priors, the expungement
-- system in palm6_legal already feeds this: winning a petition genuinely
-- lowers your next recommended sentence. That link is free and intentional.
-- ============================================================================

Sentencing = {}

-- Catalogue index, built once on first use. Config is static after load, so
-- caching is safe; this is the only state in the file and it is derived.
local codeIndex = nil

local function C()
    return Config.Charges or {}
end

-- Integer-coerce a configured percentage / bound. An operator who types 50.5
-- would otherwise smuggle a float into the "no floating point" arithmetic
-- below, so truncate at the boundary rather than trusting the config.
local function int(v, fallback)
    v = tonumber(v)
    if not v then return fallback end
    return math.floor(v)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Round a value held in ten-thousandths to whole units, half up.
--
-- `//` is Lua 5.3+ floor division: on two integers it stays in integer
-- arithmetic and never produces a float, which is what makes the "no floating
-- point" claim in the header literally true rather than merely approximately
-- true. This resource declares lua54 in its fxmanifest, so the operator is
-- available. `/` would have worked for these magnitudes too, but it would have
-- gone through a double, and a comment that is only nearly right is worse than
-- no comment.
local function roundX10000(v)
    return (v + 5000) // 10000
end

---Look up one charge code. Returns the catalogue entry (do not mutate it) or
---nil. Case-insensitive and whitespace-tolerant, because this is typed in chat.
---@param code string
---@return table|nil
function Sentencing.Lookup(code)
    code = tostring(code or ''):lower():gsub('%s+', '')
    if code == '' then return nil end
    if not codeIndex then
        codeIndex = {}
        for _, e in ipairs(C().Catalogue or {}) do
            codeIndex[e.code] = e
        end
    end
    return codeIndex[code]
end

---Every catalogue code, sorted, for "did you mean" style output.
---@return string[]
function Sentencing.Codes()
    local out = {}
    for _, e in ipairs(C().Catalogue or {}) do out[#out + 1] = e.code end
    table.sort(out)
    return out
end

---Scan free text for catalogue codes appearing as whole whitespace-delimited
---tokens. STRICTLY LITERAL: there is no fuzzy matching, no stemming, and no
---label matching, because a sentencing system that GUESSES what an officer
---meant is exactly the kind of unexplainable outcome this whole file exists to
---avoid. If an officer typed prose, this finds nothing and says so, which is
---the honest answer.
---Returns codes in catalogue order, de-duplicated, so the result does not
---depend on the order words happen to appear in the prose.
---
---THIS IS A SUGGESTION, NEVER A SENTENCE. Read Sentencing.CompoundCodes()
---below for why the result is systematically biased toward the mildest
---charges, and why no caller may turn it into a recommended number.
---@param text string
---@return string[]
function Sentencing.CodesInText(text)
    text = tostring(text or ''):lower()
    local seen = {}
    for token in text:gmatch('[%w_]+') do seen[token] = true end
    local out = {}
    for _, e in ipairs(C().Catalogue or {}) do
        if seen[e.code] then out[#out + 1] = e.code end
    end
    return out
end

---Catalogue codes that a token scan can only ever find if the officer typed
---the underscore form LITERALLY, because ordinary prose splits them into two
---tokens ("bank robbery" never matches `bank_robbery`).
---
---This is the structural bias that makes CodesInText unusable as a sentencing
---input on the shipped catalogue: the single-word codes are the mild ones
---(trespass 1, disorder 1, obstruct 2, assault 8) and the compound ones are
---the severe ones (leo_assault 20, bank_robbery 45, murder_1 90). Scanning
---"assault on a peace officer during a bank robbery" finds exactly `assault`
---and misses both felonies. A number derived from that scan would be
---confidently, systematically too low, which is why RecommendForBooking
---refuses to compute one and prints this list as a warning instead.
---@return string[] sorted, may be empty if an operator renames the catalogue
function Sentencing.CompoundCodes()
    local out = {}
    for _, e in ipairs(C().Catalogue or {}) do
        if tostring(e.code):find('_', 1, true) then out[#out + 1] = e.code end
    end
    table.sort(out)
    return out
end

---A well-formed, all-zero result carrying `reason`. Single-sources the result
---SHAPE so a caller that has to refuse (no codes given, prior lookup failed)
---returns something every consumer can read without nil-checking each field.
---Calculate() below starts from this too, so the shape can never drift between
---the success and failure paths.
---@param reason string|nil
---@return table
function Sentencing.Failure(reason)
    return {
        ok = false, reason = reason, sentence = 0, fine = 0,
        unit = tostring(C().SentenceUnit or 'months'),
        applied = {}, unknown = {}, dropped = {},
        priors = 0, priorsGiven = 0, multPct = 100,
        capped = false, cappedHigh = false, cappedLow = false,
        breakdown = {},
    }
end

---The calculator.
---
---@param codes string[] charge codes (unknown ones are reported, never guessed)
---@param priors number   count of prior unsealed bookings for this citizen
---@return table result
---
---result = {
---  ok          = boolean,    false when no code resolved (see `reason`)
---  reason      = string|nil,
---  sentence    = integer,    recommended time, in Config.Charges.SentenceUnit
---  fine        = integer,    recommended fine, whole currency
---  unit        = string,     the SentenceUnit label, carried for display
---  applied     = table[],    per-charge rows, primary first
---  unknown     = string[],   codes that are not in the catalogue
---  dropped     = string[],   codes past Config.Charges.MaxCodes
---  priors      = integer,    priors actually counted (after the cap)
---  priorsGiven = integer,    priors passed in, before the cap
---  multPct     = integer,    priors multiplier, as a percent
---  capped      = boolean,    true when EITHER configured bound (floor or
---                            ceiling, time or fine) changed the result
---  cappedHigh  = boolean,    true when a ceiling clamped it down
---  cappedLow   = boolean,    true when the MinSentence floor clamped it up
---  breakdown   = string[],   the arithmetic, in the order it was performed
---}
function Sentencing.Calculate(codes, priors)
    local cfg          = C()
    local concurrent   = int(cfg.ConcurrentPct, 50)
    local stepPct      = int(cfg.PriorsStepPct, 10)
    local priorsCap    = int(cfg.PriorsCap, 5)
    local minSentence  = int(cfg.MinSentence, 1)
    local maxSentence  = int(cfg.MaxSentence, 120)
    local maxFine      = int(cfg.MaxFine, 250000)
    local maxCodes     = int(cfg.MaxCodes, 10)
    local unit         = tostring(cfg.SentenceUnit or 'months')

    local result = Sentencing.Failure(nil)

    -- 1. Resolve. De-duplicate: charging the same code twice in one booking is
    -- a typo far more often than it is intent, and silently doubling a
    -- sentence off a typo is precisely the unexplainable outcome to avoid.
    --
    -- NOTE the cap is NOT applied here. Truncating during resolution would cut
    -- in the order the codes were typed, so an officer who listed eleven
    -- charges with the murder last would have the murder silently dropped and
    -- get sentenced on the ten petty ones. Resolve everything, sort, then cut
    -- from the bottom (step 3), which also keeps the whole result independent
    -- of the order the codes arrived in.
    local resolved, seen = {}, {}
    for _, raw in ipairs(type(codes) == 'table' and codes or {}) do
        local key = tostring(raw or ''):lower():gsub('%s+', '')
        if key ~= '' and not seen[key] then
            seen[key] = true
            local entry = Sentencing.Lookup(key)
            if entry then
                -- A COPY with the two numeric fields coerced to non-negative
                -- integers. The percentages above already go through int(); the
                -- catalogue values did not, so an operator typing
                -- `sentence = 7.5` used to smuggle a float straight into the
                -- `//` at the end and quietly break the no-floating-point
                -- guarantee. Copying also keeps Config immutable across the
                -- export boundary.
                resolved[#resolved + 1] = {
                    code = entry.code, label = entry.label, class = entry.class,
                    sentence = math.max(0, int(entry.sentence, 0)),
                    fine = math.max(0, int(entry.fine, 0)),
                }
            elseif #result.unknown < maxCodes then
                -- Bounded for the same reason the charge list is: this list is
                -- printed, and an unbounded caller should not be able to make
                -- one command emit an unbounded number of chat lines.
                result.unknown[#result.unknown + 1] = key
            end
        end
    end

    if #resolved == 0 then
        result.reason = 'no known charge codes'
        return result
    end

    -- 2. Order by severity, most serious first. The tiebreak chain ends on
    -- `code`, which is unique, so two runs with the same input can never
    -- produce a different primary charge. An unstable sort here would make the
    -- whole result non-deterministic, since position 1 is the only charge that
    -- counts in full.
    table.sort(resolved, function(a, b)
        if a.sentence ~= b.sentence then return a.sentence > b.sentence end
        if a.fine ~= b.fine then return a.fine > b.fine end
        return a.code < b.code
    end)

    -- 3. Cut to the charge limit from the BOTTOM, so what gets dropped is
    -- always the least serious charge on the sheet, never whatever happened to
    -- be typed last.
    while #resolved > maxCodes do
        local cut = table.remove(resolved)
        result.dropped[#result.dropped + 1] = cut.code
    end

    -- 4. Time subtotal, kept in hundredths. Primary at 100%, the rest at
    -- ConcurrentPct. Fine subtotal in whole currency, every charge at full.
    local sentenceX100, fineTotal = 0, 0
    for i, e in ipairs(resolved) do
        local pct = (i == 1) and 100 or concurrent
        local addX100 = e.sentence * pct
        sentenceX100 = sentenceX100 + addX100
        fineTotal = fineTotal + e.fine
        result.applied[#result.applied + 1] = {
            code = e.code, label = e.label, class = e.class,
            baseSentence = e.sentence, baseFine = e.fine,
            pct = pct, primary = (i == 1), appliedX100 = addX100,
        }
    end

    -- 5. Priors multiplier, integer percent, capped.
    --
    -- math.floor on a non-finite float returns a FLOAT, not an integer, and it
    -- survives math.max. The arithmetic below still worked (math.min(inf, cap)
    -- is the cap), but the breakdown line formats `given` with %d, and in Lua
    -- 5.3+ string.format('%d', math.huge) RAISES "number has no integer
    -- representation". This file exists to never throw at a caller (that is what
    -- Sentencing.Failure is for), so an infinite or over-large priors count is
    -- normalised to the cap here rather than being allowed to reach %d.
    -- In-repo callers cannot produce it (priorsFor is a SELECT COUNT(*)), but
    -- CalculateSentence is an exported entry point any resource may call with
    -- anything. NaN is already absorbed: math.max(0, nan) returns 0.
    -- Found by the tests/ suite.
    -- Only values with NO integer representation are normalised. A legitimate
    -- over-cap count (8 priors against a cap of 5) must stay 8, because the
    -- breakdown reports "of 8, capped at 5" and clamping it here would silently
    -- delete that line's meaning.
    local rawPriors = math.max(0, math.floor(tonumber(priors) or 0))
    local given = math.tointeger and math.tointeger(rawPriors) or nil
    if given == nil then
        -- NaN reads as 0 priors (no evidence of any), anything else without an
        -- integer representation is inf or too large to be a real count, so it
        -- is treated as the cap: the multiplier is capped there regardless.
        given = (rawPriors ~= rawPriors) and 0 or priorsCap
    end
    local counted = math.min(given, priorsCap)
    local multPct = 100 + counted * stepPct
    result.priorsGiven = given
    result.priors = counted
    result.multPct = multPct

    -- 6. One rounding, at the end, in integers. Fines are NOT multiplied.
    local totalX10000 = sentenceX100 * multPct
    local rounded = roundX10000(totalX10000)
    local finalSentence = clamp(rounded, minSentence, maxSentence)
    local finalFine = clamp(fineTotal, 0, maxFine)
    -- `capped` means "a configured bound changed the printed number", which is
    -- exactly the condition the breakdown lines below announce. The earlier
    -- `rounded > maxSentence or fineTotal > maxFine` form missed the MinSentence
    -- floor, so a one-infraction sheet could print "clamped to the configured
    -- range" while the flag a consumer reads stayed false.
    result.cappedHigh = (rounded > maxSentence) or (fineTotal > maxFine)
    result.cappedLow  = (rounded < minSentence)
    result.capped     = result.cappedHigh or result.cappedLow
    result.sentence = finalSentence
    result.fine = finalFine
    result.ok = true

    -- 7. The arithmetic, written out. This is the deliverable: a player who
    -- disagrees with a sentence should be able to check it line by line.
    -- The %.2f values here are DISPLAY ONLY and are derived from the integer
    -- hundredths above; nothing below is ever read back into the computation.
    local b = result.breakdown
    for i, a in ipairs(result.applied) do
        b[#b + 1] = ('%d. %s [%s] %s: %d %s x %d%%%s = %.2f'):format(
            i, a.code, a.class, a.label, a.baseSentence, unit, a.pct,
            a.primary and ' (most serious, served in full)' or ' (concurrent)',
            a.appliedX100 / 100)
    end
    b[#b + 1] = ('subtotal: %.2f %s, fine $%d (fines are cumulative, never concurrent)')
        :format(sentenceX100 / 100, unit, fineTotal)
    b[#b + 1] = ('priors: %d counted%s, multiplier %d%% (time only, fines unaffected)')
        :format(counted,
            given > counted and (' of %d, capped at %d'):format(given, priorsCap) or '',
            multPct)
    b[#b + 1] = ('%.2f x %d%% = %.4f, rounded half up = %d %s')
        :format(sentenceX100 / 100, multPct, totalX10000 / 10000, rounded, unit)
    if finalSentence ~= rounded then
        b[#b + 1] = ('clamped to the configured range %d-%d %s = %d')
            :format(minSentence, maxSentence, unit, finalSentence)
        -- Say out loud what the ceiling costs, because the model's headline
        -- promise stops being visible above it: once the raw total exceeds
        -- MaxSentence, adding another charge changes the fine and nothing
        -- else, so two very different sheets print the same time.
        if rounded > maxSentence then
            b[#b + 1] = ('at the ceiling: extra charges and priors no longer change the time, only the fine')
        end
    end
    if finalFine ~= fineTotal then
        b[#b + 1] = ('fine clamped to the configured ceiling $%d'):format(maxFine)
    end
    if #result.unknown > 0 then
        b[#b + 1] = ('NOT counted (no such code): %s'):format(table.concat(result.unknown, ', '))
    end
    if #result.dropped > 0 then
        b[#b + 1] = ('NOT counted (over the %d-charge limit, least serious dropped first): %s')
            :format(maxCodes, table.concat(result.dropped, ', '))
    end

    return result
end
