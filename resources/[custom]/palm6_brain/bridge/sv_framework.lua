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

-- Send a dispatch alert (blip + notify) to every on-duty officer. `coords` is
-- {x,y,z}. Renders via OUR OWN palm6_brain:dispatch client event (this server
-- has no shared dispatch UI — each crime resource fires its own, exactly like
-- palm6_robbery). Sent ONLY to on-duty cops, so no other player sees the blip.
function Bridge.AlertPolice(coords, label, durationSeconds, sprite, colour, scale)
    for _, sid in ipairs(onDutyPolice()) do
        TriggerClientEvent('palm6_brain:dispatch', sid, {
            coords = coords, label = label, duration = durationSeconds,
            sprite = sprite, colour = colour, scale = scale,
        })
    end
end
