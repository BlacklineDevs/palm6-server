-- ============================================================================
-- palm6_brain/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that touches
-- qbx_core / server-side framework natives. The Director (server/director.lua)
-- calls Bridge.* only. Mirrors palm6_robbery/bridge/sv_framework.lua so the
-- police-alert semantics are IDENTICAL to the hand-built crime resources — same
-- on-duty check, same dispatch shape. To port to GTA VI, rewrite THIS FILE.
--
-- Loaded BEFORE server/director.lua (see fxmanifest) so the Bridge global exists
-- when the Director's crime path calls it. Nothing here fires until the Director
-- actually calls it, which only happens when Config.Director.CrimeEnabled is on.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- List of server ids of on-duty police (same predicate palm6_robbery uses).
local function onDutyPolice()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        local p = getPlayer(sid)
        local job = p and p.PlayerData and p.PlayerData.job
        if job and job.name == 'police' and job.onduty then
            out[#out + 1] = sid
        end
    end
    return out
end

-- How many police are on duty right now. The crime throttle's MinOnDutyPolice
-- gate reads this so an AI crime is never dispatched to an empty PD.
function Bridge.CountOnDutyPolice()
    return #onDutyPolice()
end

-- ---------------------------------------------------------------------------
-- POLICE RECORD BUS (Config.PoliceBus - read that block before touching this).
--
-- The private fan-out below puts a blip on officers' maps and leaves NO record:
-- it never touches police:server:policeAlert, so brain's dispatches are absent
-- from palm6_mdt's /calls log and from palm6_witnesses' incidents. This routes
-- them onto the sanctioned server-side path so they are recorded like any other
-- 911. Ships OFF: the suspect path opens a real witness incident against a
-- player for something an NPC perceived, which is a live gameplay change.
--
-- Counters run in BOTH states so /brainstatus can show what a flip WOULD
-- ATTEMPT. Attempted, not recorded: every sink has gates of its own after this
-- point (palm6_mdt Config.Calls.Enabled / RequireServerProvenance /
-- PerSourceCdSec, palm6_witnesses' per-source rate limit + IncidentCooldownSec +
-- MinWitnesses), so notRouted is an UPPER BOUND on the rows a flip would
-- produce, never a preview of them. Same caveat applies to alertRaised.
-- ---------------------------------------------------------------------------
local busStats = { dispatches = 0, alertRaised = 0, callLogged = 0, notRouted = 0, noSink = 0 }

-- One console line for /brainstatus.
function Bridge.PoliceBusLine()
    local cfg = Config.PoliceBus or {}
    return ('%s: %d dispatch(es) this session - %d raised onto police:server:policeAlert (raise attempted, NOT proof of a record), %d logged via palm6_mdt:LogCall (return value checked), %d not routed (flag off), %d not routed (no sink)')
        :format(cfg.Enabled and 'ON' or 'off', busStats.dispatches, busStats.alertRaised,
            busStats.callLogged, busStats.notRouted, busStats.noSink)
end

-- Put one dispatch on the police record. NEVER YIELDS IN THE CALLER and never
-- throws: every cross-resource call is GetResourceState + pcall, because a
-- stopped or broken consumer must not break a brain dispatch (the blip has
-- already gone out).
--
-- BOTH SINKS YIELD, so the routing runs DETACHED in a CreateThread and this
-- function returns to its caller on the same tick it was called. Both reach the
-- same insert: exports.palm6_mdt:LogCall and police:server:policeAlert each land
-- in palm6_mdt's insertCall, which is a MySQL.insert.await.
--
-- Detaching is load-bearing, not tidiness. Three in-tree comments state the
-- never-yields property and were written against it:
--   server/snitch.lua header - "the handler never yields (all reads + a
--     fire-and-forget alert)"
--   server/snitch.lua, above tryReport - "Never yields."
--   server/witness.lua, above onSocialEvent - it runs SYNCHRONOUSLY inside
--     Social.ReportEvent's consumer loop (server/social.lua, `for _, fn in
--     ipairs(consumers) do pcall(fn, evt) end`), "so we do NO yields here".
-- Both dispatch callers write their COOLDOWN AFTER calling Bridge.AlertPolice:
-- snitch.lua sets lastSnitch/lastByCid after the fire, director.lua calls
-- crimeRecord after it. A yield here would hand control back to the event
-- dispatcher with those cooldowns still unwritten, so the next report in flight
-- would pass the very gate the first one just passed - twenty witnesses to one
-- shooting becoming twenty dispatches, which is the exact thing
-- GLOBAL_COOLDOWN_SEC exists to stop. palm6_eventguard/server/main.lua writes up
-- that miswiring (a yield mid-handler let the dispatcher run the NEXT handler);
-- it is why every non-combat budget there was inert for a while.
--
-- Cost of detaching: the three counters below land one tick later than
-- busStats.dispatches. They are a meter, nothing reads them synchronously.
local function recordDispatch(coords, label, suspectSrc)
    if not (Config.PoliceBus or {}).Enabled then
        busStats.notRouted = busStats.notRouted + 1
        return
    end

    local src = tonumber(suspectSrc)

    CreateThread(function()
        -- SUSPECT PATH. Only for a suspect who is STILL CONNECTED: the alert bus
        -- reads that player's live ped for the call coords and their citizenid
        -- for the log, so a stale server id would attribute the call to whoever
        -- holds that id now. GetPlayerName returns nil for an id nobody is
        -- using. Checked HERE rather than in the caller precisely because this
        -- body runs a tick later: this is the check closest to the raise.
        -- Raised unconditionally rather than behind a
        -- GetResourceState('qbx_police') check, because the point here is the
        -- RECORD (palm6_mdt, palm6_witnesses), not qbx_police's notify; a
        -- TriggerEvent nobody listens to is a no-op.
        if src and src > 0 and src ~= 65535 and GetPlayerName(src) then
            local ok = pcall(function()
                TriggerEvent('police:server:policeAlert', label, nil, src)
            end)
            if ok then
                -- ATTEMPTED, not recorded. TriggerEvent has no return value, so
                -- unlike the LogCall branch below there is nothing to read: this
                -- counts raises onto the bus, and a raise still dies at any of
                -- palm6_mdt's Config.Calls gates (Enabled off,
                -- RequireServerProvenance, PerSourceCdSec) or palm6_witnesses'
                -- (per-source rate limit, IncidentCooldownSec, MinWitnesses).
                -- The counter name and /brainstatus wording both say "raised".
                busStats.alertRaised = busStats.alertRaised + 1
                return
            end
        end

        -- NO-SUSPECT PATH. An AI-Director crime has no player to attribute, and
        -- police:server:policeAlert derives everything from a player source, so
        -- it cannot carry one. palm6_mdt's additive LogCall export can, and it
        -- keeps the coords we were handed (see Config.PoliceBus for where those
        -- coords come from per caller - they are server-derived for the Director
        -- and a bounded client claim for the snitch path).
        -- The export's own return value decides the counter, not just pcall
        -- success: LogCall returns false when palm6_mdt's Config.Calls.Enabled is
        -- off or the INSERT failed, and a meter that counted those as logged
        -- would be lying.
        if GetResourceState('palm6_mdt') == 'started' then
            local ok, logged = pcall(function()
                return exports.palm6_mdt:LogCall(label, coords, (Config.PoliceBus or {}).CallLabel)
            end)
            if ok and logged then
                busStats.callLogged = busStats.callLogged + 1
                return
            end
        end

        busStats.noSink = busStats.noSink + 1
    end)
end

-- Send a dispatch alert (blip + notify) to every on-duty officer. `coords` is
-- {x,y,z}. Renders via OUR OWN palm6_brain:dispatch client event (this server
-- has no shared dispatch UI — each crime resource fires its own, exactly like
-- palm6_robbery). Sent ONLY to on-duty cops, so no other player sees the blip.
--
-- `suspectSrc` (optional) is the server id of the PLAYER this dispatch is about,
-- when there is one (the snitch path passes it; the AI-Director path has no
-- player and passes nothing). It is used ONLY by recordDispatch above and only
-- when Config.PoliceBus.Enabled - the blip fan-out ignores it entirely.
function Bridge.AlertPolice(coords, label, durationSeconds, sprite, colour, scale, suspectSrc)
    busStats.dispatches = busStats.dispatches + 1
    for _, sid in ipairs(onDutyPolice()) do
        TriggerClientEvent('palm6_brain:dispatch', sid, {
            coords = coords, label = label, duration = durationSeconds,
            sprite = sprite, colour = colour, scale = scale,
        })
    end
    recordDispatch(coords, label, suspectSrc)
end
