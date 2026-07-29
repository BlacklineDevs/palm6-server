-- ============================================================================
-- palm6_turf/server/main.lua
--
-- Gang turf control — the Phase 6 roadmap "faction reputation tracker"
-- candidate. Two phases like palm6_robbery: `requestTag` validates (in a
-- gang, proximity, not already yours) and reserves; `complete` flips
-- ownership after the client-side tag animation. Reputation = turf count,
-- shown via /turf. Pure logic — all framework/native access via Bridge.*
-- (§6 gate). Our own `palm6_turf` SQL stays here (Section 3 of
-- docs/GTA6-READINESS.md).
-- ============================================================================

local zones   = {}  -- [id] = { label, coords, owner_gang, captured_by, captured_at }
local pending = {}  -- [src] = { zoneId, gangName, holdUntil }

-- ---------------------------------------------------------------------------
-- TURF CONFLICT state (v2). ALL of it is dead while Config.Conflict.Enabled is
-- false: nothing below is written unless a contest opens, and a contest cannot
-- open on the disabled path.
--
-- PERSISTENCE DECISION (Config.Conflict documents the player-facing side):
-- CONTESTS themselves are deliberately NOT persisted. On a restart every open
-- contest simply ceases to exist and the DEFENDER keeps the zone, which is the
-- fail-safe direction. There is no "contested" flag in any table, so there is
-- no way for a restart to leave a zone permanently locked.
--
-- The BRAKES are a different question and all four now survive a restart:
--   * the anti-ping-pong flip cooldown persists for free, derived from
--     palm6_turf.captured_at which every flip already writes;
--   * gangOpenAt / gangRepelAt / gangNotifyAt are mirrored into
--     palm6_turf_brakes (sql/0074_turf_brakes.sql) and reloaded at boot, so a
--     reboot no longer cuts a gang's remaining cooldown short.
-- The in-memory tables below stay the read path: nothing on a gate, a tick or a
-- notify ever touches the DB. The DB is written once per brake CHANGE, on its
-- own thread, and read once at boot.
-- ---------------------------------------------------------------------------
local contests     = {}  -- [zoneId] = live contest (see openContest)
local gangOpenAt   = {}  -- [attackerGangId]   = ts that gang last OPENED a contest
local gangNotifyAt = {}  -- [defenderGangName] = ts that gang was last notified
local gangRepelAt  = {}  -- [attackerGangId]   = ts that gang was DRIVEN OFF a zone

-- os.time() at which the contest engine armed. Starts RestartGraceSec, which is
-- no longer the only thing standing between a reboot and a free reset (the three
-- brakes above are reloaded from palm6_turf_brakes first); it now covers the
-- reconnect window, when the player list is still filling and a defender
-- headcount would wrongly read as "nobody online". 0 while the flag is off.
local conflictBootAt = 0

-- Cached {gangName -> {srcs}} snapshot of everyone online. Rebuilt at most once
-- per Config.Conflict.PresenceCacheSec because it costs one palm6_gangs DB read
-- per online player. Callers that must be authoritative pass maxAge 0.
local presenceCache = { at = 0, byGang = nil }

local function conflictOn()
    return Config.Conflict ~= nil and Config.Conflict.Enabled == true
end

-- ===========================================================================
-- BRAKE PERSISTENCE (palm6_turf_brakes). Everything in this section is reached
-- ONLY from a conflictOn() branch, so with the flag off the table is never
-- created, never read and never written, and this whole section is dead code.
--
-- WHY A SECOND TABLE. The three per-gang brakes are not properties of a zone,
-- so palm6_turf (one row per zone) has nowhere to put them: a gang can be on
-- open cooldown while holding no turf at all, and the notify budget belongs to
-- the gang being pinged, not to any one of its zones. This resource owns its
-- own schema, so it owns one more table rather than borrowing a sibling's.
--
-- WHAT IT COSTS. One write per brake CHANGE, which is one per contest opened,
-- one per contest lost with a defender present, and one per defender ping. Those
-- are already rate-limited by the very cooldowns being stored, so the write rate
-- is bounded by the feature's own design and not by player input. There is no
-- timer flush and no write on any read path.
-- ===========================================================================
local brakesReady = false   -- true once palm6_turf_brakes is known to exist

-- Which brake a row belongs to. `open`/`repel` are keyed on the IMMUTABLE
-- palm6_gangs.id; `notify` is keyed on the gang NAME, because that is what turf
-- ownership (and therefore the defender side) is keyed on.
local BRAKE_SCOPES = { 'open', 'repel', 'notify' }

-- The window each scope is measured against. These MUST stay identical to the
-- fallbacks used by the in-memory sweep in startContestTicker, or the DB sweep
-- and the RAM sweep would disagree about when a row dies.
local function brakeWindow(scope)
    local c = Config.Conflict or {}
    if scope == 'open'   then return tonumber(c.OpenCooldownSec)   or 600 end
    if scope == 'repel'  then return tonumber(c.RepelCooldownSec)  or 600 end
    if scope == 'notify' then return tonumber(c.NotifyCooldownSec) or 300 end
    return nil   -- unknown scope: never loaded, and never swept either
end

-- Mirror one brake stamp to the DB. Fire-and-forget BY DESIGN.
--
-- The caller must never wait on this. closeContest() stamps the repel brake and
-- closeContest() is called from inside the contest ticker, so a synchronous
-- MySQL.*.await here would yield the ticker thread mid-pass and stretch every
-- live contest's clock by the round-trip. CreateThread hands the write to a
-- fresh coroutine and returns immediately, so the ticker never blocks on the DB.
-- pcall'd on top of that: a dead DB must cost the brakes their persistence and
-- nothing else, exactly like every other write in this resource.
--
-- GREATEST(set_at, ?) rather than a plain overwrite, because two deferred writes
-- for the same gang can land out of order. Monotonic means a late-arriving older
-- stamp can only ever be ignored, never SHORTEN a brake that is already stored.
local function persistBrake(scope, key, ts)
    if not brakesReady then return end
    if key == nil or ts == nil then return end
    local gangKey = tostring(key)
    if gangKey == '' then return end
    -- Clamp a future stamp DOWN to now before it is ever stored. Without this,
    -- a forward clock jump (NTP correcting a bad RTC, or a manual date during
    -- maintenance) writes set_at = T_future, and then GREATEST() below silently
    -- discards every correct stamp that follows, the sweeper's `set_at < cutoff`
    -- never matches a future value, and loadBrakes clamps it to now on EVERY
    -- boot, so the gang eats a fresh unearned cooldown forever. Before the table
    -- existed a restart cleared that; persistence turned the restart into the
    -- thing that re-arms it. Clamping on write is what keeps the row reachable
    -- by the sweep at all.
    local nowTs = os.time()
    if ts > nowTs then ts = nowTs end
    CreateThread(function()
        pcall(function()
            MySQL.query.await(
                'INSERT INTO palm6_turf_brakes (scope, gang_key, set_at) VALUES (?, ?, ?) '
                .. 'ON DUPLICATE KEY UPDATE set_at = GREATEST(set_at, ?)',
                { scope, gangKey, ts, ts })
        end)
    end)
end

-- Boot DDL for the brakes table. Kept OUT of ensureSchema() on purpose: that
-- function runs on every boot including today's, and the safest possible change
-- to a live path is no change at all. This one is called only from the
-- conflictOn() branch of the boot handler, so a box with the feature off never
-- creates the table. palm6_turf itself still answers for SchemaReady; a missing
-- brakes table is reported on its own line and only disables persistence.
--
-- DDL copied VERBATIM from sql/0074_turf_brakes.sql.
local function ensureBrakeSchema()
    local ok, err = pcall(function()
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `palm6_turf_brakes` (
    scope VARCHAR(16) NOT NULL,
    gang_key VARCHAR(64) NOT NULL,
    set_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (scope, gang_key),
    KEY idx_palm6_turf_brakes_scope_set_at (scope, set_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    brakesReady = ok
    if not ok then
        print(('^1[palm6_turf] brake table init FAILED -> %s^0'):format(tostring(err)))
        print('^1[palm6_turf] contest cooldowns will NOT survive a restart on this box.^0')
    end
    return brakesReady
end

-- Reload the three brakes. Runs ONCE, at boot, before the ticker starts.
--
-- A row is only honoured while it is still inside its own window, so a stale
-- row can never resurrect a dead cooldown; expired rows are simply not loaded
-- and the sweeper deletes them. A set_at in the FUTURE is clamped to now rather
-- than trusted: a box whose clock jumped must not be able to mint a brake that
-- outlives its window.
local function loadBrakes()
    if not brakesReady then return end
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT scope, gang_key, set_at FROM palm6_turf_brakes') or {}
    end)
    if not ok then return end

    local now, live, stale = os.time(), 0, 0
    for _, r in ipairs(rows) do
        local window = brakeWindow(r.scope)
        local ts = tonumber(r.set_at) or 0
        if ts > now then ts = now end
        if window and ts > 0 and (ts + window) >= now then
            if r.scope == 'notify' then
                -- Keyed on the gang NAME. A gang renamed while the server was
                -- down orphans its row, which then just expires: the effect is
                -- one un-throttled ping, the same as today's in-memory table
                -- (RenameOwner does not rewrite gangNotifyAt either).
                local k = r.gang_key
                if k and k ~= '' then
                    gangNotifyAt[k] = math.max(gangNotifyAt[k] or 0, ts)
                    live = live + 1
                end
            else
                -- Keyed on palm6_gangs.id, which is a NUMBER in memory. The
                -- column is text, so it must be converted back or the reloaded
                -- key would never match a live gang.id lookup.
                local gid = tonumber(r.gang_key)
                if gid then
                    local t = (r.scope == 'open') and gangOpenAt or gangRepelAt
                    t[gid] = math.max(t[gid] or 0, ts)
                    live = live + 1
                end
            end
        else
            stale = stale + 1
        end
    end
    print(('[palm6_turf] restored %d live contest brake(s), %d expired'):format(live, stale))
end

-- PRUNE. An expired row can no longer gate anything, so it is dead weight in a
-- table that would otherwise grow one row per gang per brake forever.
--
-- The delete CANNOT touch a live brake. Its predicate is `set_at + window < now`
-- with the window read from the same Config value the gate reads, which is the
-- exact expression the in-memory sweep in startContestTicker already uses: a row
-- survives for precisely as long as it can still refuse something. It is written
-- as the algebraically identical `set_at < now - window` so the cutoff is a
-- plain constant and the set_at index can be used instead of scanning. Three
-- consequences worth stating, because "sweep" is where data loss usually hides:
--   * it is per-scope, so a row is only ever measured against ITS OWN window and
--     an unknown scope (brakeWindow -> nil) is skipped entirely rather than
--     swept with a wrong one;
--   * raising a cooldown in Config immediately extends the rows already stored,
--     because the window is applied at sweep time and not frozen at write time;
--   * a future-dated set_at fails the predicate and is kept, so a clock skew
--     cannot delete a brake early.
-- Runs on its own thread at a low frequency: never in the ticker, never on a
-- gate. Every statement is pcall'd, so a DB hiccup skips a sweep and nothing
-- else - the table is disposable, only ever growing until the next pass.
local function startBrakeSweeper()
    CreateThread(function()
        local every = math.max(60, tonumber(Config.Conflict.BrakeSweepSec) or 900)
        while true do
            for _, scope in ipairs(BRAKE_SCOPES) do
                local window = brakeWindow(scope)
                if window and window >= 0 then
                    local nowTs = os.time()
                    local cutoff = nowTs - window
                    -- The OR arm collects rows stamped in the FUTURE. persistBrake
                    -- now clamps on write so this should never fire, but a row
                    -- written before that clamp existed, or by hand, would
                    -- otherwise be immortal: it fails `set_at < cutoff` forever
                    -- and re-arms the gang on every boot. The bound is a full
                    -- window past now, so a few seconds of ordinary clock skew
                    -- still cannot delete a live brake early.
                    pcall(function()
                        MySQL.query.await(
                            'DELETE FROM palm6_turf_brakes WHERE scope = ? AND (set_at < ? OR set_at > ?)',
                            { scope, cutoff, nowTs + window })
                    end)
                end
            end
            -- Rows whose scope is not one we know about (a hand-written row, or
            -- a scope renamed in a later version) match no branch above and
            -- would live forever, so "prune" would not actually cover the table.
            -- Deleting by exclusion keeps the sweep total. Guarded on a non-empty
            -- scope list so a future refactor emptying BRAKE_SCOPES cannot turn
            -- this into a full table wipe.
            if #BRAKE_SCOPES > 0 then
                local placeholders = {}
                local params = {}
                for _, scope in ipairs(BRAKE_SCOPES) do
                    placeholders[#placeholders + 1] = '?'
                    params[#params + 1] = scope
                end
                pcall(function()
                    MySQL.query.await(
                        'DELETE FROM palm6_turf_brakes WHERE scope NOT IN ('
                            .. table.concat(placeholders, ', ') .. ')',
                        params)
                end)
            end
            Wait(every * 1000)
        end
    end)
end

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner
local bootReady   = false  -- flipped once the boot seed+load has actually populated `zones`

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- CREATE ... IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- palm6_turf table. Every query here is pcall-wrapped, so the failure is
-- SILENT and the resource looks perfectly healthy: loadZones falls back to
-- Config, so the boot banner still prints the right zone count and the blips
-- still appear. Every zone just reads as unowned forever and every capture is
-- discarded on the next restart, so turf ownership (and palm6_protection's
-- collections on top of it) quietly stops persisting. On the live box (0013 +
-- 0051 already applied by hand) these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0013_turf.sql. NOT included: sql/0049's
-- identity reset, which is a data UPDATE rather than schema and is owned by
-- palm6_dbmigrate (it re-runs it every boot).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- The table THIS resource owns and can answer for. Only these feed SchemaReady.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_turf` (
    zone_id VARCHAR(50) NOT NULL PRIMARY KEY,
    owner_gang VARCHAR(50) DEFAULT NULL,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP NULL DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists, so folding it into SchemaReady would make a healthy
    -- MySQL box print `schema MISSING` on every boot and train operators to
    -- ignore the banner. Same split as palm6_courier and palm6_mdt.
    --
    -- Copied VERBATIM from sql/0051_turf_rep_at.sql. It is repeated here (it
    -- also lives in palm6_dbmigrate) because dbmigrate and this resource boot
    -- on independent threads: whichever runs second is a no-op and neither can
    -- lose the race. Without rep_at, loadZones reads nil and the anti-farm
    -- cooldown falls back to 0, which is the pre-0051 in-memory behaviour.
    local alters = {
        [[
ALTER TABLE `palm6_turf`
    ADD COLUMN IF NOT EXISTS `rep_at` BIGINT NOT NULL DEFAULT 0
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_turf] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_turf] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function ensureZones()
    for _, z in ipairs(Config.Zones) do
        pcall(function()
            MySQL.insert.await(
                'INSERT IGNORE INTO palm6_turf (zone_id) VALUES (?)', { z.id })
        end)
    end
end

local function loadZones()
    zones = {}
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM palm6_turf') or {}
    end)
    local byId = {}
    if ok then
        for _, r in ipairs(rows) do byId[r.zone_id] = r end
    end
    for _, z in ipairs(Config.Zones) do
        local row = byId[z.id] or {}
        zones[z.id] = {
            id = z.id, label = z.label, coords = z.coords,
            owner_gang = row.owner_gang, captured_by = row.captured_by,
            rep_at = tonumber(row.rep_at) or 0,   -- persisted anti-farm cooldown
        }
    end
end

local function publicZones()
    local out = {}
    for id, z in pairs(zones) do
        out[id] = { id = z.id, label = z.label, coords = z.coords, owner_gang = z.owner_gang }
    end
    return out
end

local function syncAll()
    local data = publicZones()
    for _, src in ipairs(GetPlayers()) do
        TriggerClientEvent('palm6_turf:syncZones', tonumber(src), data)
    end
end

-- ===========================================================================
-- TURF CONFLICT engine. Every function below is only ever REACHED from a
-- Config.Conflict.Enabled branch, so with the flag off none of it runs and the
-- instant-flip path in `palm6_turf:complete` is untouched.
--
-- SERVER-AUTHORITATIVE PRESENCE: the only inputs to capture progress are
-- (a) elapsed wall-clock time the server measured itself and (b) ped positions
-- the server read with GetEntityCoords through Bridge.GetCoords. No client ever
-- reports its progress, its position, its gang, or its presence. The client's
-- only contribution to this whole feature is "I finished the tag animation",
-- which is already re-validated against the server's own startedAt clock.
-- ===========================================================================

-- Everyone online, bucketed by player-run gang NAME. One palm6_gangs DB read
-- per online player, so it is cached; pass maxAge 0 to force a fresh read.
local function presenceSnapshot(maxAge)
    local now = os.time()
    local ttl = maxAge or (Config.Conflict.PresenceCacheSec or 15)
    if presenceCache.byGang and (now - presenceCache.at) < ttl then
        return presenceCache.byGang
    end
    local byGang = {}
    for _, psrc in ipairs(Bridge.GetOnlinePlayers()) do
        local g = Bridge.GetGang(psrc)
        if g and g.name then
            local bucket = byGang[g.name]
            if not bucket then bucket = {}; byGang[g.name] = bucket end
            bucket[#bucket + 1] = psrc
        end
    end
    presenceCache.at, presenceCache.byGang = now, byGang
    return byGang
end

local function onlineMembers(gangName, maxAge)
    if not gangName then return {} end
    return presenceSnapshot(maxAge)[gangName] or {}
end

-- Seconds since this zone last changed hands. Reads the PERSISTED timestamp, so
-- a restart cannot reset the flip cooldown. Never captured -> a huge number, so
-- an untouched zone is never treated as freshly flipped.
local function sinceFlip(z)
    local ts = tonumber(z.captured_ts)
    if not ts or ts <= 0 then return math.huge end
    return os.time() - ts
end

-- May a DIFFERENT gang take this contest over? Only while the incumbent
-- attacker is not actually holding the zone, measured as at least one full
-- ticker pass in which they failed to beat their own best progress.
--
-- This is the rule that stops "there is a contest here" from being a lock. One
-- contest per zone is the right model, but on its own it means any crew can
-- deny a zone to everyone else for the whole window just by keeping a contest
-- technically alive, and staggering two throwaway crews covers the gaps. With
-- displacement the refusal only ever lasts as long as somebody is genuinely
-- taking the zone: a squatter who is not gaining can always be pushed aside by
-- a crew that shows up and does the work, while an attacker who is actually
-- holding the zone (stalledFor == 0 every pass) can never be pushed aside at
-- all. So the fix does not hand the lock to the challenger either.
local function displaceable(ct)
    return (ct.stalledFor or 0) >= (Config.Conflict.DisplaceAfterStallSec or 5)
end

-- Why this zone cannot be contested right now, or nil if it can. Ordered
-- cheapest-first: nothing here touches the DB or walks the player list.
local function contestBlocked(z, gang)
    -- Post-restart grace, first because it is the cheapest gate here. It is no
    -- longer what makes the other brakes restart-proof (they are reloaded from
    -- palm6_turf_brakes at boot); it covers the reconnect window, when the
    -- player list is still filling and the defender headcount below would
    -- wrongly read as "nobody online".
    local graceLeft = (Config.Conflict.RestartGraceSec or 0) - (os.time() - conflictBootAt)
    if graceLeft > 0 then
        return ('Turf conflict is still settling after a server restart. %d min to go.')
            :format(math.max(1, math.ceil(graceLeft / 60)))
    end
    local live = contests[z.id]
    if live then
        if live.attackerGangId == gang.id then
            return 'Your gang is already contesting this turf.'
        end
        if not displaceable(live) then
            return ('%s is already being contested.'):format(z.label)
        end
        -- Falls through on purpose: a STALLED contest can be taken over, and
        -- every remaining gate below still has to pass for the challenger.
    end
    local flipLeft = (Config.Conflict.FlipCooldownSec or 0) - sinceFlip(z)
    if flipLeft > 0 then
        return ('%s changed hands too recently. %d min until it can be contested again.')
            :format(z.label, math.max(1, math.ceil(flipLeft / 60)))
    end
    -- Repel is keyed to the ATTACKING GANG, never to the zone. A zone-keyed
    -- repel is a denial weapon: any gang could open a throwaway contest, lose
    -- it on purpose, and lock the zone against EVERY other gang (including the
    -- owner's real rivals) for RepelCooldownSec. Keying it to the loser
    -- penalises exactly the party that failed and leaves the zone open to
    -- everyone else the instant the contest ends.
    local repelLeft = (Config.Conflict.RepelCooldownSec or 0) - (os.time() - (gangRepelAt[gang.id] or 0))
    if repelLeft > 0 then
        return ('Your gang was driven off turf too recently. %d min to go.')
            :format(math.max(1, math.ceil(repelLeft / 60)))
    end
    local openLeft = (Config.Conflict.OpenCooldownSec or 0) - (os.time() - (gangOpenAt[gang.id] or 0))
    if openLeft > 0 then
        return ('Your gang started a contest too recently. %d min to go.')
            :format(math.max(1, math.ceil(openLeft / 60)))
    end
    return nil
end

-- The 4am gate, stated precisely because it is weaker than it sounds: a rival
-- zone cannot be OPENED unless the owning gang has MinDefendersOnline members
-- CONNECTED TO THE SERVER. That is presence on the server, not ability or
-- willingness to respond: a member AFK on the other side of the map satisfies
-- it, and the gate is checked only at open, so the whole gang can log off one
-- second later and the attacker holds an uncontested window.
--
-- Both of those are deliberate. Re-checking mid-contest and aborting when the
-- defenders go offline would hand every defending gang a guaranteed way to kill
-- any attack on demand (log off, contest dies, zone kept), which is a strictly
-- worse exploit than the one it would close. So the gate does what it can do
-- honestly: it stops a zone being taken from a gang with literally nobody on.
local function defenderGateBlocked(z, maxAge)
    if not Config.Conflict.RequireDefenderOnline then return nil end
    local n = #onlineMembers(z.owner_gang, maxAge)
    if n >= (Config.Conflict.MinDefendersOnline or 1) then return nil end
    return ('Nobody from %s is around to defend %s. Come back when they are.')
        :format(tostring(z.owner_gang), z.label)
end

-- Resolve a player's gang at most ONCE per ticker pass. Bridge.GetGang is two
-- sequential DB reads inside palm6_gangs (memberRow then gangRow, neither
-- cached), and without this memo the same player is re-queried once per LIVE
-- CONTEST per tick, which is exactly the load a busy conflict night creates.
-- The memo is built fresh each pass and thrown away, so a gang change is
-- visible on the next tick. `false` is the "looked up, no gang" marker so a
-- gangless player is not re-queried either.
local function memoGang(memo, psrc)
    if not memo then return Bridge.GetGang(psrc) end
    local hit = memo[psrc]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local g = Bridge.GetGang(psrc)
    memo[psrc] = g or false
    return g
end

-- Re-derive who is physically inside the zone RIGHT NOW. Coordinates come from
-- the server's own read of each ped; gang identity is resolved only for the
-- handful of players who passed the cheap distance test.
local function presenceInZone(z, attackerGangId, defenderGang, memo)
    local atk, def, atkCids = 0, 0, {}
    local radius = Config.Conflict.Radius or 50.0
    for _, psrc in ipairs(Bridge.GetOnlinePlayers()) do
        local c = Bridge.GetCoords(psrc)
        if c and Bridge.Distance(c, z.coords) <= radius then
            local g = memoGang(memo, psrc)
            if g then
                if g.id == attackerGangId then
                    atk = atk + 1
                    local cid = Bridge.GetCitizenId(psrc)
                    if cid then atkCids[#atkCids + 1] = cid end
                elseif g.name == defenderGang then
                    def = def + 1
                end
            end
        end
    end
    return atk, def, atkCids
end

local function notifyGang(gangName, title, msg, kind)
    for _, psrc in ipairs(onlineMembers(gangName)) do
        Bridge.Notify(psrc, title, msg, kind)
    end
end

-- EVERY defender-facing ping goes through here. gangNotifyAt is ONE shared
-- budget per defending gang covering all three: the "X is hitting your turf"
-- open ping, the "you held X" close ping and the "you lost X" close ping.
-- Throttling only the open ping does not close the spam vector, it just moves
-- it: six contests opened on one gang's zones at t=0 suppress five open pings
-- and then deliver six simultaneous unthrottled close pings when they all end.
-- A suppressed ping is never the only source of truth — /turf lists every live
-- contest and the blips always show current ownership.
--
-- Attacker-facing pings are deliberately NOT throttled: an attacker only ever
-- hears about a contest its own gang chose to open, and OpenCooldownSec already
-- bounds how often that can happen.
local function notifyDefender(gangName, title, msg, kind)
    if not gangName or gangName == 'none' then return false end
    local now = os.time()
    if (now - (gangNotifyAt[gangName] or 0)) < (Config.Conflict.NotifyCooldownSec or 300) then
        return false
    end
    gangNotifyAt[gangName] = now
    -- Deferred, pcall'd DB mirror. Stamped BEFORE the notify loop, which yields
    -- once per online member, so the throttle is banked even if this handler is
    -- torn down mid-broadcast. persistBrake never yields the caller.
    persistBrake('notify', gangName, now)
    notifyGang(gangName, title, msg, kind)
    return true
end

-- Commit a capture. Mirrors the instant-flip path's writes but adds the guarded
-- UPDATE, the pulse-scaled rep, and heat. It is a SEPARATE function rather than
-- a shared one on purpose: the disabled path must stay exactly the code that is
-- deployed today, and sharing would have meant editing it.
local function finishCapture(z, ct)
    local now = os.time()
    local prevOwner = ct.defenderGang

    -- The WHERE pins the owner we believe we are taking from, so two
    -- resolutions that somehow interleave can never both flip the same zone.
    -- `<=>` is NULL-safe equality (MySQL 8 and MariaDB both have it), which
    -- matters if the zone was released to NULL under us.
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'UPDATE palm6_turf SET owner_gang = ?, captured_by = ?, captured_at = NOW() '
            .. 'WHERE zone_id = ? AND owner_gang <=> ?',
            { ct.attackerGang, ct.actorCid, z.id, prevOwner }) or 0
    end)
    if affected ~= 1 then
        -- Someone else already moved this zone. Drop the contest, mint nothing.
        return false
    end

    z.owner_gang  = ct.attackerGang
    z.captured_by = ct.actorCid
    z.captured_ts = now   -- starts FlipCooldownSec; persisted as captured_at above

    -- Reputation. Same rule and same PERSISTED per-zone cooldown as the instant
    -- path, scaled by palm6_pulse's 'gang' window if one is live. The pulse read
    -- is soft and re-clamped locally: a sibling's own cap is not our guarantee.
    local mult = 1.0
    if Config.Conflict.UsePulse and GetResourceState('palm6_pulse') == 'started' then
        pcall(function()
            local m = tonumber(exports.palm6_pulse:GetActiveModifier('gang'))
            if m and m > 0 then
                local cap = Config.Conflict.MaxPulseMult or 2.0
                mult = m > cap and cap or m
            end
        end)
    end
    local repAmount = math.floor((Config.RepPerCapture or 0) * mult)
    local mintRep = repAmount > 0 and ct.attackerGangId
        and prevOwner and prevOwner ~= 'none' and prevOwner ~= ct.attackerGang
        and (now - (tonumber(z.rep_at) or 0)) >= (Config.RepCooldownSec or 600)
    if mintRep then
        z.rep_at = now
        pcall(function()
            MySQL.update.await('UPDATE palm6_turf SET rep_at = ? WHERE zone_id = ?', { now, z.id })
        end)
        pcall(function()
            exports.palm6_gangs:AddRep(ct.attackerGangId, repAmount, 'turf_capture')
        end)
    end

    -- Police attention. Wired ONLY here, at the moment territory actually
    -- changes hands, never on the tag action and never on opening a contest,
    -- because this is the only event FlipCooldownSec can rate-limit. Keyed to
    -- the citizenids the server saw standing in the zone at the moment of
    -- capture. Soft-dep + pcall exactly like palm6_smuggling's delivery wire:
    -- a stopped palm6_heat never touches the capture path.
    --
    -- WHO pays is ranked by the seconds the SERVER measured each attacker
    -- inside the radius, not by GetPlayers() order. With 12 attackers and
    -- HeatMaxRecipients = 8, order-based slicing made an arbitrary 8 pay and let
    -- 4 walk; ranking makes the 8 who actually did the work pay. Ties break on
    -- citizenid so the selection is deterministic rather than hash-order.
    -- HeatMinPresenceSec then drops anyone who only drifted through the radius
    -- late in the contest: heat is a PENALTY, so failing open (no heat) is the
    -- safe direction for a bystander.
    local weight = Config.Conflict.HeatOnCapture or 0
    if weight > 0 and GetResourceState('palm6_heat') == 'started' then
        local ranked = {}
        for _, hcid in ipairs(ct.presentCids or {}) do
            ranked[#ranked + 1] = { cid = hcid, sec = (ct.presentSec and ct.presentSec[hcid]) or 0 }
        end
        table.sort(ranked, function(a, b)
            if a.sec ~= b.sec then return a.sec > b.sec end
            return a.cid < b.cid
        end)
        local minSec = Config.Conflict.HeatMinPresenceSec or 0
        local sent = 0
        for _, entry in ipairs(ranked) do
            if sent >= (Config.Conflict.HeatMaxRecipients or 8) then break end
            if entry.sec >= minSec then
                sent = sent + 1
                pcall(function()
                    exports.palm6_heat:AddHeat(entry.cid, weight, 'turf_capture')
                end)
            end
        end
    end

    return true
end

local function closeContest(zoneId, outcome)
    local ct = contests[zoneId]
    if not ct then return end
    contests[zoneId] = nil
    local z = zones[zoneId]
    local label = z and z.label or zoneId

    if outcome == 'captured' then
        notifyGang(ct.attackerGang, 'Turf', ('%s is yours.'):format(label), 'success')
        notifyDefender(ct.defenderGang, 'Turf', ('You lost %s to %s.'):format(label, ct.attackerGang), 'error')
        syncAll()
    elseif outcome == 'defended' then
        -- The repel cooldown lands on the ATTACKING GANG, and only when the
        -- server actually SAW a defender inside the radius during the contest.
        -- Both conditions matter. Keyed to the zone it was a total-denial
        -- weapon: run the window down without banking progress and the zone
        -- locks against every gang, the owner's real rivals included, so a gang
        -- could freeze its own turf with a throwaway alt crew. Ungated by
        -- defenderSeen it paid out for a contest nobody ever defended, which is
        -- not a repel at all. Now it is exactly what the name says: the crew
        -- that got pushed off waits before it can start anything again, and no
        -- third party pays for that.
        if ct.defenderSeen and ct.attackerGangId then
            local repelAt = os.time()
            gangRepelAt[ct.attackerGangId] = repelAt
            -- This runs ON THE TICKER THREAD (closeContest is called from the
            -- contest loop), which is exactly why persistBrake defers the write
            -- to its own coroutine instead of awaiting here.
            persistBrake('repel', ct.attackerGangId, repelAt)
        end
        notifyDefender(ct.defenderGang, 'Turf', ('You held %s.'):format(label), 'success')
        notifyGang(ct.attackerGang, 'Turf', ('You failed to take %s.'):format(label), 'error')
    else
        -- Abandoned or aborted. Deliberately quiet toward the DEFENDER: a
        -- walk-away must not become a second way to ping them.
        --
        -- Deliberately NO repel stamp here. The gang that walked away is already
        -- held off by its own OpenCooldownSec, which is the party that should
        -- pay, and an attacker who never established a foothold has not been
        -- driven off anything.
        notifyGang(ct.attackerGang, 'Turf', ('Your contest on %s collapsed.'):format(label), 'error')
    end
end

-- Contest ticker. Only started when the flag is on. Sleeps cheaply when no
-- contest is open, and only resolves gang identity for players who already
-- passed a distance test, so an idle server pays nothing for this.
local function startContestTicker()
    CreateThread(function()
        local tick = math.max(1, Config.Conflict.TickSeconds or 5)
        -- One pass is NOT `tick` seconds of real time and must never be treated
        -- as if it were. presenceInZone yields (gang identity is a DB read) and
        -- every live contest is processed serially on this one thread, so a
        -- 15v15 fight across several zones stretches a pass well past its Wait.
        -- Meanwhile endsAt and the abandon clock run on real wall time. Banking
        -- `tick` per pass therefore makes the clock lie WORST when the feature
        -- is busiest, which is backwards for a contest mechanic, so every
        -- accumulator below uses MEASURED elapsed seconds instead.
        --
        -- The step is capped at MaxCatchupTicks so the opposite failure is
        -- bounded too: one pathological stall must not bank a whole capture off
        -- a single presence sample taken after it.
        local maxStep = tick * math.max(1, Config.Conflict.MaxCatchupTicks or 4)
        while true do
            Wait(tick * 1000)
            local now = os.time()

            -- Bound the anti-grief ledgers: an entry older than its own window
            -- can no longer gate anything (same sweep as palm6_drugs' heatLast).
            -- Memory only, no DB work on this thread; the matching rows in
            -- palm6_turf_brakes are deleted by startBrakeSweeper on its own
            -- thread, using `set_at < now - window`, which is this same
            -- `ts + window < now` test rearranged.
            for gid, ts in pairs(gangOpenAt) do
                if ts + (Config.Conflict.OpenCooldownSec or 600) < now then gangOpenAt[gid] = nil end
            end
            for gname, ts in pairs(gangNotifyAt) do
                if ts + (Config.Conflict.NotifyCooldownSec or 300) < now then gangNotifyAt[gname] = nil end
            end
            for gid, ts in pairs(gangRepelAt) do
                if ts + (Config.Conflict.RepelCooldownSec or 600) < now then gangRepelAt[gid] = nil end
            end

            -- Snapshot the keys BEFORE touching anything. presenceInZone yields
            -- (it reads the DB), and a `palm6_turf:complete` landing during that
            -- yield can INSERT a brand new contest key. Adding a key to a table
            -- that is mid-`pairs()` traversal is undefined in Lua, so the loop
            -- must not be the live table. Deleting is safe, hence the nils below
            -- and inside closeContest are fine.
            local liveZoneIds = {}
            for zoneId in pairs(contests) do liveZoneIds[#liveZoneIds + 1] = zoneId end

            -- One gang lookup per player per PASS, shared by every contest in
            -- this pass. Built here (not inside presenceInZone) so six live
            -- contests cost one lookup for a given player, not six.
            local gangMemo = {}

            for _, zoneId in ipairs(liveZoneIds) do
                local ct = contests[zoneId]
                local z = ct and zones[zoneId]
                if ct and not z then
                    contests[zoneId] = nil
                elseif ct then
                    -- presenceInZone yields (DB reads). Re-check that THIS
                    -- contest is still the live one before mutating it, so a
                    -- resolution that happened during the yield is not undone.
                    local atk, def, cids = presenceInZone(z, ct.attackerGangId, ct.defenderGang, gangMemo)
                    if contests[zoneId] == ct then
                        -- MEASURED elapsed, read after the yields above, not the
                        -- loop's `tick`. See maxStep at the top of this thread.
                        local tnow = os.time()
                        local elapsed = tnow - (ct.lastTickAt or tnow)
                        if elapsed < 0 then elapsed = 0 end
                        if elapsed > maxStep then elapsed = maxStep end
                        ct.lastTickAt = tnow

                        ct.presentCids = cids
                        if #cids > 0 then ct.actorCid = cids[1] end
                        -- Per-attacker presence ledger, used to rank heat
                        -- recipients at capture (see finishCapture).
                        for _, pcid in ipairs(cids) do
                            ct.presentSec[pcid] = (ct.presentSec[pcid] or 0) + elapsed
                        end
                        -- Latched: did the server ever see a defender in the
                        -- radius? Gates the repel stamp in closeContest.
                        if def > 0 then ct.defenderSeen = true end

                        if atk > 0 and atk > def then
                            ct.progress = ct.progress + elapsed
                        elseif def > 0 then
                            ct.progress = ct.progress - (elapsed * (Config.Conflict.DefenderDecayMult or 2.0))
                        else
                            ct.progress = ct.progress - elapsed
                        end
                        if ct.progress < 0 then ct.progress = 0 end

                        -- THE ANTI-LOCK CLOCK. It measures progress against the
                        -- attacker's own HIGH-WATER MARK, not against presence,
                        -- and that distinction is the whole point: an "is anyone
                        -- standing here" clock is trivially reset by stepping in
                        -- and out of the radius, and a contest that cannot be
                        -- ended is a zone that cannot be attacked by anybody
                        -- else. A contest survives only while the attacker keeps
                        -- BEATING their own best, so every way of not taking the
                        -- zone collapses on the same AbandonSeconds timer:
                        -- walking away, oscillating across the radius edge, and
                        -- being pinned at a standstill by defenders.
                        if ct.progress > ct.peak then
                            ct.peak = ct.progress
                            ct.stalledFor = 0
                        else
                            ct.stalledFor = ct.stalledFor + elapsed
                        end

                        if ct.progress >= (Config.Conflict.HoldSeconds or 120) then
                            if finishCapture(z, ct) then
                                closeContest(zoneId, 'captured')
                            else
                                closeContest(zoneId, 'aborted')
                            end
                        elseif ct.stalledFor >= (Config.Conflict.AbandonSeconds or 60) then
                            -- Same clock, two different stories, told apart by
                            -- whether the server ever saw a defender in the
                            -- radius. Defenders present and the attacker made no
                            -- headway: that is a successful defence and is
                            -- credited as one. Nobody there at all: the attacker
                            -- simply wandered off, which must stay the quiet
                            -- path so a walk-away cannot be used to ping the
                            -- defenders or to stamp a repel.
                            closeContest(zoneId, ct.defenderSeen and 'defended' or 'aborted')
                        -- os.time() rather than the loop's `now`: presenceInZone
                        -- yielded, possibly several times across several
                        -- contests, so `now` is stale by the time we get here.
                        elseif os.time() >= ct.endsAt then
                            closeContest(zoneId, 'defended')
                        end
                    end
                end
            end
        end
    end)
end

-- Open a contest instead of flipping. Called ONLY from the enabled branch of
-- `palm6_turf:complete`, after that handler has already re-verified gang,
-- proximity, and that the tag animation was not skipped.
local function openContest(src, z, gang, cid)
    -- Re-run every gate: `complete` lands seconds after `requestTag`, and this
    -- is the authoritative check. Cheap gates first, then the DB-backed one.
    local why = contestBlocked(z, gang)
    if why then Bridge.Notify(src, 'Turf', why, 'error'); return end
    why = defenderGateBlocked(z, 0)   -- maxAge 0: force a fresh headcount here
    if why then Bridge.Notify(src, 'Turf', why, 'error'); return end

    -- CHECK-AND-SET with no yield between them. Everything that can yield ran
    -- above, so two players from different gangs completing a tag on the same
    -- zone in the same instant cannot both install a contest: the second one
    -- finds contests[z.id] already set and is refused by contestBlocked on its
    -- own pass, or by this guard. Displacement does not weaken that, because a
    -- contest installed microseconds ago has stalledFor = 0 and the ticker has
    -- not run on it yet, so it is not displaceable.
    --
    -- A STALLED incumbent is displaced rather than refused (see displaceable).
    -- The swap below is a plain overwrite of the same key, so it is still one
    -- yield-free step; closeContest is deliberately NOT called here because it
    -- notifies, and notifying yields, which would reopen exactly the race this
    -- block exists to close. The pushed-aside crew is told AFTER the new
    -- contest is installed. The ticker is safe either way: it re-checks
    -- `contests[zoneId] == ct` after its own yields and skips a contest that
    -- was replaced underneath it.
    local displacedGang = nil
    local live = contests[z.id]
    if live then
        if live.attackerGangId == gang.id or not displaceable(live) then
            Bridge.Notify(src, 'Turf', ('%s is already being contested.'):format(z.label), 'error')
            return
        end
        displacedGang = live.attackerGang
    end
    local now = os.time()
    contests[z.id] = {
        zoneId         = z.id,
        attackerGang   = gang.name,
        attackerGangId = gang.id,   -- matched on the IMMUTABLE id, so a mid-contest
                                    -- gang rename cannot orphan the attacker
        defenderGang   = z.owner_gang,
        openerCid      = cid,
        actorCid       = cid,
        presentCids    = { cid },
        presentSec     = {},         -- [citizenid] = measured seconds in radius
        openedAt       = now,
        lastTickAt     = now,        -- anchor for MEASURED elapsed in the ticker
        endsAt         = now + (Config.Conflict.ContestSeconds or 300),
        progress       = 0,
        peak           = 0,          -- best progress ever reached
        stalledFor     = 0,          -- measured seconds since peak last rose
        defenderSeen   = false,      -- latched once a defender is seen in radius
    }
    gangOpenAt[gang.id] = now
    -- Mirrored to palm6_turf_brakes so a restart cannot hand this gang a free
    -- early reopen. Deferred and pcall'd: it must not delay the notify below,
    -- and it must not be able to fail the contest that was just installed.
    persistBrake('open', gang.id, now)

    local mins = math.max(1, math.ceil((Config.Conflict.ContestSeconds or 300) / 60))
    local hold = math.max(1, math.ceil((Config.Conflict.HoldSeconds or 120) / 60))
    Bridge.Notify(src, 'Turf',
        ('Contest opened on %s. Hold it for %d min within the next %d.'):format(z.label, hold, mins), 'success')

    -- Everything from here on may yield. The new contest is already installed.
    if displacedGang then
        notifyGang(displacedGang, 'Turf',
            ('Another crew took over the fight for %s.'):format(z.label), 'error')
    end

    -- Defender notification, throttled PER DEFENDING GANG across all attackers
    -- AND across open/held/lost alike (see notifyDefender). A suppressed contest
    -- still runs; it just does not re-ping. /turf always shows the live board,
    -- so a throttled defender is never blind to it.
    notifyDefender(z.owner_gang, 'Turf',
        ('%s is hitting your turf at %s. Get there and hold it.'):format(gang.name, z.label), 'error')
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The whole boot sequence runs on this thread because ensureSchema has to
    -- Wait for oxmysql's connection before it can issue any query, and neither
    -- ensureZones nor loadZones may run before the table is guaranteed to
    -- exist. That Wait is why bootReady exists: until the load lands, `zones`
    -- is EMPTY, and an ungated tag request would silently no-op on a nil zone
    -- instead of telling the player why. The final syncAll repairs any client
    -- that asked for a sync during the window and got an empty set.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It is the only line that can report the fresh-box
        -- case: loadZones falls back to Config, so the "loaded N zone(s)" line
        -- below prints the same number whether or not the table exists.
        if not SchemaReady then
            print('^1[palm6_turf] schema MISSING - turf ownership does NOT persist on this box.^0')
        end
        ensureZones()
        loadZones()
        -- CONFLICT only: pull the PERSISTED last-flip timestamps that drive
        -- FlipCooldownSec. Deliberately a SECOND, separately-pcall'd query
        -- rather than a change to loadZones' `SELECT *`: naming columns there
        -- would make the whole load throw on a box where the additive rep_at
        -- ALTER never applied, and that load is on the disabled path. Every
        -- column named here is in the CREATE TABLE, so it cannot be missing.
        -- Any zone this misses keeps captured_ts nil, which sinceFlip reads as
        -- "never flipped": the cooldown fails OPEN, never locked.
        if conflictOn() then
            pcall(function()
                local rows = MySQL.query.await(
                    'SELECT zone_id, UNIX_TIMESTAMP(captured_at) AS captured_ts FROM palm6_turf') or {}
                for _, r in ipairs(rows) do
                    local z = zones[r.zone_id]
                    if z then z.captured_ts = tonumber(r.captured_ts) or 0 end
                end
            end)
            -- Per-gang brakes. The table is created HERE and not in
            -- ensureSchema(), so a box running with the feature off never grows
            -- it. Order matters: the brakes must be back in memory before the
            -- ticker can close a contest and before any gate can be evaluated,
            -- and the sweeper is started last so it can never race the load.
            ensureBrakeSchema()
            loadBrakes()
            if brakesReady then startBrakeSweeper() end
            conflictBootAt = os.time()   -- starts RestartGraceSec (see contestBlocked)
            startContestTicker()
            print(('[palm6_turf] conflict ARMED - hold %ds inside %.0fm, window %ds, flip cooldown %ds, grace %ds, brakes %s')
                :format(Config.Conflict.HoldSeconds or 0, Config.Conflict.Radius or 0,
                        Config.Conflict.ContestSeconds or 0, Config.Conflict.FlipCooldownSec or 0,
                        Config.Conflict.RestartGraceSec or 0,
                        brakesReady and 'persisted' or 'MEMORY ONLY'))
        end
        bootReady = true
        print(('[palm6_turf] loaded %d turf zone(s)'):format(#Config.Zones))
        syncAll()
    end)
end)

RegisterNetEvent('palm6_turf:requestSync', function()
    TriggerClientEvent('palm6_turf:syncZones', source, publicZones())
end)

RegisterNetEvent('palm6_turf:requestTag', function(zoneId)
    local src = source
    if not Bridge.GetCitizenId(src) then return end
    -- `zones` is empty until the boot load lands (~3s after resource start,
    -- because ensureSchema has to wait for oxmysql). Without this gate the
    -- nil-zone check below would refuse the tag with NO message at all.
    if not bootReady then
        Bridge.Notify(src, 'Turf', 'Turf is still loading. Try again in a moment.', 'error')
        return
    end
    local z = zones[zoneId]
    if not z then return end

    local gang = Bridge.GetGang(src)
    if not gang then
        Bridge.Notify(src, 'Turf', 'You need to be in a gang to tag turf.', 'error')
        return
    end
    if z.owner_gang == gang.name then
        Bridge.Notify(src, 'Turf', 'Your gang already holds this turf.', 'error')
        return
    end

    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, z.coords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Turf', 'You are too far from this turf.', 'error')
        return
    end

    -- CONFLICT pre-check. REFUSALS ONLY, so the player learns the zone is locked
    -- before being asked to stand still for TagProgressMs, not after. Every gate
    -- here re-runs authoritatively in openContest, which is what actually
    -- decides. Skipped entirely with the flag off, and skipped for an UNOWNED
    -- zone, which stays an instant claim because there is no defender to give a
    -- window to. Cheapest gates run first (contestBlocked touches no DB); the
    -- defender headcount is served from a short cache so repeated [E] presses
    -- cannot turn this into a per-press scan of every online player.
    if conflictOn() and z.owner_gang and z.owner_gang ~= 'none' then
        local why = contestBlocked(z, gang) or defenderGateBlocked(z)
        if why then
            Bridge.Notify(src, 'Turf', why, 'error')
            return
        end
    end

    pending[src] = { zoneId = zoneId, gangName = gang.name, startedAt = os.time(), holdUntil = os.time() + 30 }
    TriggerClientEvent('palm6_turf:begin', src, { zoneId = zoneId, label = z.label })
end)

RegisterNetEvent('palm6_turf:complete', function(zoneId)
    local src = source
    local pend = pending[src]
    if not pend or pend.zoneId ~= zoneId then return end
    pending[src] = nil
    local now = os.time()
    if now > pend.holdUntil then return end
    if now - pend.startedAt < math.floor(Config.TagProgressMs / 1000) then return end  -- skipped the tag animation

    local z = zones[zoneId]
    if not z then return end
    local gang = Bridge.GetGang(src)
    if not gang or gang.name ~= pend.gangName then return end

    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, z.coords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Turf', 'You left the turf.', 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src)
    local prevOwner = z.owner_gang   -- capture before the flip for takeover check

    -- CONFLICT: a RIVAL-held zone no longer flips here. Finishing the tag now
    -- OPENS a contest and returns; the ticker decides who ends up owning it. An
    -- UNOWNED zone falls straight through to the instant claim below, unchanged,
    -- because there is no defender to notify or give a window to.
    --
    -- With Config.Conflict.Enabled = false this condition short-circuits on its
    -- FIRST term and every line below is byte-for-byte the flip that is
    -- deployed today. That is the whole reason the contest capture lives in its
    -- own finishCapture() instead of being folded into this block.
    if conflictOn() and prevOwner and prevOwner ~= 'none' and prevOwner ~= gang.name then
        openContest(src, z, gang, cid)
        return
    end

    -- Reputation for a GENUINE takeover: the zone was held by a DIFFERENT
    -- player-run gang, and this zone hasn't minted rep within RepCooldownSec.
    -- The cooldown is PERSISTED in palm6_turf.rep_at so a server restart can't
    -- reset it (an in-memory version let a reboot re-enable an instant mint).
    -- Claiming unowned turf grants nothing. Rep is a DISPLAY-ONLY prestige stat:
    -- it does NOT pay a season prize (palm6_season rep ladder is noPrize), so it
    -- cannot be farmed for cash by two gangs trading zones. AddRep is soft/pcall.
    local mintRep = Config.RepPerCapture and Config.RepPerCapture > 0 and gang.id
        and prevOwner and prevOwner ~= 'none' and prevOwner ~= gang.name
        and (now - (tonumber(z.rep_at) or 0)) >= (Config.RepCooldownSec or 600)

    z.owner_gang = gang.name
    z.captured_by = cid
    -- Mirror of finishCapture's stamp. This is the OTHER runtime write of
    -- captured_at, and without the matching in-memory stamp sinceFlip() kept
    -- reading math.huge for every zone claimed this way: an instantly-claimed
    -- zone could be contested one second later with no flip cooldown at all,
    -- for the whole life of the process. Inert while the flag is off, because
    -- sinceFlip is only ever reached from contestBlocked.
    z.captured_ts = now
    if mintRep then z.rep_at = now end
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_turf SET owner_gang = ?, captured_by = ?, captured_at = NOW()'
            .. (mintRep and ', rep_at = ?' or '') .. ' WHERE zone_id = ?',
            mintRep and { gang.name, cid, now, zoneId } or { gang.name, cid, zoneId })
    end)

    if mintRep then
        pcall(function()
            exports.palm6_gangs:AddRep(gang.id, Config.RepPerCapture, 'turf_takeover')
        end)
    end

    Bridge.Notify(src, 'Turf', ('%s tagged for %s.'):format(z.label, gang.name), 'success')
    syncAll()
end)

RegisterNetEvent('palm6_turf:cancel', function(zoneId)
    local src = source
    local pend = pending[src]
    if pend and pend.zoneId == zoneId then pending[src] = nil end
end)

-- Cascade a gang rename onto turf ownership. Turf keys owner_gang on the MUTABLE
-- gang NAME (both the DB rows and the in-memory `zones` cache), so a /gang rename
-- that does not rewrite it silently orphans the gang's territory: live
-- comparisons (z.owner_gang == gang.name) stop matching, palm6_protection can no
-- longer collect on its own turf, season turf standings drop to 0, and — worst —
-- dbmigrate 0049 (runs every boot) permanently NULLs any turf whose owner_gang is
-- not a current palm6_gangs.name, so the renamed gang loses all turf on the next
-- restart. palm6_gangs calls this from its rename success path. Idempotent and
-- guarded; returns the number of DB rows rewritten (0 if the gang held no turf).
exports('RenameOwner', function(oldName, newName)
    if type(oldName) ~= 'string' or type(newName) ~= 'string' then return 0 end
    if oldName == '' or newName == '' or oldName == newName then return 0 end
    local updated = 0
    pcall(function()
        updated = MySQL.update.await(
            'UPDATE palm6_turf SET owner_gang = ? WHERE owner_gang = ?', { newName, oldName }) or 0
    end)
    -- Keep any LIVE contest pointed at the renamed gang. A contest matches its
    -- ATTACKER on the immutable gang id, so a rename cannot orphan that side,
    -- but the DEFENDER is matched on NAME because that is what turf ownership is
    -- keyed on. Without this a defending gang that renamed mid-contest would
    -- stop counting as present and hand the zone over. Empty loop (so a no-op)
    -- whenever Config.Conflict.Enabled is false, since nothing can open then.
    for _, ct in pairs(contests) do
        if ct.defenderGang == oldName then ct.defenderGang = newName end
        if ct.attackerGang == oldName then ct.attackerGang = newName end
    end

    -- Rewrite the in-memory cache so live name comparisons match without a reload.
    local touched = false
    for _, z in pairs(zones) do
        if z.owner_gang == oldName then z.owner_gang = newName; touched = true end
    end
    if touched then syncAll() end
    return updated
end)

--- Read-only snapshot of every LIVE turf contest, keyed by zone id, for siblings
--- that want to narrate or score gang conflict (cityfeed, season, ganginfo).
--- Returns COPIES so a consumer cannot mutate contest state. Always an empty
--- table while Config.Conflict.Enabled is false, so a consumer wired today is
--- inert until the flag is flipped rather than broken by it.
exports('GetContests', function()
    local out = {}
    for zoneId, ct in pairs(contests) do
        local z = zones[zoneId]
        out[zoneId] = {
            zoneId       = zoneId,
            label        = z and z.label or zoneId,
            attackerGang = ct.attackerGang,
            defenderGang = ct.defenderGang,
            openedAt     = ct.openedAt,
            endsAt       = ct.endsAt,
            progress     = ct.progress,
            holdSeconds  = Config.Conflict and Config.Conflict.HoldSeconds or 0,
        }
    end
    return out
end)

RegisterCommand('turf', function(src)
    local counts = {}
    for _, z in pairs(zones) do
        if z.owner_gang then
            counts[z.owner_gang] = (counts[z.owner_gang] or 0) + 1
        end
    end

    local board = {}
    for gang, count in pairs(counts) do board[#board + 1] = { gang = gang, count = count } end
    table.sort(board, function(a, b) return a.count > b.count end)

    local lines = {}
    for i, entry in ipairs(board) do
        lines[#lines + 1] = ('%d. **%s** — %d turf'):format(i, entry.gang, entry.count)
    end
    for _, z in pairs(zones) do
        if not z.owner_gang then
            lines[#lines + 1] = ('_%s — unclaimed_'):format(z.label)
        end
    end

    -- Live contests. This is the reason NotifyCooldownSec is safe: a defender
    -- whose notification was throttled is never blind, because the board always
    -- shows every open contest. `contests` is permanently empty with the flag
    -- off, so this adds nothing to today's output.
    if conflictOn() then
        for zoneId, ct in pairs(contests) do
            local z = zones[zoneId]
            local left = math.max(0, ct.endsAt - os.time())
            local pct = math.floor((ct.progress / math.max(1, Config.Conflict.HoldSeconds or 120)) * 100)
            if pct > 100 then pct = 100 end
            lines[#lines + 1] = ('**CONTESTED** %s - %s attacking %s, %d%% held, %ds left'):format(
                z and z.label or zoneId, ct.attackerGang, tostring(ct.defenderGang), pct, left)
        end
    end

    if #lines == 0 then lines[1] = 'No turf claimed yet.' end
    TriggerClientEvent('palm6_turf:showLog', src, table.concat(lines, '\n'))
end, false)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
