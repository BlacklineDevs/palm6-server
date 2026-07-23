-- ============================================================================
-- palm6_brain/server/alibi.lua — ALIBI (the SOCIAL LAYER's counter-play).
--
-- A static NPC agrees to VOUCH that a player was with it during a window of time
-- — the deliberate counter to witness/gossip/snitch. Where a witnessed crime
-- pushes a report toward police, a live alibi is the thing that report logic can
-- later CONSULT to suppress itself ("Rosa will swear he was buying coffee").
--
-- Built on the shared `Social` foundation (server/social.lua, loaded FIRST in the
-- fxmanifest): reputation gates whether the NPC AGREES (an NPC won't lie for a
-- menace it distrusts), and a dialogue-context hook makes the ped OWN the cover
-- story in its own LLM-voiced line. This module never wires suppression itself —
-- it only records alibis and EXPOSES HasAlibi for snitch/witness to read later.
--
-- Server-authoritative, bounded (hard cap + TTL prune), dark by default
-- (Config.Social.Enabled). No yields in the hot paths; every store op is O(n) over
-- a small, self-pruning list.
-- ============================================================================

local CFG = Config.Social or {}
local function enabled() return (Config.Social or {}).Enabled == true end

-- Tuning (self-contained; the shared config has no alibi block yet).
local MAX_ALIBIS   = 200      -- hard ceiling on live alibis server-wide (eviction guard).
local MIN_DURATION = 60       -- clamp floor: an alibi covers at least 1 minute…
local MAX_DURATION = 3600     -- …and at most 1 hour (an NPC won't vouch forever).
-- Tiers at/below which an NPC REFUSES to vouch — it won't lie for someone it
-- doesn't trust. Everything from 'neutral' up is willing to cover for you.
local REFUSE_TIERS = { hated = true, feared = true, distrusted = true }

-- ── STORE ────────────────────────────────────────────────────────────────────
-- alibis = array of { cid=<string>, pedKey=<string>, coords={x,y,z}|nil,
--                     from=<os.time>, until_=<os.time+duration> }
-- An alibi is a bounded, TTL'd record: it self-expires at `until_` and is pruned
-- lazily on every read/write, so a stale alibi can never linger past its window.
local alibis = {}

-- Drop every expired record in place (O(n), no yields). Called before any op.
local function prune(now)
    now = now or os.time()
    local kept = {}
    for i = 1, #alibis do
        local a = alibis[i]
        if a.until_ > now then kept[#kept + 1] = a end
    end
    alibis = kept
end

-- ── ESTABLISH ────────────────────────────────────────────────────────────────
-- Record an alibi if the NPC agrees. Returns true (vouched) / false (refused or
-- disabled). Whether it agrees depends on the player's reputation tier.
local function establish(cid, pedKey, coords, durationSec)
    if not enabled() then return false end
    cid = tostring(cid or '')
    pedKey = tostring(pedKey or '')
    if cid == '' or pedKey == '' then return false end

    -- Reputation gate: an NPC won't cover for a distrusted/feared/hated player.
    if Social and Social.GetTier and REFUSE_TIERS[Social.GetTier(cid)] then
        return false
    end

    local now = os.time()
    prune(now)

    durationSec = math.max(MIN_DURATION, math.min(MAX_DURATION, tonumber(durationSec) or MIN_DURATION))

    -- If a live alibi from THIS ped for THIS player already exists, extend it
    -- rather than stacking duplicates.
    for i = 1, #alibis do
        local a = alibis[i]
        if a.cid == cid and a.pedKey == pedKey then
            a.until_ = now + durationSec
            a.coords = coords or a.coords
            return true
        end
    end

    -- Cap guard: evict the soonest-to-expire record if we're full.
    if #alibis >= MAX_ALIBIS then
        local minIdx, minUntil = 1, math.huge
        for i = 1, #alibis do
            if alibis[i].until_ < minUntil then minIdx, minUntil = i, alibis[i].until_ end
        end
        table.remove(alibis, minIdx)
    end

    alibis[#alibis + 1] = { cid = cid, pedKey = pedKey, coords = coords, from = now, until_ = now + durationSec }
    return true
end

-- ── EXPORTS ──────────────────────────────────────────────────────────────────
-- EstablishAlibi(cid, pedKey, coords, durationSec) -> bool. The talk module calls
-- this when a player asks a nearby static NPC to cover for them.
exports('EstablishAlibi', function(cid, pedKey, coords, durationSec)
    return establish(cid, pedKey, coords, durationSec)
end)

-- HasAlibi(cid, atTime) -> bool. True if the player has a live alibi covering
-- `atTime` (default now). Lazy-pruned on read. This is the seam snitch/witness
-- logic can consult later to suppress a report — NOT wired here, just exposed.
exports('HasAlibi', function(cid, atTime)
    cid = tostring(cid or '')
    if cid == '' then return false end
    local now = os.time()
    prune(now)
    atTime = tonumber(atTime) or now
    for i = 1, #alibis do
        local a = alibis[i]
        if a.cid == cid and atTime >= a.from and atTime <= a.until_ then return true end
    end
    return false
end)

-- GetAlibiSummary() -> short meter string (David's "ship the meter" rule).
exports('GetAlibiSummary', function()
    prune()
    local players = {}
    for i = 1, #alibis do players[alibis[i].cid] = true end
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    return ('%d live alibi(s) covering %d player(s)%s')
        :format(#alibis, n, enabled() and '' or ' [dark]')
end)

-- ── DIALOGUE CONTEXT ─────────────────────────────────────────────────────────
-- If the ped being talked to has a LIVE alibi vouching for this player, make it
-- own the cover story in its own reply. nil otherwise (no line injected).
if Social and Social.RegisterDialogueContext then
    Social.RegisterDialogueContext(function(cid, pedKey)
        if not enabled() or not cid then return nil end
        cid, pedKey = tostring(cid), tostring(pedKey or '')
        local now = os.time()
        for i = 1, #alibis do
            local a = alibis[i]
            if a.cid == cid and a.pedKey == pedKey and a.until_ > now then
                return "You agreed to say this person was with you earlier — you'll cover for them if anyone asks."
            end
        end
        return nil
    end)
end

-- ── CLIENT REQUEST SEAM ──────────────────────────────────────────────────────
-- A UI/keybind fires this so a player can ask the nearby static NPC to vouch.
-- Source is validated and the citizenid resolved server-side (never trusted from
-- the client). Everything is pcall-isolated so a bad payload can't crash the net.
RegisterNetEvent('palm6_brain:alibi:request', function(pedKey, coords, durationSec)
    if not enabled() then return end
    local src = source
    if not src or src <= 0 then return end
    local ok, cid = pcall(function()
        local p = exports.qbx_core:GetPlayer(src)
        return p and p.PlayerData and p.PlayerData.citizenid
    end)
    if not ok or not cid then return end
    local agreed = establish(cid, pedKey, coords, durationSec)
    -- Tell the requesting client whether the NPC agreed (UI feedback).
    TriggerClientEvent('palm6_brain:alibi:result', src, agreed, tostring(pedKey or ''))
end)

-- ── DEV COMMAND (ACE-gated) ──────────────────────────────────────────────────
-- /alibitest — establish a 5-min alibi for the caller near a synthetic ped, to
-- exercise the store + HasAlibi + dialogue hook in-game. Only when Enabled.
if enabled() then
    RegisterCommand('alibitest', function(src)
        if not src or src <= 0 then return end
        local ok, cid = pcall(function()
            local p = exports.qbx_core:GetPlayer(src)
            return p and p.PlayerData and p.PlayerData.citizenid
        end)
        if not ok or not cid then return end
        local pedKey = 'alibitest_ped'
        local agreed = establish(cid, pedKey, nil, 300)
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[alibi]', ('%s — %s. %s'):format(
                agreed and 'NPC AGREED (5-min alibi set)' or 'NPC REFUSED (tier too low)',
                exports[GetCurrentResourceName()]:HasAlibi(cid) and 'HasAlibi=true' or 'HasAlibi=false',
                exports[GetCurrentResourceName()]:GetAlibiSummary()) },
        })
    end, true)   -- restricted = true (ACE 'command.alibitest')
end

print(('[palm6_brain:alibi] ready (%s) — NPC vouch store, rep-gated, TTL-pruned.')
    :format(enabled() and 'ENABLED' or 'dark'))
