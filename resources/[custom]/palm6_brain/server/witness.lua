-- ============================================================================
-- palm6_brain/server/witness.lua — THE WITNESS SYSTEM ("INTEL+").
--
-- INTEL's witness mechanic, LLM-fused: a ped that SEES a player commit a crime
-- REMEMBERS it, and that memory (a) colours what the ped says when you later talk
-- to it (via Social's dialogue-context seam → GLM prompt) and (b) becomes the
-- upstream signal the gossip/snitch modules consume. This file is ONE link in the
-- chain — it turns a raw PLAYER-crime social event into a bounded, decaying
-- "somebody saw that" memory and re-fires it as a derived `crime_witnessed` event.
--
-- The whole thing hangs off the shared `Social` foundation (server/social.lua,
-- loaded BEFORE us). We never touch another module's file — we only use the seams:
--   • Social.OnEvent(fn)               — subscribe to every social event; we filter
--       to PLAYER-crime kinds (rob/attack/kill/deal) that carry a witness count.
--   • Social.ReportEvent(evt)          — re-fire a derived `crime_witnessed` event
--       for gossip/snitch to pick up (only when a ped actually saw it).
--   • Social.RegisterDialogueContext  — inject a short "you saw this person do X"
--       line into a ped's LLM dialogue prompt when the perp has a fresh memory.
--
-- DARK BY DEFAULT (Config.Social.Enabled): with the layer dark, OnEvent never
-- fires (ReportEvent is gated in social.lua), the dialogue hook returns nil, and
-- the test command refuses — so this is prod-inert until the social gate flips.
--
-- Memory discipline (David's "never grow unbounded" rule): the store is a ring of
-- the last ~MAX_MEMORIES crimes, and every touch lazily prunes anything older than
-- Config.Social.WitnessMemorySec. It can never leak.
-- ============================================================================

local CFG = (Config and Config.Social) or {}
local function enabled() return CFG.Enabled == true end

-- Crime kinds we treat as witnessable. A social event of any other kind (help,
-- bribe, gift…) is ignored here — those aren't crimes and have no witnesses.
local CRIME_KINDS = { rob = true, attack = true, deal = true, kill = true }

-- Tunables. TTL comes from config; the cap is local (a memory-safety backstop, not
-- a gameplay knob). Keep the store small — witnesses are recency-driven anyway.
local MAX_MEMORIES  = 40
local MEMORY_TTL    = tonumber(CFG.WitnessMemorySec) or 86400

-- ── THE STORE ────────────────────────────────────────────────────────────────
-- A flat list of witnessed-crime memories, newest last. Shape of each entry:
--   { crimeKind=<string>, cid=<string>, coords={x,y,z}, at=<os.time()>,
--     witnesses=<int>, disguised=<bool> }
-- Bounded by MAX_MEMORIES (oldest dropped) and by MEMORY_TTL (pruned lazily).
local memories = {}

-- Drop anything past its TTL, then trim to the cap (oldest first). Called on every
-- write and read, so the store self-heals without a background thread.
local function prune()
    local now = os.time()
    local kept = {}
    for i = 1, #memories do
        local m = memories[i]
        if m and (now - (m.at or 0)) <= MEMORY_TTL then
            kept[#kept + 1] = m
        end
    end
    -- Hard cap: if still over, drop the oldest (front of the list).
    while #kept > MAX_MEMORIES do table.remove(kept, 1) end
    memories = kept
end

-- ── EVENT SEAM: consume player-crime, produce crime_witnessed ─────────────────
-- Registered with Social.OnEvent. Runs SYNCHRONOUSLY inside ReportEvent's consumer
-- loop (which is pcall-isolated on the Social side), so we do NO yields here and
-- stay defensive about every field the client detector supplies.
local function onSocialEvent(evt)
    if not enabled() then return end
    if type(evt) ~= 'table' or type(evt.kind) ~= 'string' then return end
    if not CRIME_KINDS[evt.kind] then return end
    -- Never re-consume our own derived event (avoids a feedback loop).
    if evt.kind == 'crime_witnessed' then return end

    local meta = type(evt.meta) == 'table' and evt.meta or {}
    local witnesses = math.floor(tonumber(meta.nearbyPeds) or 0)
    if witnesses <= 0 then return end   -- nobody saw it = no witness memory.

    local cid = tostring(evt.cid or '')
    if cid == '' then return end

    local coords = evt.coords or {}
    local disguised = meta.disguised == true

    -- Record the bounded memory.
    memories[#memories + 1] = {
        crimeKind = evt.kind,
        cid       = cid,
        coords    = { x = coords.x or 0.0, y = coords.y or 0.0, z = coords.z or 0.0 },
        at        = os.time(),
        witnesses = witnesses,
        disguised = disguised,
    }
    prune()

    -- Fan the DERIVED event to gossip/snitch. ReportEvent is itself gated on the
    -- social layer being enabled, so this is a no-op while dark.
    if Social and Social.ReportEvent then
        Social.ReportEvent({
            kind      = 'crime_witnessed',
            crimeKind = evt.kind,
            cid       = cid,
            coords    = coords,
            witnesses = witnesses,
            disguised = disguised,
        })
    end
end

-- ── DIALOGUE CONTEXT: what the ped "knows" about this player ──────────────────
-- We only have (cid, pedKey) here — not the ped's live coords — so we key off
-- RECENCY: if the player being spoken to has a fresh unresolved witnessed crime,
-- any nearby ped plausibly caught wind of it. Returns a single short line, or nil.
local function dialogueContext(cid, _pedKey)
    if not enabled() or not cid then return nil end
    prune()
    cid = tostring(cid)
    -- Newest-first scan for the most recent memory belonging to this player.
    for i = #memories, 1, -1 do
        local m = memories[i]
        if m and m.cid == cid then
            if m.disguised then
                return 'You have a nagging feeling this person was involved in something bad nearby recently, but their face was hidden so you cannot be sure.'
            end
            return ('You recently saw this person commit a %s nearby and it unsettled you.')
                :format(m.crimeKind or 'crime')
        end
    end
    return nil
end

-- ── SUMMARY EXPORT (the meter) ────────────────────────────────────────────────
-- A short human string of recent witnessed crimes, for a status/debug meter.
-- Safe to call while dark (returns a plain "disabled" note).
local function witnessSummary()
    if not enabled() then return 'witness: social layer dark' end
    prune()
    local n = #memories
    if n == 0 then return 'witness: no crimes on record' end
    local last = memories[n]
    local mask = last.disguised and ' (masked)' or ''
    return ('witness: %d on record | latest %s x%d witnesses%s')
        :format(n, last.crimeKind or '?', last.witnesses or 0, mask)
end

-- ── WIRE-UP ───────────────────────────────────────────────────────────────────
-- Guard the whole registration on the Social foundation being present (load order
-- is fxmanifest-enforced: social.lua before witness.lua, but stay defensive).
if Social and Social.OnEvent then
    Social.OnEvent(onSocialEvent)
    if Social.RegisterDialogueContext then
        Social.RegisterDialogueContext(dialogueContext)
    end
end

exports('GetWitnessSummary', witnessSummary)

-- ── DEV TEST COMMAND ──────────────────────────────────────────────────────────
-- /witnesstest <rob|attack|kill>  — fires a FAKE player-crime social event at the
-- invoking player's server-side position with 3 nearby witnesses, so the full
-- witness → gossip → snitch chain is exercisable solo. ACE-restricted; only lives
-- while the social layer is enabled. Uses server-side GetEntityCoords, which is
-- valid under OneSync.
RegisterCommand('witnesstest', function(src, args)
    if src == 0 then return end   -- console has no ped/position to originate from.
    if not enabled() then
        print('[palm6_brain:witness] /witnesstest ignored — Config.Social.Enabled is false (dark).')
        return
    end

    local kind = tostring(args and args[1] or 'rob'):lower()
    if not CRIME_KINDS[kind] then kind = 'rob' end

    -- Server-side ped position (OneSync). Defensive: bail if we can't resolve it.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        print(('[palm6_brain:witness] /witnesstest: no ped for src %s.'):format(tostring(src)))
        return
    end
    local pos = GetEntityCoords(ped)
    if not pos then return end

    -- Player's citizenid via QBox. Fall back to a synthetic id so the test still
    -- flows if the framework isn't resolvable in this context.
    local cid = ('src:%s'):format(tostring(src))
    local ok, QBX = pcall(function() return exports['qbx_core'] end)
    if ok and QBX then
        local player = QBX:GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.citizenid then
            cid = player.PlayerData.citizenid
        end
    end

    if Social and Social.ReportEvent then
        Social.ReportEvent({
            kind      = kind,
            cid       = cid,
            playerSrc = src,
            coords    = { x = pos.x, y = pos.y, z = pos.z },
            meta      = { nearbyPeds = 3, disguised = false },
        })
        print(('[palm6_brain:witness] /witnesstest fired a fake %s by %s (3 witnesses) at %.1f,%.1f,%.1f — %s')
            :format(kind, cid, pos.x, pos.y, pos.z, witnessSummary()))
    end
end, true)   -- true = ACE-restricted (needs command.witnesstest ace).

print(('[palm6_brain:witness] witness system ready (%s) — bounded memory + crime_witnessed seam + dialogue context.')
    :format(enabled() and 'ENABLED' or 'dark'))
