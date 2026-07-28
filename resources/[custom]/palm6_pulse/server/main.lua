-- ============================================================================
-- palm6_pulse — live city director (server logic)
--
-- Every Config.TickSeconds the director evaluates population + what's happening
-- and opens the single best-fitting Pulse Window: a ~15-min, city-wide, fully
-- transparent PAYOUT MODIFIER that sibling resources read at grant time via
-- exports.palm6_pulse:GetActiveModifier(domain[, target]). Pulse itself NEVER
-- grants money/items except the participation reward, which is gated by an
-- atomic UNIQUE-key check-in row, so it can never be double-collected.
--
-- Authoritative state: the DB `palm6_pulse_windows` table. The active window is
-- derived from the newest row where ends_at > now (restart/relog-safe — no
-- in-DB "active" flag to desync), and rehydrated into memory on boot.
-- ============================================================================

local function now() return os.time() end
local function dbg(m) if Config.Debug then print('[palm6_pulse] ' .. m) end end

-- In-memory mirror of the authoritative active window (nil = quiet).
local active = nil          -- { id, kind, label, domain, modifier, target, blurb, startedAt, endsAt, reason, onlineStart }
local lastCloseAt = 0       -- unix ts of the last window close (cooldown anchor)

local SchemaReady = false   -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: runs on the director thread after its existing wait, with a
-- per-statement pcall, everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a new box boots with no palm6_pulse_*
-- tables. Every query here is pcall-wrapped, so the failure is near-silent: the
-- director opens nothing (only a Config.Debug-gated dbg line says why), and the
-- UNIQUE(window_id,citizenid) row that IS the check-in consume gate does not
-- exist, so the participation reward loses its double-collect guard entirely.
-- On the live box these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0048_pulse.sql, inline SQL comments included
-- (trailing semicolons dropped, same as the other resources that carry their
-- own DDL). The same statements are also embedded in palm6_dbmigrate, which
-- 0048 itself notes; both are IF NOT EXISTS so whichever runs second no-ops.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_windows` (
    id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    kind          VARCHAR(32)  NOT NULL,           -- boomtown|hot_exchange|bounty_surge|crackdown|turf_war
    domain        VARCHAR(16)  NOT NULL,           -- grind|market|bounty|police|gang
    modifier      DOUBLE       NOT NULL,           -- capped payout scalar
    target        VARCHAR(64)  NULL,               -- optional sub-key (e.g. spiked commodity)
    reason        VARCHAR(128) NOT NULL,
    online_start  INT          NOT NULL DEFAULT 0,
    started_at    BIGINT       NOT NULL,
    ends_at       BIGINT       NOT NULL,
    INDEX idx_palm6_pulse_windows_ends (ends_at)
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_checkins` (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    window_id   INT          NOT NULL,
    citizenid   VARCHAR(64)  NOT NULL,
    ts          BIGINT       NOT NULL,
    UNIQUE KEY uq_palm6_pulse_checkin (window_id, citizenid),  -- the consume/idempotency gate
    INDEX idx_palm6_pulse_checkins_cid (citizenid)
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_pulse_streaks` (
    citizenid       VARCHAR(64) NOT NULL PRIMARY KEY,
    streak          INT         NOT NULL DEFAULT 0,
    best_streak     INT         NOT NULL DEFAULT 0,
    pulse_points    INT         NOT NULL DEFAULT 0,   -- lifetime; feeds the season scoreboard, no cash value
    last_window_id  INT         NOT NULL DEFAULT 0,
    updated_at      BIGINT      NOT NULL DEFAULT 0
)
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_pulse] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- ---------------------------------------------------------------------------
-- DB helpers (all pcall-guarded — pulse boots + runs even if the table is
-- absent; it just can't open/persist windows until the migration is applied).
-- ---------------------------------------------------------------------------
-- Pure read: returns the active window only while it is genuinely open. Does NOT
-- clear state — closeWindow() is the ONLY mutator (it also sets the cooldown
-- anchor), so a consumer reading after expiry can't bypass the inter-window
-- cooldown by silently clearing `active`.
local function activeWindow()
    if active and active.endsAt > now() then return active end
    return nil
end

local function rehydrate()
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT * FROM palm6_pulse_windows WHERE ends_at > ? ORDER BY id DESC LIMIT 1', { now() })
    end)
    if row then
        local cat = Config.Windows[row.kind]
        active = {
            id = row.id, kind = row.kind, label = cat and cat.label or row.kind,
            domain = row.domain, modifier = tonumber(row.modifier) or 1.0, target = row.target,
            blurb = cat and cat.blurb or '', startedAt = tonumber(row.started_at) or now(),
            endsAt = tonumber(row.ends_at) or now(), reason = row.reason, onlineStart = row.online_start or 0,
        }
        dbg(('rehydrated active window #%d %s (%ds left)'):format(active.id, active.kind, active.endsAt - now()))
    else
        -- No active window: seed the cooldown anchor from the most recent window's
        -- end so the inter-window cooldown survives a restart (else a restart mid-
        -- cooldown would open a new window immediately).
        pcall(function()
            local last = MySQL.single.await('SELECT ends_at FROM palm6_pulse_windows ORDER BY id DESC LIMIT 1')
            if last and last.ends_at then lastCloseAt = tonumber(last.ends_at) or 0 end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Population-aware eligibility. Every sibling read is pcall-guarded; if we can't
-- confirm a precondition, the window is treated as NOT eligible (fail safe: we
-- never fire a gang/warrant window we can't justify).
-- ---------------------------------------------------------------------------
local function distinctGangsOnline()
    local seen, n = {}, 0
    if not Bridge.ResourceStarted('palm6_gangs') then return 0 end
    local ok = pcall(function()
        for _, cid in ipairs(Bridge.GetOnlineCitizenIds()) do
            local g = exports.palm6_gangs:GetGang(cid)
            local gid = g and (g.id or g.gang_id)
            if gid and not seen[gid] then seen[gid] = true; n = n + 1 end
        end
    end)
    return ok and n or 0
end

local function windowEligible(kind, cat, online)
    if online < (cat.minOnline or Config.MinOnline) then return false end
    if kind == 'turf_war' then
        return distinctGangsOnline() >= 2
    end
    -- boomtown / hot_exchange / bounty_surge / crackdown: population gate only.
    -- (bounty_surge/crackdown weighting could later read palm6_mdt warrants; the
    -- online gate keeps v0.1 inert-safe without depending on sibling summaries.)
    return true
end

-- Weighted-random pick among eligible windows. Returns kind or nil.
local function pickWindow(online)
    local pool, total = {}, 0
    for kind, cat in pairs(Config.Windows) do
        if windowEligible(kind, cat, online) then
            local w = math.max(1, cat.weight or 1)
            pool[#pool + 1] = { kind = kind, cat = cat, w = w }
            total = total + w
        end
    end
    if total <= 0 then return nil end
    local roll = math.random(1, total)
    for _, e in ipairs(pool) do
        roll = roll - e.w
        if roll <= 0 then return e.kind, e.cat end
    end
    return pool[#pool].kind, pool[#pool].cat
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------
local function announce(w)
    if Config.Toast then
        Bridge.Broadcast(('PULSE — %s'):format(w.label),
            ('%s  ·  /pulse checkin at the action to bank points.'):format(w.blurb), 'inform')
    end
    local hook = Bridge.GetConvar(Config.DiscordConvar)
    if hook then
        Bridge.PostDiscord(hook, {
            title = ('📣 Pulse Window — %s'):format(w.label),
            description = w.blurb,
            color = 15158332, -- palm6 pink/red
        })
    end
    dbg(('opened %s domain=%s x%.2f target=%s reason=%s'):format(w.kind, w.domain, w.modifier, tostring(w.target), w.reason))
end

local function openWindow(online)
    local kind, cat = pickWindow(online)
    if not kind then return end
    local target = nil
    if kind == 'hot_exchange' then
        local list = Config.MarketCommodities
        if list and #list > 0 then target = list[math.random(1, #list)] end
    end
    local modifier = math.min(Config.MaxModifier, cat.modifier or 1.0)
    local startedAt, endsAt = now(), now() + Config.WindowSeconds
    local reason = ('director: online=%d weighted-pick'):format(online)

    local id
    local ok = pcall(function()
        id = MySQL.insert.await(
            'INSERT INTO palm6_pulse_windows (kind, domain, modifier, target, reason, online_start, started_at, ends_at) '
            .. 'VALUES (?,?,?,?,?,?,?,?)',
            { kind, cat.domain, modifier, target, reason, online, startedAt, endsAt })
    end)
    if not ok or not id then dbg('open failed — is sql/0048_pulse.sql applied?'); return end

    active = {
        id = id, kind = kind, label = cat.label, domain = cat.domain, modifier = modifier,
        target = target, blurb = cat.blurb, startedAt = startedAt, endsAt = endsAt,
        reason = reason, onlineStart = online,
    }
    announce(active)
end

local function closeWindow()
    if not active then return end
    dbg(('closed %s (#%d)'):format(active.kind, active.id))
    active = nil
    lastCloseAt = now()
end

-- ---------------------------------------------------------------------------
-- Director tick
-- ---------------------------------------------------------------------------
CreateThread(function()
    Wait(5000)           -- let siblings finish booting (also covers oxmysql's connect)
    ensureSchema()       -- must precede rehydrate(): it reads palm6_pulse_windows
    rehydrate()
    print(('^5[palm6_pulse]^0 director online — tick=%ds window=%ds cooldown=%ds minOnline=%d')
        :format(Config.TickSeconds, Config.WindowSeconds, Config.CooldownSeconds, Config.MinOnline))
    if not SchemaReady then
        print('^1[palm6_pulse] schema MISSING - no window can open and check-ins are INERT on this box.^0')
    end
    while true do
        Wait(Config.TickSeconds * 1000)
        -- Close an expired window FIRST (this is what sets the cooldown anchor).
        if active and active.endsAt <= now() then closeWindow() end
        -- Open a new one only when idle, past cooldown, and populated enough.
        if not active then
            local cooling = lastCloseAt > 0 and (now() - lastCloseAt) < Config.CooldownSeconds
            if not cooling then
                local online = Bridge.GetOnlineCount()
                if online >= Config.MinOnline then openWindow(online) end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Check-in (participation reward) — server-authoritative via /pulse checkin.
-- Money-safety: the UNIQUE(window_id,citizenid) row IS the consume gate. Only a
-- genuinely inserted row grants points/tip, so spamming can never double-collect.
-- ---------------------------------------------------------------------------
local function doCheckin(src)
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local w = activeWindow()
    if not w then
        Bridge.Notify(src, 'Pulse', 'No Pulse Window is open right now.', 'error'); return
    end

    -- Atomic consume: dup (window_id,citizenid) throws -> already checked in.
    local inserted = pcall(function()
        MySQL.insert.await('INSERT INTO palm6_pulse_checkins (window_id, citizenid, ts) VALUES (?,?,?)',
            { w.id, cid, now() })
    end)
    if not inserted then
        Bridge.Notify(src, 'Pulse', 'You already checked in to this window.', 'inform'); return
    end

    -- Streak: consecutive if this window id follows the last within the grace gap.
    local srow
    pcall(function()
        srow = MySQL.single.await('SELECT streak, best_streak, pulse_points, last_window_id FROM palm6_pulse_streaks WHERE citizenid = ?', { cid })
    end)
    local prevStreak = srow and tonumber(srow.streak) or 0
    local prevBest   = srow and tonumber(srow.best_streak) or 0
    local prevPoints = srow and tonumber(srow.pulse_points) or 0
    local lastWid    = srow and tonumber(srow.last_window_id) or 0
    local streak
    if lastWid > 0 and (w.id - lastWid) <= (Config.StreakGraceWindows + 1) and w.id > lastWid then
        streak = prevStreak + 1
    else
        streak = 1
    end
    local bonus  = math.min(streak * Config.StreakBonusPoints, Config.StreakBonusCap)
    local points = Config.PointsPerCheckin + bonus
    local best   = math.max(prevBest, streak)

    pcall(function()
        MySQL.update.await(
            'INSERT INTO palm6_pulse_streaks (citizenid, streak, best_streak, pulse_points, last_window_id, updated_at) '
            .. 'VALUES (?,?,?,?,?,?) ON DUPLICATE KEY UPDATE streak=VALUES(streak), best_streak=VALUES(best_streak), '
            .. 'pulse_points=VALUES(pulse_points), last_window_id=VALUES(last_window_id), updated_at=VALUES(updated_at)',
            { cid, streak, best, prevPoints + points, w.id, now() })
    end)

    -- Optional flat, hard-capped clean-cash tip — reached only via the atomic
    -- insert above, so it is once-per-window and cannot be double-granted.
    if (Config.CashTip or 0) > 0 then
        Bridge.AddCash(src, Config.CashTip, 'pulse_checkin')
    end

    Bridge.Notify(src, 'Pulse',
        ('Checked in to %s. +%d pulse points (streak %d).'):format(w.label, points, streak), 'success')
end

-- ---------------------------------------------------------------------------
-- /pulse  — status/meter; /pulse checkin — bank participation
-- ---------------------------------------------------------------------------
local function meter()
    -- 0..100 city activity index: online headroom + whether a window is live +
    -- recent check-in energy. Cheap, computed on read.
    local online = Bridge.GetOnlineCount()
    local base = math.min(60, online * 6)          -- population component
    local live = activeWindow() and 30 or 0        -- an open window = energy
    local recent = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_pulse_checkins WHERE ts > ?', { now() - 900 })
        recent = math.min(10, (r and tonumber(r.n) or 0))
    end)
    return math.min(100, base + live + recent)
end

Bridge.RegisterCommand('pulse', function(src, args)
    if src == 0 then return end
    if args and args[1] and args[1]:lower() == 'checkin' then
        doCheckin(src); return
    end
    local lines = {}
    lines[#lines + 1] = ('City Pulse: %d / 100'):format(meter())
    local w = activeWindow()
    if w then
        local mins = math.floor((w.endsAt - now()) / 60)
        lines[#lines + 1] = ('LIVE: %s — %s'):format(w.label, w.blurb)
        lines[#lines + 1] = ('Ends in ~%d min. Type /pulse checkin at the action to bank points.'):format(math.max(0, mins))
        if w.target then lines[#lines + 1] = ('Focus: %s'):format(w.target) end
    else
        lines[#lines + 1] = 'No window open right now — the city director is watching. Stay online.'
    end
    local cid = Bridge.GetCitizenId(src)
    if cid then
        pcall(function()
            local s = MySQL.single.await('SELECT streak, best_streak, pulse_points FROM palm6_pulse_streaks WHERE citizenid = ?', { cid })
            if s then lines[#lines + 1] = ('Your streak: %d (best %d) · %d pulse points'):format(
                tonumber(s.streak) or 0, tonumber(s.best_streak) or 0, tonumber(s.pulse_points) or 0) end
        end)
    end
    Bridge.Reply(src, lines)
end)

-- ---------------------------------------------------------------------------
-- Frozen export API (server-only; ADD-ONLY, never re-sign these signatures).
-- ---------------------------------------------------------------------------

-- The modifier bus. A consumer asks, server-side, at grant time: "is a window
-- boosting my domain right now?" Returns 1.0 if none (safe no-op multiplier),
-- capped at Config.MaxModifier. Optional target must match the window's sub-key
-- (e.g. the spiked commodity) when the window has one.
exports('GetActiveModifier', function(domain, target)
    local w = activeWindow()
    if not w or w.domain ~= domain then return 1.0 end
    if w.target and target and w.target ~= target then return 1.0 end
    if w.target and not target then return 1.0 end
    return math.min(Config.MaxModifier, w.modifier or 1.0)
end)

exports('GetActive', function()
    local w = activeWindow()
    if not w then return nil end
    return { kind = w.kind, label = w.label, domain = w.domain, modifier = w.modifier,
             target = w.target, endsAt = w.endsAt, reason = w.reason }
end)

exports('GetMeter', function() return meter() end)

exports('GetSummary', function()
    local w = activeWindow()
    local windowsToday, checkinsToday = 0, 0
    pcall(function()
        local since = now() - 86400
        local a = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_pulse_windows WHERE started_at > ?', { since })
        local b = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_pulse_checkins WHERE ts > ?', { since })
        windowsToday = a and tonumber(a.n) or 0
        checkinsToday = b and tonumber(b.n) or 0
    end)
    return { activeKind = w and w.kind or nil, windowsToday = windowsToday,
             checkinsToday = checkinsToday, meter = meter() }
end)
