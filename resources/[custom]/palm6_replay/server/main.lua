-- ============================================================================
-- palm6_replay/server/main.lua
--
-- The city black-box. Incidents (server-observed weapon damage, downed
-- players, robbery triggers, bodycam, staff flags) pull the telemetry ring
-- buffers of every client in radius and persist a scene snippet; detectives
-- stand at the scene and replay it as ghost peds (client/main.lua).
--
-- Server is the source of truth: clients upload their ring ONLY when asked
-- (per-capture invite list), every frame is type/bounds/monotonicity
-- checked and rebuilt from whitelisted fields, and scene size is hard-capped
-- (participants, frames, radius) so a hostile client cannot flood the DB.
-- Incident positions always come from the server's own read of player
-- coords — never from a client claim. Uploads are additionally CORROBORATED
-- against server-observed truth (invite-time position read, observed weapon
-- damage) — see corroborateUpload; anything not corroborated there is the
-- participant's self-reported account, not server-verified evidence.
--
-- Pure logic — all framework/native/engine access via Bridge.* (§6 gate).
-- Our own palm6_replay_* SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
-- ============================================================================

local pendingCaptures = {}   -- [captureId] = capture state (see flagIncident)
local captureSeq      = 0
local recentScenes    = {}   -- ring of { type, coords, at } for dedupe
local sceneMinuteLog  = {}   -- os.time stamps of recent scene creations

local srcFlagAt      = {}    -- [src] = os.time of the last incident flag accepted from
                             -- ANY per-source trigger (damage/downed/shots/foreign).
                             -- One shared table on purpose: every one of those events
                             -- can be emitted by a modified client, so a per-type
                             -- table would let a griefer multiply scenes by rotating
                             -- trigger types. Each trigger still applies its own
                             -- cooldown length against this shared timestamp.
local serverShotLog  = {}    -- [src] = ascending os.time stamps of weapon damage the
                             -- SERVER itself observed this source deal — the ground
                             -- truth used to corroborate uploaded rings (see
                             -- corroborateUpload).
local bodycamAt      = {}    -- [src] = os.time of last bodycam
local commandAt      = {}    -- ['<cmd>:<src>'] = os.time of last use of that replay
                             -- command by that source (per-command so the designed
                             -- /replayscenes → /replay flow is never swallowed).

local function dbg(msg)
    if Config.Debug then print('[palm6_replay] ' .. msg) end
end

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- every statement IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with neither
-- replay table. Every query in this file sits inside a pcall, so the failure
-- is SILENT: scenes appear to record (the capture pipeline reports success to
-- the flagging officer), /replayscenes returns "no scenes nearby" forever, and
-- the boot banner still prints "black-box online". The whole evidentiary
-- record of the city vanishes with nothing in the console. On the live box
-- (0015 already applied by hand) these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0015_replay.sql. The inline `--` column
-- comments are carried across with it. NOTE: this resource also writes a row
-- into `palm6_evidence` on /replayattach; that table is NOT created here
-- because palm6_evidence owns it and self-creates it in its own ensureSchema.
-- That write is already soft (pcall + a "evidence log unavailable" fallback
-- message), so duplicating its DDL would only add a second place to keep in
-- sync with sql/0012 + sql/0018.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- The tables THIS resource owns and can answer for. Only these feed SchemaReady.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_replay_scenes` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    incident_type VARCHAR(32) NOT NULL,       -- shots | damage | downed | robbery | bodycam | manual
    label VARCHAR(120) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    flagged_by VARCHAR(64) DEFAULT NULL,      -- citizenid for officer-initiated scenes, NULL for automatic
    participant_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
    case_ref VARCHAR(120) DEFAULT NULL,       -- set by /replayattach (evidence-exhibit note)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_replay_scenes_created (created_at),
    INDEX idx_palm6_replay_scenes_expires (expires_at),
    INDEX idx_palm6_replay_scenes_xy (x, y)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_replay_participants` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    scene_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    player_name VARCHAR(100) NOT NULL,
    ped_model VARCHAR(32) NOT NULL,           -- model hash as string (fallback applied at playback)
    frame_count SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    frames MEDIUMTEXT NOT NULL,               -- sanitised JSON array of 4 Hz frames
    INDEX idx_palm6_replay_participants_scene (scene_id),
    INDEX idx_palm6_replay_participants_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_replay] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- ---------------------------------------------------------------------------
-- Gates / rate limits
-- ---------------------------------------------------------------------------

-- May this source use the detective-facing replay commands? Job (+ duty)
-- and, if configured, the scanner item — all checked server-side.
local function isAuthorized(src)
    if not Bridge.GetCitizenId(src) then return false end
    if not Bridge.HasJob(src, Config.Access.Jobs, Config.Access.OnDuty) then
        Bridge.Notify(src, 'Replay', 'Restricted to on-duty investigators.', 'error')
        return false
    end
    if Config.Access.RequiredItem and not Bridge.HasItem(src, Config.Access.RequiredItem) then
        Bridge.Notify(src, 'Replay', 'You need a forensic scanner for this.', 'error')
        return false
    end
    return true
end

-- Generic per-source cooldown against an os.time table. True = allowed now.
local function cooldownOk(tbl, src, seconds)
    local now = os.time()
    if (tbl[src] or 0) + seconds > now then return false end
    tbl[src] = now
    return true
end

-- Detective-command cooldown: keyed per command (so /replayscenes doesn't
-- swallow the /replay that follows it) and NEVER silent — the officer is
-- told why nothing happened, same as /bodycam.
local function commandCooldownOk(src, cmd)
    if cooldownOk(commandAt, cmd .. ':' .. src, Config.Playback.CommandCooldown) then
        return true
    end
    Bridge.Notify(src, 'Replay', 'Give it a few seconds between uses of /' .. cmd .. '.', 'error')
    return false
end

-- Global scenes-per-minute ceiling.
local function underGlobalCap()
    local now = os.time()
    local keep = {}
    for _, t in ipairs(sceneMinuteLog) do
        if now - t < 60 then keep[#keep + 1] = t end
    end
    sceneMinuteLog = keep
    return #sceneMinuteLog < Config.Incident.GlobalPerMinuteCap
end

-- One firefight = one scene: suppress a new flag of the same type near a
-- pending capture or a scene created moments ago.
local function isDuplicate(incidentType, coords)
    local now = os.time()
    for _, cap in pairs(pendingCaptures) do
        if cap.type == incidentType
            and Bridge.Distance(cap.coords, coords) <= Config.Incident.DedupeRadius then
            return true
        end
    end
    local keep, dup = {}, false
    for _, s in ipairs(recentScenes) do
        if now - s.at < Config.Incident.DedupeSeconds then
            keep[#keep + 1] = s
            if s.type == incidentType
                and Bridge.Distance(s.coords, coords) <= Config.Incident.DedupeRadius then
                dup = true
            end
        end
    end
    recentScenes = keep
    return dup
end

-- ---------------------------------------------------------------------------
-- Frame validation — the trust boundary
-- ---------------------------------------------------------------------------

local FLAG_MASK  = 31  -- shooting=1, vehicle=2, dead=4, aiming=8, ragdoll=16
local FLAG_SHOOT = 1

local function num(v) return type(v) == 'number' and v or nil end

-- Rebuild an uploaded ring from whitelisted, bounds-checked fields only.
-- Returns a sanitised frame array (may be shorter than the upload — bad
-- frames are dropped, a fully bad upload returns nil).
local function sanitizeFrames(frames, incidentCoords)
    if type(frames) ~= 'table' then return nil end
    local count = #frames
    if count < 2 or count > Config.Incident.MaxFrames then return nil end

    local out, lastT = {}, -1
    local maxSpan = Config.Recording.BufferSeconds * 1000 * 1.5

    for i = 1, count do
        local fr = frames[i]
        if type(fr) ~= 'table' then return nil end
        local t = num(fr.t)
        local x, y, z = num(fr.x), num(fr.y), num(fr.z)
        local h, s = num(fr.h), num(fr.s)
        if not (t and x and y and z and h and s) then return nil end
        if t < lastT or t < 0 or t > maxSpan then return nil end  -- non-monotonic / spoofed clock
        lastT = t

        -- Bounds: on the map, near the incident, at sane speed. A frame that
        -- fails only the distance check is dropped (a 90 s ring can start a
        -- long drive away); anything else voids the upload.
        if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or z < -300.0 or z > 2000.0 then
            return nil
        end
        if Bridge.Distance({ x = x, y = y, z = z }, incidentCoords) <= Config.Incident.MaxFrameDistance then
            local w = num(fr.w) or 0
            local f = num(fr.f) or 0
            out[#out + 1] = {
                t = math.floor(t),
                x = math.floor(x * 100 + 0.5) / 100,
                y = math.floor(y * 100 + 0.5) / 100,
                z = math.floor(z * 100 + 0.5) / 100,
                h = math.floor((h % 360) * 10 + 0.5) / 10,
                s = math.min(math.max(s, 0.0), 200.0),
                w = math.floor(w),
                f = math.floor(f) % (FLAG_MASK + 1),
            }
        end
    end

    if #out < 2 then return nil end
    -- Rebase time so the snippet starts at 0 ms.
    local t0 = out[1].t
    for _, fr in ipairs(out) do fr.t = fr.t - t0 end
    return out
end

-- Corroborate an uploaded ring against SERVER-observed truth.
--
-- sanitizeFrames() above only proves an upload is WELL-FORMED — the frames
-- themselves are still client-authored, so a modified client could shift its
-- positions or strip its FLAG_SHOOT bits and still pass every shape check.
-- Two server-side observations close that gap:
--
--   1. Position. The participant made the invite list because the SERVER read
--      their coords at flag time; the newest frame of the ring was sampled at
--      essentially that same instant. If the two disagree beyond
--      Config.Incident.CorroborationTolerance, the ring's positions were
--      forged — reject the whole upload.
--
--   2. Shots. Every weaponDamageEvent the server observes is logged per
--      source (serverShotLog). For each observed firing inside the ring's
--      window, the nearest frame gets FLAG_SHOOT forced on if the client
--      stripped it — the SHOT marker renders where the server saw damage
--      dealt, regardless of what the client claims.
--
-- Everything NOT corroborated here (exact path between samples, aim/ragdoll
-- flags, weapon hash) remains the participant's own account — documented in
-- the README so investigators know which parts of a reconstruction are
-- server-verified and which are self-reported.
local function corroborateUpload(src, cap, frames)
    -- 1. Position vs the server's own invite-time read.
    local invite = cap.inviteCoords and cap.inviteCoords[src]
    if invite then
        local last = frames[#frames]
        local d = Bridge.Distance({ x = last.x, y = last.y, z = last.z }, invite)
        if d > Config.Incident.CorroborationTolerance then
            dbg(('capture %d: rejected upload from %d — newest frame %.0fm from server-read position')
                :format(cap.id, src, d))
            return false
        end
    end

    -- 2. Force server-observed shots onto the ring. The newest frame lines up
    -- with cap.flaggedAt (the invite is what triggered the snapshot), so an
    -- observed firing at time S maps to frame time lastT - (flaggedAt - S)*1000.
    local log = serverShotLog[src]
    if log then
        local window = Config.Incident.ShotAnnotateWindowMs
        local lastT = frames[#frames].t
        for _, shotAt in ipairs(log) do
            local target = lastT - (cap.flaggedAt - shotAt) * 1000
            if target >= -window and target <= lastT + window then
                local nearest, nearestGap, alreadyMarked
                for _, fr in ipairs(frames) do
                    local gap = math.abs(fr.t - target)
                    if gap <= window then
                        if fr.f % (FLAG_SHOOT * 2) >= FLAG_SHOOT then
                            alreadyMarked = true
                            break
                        end
                        if not nearestGap or gap < nearestGap then
                            nearest, nearestGap = fr, gap
                        end
                    end
                end
                if not alreadyMarked and nearest then
                    nearest.f = nearest.f + FLAG_SHOOT
                    dbg(('capture %d: forced FLAG_SHOOT onto upload from %d at t=%dms (server saw damage)')
                        :format(cap.id, src, nearest.t))
                end
            end
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Incident capture lifecycle
-- ---------------------------------------------------------------------------

-- Persist a finished capture (scene + everyone who answered in time).
local function persistCapture(cap)
    if #cap.uploads == 0 then
        dbg(('capture %d (%s) expired with no uploads'):format(cap.id, cap.type))
        return
    end

    local ok, sceneId = pcall(function()
        return MySQL.insert.await(
            [[INSERT INTO palm6_replay_scenes
                (incident_type, label, x, y, z, flagged_by, participant_count, expires_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, DATE_ADD(NOW(), INTERVAL ? DAY))]],
            { cap.type, cap.label, cap.coords.x, cap.coords.y, cap.coords.z,
              cap.flaggedBy, #cap.uploads, Config.Retention.Days })
    end)
    if not ok or not sceneId then
        print('[palm6_replay] ERROR: failed to persist scene (' .. cap.type .. ')')
        return
    end

    for _, u in ipairs(cap.uploads) do
        pcall(function()
            MySQL.insert.await(
                [[INSERT INTO palm6_replay_participants
                    (scene_id, citizenid, player_name, ped_model, frame_count, frames)
                  VALUES (?, ?, ?, ?, ?, ?)]],
                { sceneId, u.citizenid, u.name, u.model, #u.frames, json.encode(u.frames) })
        end)
    end

    dbg(('scene #%d persisted: %s, %d participant(s)'):format(sceneId, cap.type, #cap.uploads))
end

-- Flag an incident: collect everyone in radius (server-side positions),
-- invite exactly those clients to upload their rings, persist when the
-- window closes. `opts` = { flaggedBy?, radius?, includeSrc? }.
local function flagIncident(incidentType, coords, label, opts)
    opts = opts or {}
    if not coords then return end
    if not underGlobalCap() then return end
    if isDuplicate(incidentType, coords) then return end

    local radius = opts.radius or Config.Incident.Radius

    -- Nearest-first participant list, hard-capped. The server-read coords are
    -- kept per participant — corroborateUpload() checks each ring against them.
    local nearby = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        local c = Bridge.GetCoords(src)
        if c then
            local d = Bridge.Distance(c, coords)
            if src == opts.includeSrc then d = -1.0 end  -- initiator always makes the cut
            if d <= radius then
                nearby[#nearby + 1] = { src = src, dist = d, coords = c }
            end
        end
    end
    if #nearby == 0 then return end
    table.sort(nearby, function(a, b) return a.dist < b.dist end)

    captureSeq = captureSeq + 1
    local cap = {
        id       = captureSeq,
        type     = incidentType,
        label    = label,
        coords   = { x = coords.x, y = coords.y, z = coords.z },
        flaggedBy = opts.flaggedBy,
        flaggedAt = os.time(),
        deadline = os.time() + Config.Incident.UploadWindowSeconds,
        expected = {},     -- [src] = true until that src uploads
        expectedCount = 0,
        inviteCoords = {}, -- [src] = the server's OWN coord read at invite time
        uploads  = {},
    }
    for i = 1, math.min(#nearby, Config.Incident.MaxParticipants) do
        cap.expected[nearby[i].src] = true
        cap.expectedCount = cap.expectedCount + 1
        cap.inviteCoords[nearby[i].src] = nearby[i].coords
    end

    pendingCaptures[cap.id] = cap
    recentScenes[#recentScenes + 1] = { type = incidentType, coords = cap.coords, at = os.time() }
    sceneMinuteLog[#sceneMinuteLog + 1] = os.time()

    for src in pairs(cap.expected) do
        TriggerClientEvent('palm6_replay:requestBuffer', src, cap.id)
    end
    dbg(('capture %d flagged: %s (%d client(s) invited)'):format(cap.id, incidentType, cap.expectedCount))
end

-- Close out captures whose upload window has passed. Two-phase on purpose:
-- persistCapture() yields (awaited SQL), and flagIncident() can insert a NEW
-- key into pendingCaptures during that yield — inserting into a table
-- mid-pairs() is undefined behaviour in Lua ("invalid key to 'next'") and
-- would kill this thread. So: collect expired ids with no yields, then
-- remove + persist outside the traversal.
CreateThread(function()
    while true do
        Wait(1000)
        local now = os.time()
        local expired = {}
        for id, cap in pairs(pendingCaptures) do
            if now >= cap.deadline then
                expired[#expired + 1] = id
            end
        end
        for _, id in ipairs(expired) do
            local cap = pendingCaptures[id]
            if cap then  -- may have persisted early (all uploads in) meanwhile
                pendingCaptures[id] = nil
                persistCapture(cap)
            end
        end
    end
end)

-- Clients answer a buffer request here. Accepted only if this exact source
-- was invited to this exact capture and hasn't answered yet.
RegisterNetEvent('palm6_replay:uploadBuffer', function(captureId, frames, modelHash)
    local src = source
    local cap = pendingCaptures[captureId]
    if not cap or not cap.expected[src] then return end   -- uninvited / late / replayed
    cap.expected[src] = nil
    cap.expectedCount = cap.expectedCount - 1

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local clean = sanitizeFrames(frames, cap.coords)
    if not clean then
        dbg(('capture %d: rejected upload from %d (failed validation)'):format(captureId, src))
        return
    end

    -- Shape checks passed — now check the CONTENT against what the server
    -- itself observed (position at invite time, weapon damage dealt).
    if not corroborateUpload(src, cap, clean) then
        return
    end

    cap.uploads[#cap.uploads + 1] = {
        citizenid = cid,
        name      = Bridge.GetPlayerName(src),
        model     = tostring(math.floor(num(modelHash) or 0)),
        frames    = clean,
    }

    -- Everyone answered? Persist early instead of waiting out the window.
    if cap.expectedCount <= 0 then
        pendingCaptures[captureId] = nil
        persistCapture(cap)
    end
end)

-- ---------------------------------------------------------------------------
-- Incident triggers
-- ---------------------------------------------------------------------------

-- EVERY per-source trigger below can be emitted by a modified client
-- (weaponDamageEvent and baseevents death reports are networked game/client
-- events, not server observations of intent) — so none of them ever pays,
-- grants, or teleports anything; they only flag a scene at the SERVER's own
-- read of the source's position. Abuse is bounded by: one shared per-source
-- cooldown across ALL trigger types (rotating types buys nothing), the
-- global per-minute cap, dedupe, and flaggedBy attribution so staff can see
-- exactly which citizenid manufactured a junk scene.

-- Server-observed weapon damage — the highest-trust trigger.
if Config.Triggers.WeaponDamage then
    Bridge.OnWeaponDamage(function(attacker)
        -- Log EVERY observed firing (before any cooldown) — this is the
        -- ground truth corroborateUpload() forces onto uploaded rings.
        local log = serverShotLog[attacker]
        if not log then log = {}; serverShotLog[attacker] = log end
        log[#log + 1] = os.time()
        local cutoff = os.time() - Config.Recording.BufferSeconds * 2
        while log[1] and log[1] < cutoff do table.remove(log, 1) end

        if not cooldownOk(srcFlagAt, attacker, 15) then return end
        flagIncident('damage', Bridge.GetCoords(attacker), 'Weapon damage reported',
            { flaggedBy = Bridge.GetCitizenId(attacker) })
    end)
end

-- Downed player (client-originated death report — flag-only, no effects).
if Config.Triggers.PlayerDowned then
    Bridge.OnPlayerDowned(function(victim)
        if not Bridge.GetCitizenId(victim) then return end
        if not cooldownOk(srcFlagAt, victim, 15) then return end
        flagIncident('downed', Bridge.GetCoords(victim), 'Person down',
            { flaggedBy = Bridge.GetCitizenId(victim) })
    end)
end

-- Client shots-fired report. The claim carries NO data we act on — position
-- comes from the server's own read, and the per-source + global rate limits
-- bound the worst a hostile client can do to "one extra scene a minute".
if Config.Triggers.ShotsFired then
    RegisterNetEvent('palm6_replay:shotsFired', function()
        local src = source
        local cid = Bridge.GetCitizenId(src)
        if not cid then return end
        if not cooldownOk(srcFlagAt, src, Config.Triggers.ShotsFiredCooldown) then return end
        flagIncident('shots', Bridge.GetCoords(src), 'Shots fired', { flaggedBy = cid })
    end)
end

-- Foreign-resource incident hooks (palm6_robbery etc.) — read-only
-- subscriptions to their existing incident events. Server-raised signals are
-- the default; an entry only becomes a net-event subscription if it carries an
-- explicit `clientRaised = true` (see bridge/sv_framework.lua).
for _, hook in ipairs(Config.Triggers.AutoFlagEvents or {}) do
    Bridge.OnForeignNetEvent(hook.event, function(src)
        local cid = Bridge.GetCitizenId(src)
        if not cid then return end
        if not cooldownOk(srcFlagAt, src, 30) then return end
        flagIncident(hook.type, Bridge.GetCoords(src), hook.label, { flaggedBy = cid })
    end, hook.clientRaised)
end

-- Officer bodycam: capture a snippet centred on yourself, on demand.
RegisterCommand('bodycam', function(src)
    if src == 0 or not Config.Bodycam.Enabled then return end
    if not isAuthorized(src) then return end
    if not cooldownOk(bodycamAt, src, Config.Bodycam.CooldownSeconds) then
        Bridge.Notify(src, 'Bodycam', 'Bodycam is still cooling down.', 'error')
        return
    end
    local cid = Bridge.GetCitizenId(src)
    flagIncident('bodycam', Bridge.GetCoords(src),
        ('Bodycam — %s'):format(Bridge.GetPlayerName(src)),
        { flaggedBy = cid, radius = Config.Bodycam.Radius, includeSrc = src })
    Bridge.Notify(src, 'Bodycam', 'Snippet captured — persists in a few seconds.', 'success')
end, false)

-- Staff/testing: manually flag a scene where you stand. Ace-restricted
-- (add_ace group.admin command.replayflag allow).
RegisterCommand('replayflag', function(src, args)
    if src == 0 then return end
    local label = #args > 0 and table.concat(args, ' ') or 'Manually flagged scene'
    flagIncident('manual', Bridge.GetCoords(src), label:sub(1, 100),
        { flaggedBy = Bridge.GetCitizenId(src), includeSrc = src })
    Bridge.Notify(src, 'Replay', 'Scene flagged.', 'success')
end, true)

-- ---------------------------------------------------------------------------
-- Detective commands — review + reconstruct
-- ---------------------------------------------------------------------------

-- Scenes near a point, newest first (SQL bounding box, precise check in Lua).
local function nearbyScenes(coords, radius, limit)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            [[SELECT id, incident_type, label, x, y, z, participant_count, case_ref,
                     DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS created_at
              FROM palm6_replay_scenes
              WHERE (expires_at IS NULL OR expires_at > NOW())
                AND x BETWEEN ? AND ? AND y BETWEEN ? AND ?
              ORDER BY created_at DESC LIMIT 50]],
            { coords.x - radius, coords.x + radius, coords.y - radius, coords.y + radius })
    end)
    if not ok or not rows then return {} end

    local out = {}
    for _, r in ipairs(rows) do
        local d = Bridge.Distance(coords, { x = r.x, y = r.y, z = r.z })
        if d <= radius then
            r.dist = d
            out[#out + 1] = r
            if #out >= limit then break end
        end
    end
    return out
end

RegisterCommand('replayscenes', function(src)
    if src == 0 then return end
    if not isAuthorized(src) then return end
    if not commandCooldownOk(src, 'replayscenes') then return end

    local coords = Bridge.GetCoords(src)
    if not coords then return end

    local scenes = nearbyScenes(coords, Config.Playback.SceneQueryRadius, Config.Playback.SceneListLimit)
    if #scenes == 0 then
        Bridge.Notify(src, 'Replay', 'No recorded scenes near this location.', 'inform')
        return
    end

    local lines = {}
    for _, s in ipairs(scenes) do
        lines[#lines + 1] = ('**#%d — %s** (%s)\n_%s · %d participant(s) · %dm away%s_'):format(
            s.id, s.label, s.incident_type, s.created_at, s.participant_count,
            math.floor(s.dist + 0.5), s.case_ref and ' · exhibit: ' .. s.case_ref or '')
    end
    lines[#lines + 1] = '\nStand at the scene and run **/replay <id>** to reconstruct.'
    TriggerClientEvent('palm6_replay:showSceneList', src, table.concat(lines, '\n\n'))
end, false)

RegisterCommand('replay', function(src, args)
    if src == 0 then return end
    if not isAuthorized(src) then return end
    if not commandCooldownOk(src, 'replay') then return end

    local sceneId = tonumber(args[1])
    if not sceneId then
        Bridge.Notify(src, 'Replay', 'Usage: /replay <scene id> — see /replayscenes.', 'error')
        return
    end

    local ok, scene = pcall(function()
        return MySQL.single.await(
            [[SELECT id, incident_type, label, x, y, z,
                     DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS created_at
              FROM palm6_replay_scenes
              WHERE id = ? AND (expires_at IS NULL OR expires_at > NOW())]],
            { sceneId })
    end)
    if not ok or not scene then
        Bridge.Notify(src, 'Replay', 'No such scene (it may have expired).', 'error')
        return
    end

    -- Reconstruct AT the crime scene — server-side proximity gate.
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, { x = scene.x, y = scene.y, z = scene.z })
        > Config.Playback.StartRadius then
        Bridge.Notify(src, 'Replay',
            ('You must be at the scene to reconstruct it (scene #%d is elsewhere).'):format(sceneId), 'error')
        return
    end

    local pok, participants = pcall(function()
        return MySQL.query.await(
            [[SELECT player_name, ped_model, frames FROM palm6_replay_participants
              WHERE scene_id = ? LIMIT ?]],
            { sceneId, Config.Incident.MaxParticipants })
    end)
    if not pok or not participants or #participants == 0 then
        Bridge.Notify(src, 'Replay', 'This scene has no usable telemetry.', 'error')
        return
    end

    -- Stream the scene down: meta, then one event per participant (keeps any
    -- single net payload small), then a ready signal.
    TriggerClientEvent('palm6_replay:playbackMeta', src, {
        sceneId = scene.id,
        label = scene.label,
        incidentType = scene.incident_type,
        createdAt = scene.created_at,
        participantCount = #participants,
    })
    for _, p in ipairs(participants) do
        local fok, frames = pcall(function() return json.decode(p.frames) end)
        if fok and type(frames) == 'table' and #frames >= 2 then
            TriggerClientEvent('palm6_replay:playbackParticipant', src, {
                name = p.player_name, model = p.ped_model, frames = frames,
            })
        end
    end
    TriggerClientEvent('palm6_replay:playbackReady', src)
end, false)

-- Attach a scene to the palm6_evidence case log as a REPLAY EXHIBIT.
RegisterCommand('replayattach', function(src, args)
    if src == 0 then return end
    if not isAuthorized(src) then return end
    if not commandCooldownOk(src, 'replayattach') then return end

    local sceneId = tonumber(args[1])
    if not sceneId then
        Bridge.Notify(src, 'Replay', 'Usage: /replayattach <scene id> [case note]', 'error')
        return
    end
    local note = table.concat(args, ' ', 2):sub(1, 100)
    if #note == 0 then note = 'no note' end

    local ok, scene = pcall(function()
        return MySQL.single.await(
            [[SELECT id, incident_type, label, x, y, z,
                     DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS created_at
              FROM palm6_replay_scenes
              WHERE id = ? AND (expires_at IS NULL OR expires_at > NOW())]],
            { sceneId })
    end)
    if not ok or not scene then
        Bridge.Notify(src, 'Replay', 'No such scene (it may have expired).', 'error')
        return
    end

    pcall(function()
        MySQL.update.await('UPDATE palm6_replay_scenes SET case_ref = ? WHERE id = ?',
            { note, sceneId })
    end)

    -- Consume palm6_evidence's table (sql/0012_evidence.sql) read/insert-only
    -- — that resource itself is never touched. Guarded: absence degrades to
    -- a standalone attachment.
    local logged = false
    if Config.EvidenceIntegration then
        logged = pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_evidence (citizenid, officer_name, description, coords) VALUES (?, ?, ?, ?)',
                { Bridge.GetCitizenId(src), Bridge.GetPlayerName(src),
                  ('REPLAY EXHIBIT — scene #%d "%s" (%s, %s). Note: %s. Reconstruct on site via /replay %d.')
                      :format(scene.id, scene.label, scene.incident_type, scene.created_at, note, scene.id),
                  json.encode({ x = scene.x, y = scene.y, z = scene.z }) })
        end)
    end

    if logged then
        Bridge.Notify(src, 'Replay',
            ('Scene #%d filed as an exhibit in the evidence log.'):format(sceneId), 'success')
    else
        Bridge.Notify(src, 'Replay',
            ('Scene #%d tagged with your case note (evidence log unavailable).'):format(sceneId), 'success')
    end
end, false)

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------

local function pruneScenes()
    pcall(function()
        -- Expired scenes (participants first — no FK cascade, house style).
        MySQL.update.await(
            [[DELETE p FROM palm6_replay_participants p
              JOIN palm6_replay_scenes s ON s.id = p.scene_id
              WHERE s.expires_at IS NOT NULL AND s.expires_at < NOW()]])
        MySQL.update.await(
            'DELETE FROM palm6_replay_scenes WHERE expires_at IS NOT NULL AND expires_at < NOW()')

        -- Absolute cap: drop the oldest beyond MaxStoredScenes.
        local cutoff = MySQL.scalar.await(
            'SELECT id FROM palm6_replay_scenes ORDER BY id DESC LIMIT 1 OFFSET ?',
            { Config.Retention.MaxStoredScenes })
        if cutoff then
            MySQL.update.await('DELETE FROM palm6_replay_participants WHERE scene_id <= ?', { cutoff })
            MySQL.update.await('DELETE FROM palm6_replay_scenes WHERE id <= ?', { cutoff })
        end
    end)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The whole boot sequence runs on this thread because ensureSchema has to
    -- Wait for oxmysql's connection before it can issue any query, and
    -- pruneScenes must not run before the tables are guaranteed to exist.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). On a fresh box the old "black-box online" line was a
        -- lie: every query here is pcall'd, so a missing table printed exactly
        -- the same healthy banner.
        if not SchemaReady then
            print('^1[palm6_replay] schema MISSING - the black-box records NOTHING on this box.^0')
        end
        pruneScenes()
        print(('[palm6_replay] black-box online — %d Hz ring, %ds window, %dd retention'):format(
            Config.Recording.FrameHz, Config.Recording.BufferSeconds, Config.Retention.Days))
    end)
end)

-- Hourly prune so a long-running server doesn't wait for a restart.
CreateThread(function()
    while true do
        Wait(3600 * 1000)
        pruneScenes()
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    srcFlagAt[src]     = nil
    serverShotLog[src] = nil
    bodycamAt[src]     = nil
    commandAt['replayscenes:' .. src]  = nil
    commandAt['replay:' .. src]        = nil
    commandAt['replayattach:' .. src]  = nil
    for _, cap in pairs(pendingCaptures) do
        if cap.expected[src] then
            cap.expected[src] = nil
            cap.expectedCount = cap.expectedCount - 1
        end
    end
end)
