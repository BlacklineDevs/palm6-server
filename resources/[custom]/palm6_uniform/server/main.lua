-- ============================================================================
-- palm6_uniform/server/main.lua
--
-- Pure logic plus this resource's own SQL. Every framework, ACE, weather and
-- native read goes through Bridge.* (bridge/sv_framework.lua).
--
-- THE AUTHORITY MODEL, stated once so it does not have to be re-derived from
-- the code below:
--
--   The client can say exactly two things: "here is a photograph of the ped I
--   am standing in, taken against the token you just gave me", and "please
--   dress me". It cannot say which job it has, which grade it holds, which
--   body it is wearing, what the season is, or which uniform it wants.
--
--   This file answers all of those from qbx_core and from the server clock. A
--   modified client that shouts "apply the captain uniform" gets whatever its
--   real grade is entitled to, which for a civilian is nothing at all.
-- ============================================================================

local lastAction = {}    -- [src] = { [key] = unix ts }
local pending    = {}    -- [src] = { token, mode, grade, season, weather, label, at }
-- [src] = true once THIS resource has dressed that source. It is the gate on
-- the restore path: without it, QBCore:Server:OnJobUpdate (which fires for
-- every job change on the box, not just police ones) would send a restore
-- event to civilians switching between mechanic and taxi. The client would
-- ignore it, but "the client ignores it" is not the same as never touching a
-- non-police player, and the second is what was asked for.
local dressed    = {}
local sets       = {}    -- cached rows from palm6_uniform_sets
local schemaOk   = false
local lastVariant = nil  -- 'season|weather' pair as of the last tick

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_uniform] ' .. msg) end
end

-- Per-source, per-key cooldown. The resource's own limit, running inside the
-- handler. The palm6_eventguard budgets requested in README.md run BEFORE the
-- handler and are a blunter outer bound; neither replaces the other.
--
-- Returns allowed, secondsLeft. Callers use rlGate below rather than this
-- directly, because a rate limit that refuses in silence is worse than no rate
-- limit at all: the command looks broken, and the person on the other end
-- reports it as a bug and stops testing.
local function rl(src, key)
    if src == 0 then return true, 0 end
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    local ready = (lastAction[src][key] or 0) + window
    if ready > t then return false, ready - t end
    lastAction[src][key] = t
    return true, 0
end

-- HOW THIS RESOURCE REFUSES A RATE LIMIT: out loud, by name, with the number of
-- seconds left. Every command goes through here.
--
-- There is exactly ONE bare `if not rl(...) then return end` left in this file,
-- on the client's automatic `requestApply` spawn event, and the reason it stays
-- silent is written above it: nobody typed that, so nobody is waiting on an
-- answer, and replying to it would hand a modified client a way to spam its own
-- chat. Every other call site uses rlGate.
--
-- The bug this replaces was real and it was in the documented workflow:
-- /uniformshow and /uniformcapture shared one 3-second key, the README told
-- you to run them one after the other, and the capture was therefore dropped
-- with no output whatsoever. Two things fix that, and both are in: the two
-- commands no longer share a key (see Config.RateLimits), and a refusal is now
-- audible.
local function rlGate(src, key, what)
    local ok, left = rl(src, key)
    if ok then return true end
    Bridge.Reply(src, {
        ('Too fast: %s is rate limited to one call every %d second(s). Try again in %d.')
            :format(what, Config.RateLimits[key] or 1, math.max(1, math.ceil(left or 1))),
    })
    return false
end

AddEventHandler('playerDropped', function()
    local src = source
    lastAction[src] = nil
    pending[src] = nil
    dressed[src] = nil
end)

local function inList(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- SCHEMA
--
-- Self-creating at boot, with the identical DDL in sql/0076_uniform.sql.
-- The number came from `node tools/audit/run.js migrations`, not from
-- `ls sql/` - palm6_dbmigrate owns 0067 and 0068-0073 with no sql/ file at
-- all, so the directory listing lies about what is free. It was 0075 until a
-- parallel build claimed that number two minutes earlier; the audit caught the
-- duplicate and this yielded. See the header of sql/0076_uniform.sql.
--
-- One row per (job, min_grade, model, season, weather). `min_grade` is an
-- inclusive FLOOR, not an exact match: an officer of grade G wears the highest
-- min_grade row that is <= G. That means capturing ONE set at grade 0 dresses
-- the entire department, and every later capture is an override for the ranks
-- above it rather than a hole that has to be filled.
-- ---------------------------------------------------------------------------
local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS `palm6_uniform_sets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job VARCHAR(50) NOT NULL,
    min_grade INT NOT NULL DEFAULT 0,
    model VARCHAR(32) NOT NULL,
    season VARCHAR(16) NOT NULL DEFAULT 'any',
    weather VARCHAR(16) NOT NULL DEFAULT 'any',
    label VARCHAR(64) NOT NULL DEFAULT '',
    components_json TEXT NOT NULL,
    props_json TEXT NOT NULL,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_uniform_sets (job, min_grade, model, season, weather),
    KEY idx_palm6_uniform_sets_lookup (job, model, min_grade)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
]]

local function ensureSchema()
    local ok, err = pcall(function() MySQL.query.await(SCHEMA_SQL) end)
    if not ok then
        schemaOk = false
        print(('^1[palm6_uniform] schema init FAILED -> %s^0'):format(tostring(err)))
        return
    end
    schemaOk = true
end

-- Load every stored set into memory. Applies happen on duty toggles,
-- promotions and a two-minute variant tick, so a cache avoids a DB read per
-- officer per tick. Refreshed on every write.
local function loadSets()
    if not schemaOk then return end
    local rows
    local ok, err = pcall(function()
        rows = MySQL.query.await('SELECT * FROM palm6_uniform_sets')
    end)
    if not ok then
        print(('^1[palm6_uniform] set load FAILED -> %s^0'):format(tostring(err)))
        return
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local okC, comps = pcall(json.decode, r.components_json or '[]')
        local okP, props = pcall(json.decode, r.props_json or '[]')
        if okC and okP and type(comps) == 'table' and type(props) == 'table' then
            out[#out + 1] = {
                id         = tonumber(r.id),
                job        = r.job,
                min_grade  = tonumber(r.min_grade) or 0,
                model      = r.model,
                season     = r.season or 'any',
                weather    = r.weather or 'any',
                label      = r.label or '',
                components = comps,
                props      = props,
            }
        else
            -- A row whose JSON will not decode is unusable. Say so loudly
            -- rather than silently dressing nobody: a broken-catch swallow
            -- here would look identical to "no set captured yet".
            print(('^3[palm6_uniform] set id %s has unreadable JSON and was skipped^0'):format(tostring(r.id)))
        end
    end
    sets = out
end

-- ---------------------------------------------------------------------------
-- SEASON AND WEATHER, both derived SERVER-SIDE.
--
-- See shared/config.lua for the full statement of why the season has to be
-- derived at all: GTA V and FiveM have no built-in season concept, and the
-- in-game calendar is unmanaged because the weather resources only override
-- the clock time, never the date. Config.SeasonByMonth is the schedule and
-- this is the code that reads it.
-- ---------------------------------------------------------------------------
-- RUNTIME PINS. Config.SeasonOverride / Config.WeatherOverride seed these at
-- boot and are never read again.
--
-- They exist as runtime state, and not only as config, because the config
-- route needs `restart palm6_uniform` and a restart is destructive to a live
-- test: it wipes every client's in-memory civilian snapshot and this file's
-- `dressed` table, so anybody standing there in uniform when it happens gets
-- "No civilian outfit was recorded this session" from /uniformoff and has no
-- in-game way back into their own clothes. Feel-testing the winter uniform in
-- July must not be able to strand the person doing the feel-test.
--
-- /uniformseason and /uniformweather write these. Both are admin-ACE gated and
-- neither is persisted: a real restart returns to the config defaults, which
-- is the correct behaviour for a testing pin.
local seasonPin  = nil
local weatherPin = nil

local function currentSeason()
    if seasonPin then return seasonPin end
    local m = tonumber(os.date('%m'))
    return (m and Config.SeasonByMonth[m]) or 'any'
end

local function seasonSource()
    if seasonPin then return '/uniformseason pin, runtime' end
    return 'Config.SeasonByMonth, real date, server-side'
end

local function currentWeather()
    if weatherPin then
        return weatherPin, '/uniformweather pin, runtime'
    end
    local name = Bridge.GetWeatherName()
    if not name then
        -- No weather resource on the box, or it did not answer. Everyone
        -- resolves to 'any' and wears the season set. That is a degrade, not
        -- a failure, and /uniformstatus reports it as one.
        return 'any', 'no weather resource'
    end
    return (Config.WeatherBuckets[name] or 'any'), name
end

-- ---------------------------------------------------------------------------
-- SELECTION. Given a real officer, which stored set is theirs?
--
-- RANK DOMINATES SEASON, on purpose. A sergeant in a season with no sergeant
-- set captured wears the sergeant's all-season set, not the rookie's winter
-- coat. Dressing an officer below their rank is a worse error than dressing
-- them for the wrong weather, and it is the error David would notice first.
--
-- Within one rank, the more specific variant wins: an exact season+weather
-- match beats a season-only match beats an all-purpose set.
--
-- Returns the row, or nil plus a human-readable reason. There is no partial
-- answer and no default garment: if nothing matches, nothing is applied.
-- ---------------------------------------------------------------------------
local function pickSet(job, grade, model, season, weather)
    local best, bestScore
    local sawJobModel = false
    for i = 1, #sets do
        local s = sets[i]
        if s.job == job and s.model == model then
            sawJobModel = true
            if s.min_grade <= grade then
                -- 2 = exact match, 1 = the 'any' fallback, 0 = wrong variant.
                local seasonScore  = (s.season == season) and 2 or ((s.season == 'any') and 1 or 0)
                local weatherScore = (s.weather == weather) and 2 or ((s.weather == 'any') and 1 or 0)
                if seasonScore > 0 and weatherScore > 0 then
                    -- min_grade is weighted far above the variant scores so it
                    -- can never be outvoted by a more specific lower rank.
                    local score = (s.min_grade * 100) + (seasonScore * 10) + weatherScore
                    if bestScore == nil or score > bestScore then
                        best, bestScore = s, score
                    end
                end
            end
        end
    end
    if best then return best end
    if not sawJobModel then
        return nil, ('no uniform has been captured for %s on %s'):format(job, model)
    end
    return nil, ('no uniform captured for %s grade %d on %s in season %s / weather %s')
        :format(job, grade, model, season, weather)
end

-- ---------------------------------------------------------------------------
-- APPLY. The single door every automatic and manual dress-up goes through.
--
-- `requireDuty` is true for every AUTOMATIC path (duty toggle, promotion,
-- spawn, variant tick) and false only for the officer's own /uniform command.
-- Either way the job check is unconditional: a player whose server-side job is
-- not Config.PoliceJob never reaches TriggerClientEvent.
-- ---------------------------------------------------------------------------
local function applyTo(src, why, requireDuty, quiet)
    if not Config.Enabled then return false, 'disabled' end
    if not src or src <= 0 then return false, 'no player' end

    local id = Bridge.GetPoliceIdentity(src)
    if not id or id.job ~= Config.PoliceJob then
        -- The hard non-police gate. Nothing below this line can run for a
        -- civilian, an EMS unit, or a mechanic.
        return false, 'not police'
    end
    if requireDuty and not id.onduty then
        return false, 'off duty'
    end

    local model = Bridge.GetPedModelName(src)
    if not model then
        if not quiet then
            Bridge.Notify(src, 'Your character is not a standard freemode ped, so a captured uniform cannot be applied to it.', 'error')
        end
        return false, 'unsupported ped model'
    end

    local season = currentSeason()
    local weather = currentWeather()
    local row, reason = pickSet(id.job, id.grade, model, season, weather)
    if not row then
        -- NEVER a half set and never a stand-in. Say what is missing so the
        -- fix is obvious: run /uniformcapture for that rank on that body.
        if not quiet then
            Bridge.Notify(src, reason, 'error')
        end
        dbg(('apply skipped for %d (%s): %s'):format(src, why, reason))
        return false, reason
    end

    dbg(('apply %d (%s): set %d "%s" grade>=%d %s %s/%s')
        :format(src, why, row.id, row.label, row.min_grade, row.model, row.season, row.weather))

    TriggerClientEvent('palm6_uniform:apply', src, {
        id         = row.id,
        label      = ('%s (%s / %s)'):format(row.label ~= '' and row.label or 'uniform', row.season, row.weather),
        model      = row.model,
        components = row.components,
        props      = row.props,
    })
    dressed[src] = true
    return true
end

-- Put the officer's own clothes back. Refuses to send anything to a source
-- this resource has not dressed, so a civilian changing jobs never receives a
-- packet from here at all.
local function restoreFor(src)
    if not Config.Enabled then return end
    if not src or src <= 0 then return end
    if not dressed[src] then return end
    dressed[src] = nil
    TriggerClientEvent('palm6_uniform:restore', src)
end

-- ---------------------------------------------------------------------------
-- CAPTURE PAYLOAD VALIDATION.
--
-- REJECT, never clamp. A payload outside these bounds means a modified client,
-- and repairing it would persist a fabricated garment as if David had worn it.
-- Returns cleaned components, cleaned props, or nil plus the reason.
-- ---------------------------------------------------------------------------
local function validateCapture(payload)
    if type(payload) ~= 'table' then return nil, nil, 'payload is not a table' end
    if not inList(Config.Models, payload.model) then
        return nil, nil, 'unknown ped model'
    end

    local rawC, rawP = payload.components, payload.props
    if type(rawC) ~= 'table' or type(rawP) ~= 'table' then
        return nil, nil, 'components or props missing'
    end
    if #rawC > #Config.ComponentIds then return nil, nil, 'too many components' end
    if #rawP > #Config.PropIds then return nil, nil, 'too many props' end

    local comps, seen = {}, {}
    for i = 1, #rawC do
        local c = rawC[i]
        if type(c) ~= 'table' then return nil, nil, 'malformed component row' end
        local cid = tonumber(c.component_id)
        local dr  = tonumber(c.drawable)
        local tx  = tonumber(c.texture)
        if cid == nil or dr == nil or tx == nil then return nil, nil, 'non-numeric component field' end
        cid, dr, tx = math.floor(cid), math.floor(dr), math.floor(tx)
        if not inList(Config.ComponentIds, cid) then return nil, nil, ('component id %d is not a ped component slot'):format(cid) end
        if seen[cid] then return nil, nil, ('component id %d appears twice'):format(cid) end
        if dr < -1 or dr >= Config.MaxDrawable then return nil, nil, ('component %d drawable out of range'):format(cid) end
        if tx < 0 or tx >= Config.MaxTexture then return nil, nil, ('component %d texture out of range'):format(cid) end
        seen[cid] = true
        comps[#comps + 1] = { component_id = cid, drawable = dr, texture = tx }
    end

    local props, seenP = {}, {}
    for i = 1, #rawP do
        local p = rawP[i]
        if type(p) ~= 'table' then return nil, nil, 'malformed prop row' end
        local pid = tonumber(p.prop_id)
        local dr  = tonumber(p.drawable)
        local tx  = tonumber(p.texture)
        if pid == nil or dr == nil or tx == nil then return nil, nil, 'non-numeric prop field' end
        pid, dr, tx = math.floor(pid), math.floor(dr), math.floor(tx)
        if not inList(Config.PropIds, pid) then return nil, nil, ('prop id %d is not a ped prop slot'):format(pid) end
        if seenP[pid] then return nil, nil, ('prop id %d appears twice'):format(pid) end
        if dr < -1 or dr >= Config.MaxDrawable then return nil, nil, ('prop %d drawable out of range'):format(pid) end
        if tx < -1 or tx >= Config.MaxTexture then return nil, nil, ('prop %d texture out of range'):format(pid) end
        seenP[pid] = true
        props[#props + 1] = { prop_id = pid, drawable = dr, texture = tx }
    end

    -- COMPLETENESS. A capture has to cover every component slot and every prop
    -- slot, or it is not a uniform, it is a uniform with holes in it.
    --
    -- The slots that are missing are simply never written on apply, so the
    -- officer keeps whatever happened to be in them: the stored row would claim
    -- to be a whole outfit and dress people in half of one. The raw-native
    -- capture path always returns all of them, so this can only trip on the
    -- optional illenium accelerator (or a fork of it) returning a shorter list.
    -- bridge/cl_game.lua rejects that case client-side too and falls back to
    -- the raw natives; this is the server-realm backstop, because the client is
    -- not evidence of anything.
    for i = 1, #Config.ComponentIds do
        local want = Config.ComponentIds[i]
        if not seen[want] then
            return nil, nil, ('capture is incomplete: component slot %d is missing (all %d slots are required)')
                :format(want, #Config.ComponentIds)
        end
    end
    for i = 1, #Config.PropIds do
        local want = Config.PropIds[i]
        if not seenP[want] then
            return nil, nil, ('capture is incomplete: prop slot %d is missing (all %d slots are required)')
                :format(want, #Config.PropIds)
        end
    end

    return comps, props, nil
end

-- ---------------------------------------------------------------------------
-- NET EVENTS. Two, both rate limited, both re-deriving every authority.
-- ---------------------------------------------------------------------------

-- The client's snapshot coming back. The token proves the server asked for it.
RegisterNetEvent('palm6_uniform:captured', function(payload)
    local src = source
    if not Config.Enabled then return end
    if not src or src <= 0 then return end
    -- A refused reply is announced, like every other refusal here. This one
    -- matters more than most: the payload is the photograph the admin just
    -- asked for, and dropping it in silence looks exactly like /uniformcapture
    -- doing nothing at all.
    if not rlGate(src, 'captureReply', 'the capture snapshot coming back from your game') then
        -- The token is consumed either way. A snapshot that arrived too fast is
        -- not going to be re-sent, so leaving a live token behind would only
        -- widen the replay window.
        pending[src] = nil
        return
    end

    local p = pending[src]
    -- Single use: consumed whether or not it validates, so a token can never
    -- be replayed.
    pending[src] = nil
    if not p then return end
    if type(payload) ~= 'table' or payload.token ~= p.token then return end
    if now() - p.at > Config.CaptureTokenTTL then
        Bridge.Reply(src, { 'That capture timed out. Run the command again.' })
        return
    end

    -- Re-derive every authority. The command already checked these, but time
    -- passed and nothing the client sent is evidence of anything.
    if not Bridge.IsAdmin(src) then
        Bridge.Reply(src, { 'You no longer hold the admin permission, so that snapshot was discarded.' })
        return
    end
    -- THE POLICE CHECK IS FOR THE WRITE PATH ONLY.
    --
    -- /uniformshow stores nothing. Requiring the police job to READ OUT what
    -- you are wearing is both unnecessary and actively misleading: the message
    -- it used to produce was "You are no longer on the police job, so nothing
    -- was stored", which is a storage error reported by a command that never
    -- stores anything. An admin off the police job would read that and conclude
    -- the read-only tool was broken.
    if p.mode ~= 'show' and not Bridge.IsPolice(src) then
        Bridge.Reply(src, { ('You are no longer on the %s job, so nothing was stored.'):format(Config.PoliceJob) })
        return
    end

    local comps, props, err = validateCapture(payload)
    if not comps then
        print(('^3[palm6_uniform] rejected capture from %d: %s^0'):format(src, tostring(err)))
        Bridge.Reply(src, { ('Capture rejected: %s'):format(err) })
        return
    end

    -- The model is confirmed against the SERVER's own read of the ped, not
    -- taken from the payload. A client cannot claim to have been standing in
    -- the other body and poison the female rows with male drawables.
    local serverModel = Bridge.GetPedModelName(src)
    if not serverModel then
        Bridge.Reply(src, { 'Your ped is not a standard freemode model, so this capture is meaningless. Switch to a freemode character.' })
        return
    end
    if serverModel ~= payload.model then
        print(('^3[palm6_uniform] model mismatch from %d: client said %s, server sees %s^0')
            :format(src, tostring(payload.model), serverModel))
        return
    end

    -- READ-ONLY mode: print the snapshot back and store nothing. This is the
    -- "prove the capture is real" tool, and it is how you tell a streamed-in
    -- ped from one that has not finished loading.
    if p.mode == 'show' then
        local lines = { ('Worn right now on %s:'):format(serverModel) }
        local nonZero = 0
        for i = 1, #comps do
            local c = comps[i]
            if c.drawable ~= 0 or c.texture ~= 0 then nonZero = nonZero + 1 end
            lines[#lines + 1] = ('  component %-2d  drawable %-4d  texture %d'):format(c.component_id, c.drawable, c.texture)
        end
        for i = 1, #props do
            local pr = props[i]
            lines[#lines + 1] = ('  prop      %-2d  drawable %-4d  texture %d'):format(pr.prop_id, pr.drawable, pr.texture)
        end
        -- The pass/fail signature, spelled out, because "a wall of zeros" and
        -- "a real reading that happens to be mostly zeros" look the same and
        -- mean different things.
        lines[#lines + 1] = ('%d of %d component slots are non-zero.'):format(nonZero, #comps)
        if nonZero == 0 then
            lines[#lines + 1] = 'EVERY slot read zero. That is almost always a ped that has not finished streaming, not a broken resource. Walk twenty metres, wait five seconds and run /uniformshow again before capturing anything.'
        end
        lines[#lines + 1] = 'Nothing was stored. Use /uniformcapture to store it.'
        Bridge.Reply(src, lines)
        return
    end

    if not schemaOk then
        Bridge.Reply(src, { 'The palm6_uniform_sets table is not available, so nothing was stored. Check the server console for the schema error.' })
        return
    end

    local id = Bridge.GetPoliceIdentity(src)
    local okWrite, errWrite = pcall(function()
        MySQL.query.await([[
INSERT INTO palm6_uniform_sets
    (job, min_grade, model, season, weather, label, components_json, props_json, captured_by, captured_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE
    label = VALUES(label),
    components_json = VALUES(components_json),
    props_json = VALUES(props_json),
    captured_by = VALUES(captured_by),
    captured_at = NOW()
        ]], {
            Config.PoliceJob, p.grade, serverModel, p.season, p.weather, p.label,
            json.encode(comps), json.encode(props), id and id.citizenid or nil,
        })
    end)
    if not okWrite then
        print(('^1[palm6_uniform] capture write FAILED -> %s^0'):format(tostring(errWrite)))
        Bridge.Reply(src, { 'The capture could not be saved. Check the server console.' })
        return
    end

    loadSets()
    Bridge.Reply(src, {
        ('Captured %d components and %d props for %s grade %d and up, %s, season %s, weather %s%s.')
            :format(#comps, #props, Config.PoliceJob, p.grade, serverModel, p.season, p.weather,
                    p.label ~= '' and (', labelled "' .. p.label .. '"') or ''),
        'Run /uniform to put it on, and remember to capture the same set on the other body.',
    })
end)

-- "Dress me." Raised by the client on spawn. Everything about WHICH uniform
-- that means is decided here.
RegisterNetEvent('palm6_uniform:requestApply', function()
    local src = source
    if not Config.Enabled then return end
    if not src or src <= 0 then return end
    -- The one rate limit in this resource that stays SILENT when it refuses,
    -- and the reason is that this event is not a command: the client raises it
    -- by itself on spawn, so a refusal here is not a person being told no. The
    -- client already debounces its two spawn signals against each other
    -- (client/main.lua BOOT_DEBOUNCE_MS) so that a normal join cannot reach
    -- this limit at all; anything that does get refused here is a client
    -- raising an event nobody asked for, and answering it in chat would hand a
    -- modified client a way to spam its own screen.
    if not rl(src, 'requestApply') then return end
    -- quiet = true: a civilian spawning must not be told anything, and an
    -- officer with no captured set for their rank should not be nagged on
    -- every spawn. The manual /uniform command is the loud path.
    applyTo(src, 'spawn', true, true)
end)

-- ---------------------------------------------------------------------------
-- REACTIVE HOOKS
-- ---------------------------------------------------------------------------
Bridge.OnDutyChanged(function(src, onduty)
    if not Config.Enabled then return end
    if not Bridge.IsPolice(src) then return end
    if onduty then
        if Config.ApplyOnDuty then applyTo(src, 'on duty', true, false) end
    else
        if Config.RestoreOffDuty then restoreFor(src) end
    end
end)

-- Promotion, demotion, or a primary-job change. This is the "the uniform
-- follows the rank without relogging" half.
Bridge.OnJobChanged(function(src, jobName)
    if not Config.Enabled then return end
    if jobName ~= Config.PoliceJob then
        -- They just left the police job. Put their own clothes back rather
        -- than leaving a civilian standing around in a duty jacket.
        restoreFor(src)
        return
    end
    if not Config.ApplyOnPromotion then return end
    -- Small delay: qbx_core raises the event while it is still writing the new
    -- grade, and this handler reads the grade back out of qbx_core rather than
    -- trusting the event payload. Reading a beat later is what makes the
    -- re-read authoritative instead of racy.
    SetTimeout(500, function()
        applyTo(src, 'job change', true, false)
    end)
end)

-- Multi-job add or remove. Same treatment, different event: SetJobDuty fires
-- only the duty pair and AddPlayerToJob fires only this one, so all three
-- hooks are needed to cover every way a grade can change.
Bridge.OnGroupChanged(function(src, jobName)
    if not Config.Enabled then return end
    if jobName ~= Config.PoliceJob then return end
    if not Config.ApplyOnPromotion then return end
    SetTimeout(500, function()
        applyTo(src, 'group change', true, false)
    end)
end)

-- ---------------------------------------------------------------------------
-- SEASON / WEATHER TICK
--
-- Re-derives the pair on a timer and re-dresses every ON-DUTY officer only
-- when it CHANGES. A tick where nothing moved does nothing at all, which is
-- why a two-minute interval is cheap.
-- ---------------------------------------------------------------------------
CreateThread(function()
    if not Config.Enabled then return end
    while true do
        Wait(math.max(15, Config.VariantTickSeconds) * 1000)
        local key = currentSeason() .. '|' .. currentWeather()
        if lastVariant ~= nil and key ~= lastVariant then
            local officers = Bridge.GetPolicePlayers(true)
            dbg(('variant changed %s -> %s, re-dressing %d on-duty officer(s)')
                :format(tostring(lastVariant), key, #officers))
            for _, src in ipairs(officers) do
                applyTo(src, 'season/weather change', true, true)
            end
        end
        lastVariant = key
    end
end)

-- ---------------------------------------------------------------------------
-- COMMANDS
--
-- All RegisterCommand(..., restricted = false) via Bridge.RegisterCommand, and
-- all gated inside the handler. The admin family self-checks Config.AdminAce,
-- so custom.cfg needs exactly ONE grant for the five of them (the shape
-- /placeped and /bizshell already use).
-- ---------------------------------------------------------------------------

local function adminGate(src, key, what)
    if not Config.Enabled then
        Bridge.Reply(src, { 'palm6_uniform is disabled (Config.Enabled = false).' })
        return false
    end
    if not rlGate(src, key or 'command', what or 'this command') then return false end
    if not Bridge.IsAdmin(src) then
        -- Name the ACE and the exact cfg line. A missing add_ace is invisible
        -- to every static check in this repo (the audit's command-aces check
        -- only reconciles RESTRICTED commands, and none of these are), so the
        -- denial message is the only place the real cause can surface.
        Bridge.Reply(src, {
            ('You do not have permission to do that. This command needs the "%s" ACE.'):format(Config.AdminAce),
            ('If nobody has it, custom.cfg is missing: add_ace group.admin %s allow'):format(Config.AdminAce),
        })
        return false
    end
    return true
end

-- /uniformcapture <grade> <season> <weather> [label...]
--
-- THE COMMAND THE WHOLE RESOURCE IS BUILT AROUND. David dials a look in
-- whatever clothing menu the box runs, stands still, and runs this. Whatever
-- he is wearing at that instant becomes that rank's uniform for that variant.
-- Nothing about the garment is chosen here.
Bridge.RegisterCommand('uniformcapture', function(src, args)
    if not adminGate(src, 'capture', '/uniformcapture') then return end
    if src == 0 then
        Bridge.Reply(src, { 'This command photographs the ped you are standing in, so it cannot be run from the console.' })
        return
    end
    -- Police-gated as well as ACE-gated: a uniform is captured by someone
    -- wearing the job, which also means the capture happens where the job's
    -- lockers and menus are.
    if not Bridge.IsPolice(src) then
        Bridge.Reply(src, { ('You must be on the %s job to capture a police uniform.'):format(Config.PoliceJob) })
        return
    end

    local grade   = tonumber(args[1])
    local season  = (args[2] or 'any'):lower()
    local weather = (args[3] or 'any'):lower()
    local label   = ''
    for i = 4, #args do label = (label == '' and args[i]) or (label .. ' ' .. args[i]) end
    if #label > 64 then label = label:sub(1, 64) end

    if grade == nil or grade < 0 or grade ~= math.floor(grade) then
        Bridge.Reply(src, {
            'Usage: /uniformcapture <grade> <season> <weather> [label]',
            ('  grade   a whole number, 0 or more. The set applies to that grade AND EVERY GRADE ABOVE IT until a higher capture overrides it.'),
            ('  season  %s'):format(table.concat(Config.Seasons, ' | ')),
            ('  weather %s'):format(table.concat(Config.Weathers, ' | ')),
            'Example: /uniformcapture 0 any any Patrol',
        })
        return
    end
    if not inList(Config.Seasons, season) then
        Bridge.Reply(src, { ('Unknown season "%s". Use one of: %s'):format(season, table.concat(Config.Seasons, ', ')) })
        return
    end
    if not inList(Config.Weathers, weather) then
        Bridge.Reply(src, { ('Unknown weather bucket "%s". Use one of: %s'):format(weather, table.concat(Config.Weathers, ', ')) })
        return
    end

    -- An opaque, single-use, server-minted token. The client cannot make one,
    -- so an unsolicited palm6_uniform:captured is dropped on arrival.
    local token = ('%d-%d-%d'):format(src, now(), math.random(100000, 999999))
    pending[src] = {
        token = token, mode = 'store', grade = math.floor(grade),
        season = season, weather = weather, label = label, at = now(),
    }
    TriggerClientEvent('palm6_uniform:doCapture', src, token, 'store')
    Bridge.Reply(src, { 'Photographing what you are wearing...' })
end)

-- /uniformshow - read out what you are wearing without storing it.
--
-- Read only, so it does NOT require the police job and does NOT share a rate
-- limit key with /uniformcapture. Both of those used to be true and both were
-- wrong: the shared key silently ate the capture that the README tells you to
-- run straight afterwards, and the police check produced a storage error from a
-- command that stores nothing.
Bridge.RegisterCommand('uniformshow', function(src)
    if not adminGate(src, 'show', '/uniformshow') then return end
    if src == 0 then
        Bridge.Reply(src, { 'This command reads the ped you are standing in, so it cannot be run from the console.' })
        return
    end
    local token = ('%d-%d-%d'):format(src, now(), math.random(100000, 999999))
    pending[src] = { token = token, mode = 'show', grade = 0, season = 'any', weather = 'any', label = '', at = now() }
    TriggerClientEvent('palm6_uniform:doCapture', src, token, 'show')
    Bridge.Reply(src, { 'Reading what you are wearing...' })
end)

-- /uniformscramble - change into random clothes, right now, with no clothing
-- store and no invented ids.
--
-- THIS EXISTS BECAUSE THE FIRST TEST WAS INVISIBLE. Capture the outfit you are
-- standing in, then run /uniform, and the server correctly sends you the set
-- you just captured, the client correctly writes it, and NOTHING MOVES,
-- because you were already wearing it. Both commands report success and the
-- whole resource reads as a no-op. Seeing a uniform swap needs two different
-- outfits, and this is the fast way to get the second one.
--
-- It touches ONLY the caller's own ped, it authors no drawable or texture
-- index (the engine picks from the variations it reports as valid for that
-- ped), and it puts face and hair back from a reading taken off the ped a
-- fraction of a second earlier. Admin-gated because it changes someone's
-- appearance, even if that someone is only ever themselves.
Bridge.RegisterCommand('uniformscramble', function(src)
    if not adminGate(src, 'scramble', '/uniformscramble') then return end
    if src == 0 then
        Bridge.Reply(src, { 'This command changes the clothes of the ped you are standing in, so it cannot be run from the console.' })
        return
    end
    -- Mark the source as one this resource has altered, so /uniformoff has
    -- something to do afterwards even if no uniform was ever applied.
    dressed[src] = true
    TriggerClientEvent('palm6_uniform:scramble', src)
    Bridge.Reply(src, {
        'Randomising your clothes. Face and hair are left alone.',
        'Now run /uniform: you should visibly snap into the captured uniform. /uniformoff puts back what you were wearing before this command.',
    })
end)

-- /uniformseason <any|winter|spring|summer|autumn|auto>
-- /uniformweather <any|wet|cold|hot|auto>
--
-- Runtime pins, no restart. See the seasonPin/weatherPin declaration above for
-- why a config edit is the wrong tool: `restart palm6_uniform` wipes every
-- client's civilian snapshot, so the person feel-testing a winter uniform can
-- strand themselves in it with no in-game way out. These two commands cannot
-- do that.
local function pinCommand(cmdName, label, allowed, get, set)
    Bridge.RegisterCommand(cmdName, function(src, args)
        if not adminGate(src, 'command', '/' .. cmdName) then return end
        local value = (args[1] or ''):lower()
        if value == '' then
            Bridge.Reply(src, {
                ('Usage: /%s <%s|auto>'):format(cmdName, table.concat(allowed, '|')),
                ('  auto  hand %s back to the automatic source'):format(label),
                ('Currently: %s'):format(get()),
            })
            return
        end
        if value == 'auto' then
            set(nil)
        elseif inList(allowed, value) then
            set(value)
        else
            Bridge.Reply(src, { ('Unknown %s "%s". Use one of: %s, or auto.'):format(label, value, table.concat(allowed, ', ')) })
            return
        end
        -- Re-dress every ON-DUTY officer immediately so the change is visible
        -- now rather than up to Config.VariantTickSeconds later. quiet = true:
        -- an officer with no set captured for the new variant keeps what they
        -- have on and is not nagged about it.
        local officers = Bridge.GetPolicePlayers(true)
        for _, s in ipairs(officers) do
            applyTo(s, cmdName, true, true)
        end
        lastVariant = currentSeason() .. '|' .. currentWeather()
        Bridge.Reply(src, {
            ('%s is now: %s'):format(label, get()),
            ('Re-applied to %d on-duty officer(s). If you are off duty, run /uniform to see it.'):format(#officers),
        })
    end)
end

pinCommand('uniformseason', 'season', Config.Seasons,
    function() return ('%s (%s)'):format(currentSeason(), seasonSource()) end,
    function(v) seasonPin = v end)

pinCommand('uniformweather', 'weather bucket', Config.Weathers,
    function()
        local bucket, from = currentWeather()
        return ('%s (%s)'):format(bucket, tostring(from))
    end,
    function(v) weatherPin = v end)

-- /uniformlist - every stored set, and which one YOU would get right now.
Bridge.RegisterCommand('uniformlist', function(src)
    if not adminGate(src, 'command', '/uniformlist') then return end
    if #sets == 0 then
        Bridge.Reply(src, { 'No uniforms have been captured yet. Dress a police character and run /uniformcapture 0 any any Patrol.' })
        return
    end
    local lines = { ('%d stored set(s):'):format(#sets) }
    for i = 1, #sets do
        local s = sets[i]
        lines[#lines + 1] = ('  #%-3d %-16s grade>=%-2d %s  season=%-6s weather=%-4s  %d comps / %d props')
            :format(s.id, s.label ~= '' and s.label or '(unlabelled)', s.min_grade, s.model, s.season, s.weather, #s.components, #s.props)
    end
    if src > 0 then
        local id = Bridge.GetPoliceIdentity(src)
        local model = Bridge.GetPedModelName(src)
        if id and id.job == Config.PoliceJob and model then
            local row, reason = pickSet(id.job, id.grade, model, currentSeason(), (currentWeather()))
            lines[#lines + 1] = row
                and ('You (grade %d, %s) would get set #%d.'):format(id.grade, model, row.id)
                or  ('You (grade %d, %s) would get NOTHING: %s'):format(id.grade, model, reason)
        end
    end
    Bridge.Reply(src, lines)
end)

-- /uniformdelete <id>
Bridge.RegisterCommand('uniformdelete', function(src, args)
    if not adminGate(src, 'command', '/uniformdelete') then return end
    local id = tonumber(args[1])
    if not id then
        Bridge.Reply(src, { 'Usage: /uniformdelete <id>   (ids come from /uniformlist)' })
        return
    end
    if not schemaOk then
        Bridge.Reply(src, { 'The palm6_uniform_sets table is not available.' })
        return
    end
    local affected = 0
    local ok, err = pcall(function()
        affected = MySQL.update.await('DELETE FROM palm6_uniform_sets WHERE id = ?', { id }) or 0
    end)
    if not ok then
        print(('^1[palm6_uniform] delete FAILED -> %s^0'):format(tostring(err)))
        Bridge.Reply(src, { 'Delete failed. Check the server console.' })
        return
    end
    loadSets()
    Bridge.Reply(src, { affected > 0 and ('Deleted set #%d.'):format(id) or ('No set with id %d.'):format(id) })
end)

-- /uniformstatus - the meter. Season, weather, where each came from, how many
-- sets are loaded, and the client-side accelerator state.
Bridge.RegisterCommand('uniformstatus', function(src)
    if not adminGate(src, 'command', '/uniformstatus') then return end
    local bucket, source_ = currentWeather()
    local lines = {
        ('enabled=%s  schema=%s  sets=%d'):format(tostring(Config.Enabled), schemaOk and 'ok' or 'MISSING', #sets),
        ('season=%s (%s)'):format(currentSeason(), seasonSource()),
        ('weather bucket=%s (from %s)'):format(bucket, tostring(source_)),
        ('admin ACE "%s": you=%s, group.admin=%s'):format(
            Config.AdminAce,
            tostring(Bridge.IsAdmin(src)),
            tostring(Bridge.PrincipalHasAce('group.admin', Config.AdminAce))),
        ('season is a CONFIG SCHEDULE: GTA V and FiveM have no built-in season, and the in-game calendar is unmanaged. See shared/config.lua.'),
    }
    Bridge.Reply(src, lines)
    if src > 0 then TriggerClientEvent('palm6_uniform:statusLine', src) end
end)

-- /uniform - an officer asking for their own uniform. Police only. The server
-- still decides which set that is.
Bridge.RegisterCommand(Config.PlayerCommand, function(src)
    if not Config.Enabled then
        Bridge.Reply(src, { 'palm6_uniform is disabled (Config.Enabled = false).' })
        return
    end
    if src == 0 then
        Bridge.Reply(src, { 'This command dresses the caller, so it cannot be run from the console.' })
        return
    end
    if not rlGate(src, 'apply', '/' .. Config.PlayerCommand) then return end
    if not Bridge.IsPolice(src) then
        -- Deliberately the same phrasing for "not police" and "no set": a
        -- civilian probing the command learns nothing about the department.
        Bridge.Notify(src, 'You have no uniform to change into.', 'error')
        return
    end
    -- requireDuty = false: this is the officer's own explicit request.
    applyTo(src, 'manual', false, false)
end)

-- /uniformoff - back into civilian clothes.
Bridge.RegisterCommand(Config.RestoreCommand, function(src)
    if not Config.Enabled then
        Bridge.Reply(src, { 'palm6_uniform is disabled (Config.Enabled = false).' })
        return
    end
    if src == 0 then
        Bridge.Reply(src, { 'This command changes the caller\'s clothes, so it cannot be run from the console.' })
        return
    end
    if not rlGate(src, 'restore', '/' .. Config.RestoreCommand) then return end
    if not Bridge.IsPolice(src) then
        Bridge.Notify(src, 'You have no uniform to change out of.', 'error')
        return
    end
    -- Every branch below answers. The old version had three silent returns in
    -- a row, so an officer who typed /uniformoff and saw nothing could not tell
    -- a rate limit from a permission check from a resource that never dressed
    -- them in the first place.
    if not dressed[src] then
        Bridge.Notify(src, 'This resource has not changed your clothes, so there is nothing to change back.', 'inform')
        return
    end
    restoreFor(src)
end)

-- ---------------------------------------------------------------------------
-- BOOT
-- ---------------------------------------------------------------------------
CreateThread(function()
    if not Config.Enabled then
        print('^3[palm6_uniform] disabled (Config.Enabled = false)^0')
        return
    end

    -- Seed the runtime pins from config. Validated here rather than on every
    -- read, and an invalid config value is announced rather than ignored.
    if Config.SeasonOverride then
        if inList(Config.Seasons, Config.SeasonOverride) then
            seasonPin = Config.SeasonOverride
        else
            print(('^3[palm6_uniform] Config.SeasonOverride "%s" is not one of %s and was ignored^0')
                :format(tostring(Config.SeasonOverride), table.concat(Config.Seasons, ', ')))
        end
    end
    if Config.WeatherOverride then
        if inList(Config.Weathers, Config.WeatherOverride) then
            weatherPin = Config.WeatherOverride
        else
            print(('^3[palm6_uniform] Config.WeatherOverride "%s" is not one of %s and was ignored^0')
                :format(tostring(Config.WeatherOverride), table.concat(Config.Weathers, ', ')))
        end
    end

    ensureSchema()
    loadSets()
    lastVariant = currentSeason() .. '|' .. currentWeather()
    local bucket, wsrc = currentWeather()
    print(('^2[palm6_uniform]^0 ready - schema %s | %d set(s) loaded | season %s | weather bucket %s (%s) | job %s')
        :format(schemaOk and 'ok' or 'MISSING', #sets, currentSeason(), bucket, tostring(wsrc), Config.PoliceJob))

    -- THE ACE SELF-CHECK.
    --
    -- Every command in this resource is RegisterCommand(..., restricted =
    -- false) and checks Config.AdminAce inside the handler, which is the right
    -- shape but has one consequence: the repo audit's command-aces invariant
    -- only reconciles RESTRICTED commands against custom.cfg grants, so a
    -- missing add_ace line here passes every static gate in the tree and then
    -- refuses every admin in game with nothing to point at.
    --
    -- So the resource asks the ACE table directly at boot and prints the exact
    -- line that is missing. This READS permissions. It cannot and must not
    -- grant them; custom.cfg is the only authority for that.
    local missing = {}
    for _, principal in ipairs(Config.ExpectedAcePrincipals or {}) do
        if not Bridge.PrincipalHasAce(principal, Config.AdminAce) then
            missing[#missing + 1] = principal
        end
    end
    if #missing > 0 then
        print(('^1[palm6_uniform] ACE MISSING: %s cannot run the admin commands^0'):format(table.concat(missing, ', ')))
        for _, principal in ipairs(missing) do
            print(('^1[palm6_uniform]   add this line to custom.cfg:  add_ace %s %s allow^0'):format(principal, Config.AdminAce))
        end
        print('^1[palm6_uniform]   until then only group.owner (via the blanket "add_ace group.owner command allow") can run /uniformcapture, /uniformshow, /uniformlist, /uniformdelete, /uniformstatus, /uniformscramble, /uniformseason and /uniformweather.^0')
    end

    if #sets == 0 then
        print('^3[palm6_uniform] no uniforms captured yet. In game: dress a police character, then /uniformcapture 0 any any Patrol^0')
        print('^3[palm6_uniform] full 10-minute in-game procedure: resources/[custom]/palm6_uniform/CHECKLIST.md^0')
    end
end)
