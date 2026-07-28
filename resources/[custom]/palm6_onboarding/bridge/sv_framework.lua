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
-- server_identity — see their bridge/cl_game.lua). qbx_core fires
-- QBCore:Server:OnPlayerLoaded from server/events.lua with `source` set to
-- the newly-loaded player.
--
-- Because it is raised SERVER-side, AddEventHandler is the correct primitive and
-- RegisterNetEvent was wrong: the latter does not merely add a listener, it
-- opens the name to the network for every handler on the box, so a modified
-- client could announce "I just loaded" at will and drive the onboarding flow
-- (and anything else listening for a real character load) off a forged signal.
--
-- `source` is unaffected by the swap, but not for the reason an earlier version
-- of this comment gave. It is NOT true that "a server TriggerEvent inherits the
-- triggering context's source" - this repo's own shared server-raise predicate
-- says a raise from inside the server VM surfaces as nil, <= 0, or 65535 (see
-- palm6_eventguard/server/main.lua guard(),
-- palm6_mdt/bridge/sv_framework.lua:249-250 and
-- palm6_witnesses/server/main.lua:494-495). The swap is neutral for a much more
-- boring reason: RegisterNetEvent(name, cb) is just RegisterNetEvent(name) +
-- AddEventHandler(name, cb), so the handler and the value of `source` inside it
-- are identical either way.
--
-- We therefore still rely on the qbx_core-specific fact stated above (it sets
-- `source` to the newly-loaded player). Unlike QBCore:Server:OnJobUpdate, this
-- event carries no verified explicit player-id argument in this tree, so there
-- is nothing safer to prefer. If a future qbx_core is confirmed to pass one,
-- prefer it here the way palm6_whitelist_jobs/bridge/sv_framework.lua does.
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
