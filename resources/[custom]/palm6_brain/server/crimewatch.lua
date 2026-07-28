-- ============================================================================
-- palm6_brain/server/crimewatch.lua — player-crime → Social event bridge.
--
-- The AUTO-TRIGGER that makes the INTEL+ social chain fire from REAL gameplay:
-- when a player attacks/kills a ped near others, client/crimewatch.lua detects it
-- and reports here; we validate + fire it into the Social event bus, where
-- witness.lua → gossip.lua / snitch.lua pick it up (and reputation moves). Without
-- this, the witness/gossip/snitch modules only fire from the /witnesstest command.
--
-- Trust model: the witness count and disguise flag are FLAVOUR (a spoof at worst
-- fabricates a witness event with no money/security impact), and the report is
-- RATE-LIMITED per player so it can't be used to spam the witness→snitch→dispatch
-- chain. The COORDS are NOT flavour: they become a routed 911 blip on every on-duty
-- officer via snitch.lua → Bridge.AlertPolice, so a client that lies about them
-- drops police anywhere on the map. We therefore re-derive the reporter's position
-- SERVER-side and REJECT a claim that is too far from it. We deliberately do NOT
-- substitute the server position for the claim: the claim is the VICTIM ped's
-- position (legitimately up to NEAR_CRIME away from the reporter), so rewriting it
-- would move real blips. Reject, never rewrite. Dark-gated on Config.Social.Enabled.
-- ============================================================================

local CFG = Config.Social or {}
local function enabled() return (Config.Social or {}).Enabled == true end

local VALID = { attack = true, kill = true, rob = true, deal = true }
local lastReport = {}   -- src -> epoch seconds (per-player rate limit)
local MIN_GAP = 2       -- seconds between accepted reports from one player
-- Max distance between the claimed crime position and the reporter's SERVER-derived
-- position. 50.0 vs the client's own 45.0 NEAR_CRIME bound (client/crimewatch.lua).
-- The 5m of headroom is slack for SERVER-POSITION LAG, not for distance error: the
-- client measured the distance with its own current position and passed the check,
-- and the server then re-reads that player's ped a round trip later. Near-field
-- reports (the common case) have ~48m of headroom and never come close. A report at
-- the far edge of the 45m bound from a player moving fast CAN be dropped, which is
-- why rejections are COUNTED below instead of vanishing.
local MAX_CLAIM_M = tonumber(CFG.CrimeClaimMaxM) or 50.0

-- ── METER ────────────────────────────────────────────────────────────────────
-- "Ship the meter before shipped": the position gate is a SILENT drop path. If it
-- ever misfires - a bad MAX_CLAIM_M, a OneSync position read going stale, a lag
-- spike class of player - the symptom is "the whole witness/gossip/snitch chain
-- quietly stopped firing" with nothing in the log, because the Debug print below is
-- off in production (shared/config.lua Debug = false). These counters are ALWAYS on
-- and print in /brainstatus, so the drop is visible without a debug restart.
local stats = { accepted = 0, rejectedFar = 0, rejectedNoPed = 0, rateLimited = 0 }

local function citizenId(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and p and p.PlayerData then return p.PlayerData.citizenid end
    return 'src:' .. tostring(src)
end

-- True when `coords` is close enough to where the SERVER says `src` is standing.
-- OneSync makes GetEntityCoords(GetPlayerPed(src)) authoritative server-side (the
-- same read server/netped.lua already depends on). Fails CLOSED: if we cannot
-- resolve the reporter's ped at all we refuse the claim rather than trust it - a
-- player with no live ped cannot have just knifed a pedestrian.
-- Returns true on pass, or false + a short reason so the caller can meter WHICH
-- failure it was ('no-ped' is a different operational story from 'too-far').
local function claimNearReporter(src, coords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'no-ped' end
    local ok, pc = pcall(GetEntityCoords, ped)
    if not ok or not pc then return false, 'no-ped' end
    local dx, dy, dz = (coords.x + 0.0) - pc.x, (coords.y + 0.0) - pc.y, (coords.z + 0.0) - pc.z
    if (dx * dx + dy * dy + dz * dz) <= (MAX_CLAIM_M * MAX_CLAIM_M) then return true end
    return false, 'too-far'
end

-- GetCrimeWatchSummary() -> short meter string, printed by /brainstatus. The whole
-- point is that `rejected` is never zero-by-silence: if it climbs while `accepted`
-- sits still, the position gate is eating real reports.
exports('GetCrimeWatchSummary', function()
    return ('%d accepted / %d rejected far / %d rejected no-ped / %d rate-limited%s')
        :format(stats.accepted, stats.rejectedFar, stats.rejectedNoPed, stats.rateLimited,
            enabled() and '' or ' [dark]')
end)

RegisterNetEvent('palm6_brain:crime:report', function(kind, coords, nearbyPeds, disguised)
    if not enabled() then return end
    local src = source
    if type(kind) ~= 'string' or not VALID[kind] then return end
    if type(coords) ~= 'table' then return end
    -- Numbers, not just truthy: the old `coords.x and ...` check let a table or a
    -- boolean through to the `+ 0.0` below, which errors inside the net handler.
    -- `n ~= n` rejects NaN, which survives every ordinary comparison.
    local cx, cy, cz = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not (cx and cy and cz) then return end
    if cx ~= cx or cy ~= cy or cz ~= cz then return end

    local now = os.time()
    if lastReport[src] and (now - lastReport[src]) < MIN_GAP then
        stats.rateLimited = stats.rateLimited + 1
        return
    end
    lastReport[src] = now   -- a rejected claim still burns the budget, on purpose

    -- SERVER-AUTHORITATIVE POSITION GATE: reject a crime claimed further than
    -- MAX_CLAIM_M from where the server says this player is. Never rewrite.
    local near, why = claimNearReporter(src, { x = cx, y = cy, z = cz })
    if not near then
        if why == 'no-ped' then
            stats.rejectedNoPed = stats.rejectedNoPed + 1
        else
            stats.rejectedFar = stats.rejectedFar + 1
        end
        if Config.Debug then
            print(('[palm6_brain:crimewatch] rejected %s report from src %s - %s')
                :format(kind, tostring(src), tostring(why)))
        end
        return
    end

    if not (Social and Social.ReportEvent) then return end
    stats.accepted = stats.accepted + 1
    Social.ReportEvent({
        kind      = kind,
        cid       = citizenId(src),
        playerSrc = src,
        coords    = { x = cx + 0.0, y = cy + 0.0, z = cz + 0.0 },
        meta      = { nearbyPeds = math.max(0, math.floor(tonumber(nearbyPeds) or 0)),
                      disguised = disguised == true, via = 'crimewatch' },
    })
end)

AddEventHandler('playerDropped', function()
    lastReport[source] = nil
end)
