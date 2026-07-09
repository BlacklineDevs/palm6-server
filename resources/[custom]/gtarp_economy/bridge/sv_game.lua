-- ============================================================================
-- gtarp_economy/bridge/sv_game.lua
--
-- Game/runtime adapter (server). The ONLY file that touches natives / sibling
-- exports. server/main.lua (the aggregation + formatting) calls Bridge.* only.
-- Same shape as gtarp_perf's diag bridge. See docs/GTA6-READINESS.md §3.
-- ============================================================================

Bridge = {}

-- ACE-restricted server command (restricted=true → requires command.<name>).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, true)
end

-- Reply to a command invoker: console prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[gtarp_economy] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 130, 220, 160 }, args = { 'economy', line } })
        end
    end
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Safely pull a sibling resource's GetSummary() (soft — nil if the resource
-- isn't started or has no such export). Read-only; never mutates anything.
function Bridge.Summary(resource)
    if GetResourceState(resource) ~= 'started' then return nil end
    local ok, s = pcall(function() return exports[resource]:GetSummary() end)
    return (ok and type(s) == 'table') and s or nil
end
