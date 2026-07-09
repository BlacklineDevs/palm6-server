-- ============================================================================
-- gtarp_seizure/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / ox_inventory / gtarp_mdt / gtarp_evidence exports or server-side
-- natives. server/main.lua (the forfeiture logic) calls Bridge.* only — a
-- GTA VI port is a rewrite of THIS FILE. See docs/GTA6-READINESS.md §3.
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

-- RP display name for a citizen source (evidence attribution).
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        local name = ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if #name > 0 then return name end
    end
    return ('citizen %s'):format(tostring(src))
end

-- Is this source an on-duty police officer? (server-side authority gate)
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == 'police' and job.onduty == true
end

-- The nearest OTHER player within maxDist metres of `src`, as
-- { src=, citizenid= }, or nil. Fully server-side: positions read from each
-- ped's server entity, never a client-supplied target or coordinate.
function Bridge.NearestPlayer(src, maxDist)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local oc = GetEntityCoords(ped)
    local best, bestSrc = maxDist, nil
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        if sid ~= src then
            local sp = GetPlayerPed(sid)
            if sp and sp ~= 0 then
                local d = #(oc - GetEntityCoords(sp))
                if d <= best then best = d; bestSrc = sid end
            end
        end
    end
    if not bestSrc then return nil end
    return { src = bestSrc, citizenid = Bridge.GetCitizenId(bestSrc) }
end

-- How much dirty money (black_money, count == dollars) a player holds.
function Bridge.CountDirty(src, name)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', name) end)
    return ok and (tonumber(n) or 0) or 0
end

-- Remove exactly `count` of the dirty item. Returns true only if ox confirms
-- the removal (the forfeiture logs only what was actually taken).
function Bridge.RemoveDirty(src, name, count)
    local ok, removed = pcall(function() return exports.ox_inventory:RemoveItem(src, name, count) end)
    return ok and removed and true or false
end

function Bridge.ItemExists(name)
    local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
    return ok and item ~= nil
end

-- Soft cross-call: is this citizen wanted? (probable-cause gate). false if
-- gtarp_mdt is absent.
function Bridge.HasActiveWarrant(citizenid)
    if GetResourceState('gtarp_mdt') ~= 'started' then return false end
    local ok, has = pcall(function() return exports.gtarp_mdt:HasActiveWarrant(citizenid) end)
    return ok and has == true
end

-- Soft cross-calls into gtarp_evidence v2 (frozen exports; never its tables).
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

function Bridge.Notify(src, title, msg, t)
    if src == 0 then print(('[gtarp_seizure] %s: %s'):format(title, msg)); return end
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
