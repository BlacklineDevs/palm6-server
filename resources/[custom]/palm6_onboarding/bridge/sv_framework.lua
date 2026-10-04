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

-- Can the deployed qbx_garages reach a garage called `name`?
--
-- Returns 'present', 'absent', or 'unknown' — THREE states on purpose.
-- Collapsing 'unknown' into 'absent' would switch starter vehicles off on a
-- box where they work fine; collapsing it into 'present' is the bug this
-- whole function exists to stop. The caller decides what to do with doubt.
--
-- WHY THIS CANNOT BE ANSWERED STATICALLY: qbx_garages is part of the base
-- Qbox pack and lives on the game box, NOT in this repo (see the custom-layer
-- note in docs/). Nothing in this tree names a garage anywhere else, so there
-- is no in-repo authority to check `Config.StarterVehicle.garage` against.
-- Both probes below read the LIVE resource at runtime, which is the only
-- place the answer exists.
--
-- Probe A (authoritative when it works): ask qbx_garages for its own table.
-- The export name is not guaranteed across Qbox versions, hence the pcall and
-- the fall-through; a version that does not expose it yields 'unknown', not a
-- wrong answer.
--
-- Probe B (heuristic, deliberately weaker): read the resource's shared config
-- as TEXT and look for the name used as a table key. This can only ever
-- UPGRADE 'unknown' to 'present' — it is never allowed to prove absence,
-- because a garage defined in a file this probe does not read would look
-- identical to a garage that does not exist. A commented-out entry would be a
-- false 'present'; that is the acceptable direction of error here, since the
-- operator-facing failure mode it protects is "typo in a name nobody checked".
function Bridge.ResolveGarage(name)
    if type(name) ~= 'string' or name == '' then return 'absent' end
    if GetResourceState('qbx_garages') ~= 'started' then return 'unknown' end

    -- Probe A — the resource's own view of its garages.
    local ok, garages = pcall(function()
        return exports.qbx_garages:GetGarages()
    end)
    if ok and type(garages) == 'table' then
        if garages[name] ~= nil then return 'present' end
        -- Array-of-records shape, seen in some forks.
        for _, g in pairs(garages) do
            if type(g) == 'table' and (g.name == name or g.label == name) then
                return 'present'
            end
        end
        -- A table that resolved and does not contain it is real evidence.
        return 'absent'
    end

    -- Probe B — text read of the shipped config. Upgrade-only (see above).
    local body
    pcall(function()
        body = LoadResourceFile('qbx_garages', 'shared/garages.lua')
            or LoadResourceFile('qbx_garages', 'config/garages.lua')
            or LoadResourceFile('qbx_garages', 'shared/config.lua')
    end)
    if type(body) == 'string' and body ~= '' then
        local pat = name:gsub('(%W)', '%%%1')
        if body:find("%['" .. pat .. "'%]") or body:find('%["' .. pat .. '"%]')
            or body:find('%f[%w_]' .. pat .. '%s*=') then
            return 'present'
        end
    end

    return 'unknown'
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
