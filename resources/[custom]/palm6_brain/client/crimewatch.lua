-- ============================================================================
-- palm6_brain/client/crimewatch.lua — detect player crimes against peds.
--
-- Watches the local player. When they damage or kill a nearby non-player ped, we
-- count how many OTHER peds are near enough to have witnessed it, note whether the
-- player is masked, and report it to server/crimewatch.lua → the Social event bus
-- → witness/gossip/snitch. This is what makes the INTEL+ social chain fire from
-- REAL gameplay instead of only the /witnesstest command.
--
-- Cheap by construction: the outer scan is a light O(peds) pass every 500ms; the
-- (heavier) witness-count sub-scan only runs the moment a player-caused hit is
-- found (rare), and we clear the ped's last-damage marker so one hit reports once.
-- Dark-gated on Config.Social.Enabled — returns immediately when off.
-- ============================================================================

if not (Config.Social and Config.Social.Enabled) then return end

local SCAN_MS      = 500
local NEAR_CRIME   = 45.0    -- only crimes this close to me are "mine" to report
local WITNESS_RANGE = 50.0   -- other peds within this of the victim count as witnesses

-- Am I disguised? Component 1 is the ped's mask/head slot; a non-zero drawable
-- means a mask is on (best-effort — flavour only, server treats it as advisory).
local function isMasked(me)
    local ok, v = pcall(GetPedDrawableVariation, me, 1)
    return ok and v ~= nil and v ~= 0
end

-- Count alive non-player peds near `pos` that aren't the victim or me.
local function countWitnesses(pos, victim, me)
    local n = 0
    for _, o in ipairs(GetGamePool('CPed')) do
        if o ~= victim and o ~= me and DoesEntityExist(o)
            and not IsPedAPlayer(o) and not IsEntityDead(o)
            and #(GetEntityCoords(o) - pos) < WITNESS_RANGE then
            n = n + 1
        end
    end
    return n
end

CreateThread(function()
    while (Config.Social and Config.Social.Enabled) do
        Wait(SCAN_MS)
        local me = PlayerPedId()
        if me ~= 0 and DoesEntityExist(me) and not IsEntityDead(me) then
            local mc = GetEntityCoords(me)
            for _, ped in ipairs(GetGamePool('CPed')) do
                if ped ~= me and DoesEntityExist(ped) and not IsPedAPlayer(ped)
                    and HasEntityBeenDamagedByEntity(ped, me, true) then
                    local pc = GetEntityCoords(ped)
                    if #(pc - mc) < NEAR_CRIME then
                        local kind = IsEntityDead(ped) and 'kill' or 'attack'
                        local witnesses = countWitnesses(pc, ped, me)
                        TriggerServerEvent('palm6_brain:crime:report', kind,
                            { x = pc.x, y = pc.y, z = pc.z }, witnesses, isMasked(me))
                    end
                    ClearEntityLastDamageEntity(ped)   -- one hit -> one report
                end
            end
        end
    end
end)
