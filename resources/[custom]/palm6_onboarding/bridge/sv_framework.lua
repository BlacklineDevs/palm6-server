-- ============================================================================
-- palm6_onboarding/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side game natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    if not p or not p.PlayerData then return nil end
    return p.PlayerData.citizenid
end

-- Credit `amount` to the source's bank. Returns true if applied.
function Bridge.CreditBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    p.Functions.AddMoney('bank', amount, reason)
    return true
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Register a callback fired once a character is loaded and in the world,
-- server-side. Hides the framework's loaded-event name (same convention as
-- the client-side Game.OnPlayerLoaded in server_base/palm6_turf/
-- server_identity - see their bridge/cl_game.lua). qbx_core raises
-- QBCore:Server:OnPlayerLoaded from its own server/events.lua.
--
-- Because it is raised SERVER-side, AddEventHandler is the correct primitive and
-- RegisterNetEvent was wrong: the latter does not merely add a listener, it
-- opens the name to the network for every handler on the box, so a modified
-- client could announce "I just loaded" at will and drive the onboarding flow
-- (and anything else listening for a real character load) off a forged signal.
--
-- The RegisterNetEvent -> AddEventHandler swap is behaviour-neutral for a boring
-- reason: RegisterNetEvent(name, cb) is just RegisterNetEvent(name) +
-- AddEventHandler(name, cb), so the handler and the value of `source` inside it
-- are identical either way.
--
-- WHAT `source` ACTUALLY IS HERE IS NOT KNOWN FROM THIS REPO. An earlier version
-- of this comment asserted BOTH of the following, and they cannot both be
-- universally true:
--   (1) the repo's shared server-raise predicate - a raise from inside the
--       server VM surfaces as nil, <= 0, or 65535 (palm6_eventguard/server/
--       main.lua guard(); palm6_mdt/bridge/sv_framework.lua Bridge.OnPoliceAlert,
--       grep `local fromNet`; palm6_witnesses/server/main.lua's
--       police:server:policeAlert handler, grep `local isServerCall`), and
--   (2) that this server-raised event nevertheless delivers the newly-loaded
--       player's server id in `source`.
-- qbx_core is NOT in this repo (it lives on the game box), so nothing here can
-- settle it. Stating the consequence each way instead of picking one:
--   • If (2) holds, this works as intended: the prompt fires on character load.
--   • If (1) holds, `source` is a sentinel, Bridge.GetCitizenId returns nil, and
--     server/main.lua's handler returns immediately. It is FAIL-SAFE, not wrong:
--     nothing is granted, nothing is charged, and the belt-and-suspenders
--     palm6_onboarding:checkStatus net event (which the client always sends on
--     load, and which reads `source` from a real net event) still raises the
--     prompt. The only symptom would be the prompt arriving on the client's ask
--     rather than on the load event, which is invisible in play.
-- To settle it on the box: add a temporary print of `source` in this handler and
-- watch one character load.
--
-- WHY palm6_brain LEANS ON (1) WHILE THIS FILE REFUSES TO, so the two files are
-- not read as contradicting each other: palm6_brain/shared/config.lua's
-- Config.PoliceBus block builds on the same predicate for
-- police:server:policeAlert, and it can, because SEVEN in-repo resources already
-- raise that event in the identical shape from their own bridge/sv_framework.lua
-- (business, counterfeit, drugs, laundering, protection, smuggling,
-- palm6_witnesses) and ship live on that basis. QBCore:Server:OnPlayerLoaded has
-- no such precedent: nothing in this tree raises it, qbx_core does. Same
-- predicate, seven in-repo raises versus zero, so different confidence - and
-- palm6_brain still states the inverted consequences for the case where it does
-- not hold. Neither file asserts more than its evidence.
--
-- Why this does NOT copy palm6_whitelist_jobs/bridge/sv_framework.lua's fix of
-- preferring the explicit argument: for QBCore:Server:OnJobUpdate the affected
-- player's server id is documented (in that file) as argument 1. For
-- QBCore:Server:OnPlayerLoaded this tree records nothing about what its
-- arguments mean, so preferring argument 1 would be a guess - and a wrong guess
-- would push the mandatory rules prompt at the wrong player (the grants are safe
-- either way: they hang off the palm6_onboarding:acceptRules NET event, whose
-- `source` is the real accepting client, not off this handler). Prefer the
-- explicit argument here only once someone has confirmed its meaning on the box.
function Bridge.OnPlayerLoaded(handler)
    AddEventHandler('QBCore:Server:OnPlayerLoaded', function()
        handler(source)
    end)
end

function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Grant a one-time owned starter vehicle to `citizenid`, parked in `garage`.
-- Goes through qbx_vehicles:CreatePlayerVehicle (the supported owned-vehicle
-- API) rather than a raw player_vehicles INSERT, so it survives qbx schema
-- changes. Returns true only if the vehicle row was actually created. Any
-- missing resource / error is swallowed — onboarding must never crash over a
-- car, and the once-per-citizen INSERT guard in server/main.lua means this can
-- only be reached once anyway.
function Bridge.GiveStarterVehicle(citizenid, model, garage)
    if not citizenid or not model then return false end
    if not Bridge.ResourceStarted('qbx_vehicles') then return false end
    local ok, vehicleId = pcall(function()
        return exports.qbx_vehicles:CreatePlayerVehicle({
            model = model,
            citizenid = citizenid,
            garage = garage,
        })
    end)
    -- CreatePlayerVehicle returns a numeric vehicleId on success, or nil+err.
    return ok and vehicleId ~= nil
end

-- Placeholder for a future one-time starter outfit. Deferred (Config.StarterOutfit
-- is OFF by default) because illenium's saved-outfit format is version-specific.
-- Kept as a Bridge seam so server/main.lua stays framework-agnostic when it lands.
function Bridge.SetStarterOutfit(_src, _citizenid)
    return false
end
