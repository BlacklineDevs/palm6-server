--[[
    server/main.lua — v0.2.0, DEFERRED. Not loaded by fxmanifest.lua in v0.1.0.

    Pushes job-sync only — enables shared/config.lua's `job` gate field. v0.1.0 ships
    without this file; every `job`-gated menu node stays visible (inert, safe default).

    VERIFY before enabling (README.md "Before First Ensure" checklist):
    grep the live qbx_core resource files on the actual FiveM box (not this git repo — qbx_core
    isn't vendored locally here) for the literal event name strings below:
        qbx_core:server:playerLoaded
        qbx_core:server:onJobUpdate
    If they differ, substitute the confirmed names. If no such events exist, poll
    exports.qbx_core:GetPlayer(source) on a coarse timer instead of relying on events.

    Once verified, uncomment the server_scripts block in fxmanifest.lua to load this file
    and bridge/sv_framework.lua.
]]

--[[
    AddEventHandler, NOT RegisterNetEvent. THIS IS NOT STYLE.

    `qbx_core:server:playerLoaded` and `qbx_core:server:onJobUpdate` are
    qbx_core's own SERVER-INTERNAL event names, raised server-side with
    TriggerEvent. RegisterNetEvent on one of them does not merely subscribe: it
    promotes the name to the network for EVERY listener on the box, so any
    client can then raise it at every handler any resource has registered.
    palm6_eventguard/config.lua records that exact failure as already found and
    fixed twice in this repo, and palm6_uniform and palm6_insignia are
    currently listening on this class of name. AddEventHandler subscribes
    without net-registering anything.

    And the second handler's `src` came from ARGUMENT 1, not `source`. Once the
    name is net-registered, `TriggerServerEvent('qbx_core:server:onJobUpdate',
    -1, {name='police'})` rewrites currentJob for every connected player at
    once - both leaking job-gated wedges to everyone and stripping the right
    ones from the players who should have them. The handler above it already
    did `local src = source` correctly; palm6_insignia and palm6_uniform both
    use AddEventHandler for the analogous onGroupUpdate.

    The enable checklist in README.md asks only that the event NAMES be
    verified live. Verify the SHAPE too: which primitive raises them, and
    whether the payload carries a source at all.
]]

-- VERIFY: exact qbx_core event name against live game box qbx_core source before enabling.
AddEventHandler('qbx_core:server:playerLoaded', function()
    local src = source
    TriggerClientEvent('palm6_radialmenu:syncJob', src, Bridge.GetJob(src))
end)

-- VERIFY: exact qbx_core event name against live game box qbx_core source before enabling.
-- VERIFY ALSO: that qbx_core raises this with the affected player as `source`.
-- If it instead passes the server id as an argument, read it there - but only
-- after confirming the event is server-internal, never client-raisable.
AddEventHandler('qbx_core:server:onJobUpdate', function(job)
    local src = source
    TriggerClientEvent('palm6_radialmenu:syncJob', src, job and job.name or nil)
end)
