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

-- This player's world position as { x, y, z }, read SERVER-SIDE off their ped.
-- OneSync makes that authoritative, so it is never a client-supplied
-- coordinate. Used by the wardrobe's "move it to where I am standing" action,
-- which is the only way a new wardrobe position ever enters this resource.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    if not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end

-- ---------------------------------------------------------------------------
-- THE STATION POINT. Read, never invented.
--
-- qbx_police_overrides already owns where the police station is. It publishes
-- Config.DutyToggle (qbx_police_overrides/config.lua:61-65, the 'Mission Row PD
-- - Duty' point, radius 1.0) through an export at
-- qbx_police_overrides/server/overrides.lua:45.
--
-- The coordinate itself is DELIBERATELY not repeated here. It appears exactly
-- once in this resource, as Config.Wardrobe.FallbackCoords in
-- shared/config.lua, with the full citation next to it. One place to look, one
-- place to correct, and a test that can prove there is only one
-- (tests/suites/12_uniform_wardrobe_menu.lua).
--
-- palm6_pd_life reads that same export the same way, for the same stated
-- reason, at palm6_pd_life/bridge/sv_framework.lua:72-83: reading it means no
-- resource here has to author a world coordinate, and if the station ever
-- moves, it moves in one file and everything downstream follows.
--
-- The export is SERVER realm (qbx_police_overrides declares no client script),
-- which is why this lives here and the point is pushed out to clients rather
-- than read by them.
--
-- Returns point, sourceDescription  or  nil, whyNot. The caller falls back to
-- Config.Wardrobe.FallbackCoords, which is a verbatim copy of the coords line
-- above, and reports which of the two it used.
-- ---------------------------------------------------------------------------
local POLICE_CONFIG_RESOURCE = 'qbx_police_overrides'

function Bridge.GetStationPoint()
    if GetResourceState(POLICE_CONFIG_RESOURCE) ~= 'started' then
        return nil, POLICE_CONFIG_RESOURCE .. ' is not started'
    end
    local ok, dt = pcall(function() return exports.qbx_police_overrides:GetDutyToggle() end)
    if not ok or type(dt) ~= 'table' then
        return nil, POLICE_CONFIG_RESOURCE .. ':GetDutyToggle() did not answer with a table'
    end
    local c = dt.coords
    if type(c) ~= 'table' and type(c) ~= 'vector3' then
        return nil, POLICE_CONFIG_RESOURCE .. ':GetDutyToggle() carried no coords'
    end
    -- vector3 and a plain {x,y,z} table both answer .x/.y/.z, so one read
    -- covers however the export survives msgpack across the resource boundary.
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) then
        return nil, POLICE_CONFIG_RESOURCE .. ':GetDutyToggle() coords were not numeric'
    end
    return
        { x = x, y = y, z = z, radius = tonumber(dt.radius) or 0.0 },
        ('%s:GetDutyToggle() ("%s")'):format(POLICE_CONFIG_RESOURCE, tostring(dt.label or 'no label'))
end

-- The real police rank names, read from the same resource that owns them
-- (qbx_police_overrides/config.lua:13-19, published at
-- qbx_police_overrides/server/overrides.lua:40). Used to label the wardrobe's
-- capture choices, so an admin picks "Sergeant" from a list instead of typing
-- a grade number. Returns a level-sorted array of { level, name }, or nil when
-- the roster cannot be read - in which case the caller says so and falls back
-- to bare grade numbers rather than inventing rank names.
function Bridge.GetGradeRoster()
    if GetResourceState(POLICE_CONFIG_RESOURCE) ~= 'started' then return nil end
    local ok, grades = pcall(function() return exports.qbx_police_overrides:GetGrades() end)
    if not ok or type(grades) ~= 'table' then return nil end
    local out = {}
    for level, info in pairs(grades) do
        local lv = tonumber(level)
        if lv and lv >= 0 and lv == math.floor(lv) then
            local name = (type(info) == 'table' and type(info.name) == 'string' and info.name ~= '')
                and info.name or ('Grade ' .. tostring(math.floor(lv)))
            out[#out + 1] = { level = math.floor(lv), name = name }
        end
    end
    if #out == 0 then return nil end
    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

-- ox_lib server callback registration. ox_lib is a declared dependency and is
-- loaded via @ox_lib/init.lua in the manifest, so `lib` is present; the guard
-- is here so that a broken load surfaces as a named console line instead of a
-- resource that starts and then silently answers no menu requests. Same call
-- shape as palm6_fc_hud/server/main.lua:19.
function Bridge.RegisterCallback(name, fn)
    if not (lib and lib.callback and lib.callback.register) then
        print(('^1[palm6_uniform] ox_lib callbacks are unavailable, so the wardrobe menu ("%s") cannot be served. The chat commands still work.^0'):format(name))
        return false
    end
    lib.callback.register(name, fn)
    return true
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
