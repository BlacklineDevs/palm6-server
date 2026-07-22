-- ============================================================================
-- palm6_robbery/server/main.lua
--
-- ATM robberies. Two phases: `start` validates (police gate, cooldown,
-- proximity), reserves the target and fires dispatch; `complete` pays out
-- after the client-side hold. Pure logic — all framework/native access via
-- Bridge.*.
-- ============================================================================

local cd      = {}  -- [index] = unix expiry
local pending = {}  -- [src] = { index, holdUntil }

local function nearby(src, coords)
    local c = Bridge.GetCoords(src)
    if not c or not coords then return true end
    return Bridge.Distance(c, coords) <= (Config.InteractRadius + 2.5)
end

RegisterNetEvent('palm6_robbery:start', function(index)
    local src = source
    local loc = Config.ATMs.locations[index]
    if not loc then return end
    if not Bridge.GetCitizenId(src) then return end

    -- Cheap gates FIRST so start-spam can't force the O(players) CountOnDutyPolice
    -- scan on every packet (DoS): reject a cooling-down spot and a caller who isn't
    -- actually at the ATM before any expensive work.
    local now = os.time()
    if (cd[index] or 0) > now then
        Bridge.Notify(src, 'Robbery', 'This spot was hit recently. Come back later.', 'error')
        return
    end
    if not nearby(src, loc.coords) then return end

    if Bridge.CountOnDutyPolice() < (Config.MinPolice or 0) then
        Bridge.Notify(src, 'Robbery', 'It is too quiet — not enough police around.', 'error')
        return
    end

    if Config.RequireWeapon and not Bridge.IsArmed(src) then
        Bridge.Notify(src, 'Robbery', 'You need a weapon out for this.', 'error')
        return
    end

    -- Reserve immediately so it can't be double-started or spammed.
    cd[index] = now + Config.ATMs.cooldown_secs
    pending[src] = { index = index, startedAt = now,
                      holdUntil = now + Config.ATMs.hold_seconds + 5 }

    Bridge.AlertPolice(loc.coords,
        ('%s — %s'):format(Config.Dispatch.label, loc.label),
        Config.Dispatch.durationSeconds,
        Config.Dispatch.blipSprite, Config.Dispatch.blipColour, Config.Dispatch.blipScale)

    -- Server-only signal for shadow listeners (palm6_witnesses): fired ONLY
    -- after every gate above passed, so rejected/forged starts never leak.
    -- TriggerEvent (local), never a net event — clients cannot fake this.
    TriggerEvent('palm6_robbery:started', src)

    TriggerClientEvent('palm6_robbery:begin', src, { index = index, hold = Config.ATMs.hold_seconds })
end)

RegisterNetEvent('palm6_robbery:complete', function(index)
    local src = source
    local pend = pending[src]
    if not pend or pend.index ~= index then return end
    pending[src] = nil
    local elapsed = os.time() - pend.startedAt
    if os.time() > pend.holdUntil then return end  -- took too long / tampered
    if elapsed < Config.ATMs.hold_seconds then return end  -- skipped the hold client-side

    local loc = Config.ATMs.locations[index]
    if not loc or not nearby(src, loc.coords) then
        Bridge.Notify(src, 'Robbery', 'You left the ATM.', 'error')
        return
    end

    local reward = math.random(Config.ATMs.reward_min, Config.ATMs.reward_max)
    Bridge.AddCash(src, reward, 'robbery')

    Bridge.Notify(src, 'Robbery', ('You got away with $%d.'):format(reward), 'success')

    -- Persistent police attention: an ATM job is petty (a small heat bump) but
    -- it still puts the robber on the /heat board and follows the character
    -- after they log. Fires only AFTER every completion gate above passed.
    -- Soft-dep + pcall (same shape as the cityfeed hook below): a stopped or
    -- broken palm6_heat never touches the payout path — heat is keyed to the
    -- character, so we need the citizenid.
    if GetResourceState('palm6_heat') == 'started' then
        local citizenid = Bridge.GetCitizenId(src)
        if citizenid then
            pcall(function()
                exports.palm6_heat:AddHeat(citizenid, Config.HeatOnRob, 'atm_robbery')
            end)
        end
    end

    -- In-world civic bulletin (public facts only) via the palm6-bot feed. The
    -- bot narrates a reported robbery into its heist channel. This fires only
    -- AFTER every completion gate above passed (real pending reservation, hold
    -- served, still at the ATM), so a forged completion can't post. Soft-dep +
    -- pcall so a missing/broken cityfeed never touches the payout path.
    -- PUBLIC FACTS ONLY: the location label. Never the robber's identity and
    -- never the take (a figure the bot rejects). Convar-gated, default OFF
    -- until the bot-side `heist` payload shape is confirmed against
    -- palm6-bot/src/events/types.ts (see palm6_cityfeed README).
    if GetResourceState('palm6_cityfeed') == 'started'
        and GetConvar('palm6:cityfeed_heist', 'false') == 'true' then
        pcall(function()
            exports.palm6_cityfeed:Emit({
                type = 'heist',
                location = loc.label,
                agency = 'Palm6 Bay Police Department',
            })
        end)
    end
end)

RegisterNetEvent('palm6_robbery:cancel', function()
    local src = source
    local pend = pending[src]
    if not pend then return end
    pending[src] = nil
    -- Keep the FULL cooldown set at start. A dispatch already fired to police the
    -- moment this robbery started, so cancelling must NOT shorten the reservation —
    -- otherwise start->cancel cycling trickles a false 911 to every on-duty officer
    -- roughly once a minute per ATM. cd[index] was set to now+cooldown_secs at start;
    -- leave it (never lower it below the existing reservation).
    cd[pend.index] = math.max(cd[pend.index] or 0, os.time() + Config.ATMs.cooldown_secs)
end)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
