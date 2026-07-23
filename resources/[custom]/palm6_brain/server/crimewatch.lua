-- ============================================================================
-- palm6_brain/server/crimewatch.lua — player-crime → Social event bridge.
--
-- The AUTO-TRIGGER that makes the INTEL+ social chain fire from REAL gameplay:
-- when a player attacks/kills a ped near others, client/crimewatch.lua detects it
-- and reports here; we validate + fire it into the Social event bus, where
-- witness.lua → gossip.lua / snitch.lua pick it up (and reputation moves). Without
-- this, the witness/gossip/snitch modules only fire from the /witnesstest command.
--
-- Trust model: the client-supplied coords / witness count / disguise flag are
-- FLAVOUR (like the world-state snapshot the dialogue uses) — a spoof at worst
-- fabricates a witness event with no money/security impact — so they're accepted
-- as-is, but the report is RATE-LIMITED per player so it can't be used to spam the
-- witness→snitch→dispatch chain. Dark-gated on Config.Social.Enabled.
-- ============================================================================

local function enabled() return (Config.Social or {}).Enabled == true end

local VALID = { attack = true, kill = true, rob = true, deal = true }
local lastReport = {}   -- src -> epoch seconds (per-player rate limit)
local MIN_GAP = 2       -- seconds between accepted reports from one player

local function citizenId(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and p and p.PlayerData then return p.PlayerData.citizenid end
    return 'src:' .. tostring(src)
end

RegisterNetEvent('palm6_brain:crime:report', function(kind, coords, nearbyPeds, disguised)
    if not enabled() then return end
    local src = source
    if type(kind) ~= 'string' or not VALID[kind] then return end
    if type(coords) ~= 'table' or not (coords.x and coords.y and coords.z) then return end

    local now = os.time()
    if lastReport[src] and (now - lastReport[src]) < MIN_GAP then return end   -- rate limit
    lastReport[src] = now

    if not (Social and Social.ReportEvent) then return end
    Social.ReportEvent({
        kind      = kind,
        cid       = citizenId(src),
        playerSrc = src,
        coords    = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 },
        meta      = { nearbyPeds = math.max(0, math.floor(tonumber(nearbyPeds) or 0)),
                      disguised = disguised == true, via = 'crimewatch' },
    })
end)

AddEventHandler('playerDropped', function()
    lastReport[source] = nil
end)
