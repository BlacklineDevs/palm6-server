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
-- [src] = the id of the set this resource last sent that source. Read by the
-- wardrobe menu so a uniform the officer is already wearing says so on the row
-- instead of looking like a dead button. Cleared on restore and on drop.
local wearing    = {}
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
    wearing[src] = nil
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

-- EVERY row this officer is ALLOWED to wear, not just the best one.
--
-- pickSet answers "which single set is right for right now". The wardrobe menu
-- needs the whole permitted list, because offering the season and weather
-- variants is the point of having a menu. The gate is identical and it is the
-- gate that matters: same job, same ped model, and min_grade <= this officer's
-- REAL grade as read from qbx_core. A modified client that names a captain set
-- it is not entitled to fails this test, because this list is recomputed
-- server-side on every single pick and the chosen id has to be in it.
--
-- Sorted highest rank first, then by season and weather name, so the order in
-- the menu is stable between opens.
local function allowedSets(job, grade, model)
    local out = {}
    for i = 1, #sets do
        local s = sets[i]
        if s.job == job and s.model == model and s.min_grade <= grade then
            out[#out + 1] = s
        end
    end
    table.sort(out, function(a, b)
        if a.min_grade ~= b.min_grade then return a.min_grade > b.min_grade end
        if a.season ~= b.season then return a.season < b.season end
        if a.weather ~= b.weather then return a.weather < b.weather end
        return a.id < b.id
    end)
    return out
end

-- Push one already-authorised row at one player. THE ONLY PLACE that sends
-- palm6_uniform:apply. Both the automatic path (applyTo, below) and the
-- wardrobe menu funnel through here, so the "who is dressed" and "what are
-- they wearing" bookkeeping cannot drift between the two.
--
-- This function does NOT authorise anything. Its callers do, and both of them
-- do it by re-reading the job and grade out of qbx_core immediately before
-- calling it.
local function sendSet(src, row, why)
    dbg(('apply %d (%s): set %d "%s" grade>=%d %s %s/%s')
        :format(src, tostring(why), row.id, row.label, row.min_grade, row.model, row.season, row.weather))

    TriggerClientEvent('palm6_uniform:apply', src, {
        id         = row.id,
        label      = ('%s (%s / %s)'):format(row.label ~= '' and row.label or 'uniform', row.season, row.weather),
        model      = row.model,
        components = row.components,
        props      = row.props,
    })
    dressed[src] = true
    wearing[src] = row.id
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

    sendSet(src, row, why)
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
    wearing[src] = nil
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
        'Open the station wardrobe to put it on, and remember to capture the same set on the other body.',
    })
    -- A notify AS WELL AS the chat lines, because a capture started from the
    -- wardrobe menu is a click, and the person who clicked is looking at the
    -- notify corner, not at chat. Saying it twice is cheap; saying it in a
    -- channel the clicker is not watching is how a working save reads as
    -- nothing having happened.
    Bridge.Notify(src, ('Saved "%s" as a uniform. Open the wardrobe again to put it on.')
        :format(p.label ~= '' and p.label or ('grade ' .. tostring(p.grade))), 'success')
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

-- ===========================================================================
-- THE WALK-UP WARDROBE. This is the primary interface; the commands below it
-- are the fallback.
--
-- SHAPE: the server builds the ENTIRE menu - every row, every label, every
-- greyed-out row and the plain-English reason it is greyed out - and the
-- client draws it. The client decides nothing. That is not tidiness, it is the
-- authority model: a modified client can send any action it likes and every
-- one of them is re-checked here against the job and grade read fresh out of
-- qbx_core.
--
-- THE RULE THIS SECTION IS WRITTEN TO: the menu is never blank and a click is
-- never silent. An empty wardrobe and a broken wardrobe look identical from
-- the outside, and that has already cost two sessions. So there is no code
-- path below that returns zero rows, and no action that can be refused without
-- saying, in words, what was refused and why.
-- ===========================================================================

-- Runtime wardrobe position, set only by the "move it to where I am standing"
-- action in the menu. nil means "use the real source". Deliberately NOT
-- persisted: a runtime move is a way to find the right spot without typing a
-- coordinate, and the action prints the exact vector3 line to paste into
-- Config.Wardrobe.FallbackCoords if it should survive a restart.
local wardrobePin = nil

-- Where the wardrobe is, and where that answer came from.
--
-- NOTHING HERE INVENTS A COORDINATE. In order:
--   1. a runtime move made from the menu itself, or
--   2. qbx_police_overrides:GetDutyToggle(), the resource that already owns
--      the police station's position (see Bridge.GetStationPoint), or
--   3. Config.Wardrobe.FallbackCoords, which is a verbatim copy of the coords
--      line in that same override config.
-- Returns point, sourceDescription. The source string is shown in
-- /uniformstatus and in the menu header, so "the wardrobe is in the wrong
-- place" always comes with which of the three answered.
local function wardrobePoint()
    if wardrobePin then
        return wardrobePin, 'moved at runtime from the wardrobe menu (forgotten on restart)'
    end
    local pt, from = Bridge.GetStationPoint()
    if pt then
        -- The contract's radius is an ox_target radius (1.0m). Widen it to the
        -- configured floor for a walk-up. A derived bound, not a position.
        local radius = math.max(tonumber(pt.radius) or 0.0, Config.Wardrobe.MinRadius)
        return { x = pt.x, y = pt.y, z = pt.z, radius = radius }, from
    end
    local f = Config.Wardrobe.FallbackCoords
    if not f then
        return nil, ('%s, and Config.Wardrobe.FallbackCoords is not set'):format(tostring(from))
    end
    return
        { x = f.x, y = f.y, z = f.z, radius = Config.Wardrobe.MinRadius },
        ('Config.Wardrobe.FallbackCoords, because %s'):format(tostring(from))
end

-- Send the wardrobe position to one source, or to everyone with -1.
--
-- A FAILURE IS SENT TOO. If no point could be worked out, the client is told
-- that in so many words rather than simply never hearing back, because a
-- wardrobe that never appears and a wardrobe nobody told you about are the
-- same thing from where David is standing.
local function pushWardrobe(target)
    if not Config.Wardrobe.Enabled then return end
    local pt, from = wardrobePoint()
    TriggerClientEvent('palm6_uniform:wardrobePoint', target or -1, pt and {
        x      = pt.x,
        y      = pt.y,
        z      = pt.z,
        radius = pt.radius,
        label  = Config.Wardrobe.Label,
        icon   = Config.Wardrobe.Icon,
    } or false, from)
end

-- The client asking where the wardrobe is. Raised on spawn and on resource
-- start. Rate limited but SILENT on refusal, and for the same reason the
-- requestApply limit is silent: nobody typed this, so nobody is waiting on an
-- answer, and replying would let a modified client spam its own screen. The
-- client re-asks on the next spawn either way.
RegisterNetEvent('palm6_uniform:wardrobeRequest', function()
    local src = source
    if not Config.Enabled or not Config.Wardrobe.Enabled then return end
    if not src or src <= 0 then return end
    if not rl(src, 'wardrobe') then return end
    pushWardrobe(src)
end)

-- The police rank roster, cached.
--
-- Bridge.GetGradeRoster crosses a resource boundary, and gradeName below is
-- called once per row while a menu is being built. The roster only changes
-- when qbx_police_overrides restarts, so it is read once and re-read on the
-- next menu after that resource comes back. A nil cache is retried, so a
-- roster that was not ready at boot is not written off forever.
local rosterCache = nil
local rosterCacheAt = 0
local ROSTER_CACHE_SECONDS = 60

local function gradeRoster()
    if rosterCache and (now() - rosterCacheAt) < ROSTER_CACHE_SECONDS then
        return rosterCache
    end
    rosterCache = Bridge.GetGradeRoster()
    rosterCacheAt = now()
    return rosterCache
end

-- The rank name for a grade, read from qbx_police_overrides' roster. Falls
-- back to the bare number rather than making a rank name up.
local function gradeName(level)
    local roster = gradeRoster()
    if roster then
        for i = 1, #roster do
            if roster[i].level == level then return roster[i].name end
        end
    end
    return ('grade %d'):format(level)
end

-- The label a menu-driven capture is stored under. Built from the real rank
-- name plus the variant, so an admin never types a label either.
local function composeLabel(grade, season, weather)
    local label = gradeName(grade)
    if season ~= 'any' then label = label .. ' ' .. season end
    if weather ~= 'any' then label = label .. ' ' .. weather end
    if #label > 64 then label = label:sub(1, 64) end
    return label
end

-- The season/weather choices offered when saving a uniform. Built from
-- Config.Seasons and Config.Weathers so the menu cannot drift from what
-- validateCapture will accept, and labelled from Config.SeasonLabels /
-- Config.WeatherLabels so nothing has to be typed.
--
-- Deliberately NOT the full cartesian product. Every season crossed with every
-- weather is twenty captures per rank per body, which nobody will finish. The
-- offered set is: all-purpose, one per season, one per weather bucket.
local function captureVariants()
    local out = {}
    local function label(season, weather)
        return ('%s, %s'):format(
            Config.SeasonLabels[season] or season,
            Config.WeatherLabels[weather] or weather)
    end
    out[#out + 1] = { season = 'any', weather = 'any', title = 'Start here: ' .. label('any', 'any') }
    for i = 1, #Config.Seasons do
        local s = Config.Seasons[i]
        if s ~= 'any' then
            out[#out + 1] = { season = s, weather = 'any', title = label(s, 'any') }
        end
    end
    for i = 1, #Config.Weathers do
        local w = Config.Weathers[i]
        if w ~= 'any' then
            out[#out + 1] = { season = 'any', weather = w, title = label('any', w) }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE MENU MODEL. Every row the client will draw, decided here.
--
-- Row shape: { action, arg, title, description, icon, disabled }
--   action  what to send back on select. 'note' rows are never selectable.
--   arg     the set id for 'apply'; nil otherwise.
-- ---------------------------------------------------------------------------
local function buildMenu(src)
    local rows = {}
    local function row(t) rows[#rows + 1] = t end

    local menu = {
        title = Config.Wardrobe.Label,
        rows  = rows,
    }

    if not Config.Enabled then
        row{
            action = 'note', disabled = true, icon = 'fas fa-power-off',
            title = 'The uniform system is switched off.',
            description = 'shared/config.lua has Config.Enabled = false, so nothing in here can change anybody\'s clothes. This is a wardrobe that has been told to do nothing, not a broken one.',
        }
        return menu
    end

    -- The read limit, refused as a ROW rather than by refusing to open. A menu
    -- that does not appear is the failure this whole round exists to remove.
    if not rl(src, 'menu') then
        row{
            action = 'note', disabled = true, icon = 'fas fa-hourglass-half',
            title = 'Opening too fast.',
            description = ('The wardrobe answers once every %d second(s). Close this and open it again in a moment; nothing is broken.'):format(Config.RateLimits.menu or 1),
        }
        return menu
    end

    local isAdmin = Bridge.IsAdmin(src)
    local id      = Bridge.GetPoliceIdentity(src)
    local isPolice = id ~= nil and id.job == Config.PoliceJob
    local model   = Bridge.GetPedModelName(src)
    local season  = currentSeason()
    local weather = currentWeather()
    local _, pointFrom = wardrobePoint()

    menu.season  = season
    menu.weather = weather

    -- Header. Always present, always first, so the menu is never empty even in
    -- the worst case below.
    row{
        action = 'note', disabled = true, icon = 'fas fa-circle-info',
        title = ('Season: %s. Weather: %s.'):format(season, weather),
        description = ('The server picks what you are allowed to wear from your job and rank. Wardrobe position source: %s.'):format(tostring(pointFrom)),
    }

    -- ---- who is standing here -------------------------------------------
    if not isPolice then
        row{
            action = 'note', disabled = true, icon = 'fas fa-ban',
            title = 'You are not a police officer.',
            description = ('This wardrobe only dresses the "%s" job. Your job right now is "%s". Nothing in here will change your clothes until that changes.')
                :format(Config.PoliceJob, (id and id.job) or 'unknown'),
        }
        if isAdmin then
            row{
                action = 'note', disabled = true, icon = 'fas fa-user-shield',
                title = 'You are an admin, but saving a uniform still needs the police job.',
                description = ('A police uniform is captured by somebody wearing the job. Put yourself on "%s" and open this wardrobe again; the save option appears here.')
                    :format(Config.PoliceJob),
            }
        end
    elseif not model then
        row{
            action = 'note', disabled = true, icon = 'fas fa-triangle-exclamation',
            title = 'Your character is not a standard freemode ped.',
            description = 'Captured uniforms are drawable indices belonging to mp_m_freemode_01 or mp_f_freemode_01. They mean nothing on any other ped, so this wardrobe refuses rather than dressing you in the wrong thing.',
        }
    else
        -- ---- the uniforms this officer may wear --------------------------
        local list = allowedSets(id.job, id.grade, model)
        local best = pickSet(id.job, id.grade, model, season, weather)

        if #list == 0 then
            if #sets == 0 then
                -- THE EMPTY STATE. The most important screen in this resource.
                row{
                    action = 'note', disabled = true, icon = 'fas fa-shirt',
                    title = 'No uniforms have been captured yet.',
                    description = 'This wardrobe is working. It is empty. A uniform here is a photograph of an outfit somebody actually wore in game - not one clothing id is typed into the code - so until somebody captures the first one there is genuinely nothing to put on.',
                }
                if isAdmin then
                    row{
                        action = 'note', disabled = true, icon = 'fas fa-list-ol',
                        title = 'To create the first one, right here, with no typing:',
                        description = '1. dress this character however the rank should look, in whatever clothing menu the box runs. 2. come back here and pick "Save what I am wearing as a uniform". 3. pick the rank. 4. pick the conditions. That is the whole thing.',
                    }
                else
                    row{
                        action = 'note', disabled = true, icon = 'fas fa-user-shield',
                        title = 'Ask an admin to create the first one.',
                        description = ('An admin standing at this wardrobe gets a "save what I am wearing" option in this menu. It needs the "%s" permission, which is granted in custom.cfg.')
                            :format(Config.AdminAce),
                    }
                end
            else
                row{
                    action = 'note', disabled = true, icon = 'fas fa-user-slash',
                    title = ('%d uniform(s) are stored, but none of them is yours.'):format(#sets),
                    description = ('Nothing stored covers %s at %s on %s. A uniform applies to its rank AND EVERY RANK ABOVE IT, so a set captured above your rank will not reach down to you, and a set captured on the other body never applies to this one - the two freemode models have completely separate clothing indices.')
                        :format(Config.PoliceJob, gradeName(id.grade), model),
                }
            end
        else
            for i = 1, #list do
                local s = list[i]
                local notes = {}
                if best and best.id == s.id then notes[#notes + 1] = 'the automatic pick for right now' end
                if wearing[src] == s.id then notes[#notes + 1] = 'you are wearing this' end
                row{
                    action = 'apply', arg = s.id,
                    icon = 'fas fa-shirt',
                    title = (s.label ~= '' and s.label or ('Uniform #' .. tostring(s.id))),
                    description = ('%s and up | season %s | weather %s%s'):format(
                        gradeName(s.min_grade), s.season, s.weather,
                        #notes > 0 and (' | ' .. table.concat(notes, ', ')) or ''),
                }
            end
        end

        -- ---- back to my own clothes --------------------------------------
        row{
            action = 'restore', icon = 'fas fa-person',
            title = 'Back to my own clothes',
            disabled = not dressed[src],
            description = dressed[src]
                and 'Puts back whatever you had on before this wardrobe changed you. Your own clothes are never stored on the server, so this cannot overwrite your saved look.'
                or  'Greyed out because this wardrobe has not changed your clothes this session, so there is nothing to change back into.',
        }
    end

    -- ---- admin ------------------------------------------------------------
    if isAdmin then
        if isPolice and model then
            row{
                action = 'capture_menu', icon = 'fas fa-camera',
                title = 'Save what I am wearing as a uniform',
                description = ('Pick a rank, then pick the conditions. Whatever this ped has on right now becomes that uniform on %s. No typing, and no clothing id is chosen by anybody: it is a photograph.')
                    :format(model),
            }
            row{
                action = 'scramble', icon = 'fas fa-dice',
                title = 'Randomise my clothes (test tool)',
                description = 'Changes you into different clothes so a uniform swap is actually visible. Face and hair are left alone. If you capture the outfit you are already standing in and then put it on, nothing moves on screen and the whole thing reads as broken.',
            }
            row{
                action = 'show', icon = 'fas fa-magnifying-glass',
                title = 'Read out what I am wearing',
                description = 'Prints the twelve component slots and five prop slots to chat and stores nothing. If they all read zero, your ped has not finished streaming and a capture taken now would store "wearing nothing".',
            }
        end
        row{
            action = 'wardrobe_here', icon = 'fas fa-location-crosshairs',
            title = 'Move this wardrobe to where I am standing',
            description = ('Right now it is at: %s. This move lasts until the resource restarts, and it prints the exact config line to make it permanent. Use this instead of guessing a coordinate.')
                :format(tostring(pointFrom)),
        }
    end

    -- The floor. buildMenu always adds the header above, so this cannot fire
    -- today; it is here because a zero-row menu is the exact failure this
    -- section exists to prevent, and a floor that never trips costs nothing.
    if #rows == 0 then
        row{
            action = 'note', disabled = true, icon = 'fas fa-triangle-exclamation',
            title = 'This wardrobe produced no options at all.',
            description = 'That is a bug in palm6_uniform, not an empty wardrobe. Report it with what your job and rank were.',
        }
    end

    -- Data for the capture submenus. Sent whether or not the capture row is
    -- shown; the client only reads it after the row is clicked, and the server
    -- re-validates every field when the capture actually arrives.
    local roster = gradeRoster()
    menu.capture = {
        grades = roster or { { level = 0, name = 'grade 0' } },
        rosterKnown = roster ~= nil,
        variants = captureVariants(),
    }
    return menu
end

Bridge.RegisterCallback('palm6_uniform:menu', function(src)
    if not src or src <= 0 then return nil end
    return buildMenu(src)
end)

-- ---------------------------------------------------------------------------
-- MENU ACTIONS. One event, an action string, and every authority re-derived.
--
-- Every branch answers. There is no path through this handler that changes
-- nothing and says nothing.
-- ---------------------------------------------------------------------------

-- Pick a specific stored set from the wardrobe.
--
-- THE AUTHORITY CHECK IS HERE, NOT IN THE MENU. The menu is a view; a modified
-- client can send any id it likes. That id has to appear in allowedSets()
-- computed right now from the job and grade this server reads out of qbx_core,
-- so "pick the captain uniform" from a cadet is refused by name.
local function menuApply(src, setId)
    if not rlGate(src, 'apply', 'picking a uniform') then return end
    if type(setId) ~= 'number' or setId ~= math.floor(setId) then
        Bridge.Notify(src, 'That wardrobe option carried no uniform id, so nothing was applied.', 'error')
        return
    end
    local id = Bridge.GetPoliceIdentity(src)
    if not id or id.job ~= Config.PoliceJob then
        Bridge.Notify(src, ('This wardrobe only dresses the "%s" job, and yours is not it.'):format(Config.PoliceJob), 'error')
        return
    end
    local model = Bridge.GetPedModelName(src)
    if not model then
        Bridge.Notify(src, 'Your character is not a standard freemode ped, so a captured uniform cannot be applied to it.', 'error')
        return
    end
    local allowed = allowedSets(id.job, id.grade, model)
    local row
    for i = 1, #allowed do
        if allowed[i].id == setId then row = allowed[i] break end
    end
    if not row then
        Bridge.Notify(src, ('You are not allowed to wear that one. Nothing with id %d is available to %s at %s on %s. Reopen the wardrobe for the current list.')
            :format(setId, Config.PoliceJob, gradeName(id.grade), model), 'error')
        return
    end
    if wearing[src] == row.id then
        -- Not a refusal. Applying it again is harmless and the client still
        -- reports how many slots moved, which will be zero. Saying so first
        -- means the zero is expected rather than alarming.
        Bridge.Notify(src, ('You already have "%s" on. Putting it on again, so nothing will visibly change.')
            :format(row.label ~= '' and row.label or ('uniform #' .. tostring(row.id))), 'inform')
    end
    sendSet(src, row, 'wardrobe menu')
end

-- Save what this admin is wearing, driven entirely by menu choices. Same
-- engine as /uniformcapture: mint a single-use token, ask the client for a
-- photograph, and let the existing palm6_uniform:captured handler validate and
-- store it. Nothing about the garment is chosen here or there.
local function menuCapture(src, grade, season, weather)
    if not rlGate(src, 'capture', 'saving a uniform') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, ('Saving a uniform needs the "%s" permission and you do not have it. custom.cfg needs the line: add_ace group.admin %s allow')
            :format(Config.AdminAce, Config.AdminAce), 'error')
        return
    end
    if not Bridge.IsPolice(src) then
        Bridge.Notify(src, ('You must be on the "%s" job to save a police uniform.'):format(Config.PoliceJob), 'error')
        return
    end
    grade = tonumber(grade)
    if grade == nil or grade < 0 or grade ~= math.floor(grade) then
        Bridge.Notify(src, 'That rank was not a whole number, so nothing was saved.', 'error')
        return
    end
    season  = type(season) == 'string' and season:lower() or ''
    weather = type(weather) == 'string' and weather:lower() or ''
    if not inList(Config.Seasons, season) then
        Bridge.Notify(src, ('"%s" is not a season this resource knows, so nothing was saved. Known: %s.')
            :format(season, table.concat(Config.Seasons, ', ')), 'error')
        return
    end
    if not inList(Config.Weathers, weather) then
        Bridge.Notify(src, ('"%s" is not a weather bucket this resource knows, so nothing was saved. Known: %s.')
            :format(weather, table.concat(Config.Weathers, ', ')), 'error')
        return
    end
    if not schemaOk then
        Bridge.Notify(src, 'The palm6_uniform_sets table is not available, so nothing can be saved. There is a red schema error in the server console.', 'error')
        return
    end

    local token = ('%d-%d-%d'):format(src, now(), math.random(100000, 999999))
    pending[src] = {
        token = token, mode = 'store', grade = math.floor(grade),
        season = season, weather = weather,
        label = composeLabel(math.floor(grade), season, weather), at = now(),
    }
    TriggerClientEvent('palm6_uniform:doCapture', src, token, 'store')
    Bridge.Notify(src, ('Photographing what you are wearing, to be saved as "%s".'):format(pending[src].label), 'inform')
end

RegisterNetEvent('palm6_uniform:menuAction', function(action, arg1, arg2, arg3)
    local src = source
    if not src or src <= 0 then return end
    if type(action) ~= 'string' then return end
    if not Config.Enabled then
        Bridge.Notify(src, 'The uniform system is switched off (Config.Enabled = false), so that did nothing.', 'error')
        return
    end

    if action == 'apply' then
        menuApply(src, tonumber(arg1))

    elseif action == 'restore' then
        if not rlGate(src, 'restore', 'changing back into your own clothes') then return end
        if not Bridge.IsPolice(src) then
            Bridge.Notify(src, ('This wardrobe only handles the "%s" job, so it has nothing of yours to change back.'):format(Config.PoliceJob), 'error')
            return
        end
        if not dressed[src] then
            Bridge.Notify(src, 'This wardrobe has not changed your clothes, so there is nothing to change back into.', 'inform')
            return
        end
        restoreFor(src)

    elseif action == 'scramble' then
        if not rlGate(src, 'scramble', 'randomising your clothes') then return end
        if not Bridge.IsAdmin(src) then
            Bridge.Notify(src, ('That is an admin tool and needs the "%s" permission.'):format(Config.AdminAce), 'error')
            return
        end
        -- Mark the source as one this resource has altered, so "back to my own
        -- clothes" has real work to do afterwards even with no uniform applied.
        dressed[src] = true
        wearing[src] = nil
        TriggerClientEvent('palm6_uniform:scramble', src)

    elseif action == 'show' then
        if not rlGate(src, 'show', 'reading out what you are wearing') then return end
        if not Bridge.IsAdmin(src) then
            Bridge.Notify(src, ('That is an admin tool and needs the "%s" permission.'):format(Config.AdminAce), 'error')
            return
        end
        local token = ('%d-%d-%d'):format(src, now(), math.random(100000, 999999))
        pending[src] = { token = token, mode = 'show', grade = 0, season = 'any', weather = 'any', label = '', at = now() }
        TriggerClientEvent('palm6_uniform:doCapture', src, token, 'show')
        Bridge.Notify(src, 'Reading what you are wearing. The list is printed in chat.', 'inform')

    elseif action == 'capture' then
        menuCapture(src, arg1, arg2, arg3)

    elseif action == 'wardrobe_here' then
        if not rlGate(src, 'command', 'moving the wardrobe') then return end
        if not Bridge.IsAdmin(src) then
            Bridge.Notify(src, ('Moving the wardrobe needs the "%s" permission.'):format(Config.AdminAce), 'error')
            return
        end
        local c = Bridge.GetCoords(src)
        if not c then
            Bridge.Notify(src, 'The server could not read where you are standing, so the wardrobe was not moved.', 'error')
            return
        end
        wardrobePin = { x = c.x, y = c.y, z = c.z, radius = Config.Wardrobe.MinRadius }
        pushWardrobe(-1)
        local line = ('vector3(%.2f, %.2f, %.2f)'):format(c.x, c.y, c.z)
        Bridge.Notify(src, 'Wardrobe moved to where you are standing. Walk away and back to see it. This move is forgotten on restart.', 'success')
        Bridge.Reply(src, {
            ('Wardrobe moved to %s. This is a RUNTIME move; a restart puts it back.'):format(line),
            ('To keep it, set Config.Wardrobe.FallbackCoords in palm6_uniform/shared/config.lua to: %s'):format(line),
        })
        print(('[palm6_uniform] wardrobe moved at runtime to %s by source %d'):format(line, src))

    else
        Bridge.Notify(src, ('The wardrobe sent an action this server does not know ("%s"). Nothing was changed.')
            :format(action), 'error')
    end
end)

-- ---------------------------------------------------------------------------
-- COMMANDS. THE FALLBACK, not the feature.
--
-- The walk-up wardrobe above is the primary interface and no step of the
-- normal flow requires typing anything. These stay because a chat command
-- works from anywhere, works with no ox_target, works with no ox_lib menu, and
-- is the only route left if the wardrobe point itself cannot be resolved.
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
    local wp, wfrom = wardrobePoint()
    local lines = {
        ('enabled=%s  schema=%s  sets=%d'):format(tostring(Config.Enabled), schemaOk and 'ok' or 'MISSING', #sets),
        ('season=%s (%s)'):format(currentSeason(), seasonSource()),
        ('weather bucket=%s (from %s)'):format(bucket, tostring(source_)),
        ('wardrobe=%s  at=%s  from=%s'):format(
            Config.Wardrobe.Enabled and 'on' or 'OFF',
            wp and ('%.2f, %.2f, %.2f (radius %.1f)'):format(wp.x, wp.y, wp.z, wp.radius or 0.0) or 'UNRESOLVED',
            tostring(wfrom)),
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

    -- THE WARDROBE POSITION, stated at boot, with its source named.
    --
    -- This line exists because "I walked up to the wardrobe and nothing was
    -- there" and "the wardrobe is somewhere else" are different problems, and
    -- from in game they look the same. No coordinate here was authored by this
    -- resource; see wardrobePoint() for the three places it can come from.
    if Config.Wardrobe.Enabled then
        local wp, wfrom = wardrobePoint()
        if wp then
            print(('^2[palm6_uniform]^0 wardrobe at %.2f, %.2f, %.2f (radius %.1f) - source: %s')
                :format(wp.x, wp.y, wp.z, wp.radius or 0.0, tostring(wfrom)))
        else
            print(('^1[palm6_uniform] the wardrobe position could not be resolved (%s). No walk-up point will exist; /uniform and /uniformoff still work.^0')
                :format(tostring(wfrom)))
        end
        -- Every client already in the world when this resource starts. Clients
        -- joining later ask for it themselves on spawn.
        pushWardrobe(-1)
    else
        print('^3[palm6_uniform] the walk-up wardrobe is switched off (Config.Wardrobe.Enabled = false). Only the chat commands are available.^0')
    end

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
        print('^3[palm6_uniform] no uniforms captured yet. In game: get on the police job, dress the character, walk to the station wardrobe and pick "Save what I am wearing as a uniform". The menu says the same thing when it is empty.^0')
        print('^3[palm6_uniform] full in-game procedure: resources/[custom]/palm6_uniform/CHECKLIST.md^0')
    end
end)
