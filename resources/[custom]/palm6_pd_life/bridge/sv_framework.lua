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

-- Does this source hold the placement-editor ACE? Console (src 0) always does,
-- matching palm6_mapeditor/server/main.lua:8-10.
function Bridge.IsPlacerAllowed(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.PlacerAce)
end

-- This player's world position as { x, y, z }, or nil. Server-read (OneSync
-- makes this authoritative), never a client-supplied coordinate.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

-- The station's duty-toggle point, as { x, y, z, radius }, or nil when the
-- contract cannot be read.
--
-- Sourced from qbx_police_overrides' GetDutyToggle() export rather than a
-- hardcoded coordinate, for two reasons: that export had NO consumer anywhere
-- in the tree (it published a duty point nothing honoured), and reading it
-- means this gate never invents a world coordinate of its own. If the station
-- ever moves, it moves in the override config and this follows.
--
-- The contract's own radius is an ox_target interaction radius (1.0m) - far
-- too tight for a chat command typed while walking through the lobby - so the
-- caller widens it with Config.DutyGate.MinRadius. That is a derived bound,
-- not an invented position.
function Bridge.GetDutyPoint()
    if GetResourceState('qbx_police_overrides') ~= 'started' then return nil end
    local ok, dt = pcall(function() return exports.qbx_police_overrides:GetDutyToggle() end)
    if not ok or type(dt) ~= 'table' then return nil end
    local c = dt.coords
    if type(c) ~= 'table' and type(c) ~= 'vector3' then return nil end
    -- vector3 and a plain {x,y,z} table both answer .x/.y/.z, so one read
    -- covers however the export survives msgpack across the resource boundary.
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z, radius = tonumber(dt.radius) or 0.0 }
end

function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end
