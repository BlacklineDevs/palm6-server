-- ============================================================================
-- palm6_pd_life/server/perm.lua
--
-- The one authority on who may drive the /placeped placement editor.
--
-- client/placer.lua registers eleven commands (/placeped plus ten sub-commands)
-- that spawn peds, move them, and dump config lines to the clipboard. Every one
-- of them was `RegisterCommand(..., false)` with no ACE check and no server
-- authority anywhere in the file, so any connected player could open the editor.
-- The peds it spawns are client-local and non-networked (bridge/cl_game.lua
-- creates them with isNetwork=false), so the blast radius is self-grief plus
-- client perf rather than the networked-prop griefing that got prop_spawn
-- force-stopped in custom.cfg - but an admin dev tool should still be an admin
-- dev tool.
--
-- Shape copied from palm6_mapeditor/server/main.lua:17-19: the client asks once
-- at load, the server answers, and the client refuses everything until it hears
-- yes. The gate is advisory by construction (a modified client can lie to
-- itself), which is acceptable precisely BECAUSE nothing here is networked or
-- persistent - there is no server-side effect to protect, only a tool to keep
-- out of the wrong menu.
-- ============================================================================

-- Per-source cooldown. This is a NET event, so a modified client can raise it
-- in a loop; each raise costs an IsPlayerAceAllowed lookup plus a client event
-- back, which is cheap individually and not cheap at a thousand a second.
-- The event is deliberately NOT registered in palm6_eventguard/config.lua:
-- guard() only bounds what it is told about, and the honest place for a bound
-- on a resource's own one-shot load handshake is the resource. The client asks
-- exactly ONCE at load (client/placer.lua), so 10s is far above any legitimate
-- pattern including a `restart palm6_pd_life` while players are connected, and
-- far below a flood. Over-budget raises are dropped silently: the answer is
-- already cached client-side and there is nothing an operator needs to see.
local lastCheck = {}
local CHECK_COOLDOWN_SEC = 10

RegisterNetEvent('palm6_pd_life:checkPerm', function()
    local src = source
    if not src or src <= 0 then return end
    local t = os.time()
    if (lastCheck[src] or 0) + CHECK_COOLDOWN_SEC > t then return end
    lastCheck[src] = t
    TriggerClientEvent('palm6_pd_life:perm', src, Bridge.IsPlacerAllowed(src))
end)

-- Do not leak the cooldown table across a full session's worth of joins.
AddEventHandler('playerDropped', function()
    lastCheck[source] = nil
end)
