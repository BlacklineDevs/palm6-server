-- ============================================================================
-- palm6_brain/server/director.lua — Phase 2b: THE AI DIRECTOR (spine, dry-run).
--
-- ONE batched, low-frequency, server-side LLM call assigns every NPC a single
-- goal from a CLOSED action enum. The model only ever picks a verb + typed args;
-- three validation layers (shape → referential → legality) run BEFORE anything
-- happens, so the model literally cannot name an action or target we did not
-- define. See docs/AI-NPC-ROADMAP.md §"On-rails AI".
--
-- 🔒 WHAT THIS FILE DOES *NOT* DO (by design, this slice):
--   • It never spawns or moves a ped        (actuation = a later gated slice)
--   • It never moves money                   (Config.Director.MoneyEnabled gate)
--   • It never calls police dispatch         (Config.Director.CrimeEnabled gate)
-- It is the PLANNING + GOAL-STATE spine. In DRY-RUN (the default) accepted
-- actions are logged — "Tony WOULD goTo Legion Square" — and discarded. With
-- DryRun off they are COMMITTED to the goal store (one per NPC, TTL-expiring) and
-- broadcast on `palm6_brain:goal` for a future client executor to actuate — but
-- that broadcast has no consumer yet, so even then no ped moves. Only gate-passed
-- verbs are ever committed, so the store can never hold a money/crime goal while
-- those gates are off. This proves the batched-LLM → schema → validate → commit →
-- degrade pipeline end-to-end before any actuation, money, or dispatch exists.
--
-- The ACTIONS registry below is the SINGLE SOURCE OF TRUTH: the LLM prompt and
-- the validator are both generated from it, so they can never drift apart.
-- ============================================================================

-- ── ACTION REGISTRY — the closed enum ───────────────────────────────────────
-- Per verb:
--   desc   : one-line meaning, injected verbatim into the LLM prompt.
--   target : referential contract for the `target` arg —
--              'none'   → target must be ABSENT
--              'place'  → target must be a known scene label (Config.Scenes)
--              'place?' → optional; if present, a known scene label
--              'agent'  → a known roster NPC id, or the literal 'player'
--   gate   : capability gate the legality layer requires —
--              nil      → always allowed (pure theater / no side effect)
--              'money'  → requires Config.Director.MoneyEnabled
--              'crime'  → requires Config.Director.CrimeEnabled
--   amount : { max = N } if the verb accepts a clamped money `amount`, else nil.
local ACTIONS = {
    idle             = { desc = 'stand where you are and do nothing notable',            target = 'none',   gate = nil },
    wander           = { desc = 'stroll around your area with no goal',                  target = 'place?', gate = nil },
    goTo             = { desc = 'walk to a named place',                                 target = 'place',  gate = nil },
    queueAt          = { desc = 'go wait in line / linger as a customer at a venue',     target = 'place',  gate = nil },
    talkTo           = { desc = 'approach and start a conversation with someone',        target = 'agent',  gate = nil },
    flee             = { desc = 'run away from danger',                                  target = 'none',   gate = nil },
    complyWithPolice = { desc = 'stop and put your hands up for police',                 target = 'none',   gate = nil },
    orderAt          = { desc = 'buy something as a paying customer at a venue',         target = 'place',  gate = 'money', amount = { max = 2000 } },
    buyFrom          = { desc = 'purchase goods from another person',                    target = 'agent',  gate = 'money', amount = { max = 5000 } },
    deal             = { desc = 'sell illicit goods to someone',                         target = 'agent',  gate = 'crime' },
    rob              = { desc = 'rob someone at threat',                                 target = 'agent',  gate = 'crime' },
    attack           = { desc = 'attack someone',                                        target = 'agent',  gate = 'crime' },
}

-- ============================================================================
-- EXTENSION SEAM (Phase 3+). Phase modules (memory, factions, chatter, …) attach
-- here WITHOUT editing the Director core. `Director` is a resource-global table,
-- visible to every server_script in palm6_brain. Two hooks, both crash-isolated
-- (each call is pcall-wrapped) so a broken module can never take down a tick:
--   Director.RegisterContext(fn) — fn(world) -> string|nil; the string is folded
--     into the Director's prompt each tick (e.g. "Tony recalls the player stiffed
--     him"). This is how a module TEACHES the Director without touching its logic.
--   Director.OnAction(fn)        — fn(action) called once per COMMITTED goal
--     ({npc,verb,target,amount}); how a module OBSERVES what happened (log a
--     memory, record a grudge). Observers must be cheap and must not yield.
-- ============================================================================
Director = {}
local ctxProviders, actionObservers = {}, {}

function Director.RegisterContext(fn)
    if type(fn) == 'function' then ctxProviders[#ctxProviders + 1] = fn end
end
function Director.OnAction(fn)
    if type(fn) == 'function' then actionObservers[#actionObservers + 1] = fn end
end

-- Gather every provider's line for this tick's prompt (nil/non-string/errors skipped).
local function gatherContext(world)
    local out = {}
    for _, fn in ipairs(ctxProviders) do
        local ok, s = pcall(fn, world)
        if ok and type(s) == 'string' and s ~= '' then out[#out + 1] = s end
    end
    return out
end

-- Fan a committed action out to every observer, crash-isolated.
local function notifyObservers(action)
    for _, fn in ipairs(actionObservers) do pcall(fn, action) end
end

-- ── Referential context builders ─────────────────────────────────────────────
-- The MOVERS the Director may direct (the "acting population"), capped to
-- MaxRoster. Movers are anonymous extras anchored to a home scene; the Director
-- steers them between known places. Named NPCs are deliberately NOT here — they
-- are stationary conversational anchors and must never be tasked to walk off-post.
local function buildRoster()
    local roster = {}
    local cap = (Config.Director and Config.Director.MaxRoster) or 20
    for _, m in ipairs(Config.Movers or {}) do
        if m.id and #roster < cap then
            roster[#roster + 1] = { id = m.id, home = m.home }
        end
    end
    return roster
end

-- Identity sets for the validator, derived from the current mover roster:
--   directable = mover ids            (may RECEIVE a goal)
--   targetable = mover ids ∪ named ids (may be the TARGET of an agent verb)
local function buildIdentity(roster)
    local directable, targetable = {}, {}
    for _, m in ipairs(roster) do directable[m.id] = true; targetable[m.id] = true end
    for _, n in ipairs(Config.NamedNpcs or {}) do
        if n.id then targetable[n.id] = true end
    end
    return directable, targetable
end

-- The set of valid `place` targets = scene labels (the world's known venues).
local function buildPlaces()
    local places = {}
    for _, s in ipairs(Config.Scenes or {}) do
        if s.label then places[s.label] = true end
    end
    return places
end

-- ── THE VALIDATOR — pure, no side effects, no globals mutated ─────────────────
-- validateAction(action, ctx) -> ok:boolean, reason:string, clean:table|nil
--   ctx = { directable=set, targetable=set, places=set, moneyOn=bool, crimeOn=bool }
--   directable = ids that may RECEIVE a goal (movers only — never the stationary
--                named anchors, so the Director can't task Tony to walk off-post).
--   targetable = ids that may be the TARGET of an agent verb (movers + named
--                anchors; 'player' is always allowed and checked separately).
-- `clean` (on success) is the action with its amount clamped to the verb cap.
-- Three layers, in order; the FIRST failure returns. This function is the whole
-- safety contract — everything the model produces flows through it.
local function isInt(v)
    if type(v) ~= 'number' then return false end
    return v == math.floor(v)
end

local function validateAction(action, ctx)
    -- ---- Layer 1: SHAPE / TYPE -------------------------------------------
    if type(action) ~= 'table' then return false, 'not-an-object' end
    local verb = action.verb
    if type(verb) ~= 'string' then return false, 'verb-not-string' end
    local spec = ACTIONS[verb]
    if not spec then return false, 'unknown-verb:' .. tostring(verb):sub(1, 24) end
    if type(action.npc) ~= 'string' or #action.npc == 0 or #action.npc > 64 then
        return false, 'bad-npc-id'
    end
    if action.target ~= nil then
        if type(action.target) ~= 'string' or #action.target > 64 then return false, 'bad-target-type' end
    end
    local amount = action.amount
    if amount ~= nil then
        if not spec.amount then return false, 'amount-not-allowed-for:' .. verb end
        if not isInt(amount) then return false, 'amount-not-integer' end
        local outer = (Config.Director and Config.Director.MaxAmount) or 100000
        if amount < 0 or amount > outer then return false, 'amount-out-of-bounds' end
    end

    -- ---- Layer 2: REFERENTIAL --------------------------------------------
    -- The ACTOR must be directable (a mover). Named anchors are never directable.
    if not ctx.directable[action.npc] then return false, 'npc-not-directable:' .. action.npc end
    local tk = spec.target
    if tk == 'none' then
        if action.target ~= nil then return false, 'target-not-allowed-for:' .. verb end
    elseif tk == 'place' then
        if not action.target then return false, 'target-required' end
        if not ctx.places[action.target] then return false, 'unknown-place:' .. action.target end
    elseif tk == 'place?' then
        if action.target and not ctx.places[action.target] then return false, 'unknown-place:' .. action.target end
    elseif tk == 'agent' then
        -- The TARGET may be any targetable id (mover or named anchor) or 'player'.
        if not action.target then return false, 'target-required' end
        if action.target ~= 'player' and not ctx.targetable[action.target] then
            return false, 'unknown-agent:' .. action.target
        end
        if action.target == action.npc then return false, 'agent-targets-self' end
    end

    -- ---- Layer 3: LEGALITY (capability gates + clamp) --------------------
    if spec.gate == 'money' and not ctx.moneyOn then return false, 'blocked:money-gate-off' end
    if spec.gate == 'crime' and not ctx.crimeOn then return false, 'blocked:crime-gate-off' end

    local clean = { npc = action.npc, verb = verb, target = action.target }
    if spec.amount and amount ~= nil then
        clean.amount = math.min(amount, spec.amount.max)   -- clamp to the per-verb cap
    end
    return true, 'ok', clean
end

-- ── LLM prompt (built FROM the registry so it can't drift) ───────────────────
local function enumBlock()
    -- deterministic order so the prompt is stable across ticks (cache-friendly)
    local verbs = {}
    for v in pairs(ACTIONS) do verbs[#verbs + 1] = v end
    table.sort(verbs)
    local lines = {}
    for _, v in ipairs(verbs) do
        local s = ACTIONS[v]
        local targetHint = ({ ['none'] = 'no target', ['place'] = 'target = a place name',
            ['place?'] = 'optional target = a place name', ['agent'] = "target = an npc id or 'player'" })[s.target]
        local amtHint = s.amount and (', optional integer amount up to %d'):format(s.amount.max) or ''
        lines[#lines + 1] = ('- "%s": %s (%s%s)'):format(v, s.desc, targetHint, amtHint)
    end
    return table.concat(lines, '\n')
end

local function rosterBlock(roster)
    local lines = {}
    for _, m in ipairs(roster) do
        lines[#lines + 1] = ('- id "%s" (based at %s)'):format(m.id, m.home or 'no fixed spot')
    end
    return table.concat(lines, '\n')
end

-- Named anchors the movers may talkTo (they never move; listed only as targets).
local function residentsBlock()
    local ids = {}
    for _, n in ipairs(Config.NamedNpcs or {}) do
        if n.id then ids[#ids + 1] = ('%s (%s)'):format(n.id, n.name or n.id) end
    end
    if #ids == 0 then return nil end
    return table.concat(ids, ', ')
end

local function placesBlock(places)
    local list = {}
    for label in pairs(places) do list[#list + 1] = label end
    table.sort(list)
    return table.concat(list, ', ')
end

-- ── GLM call (same free-tier path as dialogue; see server/main.lua) ──────────
local G_URL   = GetConvar('palm6:glm_url', 'https://open.bigmodel.cn/api/paas/v4/chat/completions')
local G_MODEL = GetConvar('palm6:glm_model', 'glm-4-flash')
local function gKey() return GetConvar('palm6:glm_key', '') end

-- Pull the first JSON array out of a possibly-chatty model response. Returns a
-- Lua table or nil; never throws (pcall around decode). Defensive because the
-- model may wrap JSON in prose or ```json fences despite instructions.
local function extractActions(resp)
    if type(resp) ~= 'string' then return nil end
    resp = resp:gsub('```json', ''):gsub('```', '')  -- strip markdown code fences first
    -- Greedy: first '[' to last ']' — the whole top-level array. Our plan is an
    -- array of FLAT objects (no nested arrays, no ']' inside values), so greedy is
    -- correct and robust to trailing prose. A malformed grab still fails closed
    -- (json.decode -> nil -> no actions actuated). Audit L4.
    local arr = resp:match('%[.*%]')
    if not arr then return nil end
    local ok, data = pcall(json.decode, arr)
    return (ok and type(data) == 'table') and data or nil
end

-- Run ONE Director tick. cb(result) where result = { accepted={...}, blocked={...},
-- error=nil|string }. Pure-ish: it calls GLM and the validator, and NEVER
-- actuates (this slice). world = { players = N }.
local function runTick(world, cb)
    local roster = buildRoster()
    if #roster == 0 then return cb({ accepted = {}, blocked = {}, error = 'empty-roster' }) end
    local directable, targetable = buildIdentity(roster)
    local places = buildPlaces()

    local key = gKey()
    if key == '' then return cb({ accepted = {}, blocked = {}, error = 'no-glm-key' }) end

    local d = Config.Director or {}
    local ctx = { directable = directable, targetable = targetable, places = places,
                  moneyOn = d.MoneyEnabled == true, crimeOn = d.CrimeEnabled == true }

    local residents = residentsBlock()
    local sys = ([[You are the DIRECTOR of background characters in a Grand Theft Auto V roleplay city (Los Santos). Each tick you assign EVERY listed character ONE action so the city feels alive, especially when few real players are online.

CHARACTERS you direct (use these exact ids, one action each):
%s

PLACES you may reference as a target:
%s%s

ALLOWED ACTIONS (you may ONLY use these verbs and target forms):
%s

Right now %d real player(s) are online. Pick believable, low-key actions — most people idle, wander, or run errands; crime is rare. Keep the city coherent.

Reply with ONLY a JSON array, one object per character, no prose, no code fences. Each object: {"npc":"<id>","verb":"<verb>","target":"<optional>","amount":<optional integer>}. Omit target/amount when the verb takes none.]])
        :format(rosterBlock(roster), placesBlock(places),
            residents and ('\n\nRESIDENTS you may talk to (as a target only — they do not move): ' .. residents) or '',
            enumBlock(), world and world.players or 0)

    -- Fold in any Phase-3+ module context (memory, factions, …) via the seam.
    local extra = gatherContext(world)
    if #extra > 0 then sys = sys .. '\n\nNotes for this tick:\n- ' .. table.concat(extra, '\n- ') end

    local body = json.encode({
        model = G_MODEL,
        messages = { { role = 'system', content = sys },
                     { role = 'user', content = 'Assign this tick.' } },
        max_tokens = 400, temperature = 0.7,
    })

    PerformHttpRequest(G_URL, function(status, resp)
        if status ~= 200 or not resp then
            return cb({ accepted = {}, blocked = {}, error = ('http-%s'):format(tostring(status)) })
        end
        local ok, data = pcall(json.decode, resp)
        local content = ok and data and data.choices and data.choices[1]
            and data.choices[1].message and data.choices[1].message.content
        local actions = extractActions(content)
        if not actions then
            return cb({ accepted = {}, blocked = {}, error = 'unparseable-plan' })
        end

        local accepted, blocked, seen = {}, {}, {}
        for _, a in ipairs(actions) do
            local vok, reason, clean = validateAction(a, ctx)
            if vok then
                -- one goal per NPC: keep the first valid action for each id
                if not seen[clean.npc] then
                    seen[clean.npc] = true
                    accepted[#accepted + 1] = clean
                else
                    blocked[#blocked + 1] = { npc = clean.npc, verb = clean.verb, reason = 'duplicate-npc' }
                end
            else
                blocked[#blocked + 1] = { npc = (type(a) == 'table' and a.npc) or '?',
                    verb = (type(a) == 'table' and a.verb) or '?', reason = reason }
            end
        end
        cb({ accepted = accepted, blocked = blocked, error = nil })
    end, 'POST', body, { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bearer ' .. key })
end

-- Format a tick result for the console meter.
local function logTick(res, tag)
    tag = tag or 'tick'
    if res.error then
        print(('[palm6_brain:director] %s ERROR: %s'):format(tag, res.error))
        return
    end
    print(('[palm6_brain:director] %s — %d accepted, %d blocked (DRY-RUN, nothing actuated):')
        :format(tag, #res.accepted, #res.blocked))
    for _, a in ipairs(res.accepted) do
        local amt = a.amount and (' $' .. a.amount) or ''
        print(('  ✓ %s WOULD %s%s%s'):format(a.npc, a.verb, a.target and (' -> ' .. a.target) or '', amt))
    end
    for _, b in ipairs(res.blocked) do
        print(('  ✗ %s %s BLOCKED: %s'):format(b.npc, b.verb, b.reason))
    end
end

-- ============================================================================
-- GOAL STORE + LIFECYCLE — the substrate actuation reads from.
--
-- Turns the Director from "decide and forget" (dry-run) into "decide, COMMIT one
-- goal per NPC with a TTL, and DEGRADE safely." One active goal per npcId. A goal
-- auto-expires after GoalTtlTicks ticks with no refresh, so a Director/GLM outage
-- can never freeze an NPC on a stale goal — it expires and the NPC falls back to
-- the always-on reflex tier. The client-actuation slice subscribes to the
-- broadcast: `palm6_brain:goal` (npcId, goal|false) — goal={verb,target,amount,
-- expiresAt}; `false` means "goal cleared, return to reflex". Same seam idiom as
-- the LLM seam documented in server/main.lua.
--
-- applyCommit/applyExpire are PURE given `now` (they mutate the passed store and
-- return what changed, no I/O) so the lifecycle is deterministically testable in
-- /brainvalidate. The real commitPlan/expireStale wrap them on the module store
-- and add the broadcast side effect.
-- ============================================================================
local goals = {}   -- npcId -> { verb, target, amount, issuedAt, expiresAt }

local function goalTtlSeconds()
    local d = Config.Director or {}
    return ((d.TickSeconds or 60) * (d.GoalTtlTicks or 2))
end

-- Pure: write one goal into `store`. Returns the stored goal.
local function applyCommit(store, npcId, action, now, ttl)
    local g = { verb = action.verb, target = action.target, amount = action.amount,
                issuedAt = now, expiresAt = now + ttl }
    store[npcId] = g
    return g
end

-- Pure: remove every goal in `store` whose expiresAt has passed. Returns the list
-- of cleared npcIds.
local function applyExpire(store, now)
    local cleared = {}
    for id, g in pairs(store) do
        if now >= g.expiresAt then
            store[id] = nil
            cleared[#cleared + 1] = id
        end
    end
    return cleared
end

-- Forward-declared side-effect hooks (assigned after their guardrails below, so
-- commitPlan can reference them while their bodies are defined later). nil until.
local fireCrimeDispatch
local fireMoneyPatronage

-- Commit an accepted plan to the live store and broadcast each goal. Returns count.
local function commitPlan(accepted)
    local now = os.time()
    local ttl = goalTtlSeconds()
    for _, a in ipairs(accepted) do
        local g = applyCommit(goals, a.npc, a, now, ttl)
        TriggerClientEvent('palm6_brain:goal', -1, a.npc, g)
        if fireCrimeDispatch then fireCrimeDispatch(a) end     -- crime verbs -> throttled police dispatch
        if fireMoneyPatronage then fireMoneyPatronage(a) end   -- orderAt -> passive business income
        notifyObservers(a)                                     -- Phase-3+ modules observe committed goals
    end
    return #accepted
end

-- Expire stale goals on the live store and broadcast a clear for each. Returns count.
local function expireStale()
    local cleared = applyExpire(goals, os.time())
    for _, id in ipairs(cleared) do
        TriggerClientEvent('palm6_brain:goal', -1, id, false)
    end
    return #cleared
end

-- Read API for any consumer (the ped executor, other resources). Lazy-expires on
-- read so a caller never sees a stale goal even between sweeps.
exports('GetGoal', function(npcId)
    local g = goals[npcId]
    if not g then return nil end
    if os.time() >= g.expiresAt then goals[npcId] = nil; return nil end
    return g
end)

exports('GetGoals', function()
    local out, now = {}, os.time()
    for id, g in pairs(goals) do
        if now < g.expiresAt then out[id] = g end
    end
    return out
end)

-- ============================================================================
-- CRIME DISPATCH THROTTLE — the guardrail, built before the live police bus.
--
-- When CrimeEnabled flips on (a later slice), a committed rob/deal/attack goal
-- will call crimeAllowed() and, ONLY if permitted, fire Bridge.AlertPolice +
-- crimeRecord(). This throttle is the roadmap's mandated "rate-limit +
-- CountOnDutyPolice" guard, so off-peak AI crime can never flood on-duty cops.
-- It is pure decision logic over a small state — deterministic given
-- (state, now, onDuty, cfg) — so it is fully unit-tested (/braincrime) BEFORE any
-- dispatch is wired. NOTHING here dispatches anything yet.
-- ============================================================================
local crimeState = { lastGlobal = 0, byLocation = {}, tickCount = 0 }

-- Reset the per-tick counter; called once at the top of each Director tick.
local function crimeResetTick(state) state.tickCount = 0 end

-- Pure, read-only: may a crime dispatch fire now at `location`? -> ok, reason.
local function crimeAllowed(state, now, location, onDuty, cfg)
    if type(location) ~= 'string' or location == '' then return false, 'bad-location' end
    if (onDuty or 0) < (cfg.MinOnDutyPolice or 1) then return false, 'no-police' end
    if (now - (state.lastGlobal or 0)) < (cfg.GlobalCooldownSec or 45) then return false, 'global-cooldown' end
    local lastHere = state.byLocation[location]
    if lastHere and (now - lastHere) < (cfg.LocationCooldownSec or 180) then return false, 'location-cooldown' end
    if (state.tickCount or 0) >= (cfg.PerTickMax or 1) then return false, 'tick-cap' end
    return true, 'ok'
end

-- Record a fired dispatch (call ONLY after a real dispatch actually fired).
local function crimeRecord(state, now, location)
    state.lastGlobal = now
    state.byLocation[location] = now
    state.tickCount = (state.tickCount or 0) + 1
end

-- ── CRIME DISPATCH WIRING — the throttle's live consumer ─────────────────────
-- Server-side maps: scene label -> coords, mover id -> home label. A committed
-- crime goal is "reported" at its mover's HOME scene (the mover is a client-local
-- ped whose live position the server can't see; home is the server-known anchor).
local sceneCoordSv, moverHomeLabelMap = {}, {}
for _, s in ipairs(Config.Scenes or {}) do
    if s.label then sceneCoordSv[s.label] = { x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0 } end
end
for _, m in ipairs(Config.Movers or {}) do
    if m.id then moverHomeLabelMap[m.id] = m.home end
end

-- Assign the forward-declared hook. For a committed crime-gated verb, ask the
-- throttle, and only if it permits fire the police alert + record it. Triple-
-- gated: the validator already blocked the verb unless CrimeEnabled (so it only
-- reaches here with the gate on), commitPlan only runs when DryRun is off, and
-- the throttle caps rate/location/police-presence. Anything missing = no-op.
fireCrimeDispatch = function(action)
    local d = Config.Director or {}
    if not d.CrimeEnabled then return end                     -- defensive re-check
    local spec = ACTIONS[action.verb]
    if not (spec and spec.gate == 'crime') then return end    -- crime verbs only
    local label = moverHomeLabelMap[action.npc]
    local coords = label and sceneCoordSv[label]
    if not coords then return end                             -- no known location
    local cfg = d.Crime or {}
    local onDuty = (Bridge and Bridge.CountOnDutyPolice and Bridge.CountOnDutyPolice()) or 0
    local now = os.time()
    if not crimeAllowed(crimeState, now, label, onDuty, cfg) then return end
    local disp = cfg.Dispatch or {}
    local text = (disp.labels and disp.labels[action.verb]) or disp.defaultLabel or 'Reported incident'
    Bridge.AlertPolice(coords, ('%s — %s'):format(text, label),
        disp.durationSec or 90, disp.sprite or 161, disp.colour or 1, disp.scale or 1.2)
    crimeRecord(crimeState, now, label)
    if d.Verbose then print(('[palm6_brain:director] crime dispatch fired: %s @ %s'):format(text, label)) end
end

-- ── PASSIVE INCOME WIRING — orderAt goals credit nearby owned businesses ─────
-- A committed orderAt goal means a mover is "shopping" at a scene. If a player-
-- owned storefront sits near that scene, credit it through palm6_business's
-- passive faucet (which is itself daily-capped + supply-bounded — the real money
-- guard). Per-business cooldown makes it a believable trickle. Requires BOTH
-- Config.Director.MoneyEnabled AND palm6_business Config.NpcPassiveIncome; with
-- either off this is a no-op (AccrueNpcPassive returns false).
local lastPassive = {}   -- businessId -> epoch of last passive credit (trickle cooldown)
fireMoneyPatronage = function(action)
    local d = Config.Director or {}
    if not d.MoneyEnabled then return end                     -- defensive re-check
    if action.verb ~= 'orderAt' then return end               -- only the "shop at a venue" verb
    local coords = action.target and sceneCoordSv[action.target]
    if not coords then return end
    local mcfg = d.Money or {}
    local sok, bizId = pcall(function()
        return exports.palm6_business:NpcStorefrontAt(coords.x, coords.y, coords.z, mcfg.BusinessRadius or 40.0)
    end)
    bizId = (sok and bizId) or nil
    if not bizId then return end                              -- no owned storefront near this scene
    local now = os.time()
    local cd = mcfg.PerBusinessCooldownSec or 300
    if lastPassive[bizId] and (now - lastPassive[bizId]) < cd then return end   -- trickle
    local aok, credited = pcall(function()
        return exports.palm6_business:AccrueNpcPassive(bizId, 'AI walk-in')
    end)
    if aok and credited == true then
        lastPassive[bizId] = now
        if d.Verbose then print(('[palm6_brain:director] passive income: business %s (%s)'):format(bizId, action.target)) end
    end
end

-- ── The automatic tick loop (only runs when the master gate is on) ───────────
CreateThread(function()
    local d = Config.Director
    if not (d and d.Enabled == true) then return end   -- dark-ship: loop never starts
    local inFlight = false   -- a runTick's async GLM call is outstanding
    while (Config.Director and Config.Director.Enabled) == true do
        crimeResetTick(crimeState)   -- fresh per-tick crime budget (inert until crime is wired)

        -- Expire stale goals FIRST, every iteration — this runs even when GLM is
        -- down or players<min, so a Director outage degrades to reflex on schedule
        -- rather than leaving NPCs stuck on an old goal.
        local swept = expireStale()
        if d.Verbose and swept > 0 then
            print(('[palm6_brain:director] auto — expired %d stale goal(s)'):format(swept))
        end

        local players = #GetPlayers()
        -- Skip firing while a prior tick's GLM call is still outstanding, so two
        -- ticks can never commit in the same window (keeps PerTickMax meaningful
        -- if a GLM call ever runs longer than TickSeconds — audit L1).
        if players >= (d.MinPlayers or 0) and not inFlight then
            inFlight = true
            runTick({ players = players }, function(res)
                inFlight = false
                if d.Verbose then logTick(res, 'auto') end
                -- DryRun=false commits the accepted plan to the goal store +
                -- broadcasts it (still inert until a client executor subscribes).
                if not d.DryRun and not res.error then
                    local n = commitPlan(res.accepted)
                    if d.Verbose and n > 0 then
                        print(('[palm6_brain:director] auto — committed %d goal(s)'):format(n))
                    end
                end
            end)
        end
        Wait(((d.TickSeconds or 60) * 1000))
    end
end)

-- ============================================================================
-- DEV COMMANDS (ACE-restricted: require command.<name>). These are the meters.
-- ============================================================================

-- /braindirector — run ONE live Director tick on demand and print the plan,
-- regardless of the auto-loop gate. Lets David watch the LLM→validate pipeline
-- against the real GLM without lighting the loop. Always DRY-RUN in this slice.
RegisterCommand('braindirector', function(src)
    crimeResetTick(crimeState)   -- fresh crime budget per manual probe, like an auto tick
    runTick({ players = #GetPlayers() }, function(res)
        logTick(res, 'manual')
        -- Mirror the auto-loop: commit only when DryRun is off, so the manual
        -- probe reflects exactly what an automatic tick would do.
        local committed = 0
        if not (Config.Director and Config.Director.DryRun) and not res.error then
            committed = commitPlan(res.accepted)
            print(('[palm6_brain:director] manual — committed %d goal(s)'):format(committed))
        end
        if src ~= 0 then
            TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 },
                args = { 'director', res.error and ('error: ' .. res.error)
                    or ('%d accepted / %d blocked%s — see server console'):format(#res.accepted, #res.blocked,
                        committed > 0 and (', ' .. committed .. ' committed') or '') } })
        end
    end)
end, true)

-- /brainvalidate — run the adversarial test battery through validateAction and
-- print PASS/FAIL. NO GLM, fully deterministic: this is a real unit test running
-- in the real server runtime (per the verification-before-completion rule).
RegisterCommand('brainvalidate', function(src)
    -- Fixed context: two movers (directable), one named anchor 'tony' (targetable
    -- only, NOT directable), known places, both gates OFF (prod default).
    local ctx = {
        directable = { m1 = true, m2 = true },
        targetable = { m1 = true, m2 = true, tony = true },
        places = { ['Legion Square'] = true, ['Del Perro Pier'] = true },
        moneyOn = false, crimeOn = false,
    }
    -- Each case: { action, expectOk, label }. expectOk=false means "must reject".
    local cases = {
        { { npc = 'm1', verb = 'idle' },                                     true,  'idle no-target' },
        { { npc = 'm1', verb = 'goTo', target = 'Legion Square' },           true,  'goTo known place' },
        { { npc = 'm1', verb = 'goTo', target = 'Narnia' },                  false, 'goTo unknown place' },
        { { npc = 'm1', verb = 'teleport' },                                 false, 'unknown verb' },
        { { npc = 'm1', verb = 'talkTo', target = 'ghost' },                 false, 'talkTo unknown agent' },
        { { npc = 'm1', verb = 'talkTo', target = 'player' },                true,  "talkTo 'player'" },
        { { npc = 'm1', verb = 'talkTo', target = 'tony' },                  true,  'talkTo a named anchor (targetable)' },
        { { npc = 'm1', verb = 'talkTo', target = 'm1' },                    false, 'talkTo self' },
        { { npc = 'tony', verb = 'idle' },                                   false, 'named anchor is NOT directable' },
        { { npc = 'm2', verb = 'rob', target = 'player' },                   false, 'rob blocked (crime gate off)' },
        { { npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = 999999 }, false, 'amount over MaxAmount' },
        { { npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = 500 },    false, 'orderAt blocked (money gate off)' },
        { { npc = 'nobody', verb = 'idle' },                                 false, 'unknown npc not directable' },
        { { npc = 'm1', verb = 'idle', target = 'Legion Square' },           false, 'idle rejects a target' },
        { { npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = '500' },  false, 'amount as string' },
        { { npc = 'm1', verb = 'goTo', target = "Legion Square';DROP" },     false, 'injection-ish target' },
        { 'not-a-table',                                                     false, 'non-object action' },
    }
    -- Same battery, but with gates ON, proving money/crime PASS when enabled.
    local ctxOn = { directable = ctx.directable, targetable = ctx.targetable, places = ctx.places, moneyOn = true, crimeOn = true }
    local gateCases = {
        { { npc = 'm2', verb = 'rob', target = 'player' },                   true,  'rob passes (crime gate on)' },
        { { npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = 500 }, true, 'orderAt passes (money gate on)' },
    }

    local pass, fail = 0, 0
    local function run(list, c)
        for _, case in ipairs(list) do
            local ok = validateAction(case[1], c)
            if ok == case[2] then
                pass = pass + 1
            else
                fail = fail + 1
                print(('[palm6_brain:director]   FAIL: %s (got ok=%s, expected %s)')
                    :format(case[3], tostring(ok), tostring(case[2])))
            end
        end
    end
    print('[palm6_brain:director] running validator battery...')
    run(cases, ctx)
    run(gateCases, ctxOn)
    -- Prove the clamp: amount above the per-verb cap is reduced, not rejected.
    local cok, _, clean = validateAction({ npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = 1900 }, ctxOn)
    local clampOk = cok and clean and clean.amount == 1900
    local cok2, _, clean2 = validateAction({ npc = 'm1', verb = 'orderAt', target = 'Legion Square', amount = 5000 }, ctxOn)
    local clampOk2 = cok2 and clean2 and clean2.amount == 2000   -- clamped to orderAt cap
    if clampOk and clampOk2 then pass = pass + 1 else fail = fail + 1; print('[palm6_brain:director]   FAIL: amount clamp') end

    -- Goal lifecycle (pure, deterministic via injected `now`): a goal survives
    -- before its TTL, is cleared at/after it, and a refresh extends it. Proves the
    -- degradation guarantee (stale goals always expire) without waiting real time.
    do
        local store = {}
        applyCommit(store, 'tony', { verb = 'idle' }, 1000, 120)          -- expires 1120
        local aliveBefore = (#applyExpire(store, 1119) == 0 and store.tony ~= nil)
        local cl = applyExpire(store, 1120)                                -- 1120 >= 1120 → clear
        local clearedAt = (#cl == 1 and cl[1] == 'tony' and store.tony == nil)
        applyCommit(store, 'rosa', { verb = 'wander' }, 1000, 120)         -- expires 1120
        applyCommit(store, 'rosa', { verb = 'wander' }, 1200, 120)         -- refreshed → 1320
        local refreshOk = (#applyExpire(store, 1250) == 0 and store.rosa ~= nil)
        if aliveBefore and clearedAt and refreshOk then pass = pass + 1
        else fail = fail + 1; print('[palm6_brain:director]   FAIL: goal lifecycle') end
    end

    local msg = ('validator: %d passed, %d failed'):format(pass, fail)
    print('[palm6_brain:director] ' .. msg)
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = fail == 0 and { 120, 220, 140 } or { 230, 120, 120 },
            args = { 'director', msg } })
    end
end, true)

-- /braingoals — print the live goal store (what each NPC is currently committed
-- to and how long until it expires). The observability meter for the commit path;
-- empty while the Director is dry-run or has issued nothing.
RegisterCommand('braingoals', function(src)
    local now = os.time()
    local n = 0
    print('[palm6_brain:director] current goal store:')
    for id, g in pairs(goals) do
        local ttl = g.expiresAt - now
        if ttl > 0 then
            n = n + 1
            print(('  %s -> %s%s%s (%ds left)'):format(id, g.verb,
                g.target and (' -> ' .. g.target) or '',
                g.amount and (' $' .. g.amount) or '', ttl))
        end
    end
    if n == 0 then print('  (empty — Director is dry-run or has issued no goals)') end
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 },
            args = { 'director', ('%d active goal(s) — see server console'):format(n) } })
    end
end, true)

-- /braincrime — deterministic battery for the crime dispatch throttle (no live
-- dispatch, no GLM). Proves the rate-limiter BEFORE it guards the real police bus.
RegisterCommand('braincrime', function(src)
    local cfg = { MinOnDutyPolice = 1, GlobalCooldownSec = 45, LocationCooldownSec = 180, PerTickMax = 1 }
    local pass, fail = 0, 0
    local function expect(cond, label)
        if cond then pass = pass + 1
        else fail = fail + 1; print('[palm6_brain:director]   FAIL: ' .. label) end
    end
    local s = { lastGlobal = 0, byLocation = {}, tickCount = 0 }
    local ok, reason

    ok = crimeAllowed(s, 1000, 'Legion Square', 0, cfg);        expect(ok == false, 'no police -> reject')
    ok = crimeAllowed(s, 1000, 'Legion Square', 1, cfg);        expect(ok == true,  'police + fresh -> allow')
    crimeRecord(s, 1000, 'Legion Square')
    ok, reason = crimeAllowed(s, 1044, 'Del Perro Pier', 2, cfg); expect(ok == false and reason == 'global-cooldown', 'within global cooldown -> reject')
    crimeResetTick(s)
    ok = crimeAllowed(s, 1045, 'Del Perro Pier', 2, cfg);       expect(ok == true,  'after global cooldown, new location -> allow')
    ok, reason = crimeAllowed(s, 1100, 'Legion Square', 2, cfg); expect(ok == false and reason == 'location-cooldown', 'same location within cooldown -> reject')
    crimeResetTick(s)
    crimeRecord(s, 2000, 'Vespucci Beach')
    ok, reason = crimeAllowed(s, 2050, 'Sandy Shores', 2, cfg); expect(ok == false and reason == 'tick-cap', 'per-tick cap -> reject')
    crimeResetTick(s)
    ok = crimeAllowed(s, 2050, 'Sandy Shores', 2, cfg);         expect(ok == true,  'after tick reset -> allow')
    ok = crimeAllowed(s, 3000, '', 2, cfg);                     expect(ok == false, 'empty location -> reject')

    local msg = ('crime throttle: %d passed, %d failed'):format(pass, fail)
    print('[palm6_brain:director] ' .. msg)
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = fail == 0 and { 120, 220, 140 } or { 230, 120, 120 },
            args = { 'director', msg } })
    end
end, true)

-- /brainstatus — one-shot health snapshot of the whole AI-NPC brain: every gate
-- state + live counts in one place, so a deploy / browser-walk needs ONE command
-- instead of four. Read-only. This is also the canonical "are all the gates where
-- I think they are?" check before flipping anything live.
RegisterCommand('brainstatus', function(src)
    local d = Config.Director or {}
    local function yn(v) return v and 'ON' or 'off' end
    local now = os.time()
    local ng = 0
    for _, g in pairs(goals) do if now < g.expiresAt then ng = ng + 1 end end
    print('[palm6_brain] ===== STATUS =====')
    print(('  master Config.Enabled = %s'):format(yn(Config.Enabled == true)))
    print(('  Director: Enabled=%s  DryRun=%s  Tick=%ss  MinPlayers=%s')
        :format(yn(d.Enabled == true), yn(d.DryRun == true), tostring(d.TickSeconds or 60), tostring(d.MinPlayers or 0)))
    print(('  capability gates: MoneyEnabled=%s  CrimeEnabled=%s')
        :format(yn(d.MoneyEnabled == true), yn(d.CrimeEnabled == true)))
    print(('  roster: %d movers, %d named NPCs, %d scenes')
        :format(#(Config.Movers or {}), #(Config.NamedNpcs or {}), #(Config.Scenes or {})))
    print(('  live: %d active goal(s); GLM key %s; %d player(s) online')
        :format(ng, gKey() ~= '' and 'SET' or 'MISSING', #GetPlayers()))
    print('  note: passive money needs BOTH Director.MoneyEnabled AND palm6_business Config.NpcPassiveIncome')
    print('  note: factions + chatter each have their OWN local CFG.Enabled (server/factions.lua, client/chatter.lua)')
    print('  meters: /brainvalidate /braincrime /braindirector /braingoals /brainmemory')
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = { 150, 200, 255 },
            args = { 'brain', ('Director %s / DryRun %s / Money %s / Crime %s — full status in console')
                :format(yn(d.Enabled == true), yn(d.DryRun == true), yn(d.MoneyEnabled == true), yn(d.CrimeEnabled == true)) } })
    end
end, true)

-- On resource stop, drop every goal (in place, so export closures keep their
-- upvalue) so a restart never resurrects stale goals. Clients tear down their own
-- state via the client onResourceStop handler.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for k in pairs(goals) do goals[k] = nil end
end)
