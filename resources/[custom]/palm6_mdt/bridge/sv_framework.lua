-- ============================================================================
-- palm6_mdt/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for BOLO/report attribution.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    -- charinfo missing (partial load / disconnecting): return an IC-neutral
    -- placeholder, NEVER the FiveM native GetPlayerName(src) — that is the OOC
    -- account/gamertag, and this name flows into IC output (MDT notifications,
    -- the Discord police blotter, the cityfeed arrest character_name). Leaking a
    -- real gamertag into an IC channel breaks the IC/OOC wall.
    return 'Unknown citizen'
end

-- Is this source an on-duty police officer right now? (palm6_evidence's
-- exact gate.)
function Bridge.IsOnDutyPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == 'police' and job.onduty == true
end

-- Is the source carrying at least one of `item`?
function Bridge.HasItem(src, item)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and (tonumber(n) or 0) > 0
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Notify every on-duty officer (BOLO broadcast).
function Bridge.NotifyPolice(title, msg, t)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        if Bridge.IsOnDutyPolice(src) then
            Bridge.Notify(src, title, msg, t)
        end
    end
end

-- Reply to a command invoker: console gets prints, players get chat lines
-- (palm6_perf's /diag pattern).
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_mdt] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 116, 178, 255 }, args = { 'MDT', line } })
        end
    end
end

-- Resolve a citizenid to a display name, online or offline, or nil when
-- no such citizen exists. Offline path reads the framework's players
-- table (charinfo JSON) — framework schema knowledge, so it lives here.
function Bridge.GetCitizenName(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return Bridge.GetPlayerName(src)
        end
    end
    local name
    pcall(function()
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if row and row.charinfo then
            local ci = json.decode(row.charinfo)
            if type(ci) == 'table' then
                name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
                    :gsub('^%s+', ''):gsub('%s+$', '')
            end
        end
    end)
    return name
end

-- The nearest OTHER player within maxDist metres of `src`, as
-- { src=, citizenid=, name= }, or nil. Fully server-side: positions come from
-- each ped's server entity, never a client-supplied target or coordinate, so
-- /id cannot be pointed at someone the officer is not actually standing with.
--
-- DUPLICATION, DELIBERATE: palm6_seizure/bridge/sv_framework.lua:43-60 has the
-- same function. Bridges are per-resource by house rule (§3, the bridge is the
-- ONLY file a GTA VI port rewrites), so sharing one across resources would
-- create exactly the cross-resource native dependency the pattern exists to
-- prevent. Kept structurally identical on purpose - if one is ever fixed, fix
-- both. The only difference is the added `name` field this resource's reply
-- needs.
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
    return { src = bestSrc, citizenid = Bridge.GetCitizenId(bestSrc), name = Bridge.GetPlayerName(bestSrc) }
end

-- Metres between two online sources, or nil when either ped is unavailable.
-- Server-read on both ends (OneSync makes this authoritative).
function Bridge.DistanceBetween(a, b)
    local pa, pb = GetPlayerPed(a), GetPlayerPed(b)
    if not pa or pa == 0 or not pb or pb == 0 then return nil end
    return #(GetEntityCoords(pa) - GetEntityCoords(pb))
end

-- Resolve a command argument into a citizenid + display name. The argument is
-- either an ONLINE player's server id (all digits, matching a connected
-- character) or a citizenid string (online or offline). Returns citizenid,
-- name on success, or nil, nil when no such citizen can be found. Read-only.
--
-- Ported from palm6_rapsheet/bridge/sv_framework.lua:85-105 (same per-resource
-- bridge reasoning as NearestPlayer above). This is what lets /warrant and
-- /book take the server id an officer can actually SEE next to a player's
-- name, instead of only a raw citizenid they have no in-game way to learn.
function Bridge.ResolveTarget(arg)
    arg = tostring(arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if arg == '' then return nil, nil end

    -- Try an online player server id first (only if the input is all digits
    -- AND a live character sits on that id, so a numeric citizenid still
    -- falls through to the citizenid lookup below).
    if arg:match('^%d+$') then
        local pid = tonumber(arg)
        local p = getPlayer(pid)
        if p and p.PlayerData and p.PlayerData.citizenid then
            return p.PlayerData.citizenid, Bridge.GetPlayerName(pid)
        end
    end

    -- Otherwise treat the raw string as a citizenid (name resolves online or
    -- offline via the players table).
    local name = Bridge.GetCitizenName(arg)
    if name then return arg, name end
    return nil, nil
end

-- Registered owner of a plate, as { citizenid=, name= }, or nil when the plate
-- is on no player_vehicles row (an NPC car, or a plate that never existed).
-- player_vehicles is FRAMEWORK schema, which is why this read lives in the
-- bridge next to the `players` read GetCitizenName already does.
function Bridge.GetPlateOwner(plate)
    local row
    pcall(function()
        row = MySQL.single.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate })
    end)
    if not row or not row.citizenid then return nil end
    return { citizenid = row.citizenid, name = Bridge.GetCitizenName(row.citizenid) or 'Unknown citizen' }
end

-- Server source for an online character, or nil.
function Bridge.GetSourceByCitizenId(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

-- The qbx_police_overrides GetMDT() contract, or nil when that resource
-- isn't running (caller falls back to Config.MDTDefaults).
function Bridge.GetMDTContract()
    if GetResourceState('qbx_police_overrides') ~= 'started' then return nil end
    local ok, mdt = pcall(function() return exports.qbx_police_overrides:GetMDT() end)
    return ok and type(mdt) == 'table' and mdt or nil
end

-- Subscribe to the recipe's central police-alert funnel
-- (police:server:policeAlert — houserobbery/storerobbery/counterfeit/
-- witnesses all flow through it).
-- handler(text, src|nil, coords|nil, serverRaised: boolean).
-- Net-registered because storerobbery-style producers trigger it FROM
-- the client. `source` is the CitizenFX-resolved sender of this net event
-- and cannot be spoofed by the client; the `playerSource` payload argument
-- CAN — a modified client can TriggerServerEvent this directly with any
-- value it likes. We now trust `source` first whenever this fired from a
-- real client (source ~= 0), and only fall back to the payload value when
-- source == 0 (a trusted server-side resource raised this internally via
-- TriggerEvent and resolved the player itself). Getting this backwards let
-- a modified client frame another citizen in the persistent /calls log and
-- burn that citizen's alert cooldown — this resource is the first consumer
-- to persist this event's attribution to a queryable police record, so the
-- recipe's looser handling of it is not safe to inherit here.
--
-- Attribution was the first half of the problem; PROVENANCE is the second.
-- This handler validated WHO the alert was about but never surfaced WHO RAISED
-- IT, so a row written from a modified client's TriggerServerEvent was
-- indistinguishable in the police log from a real dispatch. That is a
-- CREDIBILITY problem, not a volume one: the volume is already bounded
-- elsewhere (palm6_eventguard budgets this event key for client raises, and
-- palm6_mdt's own Config.Calls.PerSourceCdSec floors the insert rate), so
-- "unlimited fabricated rows" was never on the table.
--
-- The fourth handler argument answers the credibility question: `serverRaised`
-- is true only when this fired from a trusted server-side resource (a plain
-- TriggerEvent inside the server VM), false when a real client raised it
-- across the net boundary. The consumer decides what a client-raised alert may
-- do - palm6_mdt logs it and stamps it `unverified` rather than dropping it,
-- because the qbx robberies raise this client-side by design - and here we
-- only report the fact, because "who raised it" is a transport question and
-- transport questions belong to the bridge.
--
-- The server-call test is copied from the OTHER consumer of this exact event,
-- palm6_witnesses/server/main.lua:483-497, which reasoned it out
-- independently: a server-side raise shows up as nil, <= 0, OR 65535. The old
-- test here missed 65535 and would have treated a server raise as a client
-- one, which would have mis-stamped a REAL dispatch call as unverified (and,
-- with Config.Calls.RequireServerProvenance flipped on, dropped it outright).
-- Two consumers of one event must not disagree about what its source means, so
-- they now use the same predicate.
function Bridge.OnPoliceAlert(handler)
    RegisterNetEvent('police:server:policeAlert', function(text, _camId, playerSource)
        -- Named once so the attribution branch and the provenance flag below
        -- can never drift apart.
        local invoker = tonumber(source)
        local fromNet = not (invoker == nil or invoker <= 0 or invoker == 65535)
        local src
        if fromNet then
            src = invoker
        else
            src = tonumber(playerSource)
            -- 65535 is the server sentinel here too, not a player id.
            if src == 0 or src == 65535 then src = nil end
        end
        local coords
        if src then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                coords = { x = c.x, y = c.y, z = c.z }
            end
        end
        handler(tostring(text or ''), src, coords, not fromNet)
    end)
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating — job, tablet item, cooldowns —
-- happens server-side in the handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
