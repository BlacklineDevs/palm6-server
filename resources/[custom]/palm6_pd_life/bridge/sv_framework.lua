-- ============================================================================
-- palm6_pd_life/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY server file that calls qbx_core. The
-- duty layer (server/duty.lua) calls Bridge.* only, so it ports to GTA VI by
-- rewriting THIS file. Mirrors palm6_heat's bridge (same getPlayer + police
-- predicate) plus a duty setter for the take-a-post flow.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Is this source a police officer (any duty state)? Taking a post is what puts
-- them ON duty, so the gate is job membership, not current duty.
function Bridge.IsPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob
end

-- Is this source an on-duty police officer?
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob and job.onduty == true
end

-- Set this officer's duty flag (qbx). Returns the new state, or nil on failure.
function Bridge.SetDuty(src, onduty)
    local p = getPlayer(src)
    if not p or not p.PlayerData or p.PlayerData.job == nil then return nil end
    if p.PlayerData.job.name ~= Config.PoliceJob then return nil end
    if p.Functions and p.Functions.SetJobDuty then
        p.Functions.SetJobDuty(onduty and true or false)
        return onduty and true or false
    end
    return nil
end

function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end
