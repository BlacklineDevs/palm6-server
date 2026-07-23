-- ============================================================================
-- palm6_brain/server/gossip.lua — GOSSIP PROPAGATION (social layer, "INTEL+").
--
-- Witnessed crime doesn't stay put: it SPREADS ped-to-ped, and every hop it
-- loses fidelity. High fidelity = the rumor still names the crime and is sure of
-- itself; low fidelity = a vague "heard someone did something shady round here",
-- until it fades below GossipMinFidelity and dies. This is INTEL's gossip idea,
-- but the rendered phrase is voice-able by GLM later (the dialogue-context line
-- becomes part of the ped's LLM prompt, not a canned bark).
--
-- ABSTRACT PROPAGATION MODEL (important): we do NOT move data between real ped
-- entities across the map. We model the RUMOR ITSELF — its reach + fidelity over
-- time — as a small bounded store of gossip items that decay on a slow tick. A
-- ped you talk to near the rumor's origin "has heard it" because we surface the
-- freshest relevant item into its dialogue context. Cheap, bounded, deterministic.
--
-- HOW IT HANGS OFF THE FOUNDATION (server/social.lua):
--   • Social.OnEvent(fn) — we subscribe and seed a gossip item whenever the
--     witness module emits a DERIVED event: kind == 'crime_witnessed'.
--   • Social.RegisterDialogueContext(fn(cid,pedKey)) — we inject one line
--     ("Word going around: ...") when a fresh, still-credible rumor exists.
--   • exports('GetGossipSummary') — a one-line meter of live rumors + fidelity.
--
-- DARK BY DEFAULT (Config.Social.Enabled): while the layer is off we register
-- NOTHING that mutates state — no seeding, no tick, no test command. Every
-- foundation call is guarded (Social present) and the whole file no-ops if the
-- seam isn't there yet. Already wired in fxmanifest AFTER social.lua.
-- ============================================================================

local CFG = (Config and Config.Social) or {}
local function enabled() return ((Config or {}).Social or {}).Enabled == true end

-- Tunables (with defensive fallbacks to the documented defaults).
local RANGE        = tonumber(CFG.GossipRange) or 15.0          -- metres a rumor is "near" a ped/area
local DECAY        = tonumber(CFG.GossipDecayPerHop) or 0.2     -- fidelity lost per spread hop (0..1)
local MIN_FIDELITY = tonumber(CFG.GossipMinFidelity) or 0.2     -- below this a rumor is dead
local MAX_ITEMS    = 30                                          -- hard cap on active rumors (NEVER unbounded)
local MAX_AGE_SEC  = 1800                                        -- rumors older than this are pruned regardless
local SPREAD_MS    = 20000                                       -- one "hop" every ~20s

-- ── STORE ────────────────────────────────────────────────────────────────────
-- A gossip item is the rumor's current state, NOT a ped:
--   { cid, crimeKind, coords={x,y,z}, fidelity, at=<os.time seed>, hops }
-- fidelity starts at 1.0 (an eyewitness), degrades toward 0 as it spreads.
local gossip = {}   -- array of items, freshest-first is NOT guaranteed; we scan.

-- ── helpers ──────────────────────────────────────────────────────────────────
local function dist2(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return math.huge end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

-- Render a rumor to a phrase AT ITS CURRENT FIDELITY — this is where detail
-- degrades. High = names the crime + confident; mid = hedged; low = vague.
local function renderPhrase(item)
    local f = item.fidelity or 0
    local crime = tostring(item.crimeKind or 'something'):gsub('_', ' ')
    if f >= 0.75 then
        return ('someone pulled a %s right around here — clear as day'):format(crime)
    elseif f >= 0.5 then
        return ('word is there was a %s nearby, though nobody\'s totally sure'):format(crime)
    elseif f >= 0.35 then
        return ('heard there was some kind of trouble around here lately')
    else
        return ('somebody did something shady round here, is all I know')
    end
end

-- Bound the store: drop the LOWEST-fidelity item when we exceed the cap.
local function enforceCap()
    while #gossip > MAX_ITEMS do
        local worstIdx, worstF = 1, math.huge
        for i, it in ipairs(gossip) do
            if (it.fidelity or 0) < worstF then worstIdx, worstF = i, (it.fidelity or 0) end
        end
        table.remove(gossip, worstIdx)
    end
end

-- Seed a fresh rumor at full fidelity from a witnessed crime.
local function seed(cid, crimeKind, coords)
    if not enabled() then return end
    gossip[#gossip + 1] = {
        cid       = cid and tostring(cid) or nil,
        crimeKind = type(crimeKind) == 'string' and crimeKind or 'crime',
        coords    = type(coords) == 'table' and { x = coords.x, y = coords.y, z = coords.z } or nil,
        fidelity  = 1.0,
        at        = os.time(),
        hops      = 0,
    }
    enforceCap()
end

-- ── SPREAD MODEL ─────────────────────────────────────────────────────────────
-- Each tick every active rumor spreads one hop: hops+1, fidelity *= (1-DECAY).
-- When fidelity drops below MIN_FIDELITY (or the item is too old) it dies. We
-- rebuild the array in place so dead items are pruned every pass.
local function spreadOnce()
    if not enabled() or #gossip == 0 then return end
    local now, kept = os.time(), {}
    for _, it in ipairs(gossip) do
        it.hops = (it.hops or 0) + 1
        it.fidelity = (it.fidelity or 0) * (1.0 - DECAY)
        local tooOld = (now - (it.at or now)) > MAX_AGE_SEC
        if it.fidelity >= MIN_FIDELITY and not tooOld then
            kept[#kept + 1] = it
        end
    end
    gossip = kept
end

-- Freshest, highest-fidelity rumor relevant to a location (or any, if no coords).
local function freshestRelevant(coords)
    local best, bestScore
    local r2 = RANGE * RANGE
    for _, it in ipairs(gossip) do
        local near = (not coords) or (not it.coords) or (dist2(coords, it.coords) <= r2)
        if near then
            -- prefer high fidelity, break ties by recency.
            local score = (it.fidelity or 0) * 1000 + (it.at or 0) / 1e6
            if not bestScore or score > bestScore then best, bestScore = it, score end
        end
    end
    return best
end

-- ── WIRE INTO THE SOCIAL FOUNDATION ──────────────────────────────────────────
if Social and Social.OnEvent then
    -- 1) Subscribe: the witness module emits a DERIVED 'crime_witnessed' event.
    --    { crimeKind, cid, coords, witnesses, disguised } → seed a rumor. No yields.
    Social.OnEvent(function(evt)
        if not enabled() or type(evt) ~= 'table' then return end
        if evt.kind == 'crime_witnessed' then
            seed(evt.cid, evt.crimeKind, evt.coords)
        end
    end)

    -- 2) Dialogue context: a ped near a live rumor "has heard it". We key off the
    --    freshest credible item and render it at its CURRENT fidelity. nil = silent.
    if Social.RegisterDialogueContext then
        Social.RegisterDialogueContext(function(_cid, _pedKey)
            if not enabled() then return nil end
            local it = freshestRelevant(nil)   -- pedKey has no coords here; area-agnostic
            if not it then return nil end
            return ('Word going around the block: %s.'):format(renderPhrase(it))
        end)
    end
end

-- ── EXPORT: a one-line meter of live rumors + fidelity (for a HUD/debug read) ─
exports('GetGossipSummary', function()
    if #gossip == 0 then return 'no rumors circulating' end
    local parts = {}
    for _, it in ipairs(gossip) do
        parts[#parts + 1] = ('%s@%d%%'):format(tostring(it.crimeKind or '?'), math.floor((it.fidelity or 0) * 100 + 0.5))
    end
    return ('%d rumor(s): %s'):format(#gossip, table.concat(parts, ', '))
end)

-- ── SPREAD TICK ──────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(SPREAD_MS)
        if enabled() then
            local ok = pcall(spreadOnce)
            if not ok then gossip = gossip or {} end
        end
    end
end)

-- ── DEV COMMAND — /gossiptest (ACE: command.gossiptest) ──────────────────────
-- Seed a fake high-fidelity rumor so you can watch it decay on the tick and see
-- it surface in a ped's dialogue context. Only registered while the layer is on.
if enabled() then
    RegisterCommand('gossiptest', function(src, _args, _raw)
        -- ACE-gate: console (src 0) always allowed, players need the ace.
        if src > 0 and not IsPlayerAceAllowed(tostring(src), 'command.gossiptest') then return end
        seed('TESTCID', 'armed_robbery', { x = 195.0, y = -934.0, z = 30.7 })
        local msg = '[palm6_brain:gossip] seeded test rumor (armed_robbery @ Legion Sq, fidelity 100%). Watch it decay ~20s/hop; ' .. exports[GetCurrentResourceName()]:GetGossipSummary()
        if src == 0 then print(msg) else TriggerClientEvent('chat:addMessage', src, { args = { 'gossip', msg } }) end
    end, false)
end

print(('[palm6_brain:gossip] ready (%s) — rumor propagation: seed on crime_witnessed, decay %d%%/hop, dies < %d%% fidelity, cap %d.')
    :format(enabled() and 'ENABLED' or 'dark', math.floor(DECAY * 100), math.floor(MIN_FIDELITY * 100), MAX_ITEMS))
