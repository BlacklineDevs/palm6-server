-- ============================================================================
-- palm6_brain/server/factions.lua — Phase 4: FACTIONS & RETALIATION (emergent).
--
-- Crime should not vanish the instant it happens. When a mover robs/attacks/deals
-- against someone, that someone should remember it and — LATER, believably — the
-- world should respond. This module is how the city grows a MEMORY OF GRIEVANCE
-- without a single line of scripted payback.
--
-- 🔑 THE DESIGN, IN ONE SENTENCE: we OBSERVE committed crime goals and record a
-- bounded, decaying GRUDGE (victim holds it against the aggressor), then FEED that
-- grudge back into the Director's LLM prompt as context so the model may CHOOSE to
-- escalate on its own. We never inject a retaliation goal — no such API exists, on
-- purpose. Retaliation is EMERGENT: the LLM reads "mover_pier_1 was robbed by
-- mover_legion_2 and may want payback" and, if it decides, assigns mover_pier_1 an
-- `attack`/`rob` back through the SAME validated Director pipeline. The safety
-- contract (shape → referential → legality + the crime gate) still stands; a grudge
-- is a nudge to the storyteller, never a bypass of the rails.
--
-- 🔒 WHAT THIS FILE DOES *NOT* DO (by design):
--   • It never forces, injects, or schedules a goal      (no goal-injection API)
--   • It never spawns a ped, moves money, or dispatches   (pure state + a prompt line)
--   • It never yields in the observer                     (cheap, synchronous record)
--   • It never grows unbounded                            (MaxGrudges cap + TTL decay)
--
-- Attaches through the Director's Phase-3+ extension seam (server/director.lua,
-- which loads BEFORE this file — see fxmanifest server_scripts order). Both hooks
-- are crash-isolated by the Director (each call is pcall-wrapped), but we stay
-- defensive here anyway: no-op if Config or Director is missing, and DARK by default.
-- ============================================================================

-- ── LOCAL CONFIG (dark by default) ──────────────────────────────────────────
-- Kept LOCAL because this module may not edit shared/config.lua. When the
-- coordinator integrates, these may be promoted to Config.Director.Factions and
-- read from there; until then this local block is the single source of truth.
--   Enabled       false = fully dark. No hooks are registered, no context is ever
--                 emitted, no state is kept — the module is inert (mirrors the
--                 Config.Director.Enabled / Config.Enabled dark-ship idiom).
--   GrudgeTtlSec  a grudge older than this (server seconds) is EXPIRED — it is
--                 pruned lazily when the digest is built and never shown again, so
--                 old crimes fade and the world does not hold an eternal vendetta.
--   MaxGrudges    hard ceiling on stored grudges. At the cap the OLDEST grudge is
--                 evicted to make room, so the table can never grow unbounded.
--   DigestMax     max grudge lines folded into one tick's prompt (keeps it short).
local CFG = {
    Enabled      = true,    -- LIVE: grudge tracking + emergent-retaliation context (inert until crime happens).
    GrudgeTtlSec = 1800,    -- 30 min: a grudge decays/expires after this many seconds.
    MaxGrudges   = 20,      -- bounded store: evict oldest beyond this many grudges.
    DigestMax    = 4,       -- at most this many grudge lines injected into the prompt.
}

-- ── GRUDGE STORE ────────────────────────────────────────────────────────────
-- A grudge = { victim, aggressor, verb, at }. It says "at server-time `at`,
-- `aggressor` committed `verb` against `victim`, and the victim now holds it."
--   victim/aggressor : mover ids (strings), or 'player' for the victim side.
--   verb             : the crime verb that created it (rob/attack/deal).
--   at               : os.time() when recorded (drives both decay and eviction).
-- Stored as a flat array so eviction of the oldest is a simple ordered scan; the
-- cap (MaxGrudges) keeps that scan trivially cheap.
local grudges = {}   -- array of { victim, aggressor, verb, at }

-- Crime verbs that create a grudge. Kept as a local set so we don't reach into
-- the Director's private ACTIONS registry (its locals are not visible here).
local CRIME_VERBS = { rob = true, attack = true, deal = true }

-- ── HELPERS ─────────────────────────────────────────────────────────────────

-- Is a stored grudge still active (not decayed) at time `now`?
local function isActive(g, now)
    return (now - (g.at or 0)) < CFG.GrudgeTtlSec
end

-- Drop every expired grudge in place (lazy decay). Cheap: one pass, no allocation
-- unless something is actually removed. Called before we read or write the store.
local function pruneExpired(now)
    local kept = nil
    for _, g in ipairs(grudges) do
        if isActive(g, now) then
            kept = kept or {}
            kept[#kept + 1] = g
        end
    end
    if kept then
        grudges = kept
    elseif #grudges > 0 then
        grudges = {}
    end
end

-- Enforce the MaxGrudges ceiling by evicting the OLDEST entries. `grudges` is
-- append-ordered, so the front of the array is oldest — remove from index 1 until
-- we are within the cap. Bounded, so worst case is a handful of shifts.
local function enforceCap()
    while #grudges > CFG.MaxGrudges do
        table.remove(grudges, 1)   -- oldest-first eviction
    end
end

-- Record one grudge. Deliberately synchronous and allocation-light — this runs
-- inside the Director's action observer and MUST NOT yield.
local function recordGrudge(victim, aggressor, verb, now)
    grudges[#grudges + 1] = { victim = victim, aggressor = aggressor, verb = verb, at = now }
    enforceCap()
end

-- ── THE OBSERVER — turn committed crime into a grudge ───────────────────────
-- fn(action) is called once per COMMITTED goal by the Director. We only care about
-- crime verbs whose target is another agent (a mover id or the literal 'player').
-- The VICTIM (the target) holds the grudge against the AGGRESSOR (action.npc).
-- Everything here is a cheap table write; no HTTP, no wait, no event.
local function onAction(action)
    if type(action) ~= 'table' then return end
    local verb, aggressor, victim = action.verb, action.npc, action.target
    if not CRIME_VERBS[verb] then return end                 -- non-crime = no grudge
    if type(aggressor) ~= 'string' or type(victim) ~= 'string' then return end
    if victim == aggressor then return end                   -- can't hold a grudge against yourself
    local now = os.time()
    pruneExpired(now)                                        -- decay first so the cap counts only live grudges
    recordGrudge(victim, aggressor, verb, now)
end

-- ── THE CONTEXT PROVIDER — teach the Director about active grudges ──────────
-- fn(world) -> a SHORT string (or nil), folded into the LLM prompt each tick. We
-- return a compact digest of live grudges phrased so the model can ACT on it if it
-- wants. We do NOT tell it to retaliate — we describe the grievance and leave the
-- choice to the storyteller (emergent, on-rails). 'player' victims are skipped in
-- the digest: the Director only directs movers, so a mover-vs-mover grudge is the
-- one it can actually play out. Capped to DigestMax lines to keep the prompt tight.
local VERB_PHRASE = { rob = 'robbed', attack = 'attacked', deal = 'was dealt to by' }

local function provideContext(_world)
    local now = os.time()
    pruneExpired(now)                                        -- lazy expiry on read
    if #grudges == 0 then return nil end
    local lines, shown = {}, 0
    -- Walk newest-first so the freshest grievances make the (capped) cut.
    for i = #grudges, 1, -1 do
        local g = grudges[i]
        -- Only surface grudges a MOVER holds — the Director can only task movers,
        -- so a 'player'-held grudge isn't actionable by it (kept in the store for
        -- exports/other consumers, just not injected into the director prompt).
        if g.victim ~= 'player' then
            local phrase = VERB_PHRASE[g.verb] or 'wronged by'
            lines[#lines + 1] = ('%s was %s %s and may seek payback')
                :format(g.victim, phrase, g.aggressor)
            shown = shown + 1
            if shown >= CFG.DigestMax then break end
        end
    end
    if shown == 0 then return nil end
    return 'Grudges (a wronged NPC may retaliate on their own): ' .. table.concat(lines, '; ') .. '.'
end

-- ── EXPORT — cheap read for other resources / consumers ─────────────────────
-- HasGrudgeAgainst(id) -> true if any LIVE grudge names `id` as the aggressor.
-- Lazy-prunes so a caller never sees a decayed grudge. Bounded scan (≤ MaxGrudges).
exports('HasGrudgeAgainst', function(id)
    if type(id) ~= 'string' then return false end
    local now = os.time()
    pruneExpired(now)
    for _, g in ipairs(grudges) do
        if g.aggressor == id then return true end
    end
    return false
end)

-- ── WIRE-UP (dark-by-default) ───────────────────────────────────────────────
-- Only attach to the Director seam when this module is ENABLED and the seam
-- actually exists. With CFG.Enabled=false NOTHING is registered — no observer, no
-- context — so the module is provably inert in prod (the export still exists but
-- always returns false because the store is never written).
if CFG.Enabled and Config and Director then
    if Director.OnAction then Director.OnAction(onAction) end
    if Director.RegisterContext then Director.RegisterContext(provideContext) end
    print('[palm6_brain:factions] armed — grudges decay after '
        .. CFG.GrudgeTtlSec .. 's, cap ' .. CFG.MaxGrudges
        .. ' (retaliation is EMERGENT via Director context, never forced).')
end
