-- ============================================================================
-- palm6_uniform/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY server file in this resource that calls
-- qbx_core, a weather resource, or a server-side native. server/main.lua calls
-- Bridge.* and nothing else, so the whole selection engine ports to GTA VI by
-- rewriting THIS file. Same shape as palm6_pd_life and palm6_citations.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- ---------------------------------------------------------------------------
-- IDENTITY. This is the server authority the whole design rests on.
--
-- The client never sends its job, its grade, its gender or its badge number.
-- It sends "I would like my uniform" and this function is what answers who
-- "my" is. A modified client cannot promote itself, because nothing it says
-- reaches this table.
-- ---------------------------------------------------------------------------
function Bridge.GetPoliceIdentity(src)
    local p = getPlayer(src)
    local pd = p and p.PlayerData
    local job = pd and pd.job
    if not job then return nil end
    local ci = pd.charinfo or {}
    return {
        citizenid = pd.citizenid,
        job       = job.name,
        onduty    = job.onduty == true,
        grade     = (job.grade and tonumber(job.grade.level)) or 0,
        gradeName = (job.grade and job.grade.name) or '',
        first     = ci.firstname or '',
        last      = ci.lastname or '',
    }
end

function Bridge.IsPolice(src)
    local id = Bridge.GetPoliceIdentity(src)
    return id ~= nil and id.job == Config.PoliceJob
end

-- ---------------------------------------------------------------------------
-- WHICH BODY. Read SERVER-SIDE off the player's actual ped, never taken from
-- the client, and never inferred from charinfo.gender.
--
-- There are three disagreeing sources of "gender" on a Qbox box: the integer
-- in charinfo, the framework's string getter, and the ped model. Only the
-- last one is the thing a drawable index actually belongs to, so it is the
-- only one this resource will use. Returns a model NAME or nil when the ped
-- is not one of the two freemode models (a custom ped cannot carry a freemode
-- capture and must be refused, not guessed at).
-- ---------------------------------------------------------------------------
function Bridge.GetPedModelName(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local model = GetEntityModel(ped)
    if not model or model == 0 then return nil end
    for _, name in ipairs(Config.Models) do
        if model == GetHashKey(name) then return name end
    end
    return nil
end

-- Does this source hold the admin ACE? Console (src 0) always does, matching
-- palm6_mapeditor and palm6_pd_life. Note the console has no ped, so the
-- capture command still refuses src 0 further up: holding the ACE is not the
-- same as being able to be photographed.
function Bridge.IsAdmin(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Does a PRINCIPAL (a group, not a connected player) hold an ACE? Used once,
-- at boot, to answer the question the headless audit structurally cannot: the
-- audit's command-aces check only reconciles RESTRICTED commands against
-- grants, and every command here is registered unrestricted, so a missing
-- `add_ace group.admin command.uniformcapture allow` passes every static gate
-- and then locks every admin out in game with no clue why.
--
-- IsPrincipalAceAllowed is the server-side counterpart of IsPlayerAceAllowed
-- and takes a principal string rather than a source. It READS the ACE table;
-- it cannot grant anything. Nothing in this resource can, and nothing in this
-- resource should: custom.cfg is the only authority for grants.
function Bridge.PrincipalHasAce(principal, ace)
    local ok, allowed = pcall(function()
        return IsPrincipalAceAllowed(principal, ace)
    end)
    return ok and allowed == true
end

-- ---------------------------------------------------------------------------
-- WEATHER. Soft by construction: neither weather resource is in this repo, so
-- absence must degrade to "no bucket", never to an error. Returns the raw
-- weather NAME string (e.g. 'EXTRASUNNY') or nil.
-- ---------------------------------------------------------------------------
function Bridge.GetWeatherName()
    for _, res in ipairs(Config.WeatherResources) do
        if GetResourceState(res) == 'started' then
            local ok, w = pcall(function() return exports[res]:getWeatherState() end)
            if ok and type(w) == 'string' and w ~= '' then
                return w:upper()
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- REACTIVE HOOKS. All AddEventHandler, never RegisterNetEvent.
--
-- qbx_core raises these server-side with TriggerEvent, so AddEventHandler is
-- sufficient. RegisterNetEvent would additionally make a framework-internal
-- name network-addressable for EVERY listener on the box, which is exactly
-- the hole palm6_eventguard/config.lua documents being closed in
-- palm6_whitelist_jobs and palm6_onboarding. Do not "fix" these to
-- RegisterNetEvent.
--
-- The explicit first argument wins over the ambient `source`: a raise from
-- inside the server VM surfaces as nil, <= 0, or 65535, which is this repo's
-- own server-raise predicate (see palm6_eventguard/server/main.lua guard()).
-- ---------------------------------------------------------------------------
local function resolveSrc(evtSrc)
    local s = tonumber(evtSrc)
    if not s or s <= 0 or s == 65535 then s = source end
    return tonumber(s)
end

-- Promotion / demotion / primary-job change. handler(src, jobName, grade).
function Bridge.OnJobChanged(handler)
    AddEventHandler('QBCore:Server:OnJobUpdate', function(evtSrc, jobInfo)
        local src = resolveSrc(evtSrc)
        if not src or src <= 0 then return end
        local grade = jobInfo and jobInfo.grade and tonumber(jobInfo.grade.level) or nil
        handler(src, jobInfo and jobInfo.name or nil, grade)
    end)
end

-- Multi-job add / remove. handler(src, jobName, grade).
function Bridge.OnGroupChanged(handler)
    AddEventHandler('qbx_core:server:onGroupUpdate', function(evtSrc, jobName, grade)
        local src = resolveSrc(evtSrc)
        if not src or src <= 0 then return end
        handler(src, jobName, tonumber(grade))
    end)
end

-- Duty toggle. handler(src, onduty). SetJobDuty fires ONLY this pair and
-- never OnJobUpdate, which is why both hooks exist.
function Bridge.OnDutyChanged(handler)
    AddEventHandler('QBCore:Server:SetDuty', function(evtSrc, onduty)
        local src = resolveSrc(evtSrc)
        if not src or src <= 0 then return end
        handler(src, onduty == true)
    end)
end

-- Every connected source whose job is police. `dutyOnly` narrows it to the
-- ones actually on duty, which is what the season/weather tick re-dresses.
function Bridge.GetPolicePlayers(dutyOnly)
    local out = {}
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        if src then
            local id = Bridge.GetPoliceIdentity(src)
            if id and id.job == Config.PoliceJob and ((not dutyOnly) or id.onduty) then
                out[#out + 1] = src
            end
        end
    end
    return out
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Same rule as Game.Notify on the client: if ox_lib is not running, this falls
-- back to a chat line instead of going quiet. Every message this resource sends
-- is either a confirmation that something worked or an explanation of why it
-- did not, and both are useless if the transport silently drops them.
function Bridge.Notify(src, msg, t)
    if not src or src <= 0 then return end
    if GetResourceState('ox_lib') == 'started' then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Uniform', description = msg, type = t or 'inform',
        })
        return
    end
    Bridge.Reply(src, { msg })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_uniform] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 120, 170, 255 }, args = { 'Uniform', line } })
        end
    end
end

-- Unrestricted chat command. Every gate (ACE, police, rate limit) runs
-- server-side inside the handler; see Config.AdminAce for why restricted =
-- false is the right call here and not laziness.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
