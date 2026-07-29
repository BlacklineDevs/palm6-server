-- ============================================================================
-- palm6_brain/server/main.lua — Phase 1 dialogue: STUB brain.
--
-- The reply is server-authoritative by design: the client only sends what the
-- player said; the server decides the response. Right now it returns a canned
-- line from the NPC's identity card. THIS is the single seam where the real LLM
-- lands in Phase 1-real — replace the stub with an HTTP POST to the `cortex`
-- sidecar ({ npc = role/personality, player_said = text, memory = ... }) and send
-- the streamed reply back over the same 'palm6_brain:reply' event. Nothing else
-- (client UI, targeting, path) has to change.
-- ============================================================================

-- ============================================================================
-- LLM CALL METER + FAILURE BACKOFF (`BrainMeter`) - "ship the meter before
-- shipped" applied to the one layer in this resource that costs real money.
--
-- Every PerformHttpRequest in palm6_brain is a paid GLM call, and until now the
-- only observability was `GLM key SET/MISSING` in /brainstatus: a dead endpoint,
-- a revoked key or a rate-limited account looked EXACTLY like a working one, and
-- the Director kept POSTing every 60s forever. This is the resource-global counter
-- the three call sites (server/main.lua, server/director.lua, server/talk.lua)
-- record into, surfaced in the existing /brainstatus printout - no new command.
--
-- Defined HERE because main.lua is the first server script after the bridge in the
-- fxmanifest, so director.lua and talk.lua both see it. The CROSS-FILE consumers
-- (server/director.lua, server/talk.lua) guard with `if BrainMeter and ... then` so
-- load order can never hard-error a dialogue path. The call sites further down THIS
-- file are unguarded on purpose: they sit below the definition in the same chunk, so
-- BrainMeter is always present by the time they run.
--
-- Two lanes, because they fail and matter differently:
--   • 'director' - the unattended 60s loop. Nobody is watching it, so it is the
--     one that quietly burns budget. It BACKS OFF.
--   • 'dialogue' - a player is standing there waiting. It backs off too, but the
--     backoff simply routes to the canned-line fallback that already exists for a
--     failed call, so the player-visible behaviour is unchanged from a GLM outage.
--
-- TWO KINDS OF BAD OUTCOME, and only ONE of them may arm the backoff:
--   • OUTAGE (`BrainMeter.Result(name, false, status)`) - transport failed: a non-200,
--     a nil body, a dead endpoint, a revoked key. This IS evidence the provider is
--     down, so it feeds `consecFail` and can pause the lane.
--   • WASTED (`BrainMeter.Wasted(name, reason)`) - a 200 that carried nothing usable
--     ('empty-reply', 'unparseable-plan'). It cost real money, so it must show in the
--     meter, but it proves the endpoint ANSWERED. Counting it as an outage would let
--     three ordinary model hiccups - or a player deliberately feeding lines the model
--     refuses - pause the SHARED 'dialogue' lane for 5 minutes and drop every ped in
--     the city to canned lines. So it never touches `consecFail` or `backoffUntil`.
-- ============================================================================
BrainMeter = {}

local MCFG = Config.LlmMeter or {}
-- Consecutive failures before a lane pauses. 0 disables the pause entirely and
-- leaves the counters running (the one-value off switch for the backoff half).
local BACKOFF_AFTER = tonumber(MCFG.BackoffAfter) or 3
-- math.floor on ingest: BACKOFF_SEC is formatted with `%d` in the outage print below
-- AND (via `backoffUntil - now`) in /brainstatus. Under `lua54 'yes'` a fractional
-- config value like 300.5 would raise "number has no integer representation" inside
-- the print itself - i.e. at outage time, in the failure path, not at config load.
local BACKOFF_SEC   = math.floor(tonumber(MCFG.BackoffSeconds) or 300)

-- `failed` is every bad outcome (what the operator budgets against); `wasted` is the
-- subset that came back 200-but-useless and therefore did NOT count toward backoff.
local lanes = {
    director = { attempted = 0, ok = 0, failed = 0, wasted = 0, lastStatus = 'none', consecFail = 0, backoffUntil = 0, logged = false },
    dialogue = { attempted = 0, ok = 0, failed = 0, wasted = 0, lastStatus = 'none', consecFail = 0, backoffUntil = 0, logged = false },
}
local function lane(name) return lanes[name] or lanes.dialogue end

-- Called immediately before a PerformHttpRequest goes out.
function BrainMeter.Attempt(name)
    local m = lane(name)
    m.attempted = m.attempted + 1
end

-- Called on a SUCCESS or on a TRANSPORT FAILURE. `okCall` = we got a usable answer;
-- `status` is the HTTP status or a short reason string so the meter says WHY, not
-- just "failed". `okCall == false` here means "the endpoint did not answer usefully
-- at the transport level" and is the ONLY thing that arms the backoff - a 200 with an
-- unusable body goes to BrainMeter.Wasted instead (see the header block).
function BrainMeter.Result(name, okCall, status)
    local m = lane(name)
    local now = os.time()
    if okCall then
        m.ok, m.consecFail, m.lastStatus = m.ok + 1, 0, tostring(status or 200)
        if m.backoffUntil > 0 then
            m.backoffUntil, m.logged = 0, false
            print(('[palm6_brain:meter] %s LLM recovered - backoff cleared.'):format(name))
        end
        return
    end
    m.failed, m.consecFail = m.failed + 1, m.consecFail + 1
    m.lastStatus = tostring(status or 'nil')
    if BACKOFF_AFTER > 0 and m.consecFail >= BACKOFF_AFTER and now >= m.backoffUntil then
        m.backoffUntil = now + BACKOFF_SEC
        if not m.logged then   -- log ONCE per outage, not once per failed call
            m.logged = true
            print(('^1[palm6_brain:meter] %s LLM failed %d times in a row (last: %s) - pausing GLM calls for %ds. /brainstatus for the meter.^0')
                :format(name, m.consecFail, m.lastStatus, BACKOFF_SEC))
        end
    end
end

-- Called when the call SUCCEEDED at the transport level (HTTP 200) but produced
-- nothing we could use: an empty `content`, or a plan we could not parse. It is a
-- wasted paid call, so it counts in `failed` (and in its own `wasted` bucket, and it
-- sets lastStatus so the operator sees the reason) - but it deliberately does NOT
-- touch `consecFail` or `backoffUntil`. A model returning an empty line is not the
-- endpoint being down, and the 'dialogue' lane is SHARED by every ped in the city:
-- letting three of these pause it would hand any player a 5-minute city-wide mute.
-- consecFail is left AS IS rather than reset, so a genuine outage that is merely
-- interleaved with empty replies still reaches the threshold.
function BrainMeter.Wasted(name, reason)
    local m = lane(name)
    m.failed, m.wasted = m.failed + 1, m.wasted + 1
    m.lastStatus = tostring(reason or 'empty-reply')
end

-- True while a lane is paused. Callers skip the paid call and use their fallback.
function BrainMeter.BackingOff(name)
    return os.time() < lane(name).backoffUntil
end

-- One console line per lane for /brainstatus.
function BrainMeter.Line(name)
    local m, now = lane(name), os.time()
    return ('%s: %d attempted / %d ok / %d failed (%d wasted 200s); last %s; %d consecutive transport fail(s)%s')
        :format(name, m.attempted, m.ok, m.failed, m.wasted, m.lastStatus, m.consecFail,
            now < m.backoffUntil and (('; BACKING OFF %ds'):format(m.backoffUntil - now)) or '')
end

local function npcById(id)
    for _, n in ipairs(Config.NamedNpcs or {}) do
        if n.id == id then return n end
    end
    return nil
end

-- ── LLM BRAIN (GLM) ─────────────────────────────────────────────────────────
-- Zero-budget path: GLM (Zhipu/z.ai, the free Flash tier) called directly from
-- the server. NO Anthropic API key (David's "use Max, no API" rule is about
-- Anthropic; GLM is the free non-Anthropic option already used elsewhere). The
-- key lives ONLY in a server convar (set out-of-band, never in git). If the convar
-- is empty or the call fails, we fall back to the NPC's canned lines — so the
-- feature degrades gracefully and is safe to ship before the key is set.
local GLM_URL   = GetConvar('palm6:glm_url', 'https://open.bigmodel.cn/api/paas/v4/chat/completions')
local GLM_MODEL = GetConvar('palm6:glm_model', 'glm-4-flash')  -- free tier
local function glmKey() return GetConvar('palm6:glm_key', '') end

-- Short per-conversation memory: (src|npcId) -> { {role,content}, ... } last turns.
local convo = {}
local CONVO_MAX = 6   -- keep last 6 messages (3 exchanges) for continuity

local function cannedFor(npc)
    local lines = npc.lines or { '...' }
    return lines[math.random(#lines)]
end

local function cleanReply(s)
    s = tostring(s or '')
    s = s:gsub('^%s*"(.-)"%s*$', '%1')   -- strip wrapping quotes
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s:sub(1, 240)
end

-- Turn the client's world snapshot into one plain-English line the NPC can draw on
-- (so "what time is it / what day / weather / anyone around" get real answers). All
-- fields optional — a missing snapshot just omits the line and nothing breaks.
local function worldLine(w)
    if type(w) ~= 'table' then return nil end
    local parts = {}
    local h, m = tonumber(w.h), tonumber(w.m)
    if h then
        local ampm = h < 12 and 'AM' or 'PM'
        local h12 = h % 12; if h12 == 0 then h12 = 12 end
        parts[#parts + 1] = ('it is %d:%02d %s'):format(h12, m or 0, ampm)
    end
    if w.day then
        parts[#parts + 1] = w.dom and w.mon
            and ('%s, %s %d'):format(w.day, w.mon, w.dom) or tostring(w.day)
    end
    if w.wx then parts[#parts + 1] = 'the weather is ' .. tostring(w.wx) end
    local near = tonumber(w.near)
    if near then
        parts[#parts + 1] = near == 0 and 'the street is empty right now'
            or ('%d other %s nearby'):format(near, near == 1 and 'person is' or 'people are')
    end
    if #parts == 0 then return nil end
    return 'Current moment in the city: ' .. table.concat(parts, ', ') .. '.'
end

-- Ask GLM for an in-character line. cb(reply|nil). nil => caller uses canned.
local function askBrain(src, npc, playerText, world, cb)
    local key = glmKey()
    if key == '' then return cb(nil) end   -- not wired yet -> stub fallback
    -- GLM is failing hard: skip the paid call and take the canned line straight
    -- away. Same player-visible result a failed call already produces.
    if BrainMeter.BackingOff('dialogue') then return cb(nil) end

    local ckey = ('%s|%s'):format(src, npc.id)
    local hist = convo[ckey] or {}
    local sys = ([[You are %s, a character in a Grand Theft Auto V roleplay city (Los Santos). %s Personality: %s.
Stay fully in character. Reply with ONE short spoken line only (max 25 words) — no narration, no stage directions, no quotes, no emojis. React naturally to what the player says.]])
        :format(npc.name, npc.role or '', npc.personality or '')

    local wl = worldLine(world)
    if wl then
        sys = sys .. '\n' .. wl ..
            ' If asked about the time, day, weather, or who is around, answer naturally from this — never say you do not know.'
    end

    local messages = { { role = 'system', content = sys } }
    for _, m in ipairs(hist) do messages[#messages + 1] = m end
    messages[#messages + 1] = { role = 'user', content = playerText }

    local body = json.encode({
        model = GLM_MODEL, messages = messages,
        max_tokens = 100, temperature = 0.85,
    })

    BrainMeter.Attempt('dialogue')
    PerformHttpRequest(GLM_URL, function(status, resp)
        if status ~= 200 or not resp then
            BrainMeter.Result('dialogue', false, status)
            if Config.Debug then print(('[palm6_brain] GLM http %s: %s'):format(status, tostring(resp):sub(1, 200))) end
            return cb(nil)
        end
        local ok, data = pcall(json.decode, resp)
        local reply = ok and data and data.choices and data.choices[1]
            and data.choices[1].message and data.choices[1].message.content
        reply = reply and cleanReply(reply) or nil
        -- A 200 that carries no usable line is still a wasted paid call, so the meter
        -- records it with a reason the operator can act on - but via Wasted(), NOT
        -- Result(..., false, ...): the endpoint answered, so it must not arm the
        -- shared 'dialogue' backoff. See the BrainMeter header block.
        if reply and reply ~= '' then
            BrainMeter.Result('dialogue', true, 200)
            -- persist the exchange for continuity, trimmed to CONVO_MAX
            hist[#hist + 1] = { role = 'user', content = playerText }
            hist[#hist + 1] = { role = 'assistant', content = reply }
            while #hist > CONVO_MAX do table.remove(hist, 1) end
            convo[ckey] = hist
        else
            BrainMeter.Wasted('dialogue', 'empty-reply')
        end
        cb(reply)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. key,
    })
end
-- ────────────────────────────────────────────────────────────────────────────

local lastSay = {}  -- src -> epoch seconds (light anti-spam; eventguard is the real gate)

RegisterNetEvent('palm6_brain:say', function(npcId, text, world)
    if not (Config.Enabled and Config.NamedEnabled) then return end
    local src = source
    local now = os.time()
    if lastSay[src] and (now - lastSay[src]) < 1 then return end
    lastSay[src] = now

    local npc = npcById(tostring(npcId or ''))
    if not npc then return end
    text = tostring(text or ''):sub(1, 200)

    askBrain(src, npc, text, world, function(reply)
        if not reply or reply == '' then reply = cannedFor(npc) end  -- graceful fallback
        TriggerClientEvent('palm6_brain:reply', src, npc.id, reply)
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastSay[src] = nil
    for k in pairs(convo) do
        if k:match('^' .. src .. '|') then convo[k] = nil end
    end
end)
