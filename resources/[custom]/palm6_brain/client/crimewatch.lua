-- ============================================================================
-- palm6_brain/client/crimewatch.lua — detect player crimes against peds.
--
-- Watches the local player. When they damage or kill a nearby non-player ped, we
-- count how many OTHER peds are near enough to have witnessed it, note whether the
-- player is masked, and report it to server/crimewatch.lua → the Social event bus
-- → witness/gossip/snitch. This is what makes the INTEL+ social chain fire from
-- REAL gameplay instead of only the /witnesstest command.
--
-- Cheap by construction: the outer scan is a light O(peds) pass; the (heavier)
-- witness-count sub-scan only runs the moment a player-caused hit is found (rare),
-- and we clear the ped's last-damage marker so one hit reports once.
-- Dark-gated on Config.Social.Enabled — returns immediately when off.
--
-- SCAN COST (this runs on EVERY client, at above-recipe ped density):
--   • ADAPTIVE CADENCE. We scan at SCAN_MS while the player is shooting, in melee,
--     or has just been caught doing something, and at the cheaper SCAN_IDLE_MS the
--     rest of the time (which is nearly all of it). The engine's damage flag
--     persists until we clear it, so the slower cadence never MISSES a crime, it
--     only notices it up to SCAN_IDLE_MS later, well inside the 30s+ snitch
--     cooldown downstream. Set Config.Social.CrimeScanIdleMs = CrimeScanMs to go
--     back to the old fixed 500ms cadence.
--   • ONE POOL WALK PER HIT. countWitnesses used to call GetGamePool('CPed') a
--     second time, allocating the whole pool again; it now reuses the array the
--     outer loop already built. Same list, same frame, identical result.
-- ============================================================================

if not (Config.Social and Config.Social.Enabled) then return end

local SCAN_MS       = tonumber(Config.Social.CrimeScanMs) or 500       -- hot cadence
local SCAN_IDLE_MS  = tonumber(Config.Social.CrimeScanIdleMs) or 1000  -- idle cadence
local HOT_WINDOW_MS = 10000  -- stay on the hot cadence this long after any activity
local NEAR_CRIME   = 45.0    -- only crimes this close to me are "mine" to report
local WITNESS_RANGE = 50.0   -- other peds within this of the victim count as witnesses

if SCAN_IDLE_MS < SCAN_MS then SCAN_IDLE_MS = SCAN_MS end   -- idle is never faster than hot

-- Am I disguised? Component 1 is the ped's mask/head slot; a non-zero drawable
-- means a mask is on (best-effort — flavour only, server treats it as advisory).
local function isMasked(me)
    local ok, v = pcall(GetPedDrawableVariation, me, 1)
    return ok and v ~= nil and v ~= 0
end

-- Count alive non-player peds near `pos` that aren't the victim or me. `pool` is
-- the ped array the caller already walked this pass, so we do NOT allocate the
-- whole pool a second time on every hit.
local function countWitnesses(pool, pos, victim, me)
    local n = 0
    for _, o in ipairs(pool) do
        if o ~= victim and o ~= me and DoesEntityExist(o)
            and not IsPedAPlayer(o) and not IsEntityDead(o)
            and #(GetEntityCoords(o) - pos) < WITNESS_RANGE then
            n = n + 1
        end
    end
    return n
end

CreateThread(function()
    local interval = SCAN_MS   -- start hot; the first pass settles the cadence
    local hotUntil = 0
    while (Config.Social and Config.Social.Enabled) do
        Wait(interval)
        local reported = false
        local me = PlayerPedId()
        if me ~= 0 and DoesEntityExist(me) and not IsEntityDead(me) then
            local mc = GetEntityCoords(me)
            local pool = GetGamePool('CPed')
            for _, ped in ipairs(pool) do
                -- Order preserved on purpose: the damage flag is tested BEFORE the
                -- distance test so that a ped we damaged from beyond NEAR_CRIME
                -- still gets its marker cleared here. Testing distance first would
                -- leave that marker set and fire a stale report the moment the
                -- player walked back within range, which is a behaviour change, not
                -- an optimisation.
                if ped ~= me and DoesEntityExist(ped) and not IsPedAPlayer(ped)
                    and HasEntityBeenDamagedByEntity(ped, me, true) then
                    local pc = GetEntityCoords(ped)
                    if #(pc - mc) < NEAR_CRIME then
                        local kind = IsEntityDead(ped) and 'kill' or 'attack'
                        local witnesses = countWitnesses(pool, pc, ped, me)
                        TriggerServerEvent('palm6_brain:crime:report', kind,
                            { x = pc.x, y = pc.y, z = pc.z }, witnesses, isMasked(me))
                        reported = true
                    end
                    ClearEntityLastDamageEntity(ped)   -- one hit -> one report
                end
            end
            -- Two cheap per-PASS natives (not per-ped) decide the next cadence.
            if reported or IsPedShooting(me) or IsPedInMeleeCombat(me) then
                hotUntil = GetGameTimer() + HOT_WINDOW_MS
            end
        end
        interval = (GetGameTimer() < hotUntil) and SCAN_MS or SCAN_IDLE_MS
    end
end)
