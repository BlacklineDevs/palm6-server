-- ============================================================================
-- palm6_brain/client/netped.lua — networked-ped task applier (foundation).
--
-- Server-created networked peds (server/netped.lua) carry their GOAL in a
-- replicated state bag `p6netgoal`. A networked ped only runs tasks on the client
-- that OWNS it, and ownership migrates to the nearest player. So this file:
--   1. On a state-bag CHANGE, if we own the ped, (re)apply the task.
--   2. On a slow loop, for every networked ped we CURRENTLY own, ensure its task
--      is applied — this is what makes a task survive OWNERSHIP MIGRATION (the new
--      owner never received the change event, so it must self-apply).
-- `applied[ped]` tracks the last goal we tasked so we don't restart the task every
-- tick. Dark by default (Config.NetPed.Enabled); touches none of the client-local
-- mover system.
-- ============================================================================

local function cfg() return Config.NetPed or {} end
if cfg().Enabled ~= true then return end   -- dark: register nothing, run no loop

local applied = {}   -- ped handle -> goalKey currently tasked

local function goalKey(g)
    if type(g) ~= 'table' then return '' end
    return ('%s|%s|%s'):format(tostring(g.verb), tostring(g.x or ''), tostring(g.y or ''))
end

-- Apply a goal to a ped we own. Idempotent via `applied` so we don't re-task each
-- tick; only re-tasks when the goal actually changes (or we just gained ownership,
-- signalled by clearing applied[ped]).
local function applyGoal(ped, g)
    if not (ped and ped ~= 0 and DoesEntityExist(ped) and type(g) == 'table') then return end
    local key = goalKey(g)
    if applied[ped] == key then return end
    ClearPedTasks(ped)
    if g.verb == 'goTo' and g.x then
        TaskFollowNavMeshToCoord(ped, g.x + 0.0, g.y + 0.0, g.z + 0.0, cfg().WalkSpeed or 1.0, 30000, 2.0, false, 0.0)
    elseif g.verb == 'wander' then
        TaskWanderStandard(ped, 10.0, 10)
    else   -- idle / anything else
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_MOBILE', 0, true)
    end
    applied[ped] = key
end

local function iOwn(ped)
    return NetworkGetEntityOwner(ped) == PlayerId()
end

-- (1) Goal changed (server rewrote the bag). If we own the ped, force a re-apply.
AddStateBagChangeHandler('p6netgoal', nil, function(bagName, _key, value)
    local ped = GetEntityFromStateBagName(bagName)
    if ped == 0 or not DoesEntityExist(ped) then return end
    if iOwn(ped) then
        applied[ped] = nil        -- force re-task on an explicit goal change
        applyGoal(ped, value)
    end
end)

-- (2) Re-assert loop — the migration fix. For every networked ped we currently
-- own, apply its goal (no-op if already applied). A ped we just took ownership of
-- gets its task here even though we never saw a change event.
CreateThread(function()
    while true do
        Wait(2000)
        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped and ped ~= 0 and DoesEntityExist(ped) and iOwn(ped) then
                local ok, g = pcall(function() return Entity(ped).state.p6netgoal end)
                if ok and type(g) == 'table' then applyGoal(ped, g) end
            end
        end
        -- prune applied[] entries for peds that no longer exist (bounded cleanup)
        for ped in pairs(applied) do
            if not DoesEntityExist(ped) then applied[ped] = nil end
        end
    end
end)
