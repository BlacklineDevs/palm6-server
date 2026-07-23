-- ============================================================================
-- palm6_brain/server/social.lua — SOCIAL LAYER FOUNDATION ("INTEL+").
--
-- Every mechanic the INTEL script sells (talk to any ped, memory, mood,
-- reputation, witness, gossip, snitch, alibi) — but LLM-voiced (GLM) and fused
-- with our autonomous Director, instead of INTEL's canned config pools. This file
-- is the SHARED FOUNDATION: it exposes a resource-global `Social` table that the
-- feature modules (witness/gossip/snitch/alibi/talk-to-any-ped/UI) build on WITHOUT
-- editing each other — the same seam pattern as `Director`.
--
-- What lives here (the interfaces the feature modules use):
--   • PERSONAS   — Social.GetPersona(pedKey) -> a stable {archetype, mood, name}
--       for ANY ped, so any pedestrian can talk in character.
--   • REPUTATION — Social.GetRep/GetTier/AdjustRep(cid) — per-player trust
--       (-10..+10, nine tiers), KVP-persisted, gating dialogue tone + prices.
--   • EVENT SEAM — Social.ReportEvent(evt) fans a social event (a player helped/
--       bribed/robbed/etc.) to every Social.OnEvent(fn) consumer; also auto-moves
--       reputation for known action kinds. Witness/gossip/snitch subscribe here.
--   • DIALOGUE CONTEXT — Social.RegisterDialogueContext(fn) lets a module inject a
--       line into a ped's LLM prompt (rep, witnessed memory, mood…);
--       Social.BuildDialogueContext(cid, pedKey) assembles the full context string
--       the talk-to-any-ped module feeds to GLM.
--
-- Dark by default (Config.Social.Enabled): reputation READS and personas are pure
-- and always safe, but AdjustRep / ReportEvent / persistence only act when the
-- layer is enabled. Every consumer call is pcall-isolated.
-- ============================================================================

Social = {}
local CFG = Config.Social or {}
local function enabled() return (Config.Social or {}).Enabled == true end

-- ── small helpers ────────────────────────────────────────────────────────────
local function hashStr(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end

-- A brand-safe first-name pool for generated personas (fictional Los Santos locals).
local NAMES = {
    'Marcus', 'Elena', 'Rico', 'Tanya', 'Deshawn', 'Priya', 'Vince', 'Marisol',
    'Cole', 'Nadia', 'Omar', 'Bianca', 'Trey', 'Lena', 'Diego', 'Simone',
    'Andre', 'Rosa', 'Kwame', 'Jess', 'Hector', 'Mei', 'Franco', 'Dot',
}

-- ── PERSONAS ─────────────────────────────────────────────────────────────────
-- A persona is stable per pedKey within a session (cached). Archetype + name are
-- derived DETERMINISTICALLY from the key (so the same ped is the same character
-- each time you talk to it); mood is rolled per session for a little variance.
local personaCache = {}   -- pedKey -> { archetype, mood, name }

function Social.GetPersona(pedKey)
    pedKey = tostring(pedKey or '')
    if pedKey == '' then pedKey = 'anon' end
    local cached = personaCache[pedKey]
    if cached then return cached end

    local archKeys = {}
    for k in pairs(CFG.Archetypes or {}) do archKeys[#archKeys + 1] = k end
    table.sort(archKeys)
    local h = hashStr(pedKey)
    local arche = (#archKeys > 0) and archKeys[(h % #archKeys) + 1] or (CFG.DefaultArchetype or 'compliant')
    local name  = NAMES[(h % #NAMES) + 1]
    local moods = CFG.Moods or { 'neutral' }
    local mood  = moods[math.random(#moods)]

    local p = { archetype = arche, mood = mood, name = name }
    personaCache[pedKey] = p
    return p
end

-- Let a module nudge a ped's mood (e.g. witnessing a crime makes it 'grumpy').
function Social.SetMood(pedKey, mood)
    local p = personaCache[tostring(pedKey or '')]
    if p and type(mood) == 'string' then p.mood = mood end
end

-- ── REPUTATION (KVP-persisted, -10..+10) ─────────────────────────────────────
local REP_KVP = 'palm6_brain:social:rep:v1'
local rep = {}   -- cid(string) -> int

local function saveRep()
    local ok, blob = pcall(json.encode, rep)
    if ok and type(blob) == 'string' and #blob <= 524288 then pcall(SetResourceKvp, REP_KVP, blob) end
end
local function loadRep()
    local blob = GetResourceKvpString(REP_KVP)
    if type(blob) ~= 'string' or blob == '' then return end
    local ok, data = pcall(json.decode, blob)
    if ok and type(data) == 'table' then rep = data end
end

function Social.GetRep(cid)
    return rep[tostring(cid or '')] or 0
end

function Social.GetTier(cid)
    local r = Social.GetRep(cid)
    for _, t in ipairs(CFG.RepTiers or {}) do
        if r <= (t.max or 0) then return t.label or 'neutral' end
    end
    return 'neutral'
end

-- Move a player's reputation by delta (clamped). No-op while the layer is dark.
function Social.AdjustRep(cid, delta, reason)
    if not enabled() then return end
    cid = tostring(cid or '')
    if cid == '' then return end
    delta = tonumber(delta) or 0
    local lo, hi = CFG.RepMin or -10, CFG.RepMax or 10
    local r = math.max(lo, math.min(hi, (rep[cid] or 0) + delta))
    rep[cid] = r
    saveRep()
    return r
end

-- ── EVENT SEAM ───────────────────────────────────────────────────────────────
-- A "social event" is a thing a player did that NPCs should react to:
--   evt = { kind='rob'|'help'|'bribe'|'threat'|'attack'|'kill'|'tip'|'gift'|...,
--           cid=<victim/actor citizenid>, playerSrc=<server id>, coords={x,y,z},
--           target=<pedKey|nil>, meta={...} }
-- Consumers (witness/gossip/snitch) subscribe via Social.OnEvent. ReportEvent also
-- auto-moves reputation for known action kinds. All consumer calls are isolated.
local consumers = {}

function Social.OnEvent(fn)
    if type(fn) == 'function' then consumers[#consumers + 1] = fn end
end

function Social.ReportEvent(evt)
    if not enabled() or type(evt) ~= 'table' or type(evt.kind) ~= 'string' then return end
    if evt.cid and (CFG.RepDelta or {})[evt.kind] then
        Social.AdjustRep(evt.cid, CFG.RepDelta[evt.kind], 'event:' .. evt.kind)
    end
    for _, fn in ipairs(consumers) do pcall(fn, evt) end
end

-- ── DIALOGUE CONTEXT ─────────────────────────────────────────────────────────
-- Modules add a line to a ped's LLM prompt via RegisterDialogueContext(fn(cid,
-- pedKey)->string|nil). BuildDialogueContext assembles the persona + reputation +
-- those lines into the context string the talk-to-any-ped module prepends to the
-- GLM system prompt, so an NPC's reply reflects who it is AND what it knows about
-- the player.
local dialogueCtx = {}

function Social.RegisterDialogueContext(fn)
    if type(fn) == 'function' then dialogueCtx[#dialogueCtx + 1] = fn end
end

function Social.BuildDialogueContext(cid, pedKey)
    local p = Social.GetPersona(pedKey)
    local a = (CFG.Archetypes or {})[p.archetype] or {}
    local parts = {
        ('You are %s, an ordinary Los Santos local. Personality: %s. Right now your mood is %s.')
            :format(p.name, a.desc or p.archetype, p.mood),
    }
    if cid and enabled() then
        parts[#parts + 1] = ('You regard this person as "%s" (your history with them).'):format(Social.GetTier(cid))
    end
    for _, fn in ipairs(dialogueCtx) do
        local ok, s = pcall(fn, cid, pedKey)
        if ok and type(s) == 'string' and s ~= '' then parts[#parts + 1] = s end
    end
    return table.concat(parts, ' ')
end

-- Expose the persona/rep to other resources cheaply (e.g. a shop reading tier).
exports('GetRep', function(cid) return Social.GetRep(cid) end)
exports('GetTier', function(cid) return Social.GetTier(cid) end)
exports('GetPersona', function(pedKey) return Social.GetPersona(pedKey) end)

-- ── BOOT + PERSIST ───────────────────────────────────────────────────────────
loadRep()
CreateThread(function() while true do Wait(120000); if enabled() then saveRep() end end end)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and enabled() then saveRep() end
end)

print(('[palm6_brain:social] foundation ready (%s) — personas + reputation + event seam + dialogue context.')
    :format(enabled() and 'ENABLED' or 'dark'))
