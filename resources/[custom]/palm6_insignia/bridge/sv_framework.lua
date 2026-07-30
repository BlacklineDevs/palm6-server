-- ============================================================================
-- palm6_insignia/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY server file in this resource that calls
-- qbx_core or a server-side native. server/main.lua calls Bridge.* only, so
-- its logic ports to GTA VI by rewriting THIS FILE (house §3, the bridge
-- pattern - same shape as palm6_mdt and palm6_pd_life).
--
-- Every qbx_core touch is pcall-wrapped. If qbx_core is stopped, restarting or
-- mid-crash, every getter here returns nil and the resource degrades to "no
-- officer has an identity" rather than throwing on a hot path.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Full server-derived identity for a source, or nil.
--
-- EVERY field here comes from the framework, never from the client. This is
-- the whole integrity of the feature: a modified client cannot send its own
-- name, rank or job, so it cannot wear someone else's identity.
--
-- Returns:
--   { citizenid, first, last, job, grade, gradeName, onduty }
function Bridge.GetIdentity(src)
    local p = getPlayer(src)
    local pd = p and p.PlayerData
    if not pd or not pd.job then return nil end
    local ci = pd.charinfo or {}
    local grade = pd.job.grade or {}
    return {
        citizenid = pd.citizenid,
        first     = ci.firstname,
        last      = ci.lastname,
        job       = pd.job.name,
        grade     = tonumber(grade.level) or 0,
        gradeName = grade.name,
        onduty    = pd.job.onduty == true,
    }
end

-- Is this source a police officer at all (any duty state)? Badge allocation
-- keys on job MEMBERSHIP, because an officer keeps their number off duty.
function Bridge.IsPolice(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.PoliceJob
end

-- Does this source hold the badge-override ACE? Console (src 0) always does,
-- matching palm6_pd_life/bridge/sv_framework.lua:46-48.
function Bridge.IsAdmin(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Every connected source, as numbers.
function Bridge.GetPlayers()
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        out[#out + 1] = tonumber(sid)
    end
    return out
end

-- Server source for an online character, or nil. Copied in shape from
-- palm6_mdt/bridge/sv_framework.lua:191-200 (bridges are per-resource by house
-- rule, so this is a deliberate duplicate rather than a cross-resource call).
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

-- Sources within maxDist metres of `src`, nearest first, capped at `limit`.
--
-- Fully server-side: positions come from each ped's server entity (OneSync
-- makes this authoritative), never a client-supplied target or coordinate. So
-- /badge cannot be pointed at someone the officer is not actually standing
-- with, and it cannot be used as a map-wide broadcast.
function Bridge.NearbyPlayers(src, maxDist, limit)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return {} end
    local origin = GetEntityCoords(ped)

    local hits = {}
    for _, sid in ipairs(GetPlayers()) do
        sid = tonumber(sid)
        if sid ~= src then
            local sp = GetPlayerPed(sid)
            if sp and sp ~= 0 then
                local d = #(origin - GetEntityCoords(sp))
                if d <= maxDist then
                    hits[#hits + 1] = { src = sid, dist = d }
                end
            end
        end
    end

    table.sort(hits, function(a, b) return a.dist < b.dist end)
    local out = {}
    for i = 1, math.min(#hits, limit) do out[i] = hits[i].src end
    return out
end

function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Reply to a command invoker: console gets prints, players get chat lines
-- (the palm6_perf /diag pattern, reused by palm6_mdt).
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_insignia] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 116, 178, 255 }, args = { 'INSIGNIA', line } })
        end
    end
end

-- Resolve a /setbadge argument into a citizenid, or nil.
--
-- Accepts an ONLINE player's server id (all digits AND a live character on
-- that id) or a raw citizenid. Same precedence as
-- palm6_mdt/bridge/sv_framework.lua:155-175: a numeric citizenid still falls
-- through to the citizenid path when no player sits on that server id.
--
-- The offline half reads the framework's `players` table, which is FRAMEWORK
-- schema and therefore belongs in the bridge.
function Bridge.ResolveCitizenId(arg)
    arg = tostring(arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if arg == '' then return nil end

    if arg:match('^%d+$') then
        local p = getPlayer(tonumber(arg))
        if p and p.PlayerData and p.PlayerData.citizenid then
            return p.PlayerData.citizenid
        end
    end

    local found
    pcall(function()
        local row = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { arg })
        if row and row.citizenid then found = row.citizenid end
    end)
    return found
end

-- Display name for a citizenid, online or offline, or nil. Offline path reads
-- the framework `players` table (charinfo JSON) - framework schema, so it
-- lives here next to ResolveCitizenId.
function Bridge.GetCitizenName(citizenid)
    local src = Bridge.GetSourceByCitizenId(citizenid)
    if src then
        local id = Bridge.GetIdentity(src)
        if id then
            return (('%s %s'):format(id.first or '', id.last or '')):gsub('^%s+', ''):gsub('%s+$', '')
        end
    end

    local name
    pcall(function()
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if row and row.charinfo then
            local ci = json.decode(row.charinfo)
            if type(ci) == 'table' then
                name = (('%s %s'):format(ci.firstname or '', ci.lastname or ''))
                    :gsub('^%s+', ''):gsub('%s+$', '')
            end
        end
    end)
    return name
end

-- ---------------------------------------------------------------------------
-- Framework signals.
--
-- ALL of these use AddEventHandler, never RegisterNetEvent. These names are
-- raised INSIDE the server VM by qbx_core; net-registering one would open a
-- framework-internal name to the network for every listener on the box, not
-- just ours. palm6_eventguard/config.lua:23-32 documents exactly this mistake
-- being found and fixed in two other bridges.
-- ---------------------------------------------------------------------------

function Bridge.OnPlayerLoaded(handler)
    AddEventHandler('QBCore:Server:OnPlayerLoaded', function()
        local src = source
        if src and src > 0 then handler(src) end
    end)
end

-- Primary-job change (promotion, demotion, job swap).
function Bridge.OnJobUpdate(handler)
    AddEventHandler('QBCore:Server:OnJobUpdate', function(src)
        src = tonumber(src)
        if src and src > 0 then handler(src) end
    end)
end

-- Multi-job add/remove (qbx_core:server:onGroupUpdate).
function Bridge.OnGroupUpdate(handler)
    AddEventHandler('qbx_core:server:onGroupUpdate', function(src)
        src = tonumber(src)
        if src and src > 0 then handler(src) end
    end)
end

-- Duty flip. SetJobDuty fires ONLY this pair, never OnJobUpdate, so both must
-- be hooked or an officer clocking on keeps a stale tape.
function Bridge.OnDutyChange(handler)
    AddEventHandler('QBCore:Server:SetDuty', function(src)
        src = tonumber(src)
        if src and src > 0 then handler(src) end
    end)
end

function Bridge.OnPlayerDropped(handler)
    AddEventHandler('playerDropped', function()
        local src = source
        if src and src > 0 then handler(src) end
    end)
end

-- Unrestricted chat command. ALL gating (job, ace, cooldown) happens
-- server-side in the handler, which is why `false` is correct here: a
-- RegisterCommand(..., true) with no matching add_ace line is runnable by
-- group.owner and by literally nobody else.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
