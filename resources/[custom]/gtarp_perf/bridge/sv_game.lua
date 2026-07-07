-- ============================================================================
-- gtarp_perf/bridge/sv_game.lua
--
-- Game/runtime adapter (server). The ONLY file in this resource that calls
-- the game timer native. Core logic (server/main.lua) calls Bridge.* only,
-- so the hitch sampler's ring buffer and p95/p99 math are engine-agnostic.
--
-- To port to GTA VI, rewrite THIS FILE against the new millisecond timer.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

-- Monotonic millisecond game timer used to measure server-thread hitches.
function Bridge.GetTimerMs()
    return GetGameTimer()
end

-- ACE-restricted server command (restricted=true → requires command.<name>).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, true)
end

-- Connected player server ids (strings, per the native).
function Bridge.GetPlayers()
    return GetPlayers()
end

function Bridge.ResourceState(name)
    return GetResourceState(name)
end

-- Every resource whose name starts with `prefix`, mapped to its state.
function Bridge.CustomResources(prefix)
    local out = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and name:sub(1, #prefix) == prefix then
            out[name] = GetResourceState(name)
        end
    end
    return out
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[gtarp_perf] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 120, 200, 255 }, args = { 'diag', line } })
        end
    end
end
