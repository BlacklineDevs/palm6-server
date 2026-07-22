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

local lastSay = {}  -- src -> epoch seconds (light anti-spam; eventguard is the real gate)

RegisterNetEvent('palm6_brain:say', function(npcId, text)
    if not (Config.Enabled and Config.NamedEnabled) then return end
    local src = source
    local now = os.time()
    if lastSay[src] and (now - lastSay[src]) < 1 then return end
    lastSay[src] = now

    local npc = npcById(tostring(npcId or ''))
    if not npc then return end
    text = tostring(text or ''):sub(1, 200)   -- clamp; used as LLM input later

    -- ── STUB BRAIN ──────────────────────────────────────────────────────────
    -- TODO Phase 1-real: PerformHttpRequest to the cortex sidecar with the NPC's
    -- role/personality + this utterance + the NPC's memory row, and relay the
    -- reply. For now: a canned line so the whole loop is testable.
    local lines = npc.lines or { '...' }
    local reply = lines[math.random(#lines)]
    -- ────────────────────────────────────────────────────────────────────────

    TriggerClientEvent('palm6_brain:reply', src, npc.id, reply)
end)

AddEventHandler('playerDropped', function()
    lastSay[source] = nil
end)
