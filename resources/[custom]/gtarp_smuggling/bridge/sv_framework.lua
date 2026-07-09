-- ============================================================================
-- gtarp_smuggling/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / ox_inventory / qbx_police / gtarp_evidence exports or server-side
-- natives. server/main.lua (the run logic) calls Bridge.* only — a GTA VI port
-- is a rewrite of THIS FILE. See docs/GTA6-READINESS.md §3.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Pay the run out DIRTY (black_money, count == dollars) — this is what wires
-- smuggling into the dirty-money economy (launderable via gtarp_laundering,
-- forfeitable via gtarp_seizure). NOT markedbills (qbx_drugs' item).
function Bridge.GiveDirty(src, name, amount)
    local ok, added = pcall(function() return exports.ox_inventory:AddItem(src, name, amount) end)
    return ok and added and true or false
end

function Bridge.ItemExists(name)
    local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
    return ok and item ~= nil
end

-- On-duty police server ids (fallback dispatch fan-out).
local function onDutyPolice()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        local p = getPlayer(sid)
        local job = p and p.PlayerData and p.PlayerData.job
        if job and job.name == 'police' and job.onduty then out[#out + 1] = sid end
    end
    return out
end

-- Dispatch a smuggling-movement alert so police can try to intercept the run
-- (cornerselling/counterfeit contract: coords derived from arg 3 server-side).
function Bridge.PoliceAlert(src, text)
    if GetResourceState('qbx_police') == 'started' then
        local ok = pcall(function() TriggerEvent('police:server:policeAlert', text, nil, src) end)
        if ok then return end
    end
    local ped = GetPlayerPed(src)
    local c = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not c then return end
    for _, sid in ipairs(onDutyPolice()) do
        TriggerClientEvent('gtarp_smuggling:dispatch', sid, { coords = { x = c.x, y = c.y, z = c.z }, label = text })
    end
end

-- Soft gtarp_evidence v2 hooks (frozen exports; never its tables).
function Bridge.EvidenceEnsureCase(incidentKey, title, createdBy)
    if GetResourceState('gtarp_evidence') ~= 'started' then return nil end
    local ok, id = pcall(function() return exports.gtarp_evidence:EnsureCase(incidentKey, title, createdBy) end)
    return (ok and id) or nil
end

function Bridge.EvidenceAppend(caseId, kind, payload, source)
    pcall(function() exports.gtarp_evidence:AppendEntry(caseId, kind, payload, source) end)
end

function Bridge.EvidenceLinkSuspect(caseId, citizenid, descriptor)
    pcall(function() exports.gtarp_evidence:LinkSuspect(caseId, citizenid, descriptor) end)
end

-- Caller position as {x,y,z}, or nil (server-side proximity — never trust a
-- client-supplied coordinate).
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Bridge.Distance(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

function Bridge.Notify(src, title, msg, t)
    if src == 0 then print(('[gtarp_smuggling] %s: %s'):format(title, msg)); return end
    TriggerClientEvent('ox_lib:notify', src, { title = title, description = msg, type = t or 'inform' })
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Soft hype broadcast to the gtarp_discord announcer (tolerated absent).
function Bridge.Announce(feed, payload)
    if GetResourceState('gtarp_discord') ~= 'started' then return end
    pcall(function() exports.gtarp_discord:Announce(feed, payload) end)
end

function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
