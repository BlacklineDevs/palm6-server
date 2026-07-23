-- ============================================================================
-- palm6_brain/server/memory.lua — Phase 3: NPC MEMORY (in-memory, dark-safe).
--
-- Makes the world feel CONTINUOUS ("the dealer remembered me"). It attaches to
-- the Director's Phase-3 extension seam (server/director.lua) WITHOUT editing the
-- core, and does exactly two things, both side-effect-free:
--
--   1. OBSERVE — via Director.OnAction, every COMMITTED goal flows here. We record
--      the NOTABLE ones (agent interactions, especially anything touching the
--      literal 'player') into a small, BOUNDED store: a per-subject ring (last
--      ~N events for each npc id AND for 'player') plus a bounded global recent
--      list. NOTHING here yields (no Wait/HTTP) — the seam contract requires
--      observers to be cheap, and a broken observer is already pcall-isolated by
--      the Director, so we also never throw on bad input.
--
--   2. TEACH — via Director.RegisterContext, each tick we hand the Director a
--      SHORT natural-language digest of the most recent notable events
--      ("Recently: mover_legion_1 spoke with a player; mover_pier_1 was seen
--      dealing.") so the next plan can honour continuity. The digest is length-
--      and item-capped so it can never bloat the prompt.
--
-- 🔒 WHY THIS IS SAFE TO ALWAYS RUN: memory has ZERO gameplay side effects — it
-- only reads committed actions and appends prompt text. It cannot move a ped,
-- money, or dispatch. Even so it is gated behind the local ENABLED flag below so
-- it can be killed instantly, and it registers NOTHING (and defines no store) if
-- Config or the Director seam is missing. Load order: this file MUST come AFTER
-- server/director.lua in fxmanifest's server_scripts (the seam it hooks is
-- defined there). If Director is nil we no-op cleanly.
--
-- 📌 PERSISTENCE IS OUT OF SCOPE FOR v1 (in-memory only). Everything is dropped on
-- resource restart. A future slice can add a DB/file hook: serialise `recent`
-- (and optionally the per-subject rings) on onResourceStop and rehydrate on start
-- — see the persistence hook comment near the bottom. Kept out now to ship the
-- observe→teach loop before taking on storage/GDPR-shaped questions.
-- ============================================================================

-- ── DARK-SHIP GATE ───────────────────────────────────────────────────────────
-- true = memory observes + teaches the Director. false = this module registers
-- NOTHING (no observer, no context provider, no exports) and adds zero overhead.
-- Flip false + redeploy to disable instantly if it ever misbehaves.
local ENABLED = true

-- No-op cleanly if the shared config or the Director seam isn't present (wrong
-- load order, or the Director core was removed). Never assume a global exists.
if not ENABLED then return end
if type(Config) ~= 'table' then
    print('[palm6_brain:memory] Config missing — memory disabled.')
    return
end
if type(Director) ~= 'table' or type(Director.OnAction) ~= 'function'
   or type(Director.RegisterContext) ~= 'function' then
    print('[palm6_brain:memory] Director seam missing — load memory.lua AFTER director.lua. Disabled.')
    return
end

-- ── TUNING (local; these are advisory bounds, not invariants) ────────────────
local RING_MAX   = 5    -- events retained per subject id (and for 'player')
local RECENT_MAX = 15   -- events retained in the global recent list
local DIGEST_MAX = 4    -- notable events surfaced to the Director each tick

-- Verbs worth remembering as a social event (an actor DID something to a target).
-- These are the agent-target verbs from the Director's action enum; place/idle
-- verbs are not socially notable (a light movement trail is tracked separately).
local NOTABLE_VERBS = {
    talkTo = 'spoke with', buyFrom = 'bought from', deal = 'dealt to',
    rob = 'robbed', attack = 'attacked',
}
-- Movement verbs we keep only a LIGHT trail of (last place a mover was sent), so
-- the digest can say "was headed to Legion Square" without flooding on wandering.
local MOVE_VERBS = { goTo = true, queueAt = true, orderAt = true, wander = true }

-- ── THE BOUNDED STORE ────────────────────────────────────────────────────────
-- bySubject[id]  = ring buffer (plain array, trimmed to RING_MAX) of that
--                  subject's recent events. Keyed by the ACTOR id and, for a
--                  'player'-targeted event, ALSO under 'player' so /RecallFor can
--                  answer "what did NPCs recently do to a player?".
-- recent[]       = bounded global list (trimmed to RECENT_MAX) of the most recent
--                  notable events, newest last. Feeds the digest.
-- lastMove[id]   = last place a mover was sent (single slot per id, self-bounding).
local bySubject = {}
local recent    = {}
local lastMove  = {}

-- ── PERSISTENCE (resource KVP; survives resource restart, server restart, AND a
-- code redeploy — KVP lives in the server data store, not the resource files). So
-- the world's memory is no longer wiped every time we redeploy during a feel-test.
-- Fully defensive: a corrupt/oversized blob is ignored, never throws.
local KVP_KEY  = 'palm6_brain:memory:v1'
local SAVE_MS  = 120000   -- flush every 2 min (+ on resource stop)
local BLOB_MAX = 512000   -- refuse to persist an implausibly large blob (KVP guard)

local function saveMemory()
    local ok, blob = pcall(json.encode, { recent = recent, bySubject = bySubject })
    if ok and type(blob) == 'string' and #blob <= BLOB_MAX then
        pcall(SetResourceKvp, KVP_KEY, blob)
    end
end

local function loadMemory()
    local blob = GetResourceKvpString(KVP_KEY)
    if type(blob) ~= 'string' or blob == '' then return end
    local ok, data = pcall(json.decode, blob)
    if not ok or type(data) ~= 'table' then return end
    -- Reassign the upvalues (every closure that references recent/bySubject sees
    -- the new tables — Lua closures capture the variable, not the value).
    if type(data.recent) == 'table' then recent = data.recent end
    if type(data.bySubject) == 'table' then bySubject = data.bySubject end
    -- Re-bound after load in case the caps were lowered since the save.
    while #recent > RECENT_MAX do table.remove(recent, 1) end
    for _, ring in pairs(bySubject) do
        while type(ring) == 'table' and #ring > RING_MAX do table.remove(ring, 1) end
    end
end

-- Push onto a subject's ring, trimming from the front so it can NEVER grow past
-- RING_MAX. Creates the ring lazily. (table.remove(t, 1) keeps insertion order.)
local function pushRing(id, entry)
    if type(id) ~= 'string' or id == '' then return end
    local ring = bySubject[id]
    if not ring then ring = {}; bySubject[id] = ring end
    ring[#ring + 1] = entry
    while #ring > RING_MAX do table.remove(ring, 1) end
end

-- Push onto the bounded global recent list, same front-trim discipline.
local function pushRecent(entry)
    recent[#recent + 1] = entry
    while #recent > RECENT_MAX do table.remove(recent, 1) end
end

-- Render a place/target as 'a player' for the literal 'player' sentinel so the
-- digest reads naturally and never leaks the sentinel token to the model.
local function humanTarget(target)
    if target == 'player' then return 'a player' end
    return tostring(target)
end

-- Turn one stored event into a short clause, e.g. "mover_legion_1 spoke with a
-- player" or "mover_pier_1 was seen dealing".
local function phrase(ev)
    if ev.kind == 'social' then
        local verbText = NOTABLE_VERBS[ev.verb] or ev.verb
        return ('%s %s %s'):format(ev.npc, verbText, humanTarget(ev.target))
    else -- 'move'
        return ('%s was seen heading to %s'):format(ev.npc, tostring(ev.target))
    end
end

-- ── OBSERVER (Director.OnAction) — CHEAP, NO YIELDS, NEVER THROWS ─────────────
-- Called once per committed goal: action = { npc, verb, target, amount }. We only
-- record; we take no gameplay action. Defensive on every field because the action
-- ultimately originates from an LLM plan (already validated by the Director, but
-- we never assume shape here).
Director.OnAction(function(action)
    if type(action) ~= 'table' then return end
    local npc, verb, target = action.npc, action.verb, action.target
    if type(npc) ~= 'string' or npc == '' then return end
    if type(verb) ~= 'string' then return end

    if NOTABLE_VERBS[verb] and type(target) == 'string' and target ~= '' then
        -- A social interaction — the memory-worthy kind. Record under the actor,
        -- under the target if the target is another npc id (so both "remember"
        -- it), and (crucially) under 'player' whenever a real player was involved.
        local ev = { kind = 'social', npc = npc, verb = verb, target = target, at = os.time() }
        pushRing(npc, ev)
        if target == 'player' then
            pushRing('player', ev)
        else
            pushRing(target, ev)   -- the other npc remembers being acted upon
        end
        pushRecent(ev)
    elseif MOVE_VERBS[verb] and type(target) == 'string' and target ~= '' then
        -- Light movement trail: overwrite the single last-place slot (self-bounded)
        -- and keep a low-priority record so the digest has fallback material when
        -- there are no social events. Not pushed per-subject to avoid ring churn.
        lastMove[npc] = target
        pushRecent({ kind = 'move', npc = npc, target = target, at = os.time() })
    end
    -- All other verbs (idle, flee, wander w/o place, complyWithPolice) are not
    -- notable — deliberately dropped so the store stays about meaningful events.
end)

-- ── CONTEXT PROVIDER (Director.RegisterContext) — the digest we TEACH ─────────
-- fn(world) -> short string|nil, folded into the Director's prompt each tick.
-- We surface the last DIGEST_MAX notable events, newest first, preferring social
-- events (they carry continuity) and topping up with movement if we're short.
-- Bounded by construction; returns nil when there's nothing to say.
Director.RegisterContext(function(_world)
    if #recent == 0 then return nil end

    -- Walk newest→oldest, taking social events first, then moves as filler.
    local socials, moves = {}, {}
    for i = #recent, 1, -1 do
        local ev = recent[i]
        if ev.kind == 'social' and #socials < DIGEST_MAX then
            socials[#socials + 1] = phrase(ev)
        elseif ev.kind == 'move' and #moves < DIGEST_MAX then
            moves[#moves + 1] = phrase(ev)
        end
        if #socials >= DIGEST_MAX then break end
    end

    local picked = {}
    for _, p in ipairs(socials) do if #picked < DIGEST_MAX then picked[#picked + 1] = p end end
    for _, p in ipairs(moves)   do if #picked < DIGEST_MAX then picked[#picked + 1] = p end end
    if #picked == 0 then return nil end

    -- One compact line the Director can act on for continuity.
    return 'Recently: ' .. table.concat(picked, '; ') .. '.'
end)

-- ── OPTIONAL EXPORTS — cheap reuse for later slices (e.g. dialogue seeding) ───
-- RecallFor(id) -> a short human string of that subject's recent events, or nil.
-- Lets the Phase-1 dialogue brain seed an NPC's context ("you recently dealt to a
-- player") without reaching into this file. Pure read, bounded by RING_MAX.
exports('RecallFor', function(id)
    if type(id) ~= 'string' or id == '' then return nil end
    local ring = bySubject[id]
    if not ring or #ring == 0 then return nil end
    local parts = {}
    for i = #ring, 1, -1 do parts[#parts + 1] = phrase(ring[i]) end
    return table.concat(parts, '; ')
end)

-- RecentEvents() -> shallow copy of the bounded global recent list (newest last),
-- for an observability meter or a future persistence serialiser. Copy so callers
-- can't mutate the live store.
exports('RecentEvents', function()
    local out = {}
    for i = 1, #recent do
        local e = recent[i]
        out[i] = { kind = e.kind, npc = e.npc, verb = e.verb, target = e.target, at = e.at }
    end
    return out
end)

-- ── DEV METER — /brainmemory prints the current digest + store sizes ─────────
-- ACE-restricted (command.brainmemory). Lets David watch what the Director is
-- being taught without waiting for a tick. Read-only; no state change.
RegisterCommand('brainmemory', function(src)
    local subjects = 0
    for _ in pairs(bySubject) do subjects = subjects + 1 end
    print(('[palm6_brain:memory] %d recent event(s), %d subject ring(s):')
        :format(#recent, subjects))
    for i = #recent, 1, -1 do print('  - ' .. phrase(recent[i])) end
    if #recent == 0 then print('  (empty — the Director has committed no notable goals yet)') end
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = { 200, 170, 255 },
            args = { 'memory', ('%d recent event(s) — see server console'):format(#recent) } })
    end
end, true)

-- ── PERSISTENCE WIRE-UP ──────────────────────────────────────────────────────
-- Rehydrate on boot, flush on a slow timer, and flush once more on stop so the
-- world keeps its memory across restarts + redeploys.
loadMemory()

CreateThread(function()
    while true do
        Wait(SAVE_MS)
        saveMemory()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    saveMemory()
end)

print('[palm6_brain:memory] Phase 3 NPC memory attached (observe + teach; KVP-persisted).')
