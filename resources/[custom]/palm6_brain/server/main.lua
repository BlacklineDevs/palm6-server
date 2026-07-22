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

-- Ask GLM for an in-character line. cb(reply|nil). nil => caller uses canned.
local function askBrain(src, npc, playerText, cb)
    local key = glmKey()
    if key == '' then return cb(nil) end   -- not wired yet -> stub fallback

    local ckey = ('%s|%s'):format(src, npc.id)
    local hist = convo[ckey] or {}
    local sys = ([[You are %s, a character in a Grand Theft Auto V roleplay city (Los Santos). %s Personality: %s.
Stay fully in character. Reply with ONE short spoken line only (max 25 words) — no narration, no stage directions, no quotes, no emojis. React naturally to what the player says.]])
        :format(npc.name, npc.role or '', npc.personality or '')

    local messages = { { role = 'system', content = sys } }
    for _, m in ipairs(hist) do messages[#messages + 1] = m end
    messages[#messages + 1] = { role = 'user', content = playerText }

    local body = json.encode({
        model = GLM_MODEL, messages = messages,
        max_tokens = 100, temperature = 0.85,
    })

    PerformHttpRequest(GLM_URL, function(status, resp)
        if status ~= 200 or not resp then
            if Config.Debug then print(('[palm6_brain] GLM http %s: %s'):format(status, tostring(resp):sub(1, 200))) end
            return cb(nil)
        end
        local ok, data = pcall(json.decode, resp)
        local reply = ok and data and data.choices and data.choices[1]
            and data.choices[1].message and data.choices[1].message.content
        reply = reply and cleanReply(reply) or nil
        if reply and reply ~= '' then
            -- persist the exchange for continuity, trimmed to CONVO_MAX
            hist[#hist + 1] = { role = 'user', content = playerText }
            hist[#hist + 1] = { role = 'assistant', content = reply }
            while #hist > CONVO_MAX do table.remove(hist, 1) end
            convo[ckey] = hist
        end
        cb(reply)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. key,
    })
end
-- ────────────────────────────────────────────────────────────────────────────

local lastSay = {}  -- src -> epoch seconds (light anti-spam; eventguard is the real gate)

RegisterNetEvent('palm6_brain:say', function(npcId, text)
    if not (Config.Enabled and Config.NamedEnabled) then return end
    local src = source
    local now = os.time()
    if lastSay[src] and (now - lastSay[src]) < 1 then return end
    lastSay[src] = now

    local npc = npcById(tostring(npcId or ''))
    if not npc then return end
    text = tostring(text or ''):sub(1, 200)

    askBrain(src, npc, text, function(reply)
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
