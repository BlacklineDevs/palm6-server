-- ============================================================================
-- palm6_brain/server/talk.lua — INTEL+ FLAGSHIP: talk to ANY pedestrian.
--
-- Walk up to any Los Santos local and have a REAL conversation: the reply is a
-- live GLM line, spoken in character for THAT ped's persona (Social.GetPersona)
-- and coloured by how the ped regards YOU (reputation + witness/gossip/alibi
-- memory, all folded in by Social.BuildDialogueContext). This is INTEL's headline
-- mechanic — but LLM-voiced instead of canned config pools.
--
-- Server-authoritative: the client only sends the ped's stable key + what the
-- player said; the server decides who that ped IS and what it says back. When the
-- player's line is itself an ACTION (a threat, or an offer of help) we fire a
-- Social.ReportEvent so the FOUNDATION moves reputation — chatter that crosses
-- into behaviour actually changes how the block treats you.
--
-- Dark by default: every entrypoint returns immediately unless Config.Social.Enabled.
-- GLM path is copied verbatim from server/main.lua (same convars, same POST, same
-- reply-clean) so there is one dialogue-brain idiom in the resource, not two.
-- ============================================================================

local function enabled() return (Config.Social or {}).Enabled == true end

-- ── LLM BRAIN (GLM) — identical wiring to server/main.lua ────────────────────
-- Zero-budget path: GLM (Zhipu/z.ai free Flash tier) called straight from the
-- server. NO Anthropic key (David's "use Max, no API" rule is Anthropic-only; GLM
-- is the free non-Anthropic option already used by the named-NPC brain). The key
-- lives ONLY in a server convar. Empty convar or a failed call => canned fallback,
-- so the feature degrades gracefully and is safe to ship before the key is set.
local GLM_URL   = GetConvar('palm6:glm_url', 'https://open.bigmodel.cn/api/paas/v4/chat/completions')
local GLM_MODEL = GetConvar('palm6:glm_model', 'glm-4-flash')
local function glmKey() return GetConvar('palm6:glm_key', '') end

-- Short per-(src|pedKey) memory so a given ped remembers the last few turns of
-- THIS conversation with THIS player (continuity). Bounded + cleared on drop.
local convo = {}
local CONVO_MAX = 6   -- last 6 messages (3 exchanges)

-- Canned fallbacks when GLM is unwired or fails — generic street one-liners so an
-- anonymous ped still says *something* in character.
local FALLBACK = {
    "What do you want?", "Yeah? I'm listenin'.", "You talkin' to me?",
    "I got somewhere to be, make it quick.", "Hm. Go on.",
    "Don't know you, friend.", "Watch where you're goin'.",
}
local function cannedLine() return FALLBACK[math.random(#FALLBACK)] end

local function cleanReply(s)
    s = tostring(s or '')
    s = s:gsub('^%s*"(.-)"%s*$', '%1')   -- strip wrapping quotes
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s:sub(1, 240)
end

-- Ask GLM for one in-character line. cb(reply|nil); nil => caller uses canned.
local function askBrain(src, pedKey, cid, playerText, cb)
    local key = glmKey()
    if key == '' then return cb(nil) end   -- not wired yet -> canned fallback

    -- The Social foundation builds the persona + reputation + witness/gossip/alibi
    -- context; we PREPEND it, then bolt on the strict output contract.
    local ctx = 'You are a Los Santos local.'
    local ok, built = pcall(Social.BuildDialogueContext, cid, pedKey)
    if ok and type(built) == 'string' and built ~= '' then ctx = built end
    local sys = ctx .. '\n' ..
        'Stay fully in character as this person. Reply with ONE short spoken line only ' ..
        '(max 25 words) — no narration, no stage directions, no quotes, no emojis. ' ..
        'React naturally to what the player says.'

    local ckey = ('%s|%s'):format(src, pedKey)
    local hist = convo[ckey] or {}
    local messages = { { role = 'system', content = sys } }
    for _, m in ipairs(hist) do messages[#messages + 1] = m end
    messages[#messages + 1] = { role = 'user', content = playerText }

    local body = json.encode({
        model = GLM_MODEL, messages = messages,
        max_tokens = 100, temperature = 0.85,
    })

    PerformHttpRequest(GLM_URL, function(status, resp)
        if status ~= 200 or not resp then
            if Config.Debug then print(('[palm6_brain:talk] GLM http %s: %s'):format(status, tostring(resp):sub(1, 200))) end
            return cb(nil)
        end
        local ok2, data = pcall(json.decode, resp)
        local reply = ok2 and data and data.choices and data.choices[1]
            and data.choices[1].message and data.choices[1].message.content
        reply = reply and cleanReply(reply) or nil
        if reply and reply ~= '' then
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

-- ── ACTION DETECTION ─────────────────────────────────────────────────────────
-- If the player's line is clearly hostile or clearly friendly, treat it as an
-- ACTION and report it to the Social foundation, which moves reputation (RepDelta:
-- threat -1, help +4) and fans the event to witness/gossip. Deliberately simple —
-- a small keyword check; the foundation owns the real bookkeeping.
local THREAT_WORDS = {
    'kill', 'shoot', 'gun', 'rob', 'give me your', 'hands up', 'die', 'threat',
    'hurt you', 'beat you', 'stab', 'gonna get you', 'or else', 'money now',
}
local HELP_WORDS = {
    'help you', 'need help', 'are you okay', 'you alright', 'let me help',
    'can i help', 'here you go', 'take this', 'for you', 'you good',
}
local function detectAction(text)
    local t = ' ' .. text:lower() .. ' '
    for _, w in ipairs(THREAT_WORDS) do if t:find(w, 1, true) then return 'threat' end end
    for _, w in ipairs(HELP_WORDS)   do if t:find(w, 1, true) then return 'help'   end end
    return nil
end

local function reportAction(src, cid, pedKey, text)
    local kind = detectAction(text)
    if not kind then return end
    if Social and Social.ReportEvent then
        pcall(Social.ReportEvent, {
            kind      = kind,
            cid       = cid,
            playerSrc = src,
            target    = pedKey,
            meta      = { via = 'talk' },
        })
    end
end

-- Resolve the player's citizenid via QBox, mirroring server/witness.lua. Falls
-- back to a synthetic per-src id so the flow still works if unresolvable.
local function resolveCid(src)
    local cid = ('src:%s'):format(tostring(src))
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and player and player.PlayerData and player.PlayerData.citizenid then
        cid = player.PlayerData.citizenid
    end
    return cid
end

-- ── ENTRYPOINT ───────────────────────────────────────────────────────────────
local lastSay = {}   -- src -> epoch seconds (light per-source anti-spam ~1/sec)

RegisterNetEvent('palm6_brain:talk:say', function(pedKey, text)
    if not enabled() then return end
    local src = source
    local now = os.time()
    if lastSay[src] and (now - lastSay[src]) < 1 then return end
    lastSay[src] = now

    pedKey = tostring(pedKey or '')
    if pedKey == '' then return end
    text = tostring(text or ''):sub(1, 200)
    if text == '' then return end

    local cid = resolveCid(src)
    reportAction(src, cid, pedKey, text)   -- action lines move reputation via the foundation

    askBrain(src, pedKey, cid, text, function(reply)
        if not reply or reply == '' then reply = cannedLine() end   -- graceful fallback
        TriggerClientEvent('palm6_brain:talk:reply', src, pedKey, reply)
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastSay[src] = nil
    local prefix = src .. '|'
    for k in pairs(convo) do
        if k:sub(1, #prefix) == prefix then convo[k] = nil end
    end
end)

print(('[palm6_brain:talk] talk-to-any-ped ready (%s) — GLM-voiced personas via the Social seam.')
    :format(enabled() and 'ENABLED' or 'dark'))
