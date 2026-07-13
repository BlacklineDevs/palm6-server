-- ============================================================================
-- gtarp_season/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for framework / native
-- access; owns its OWN two tables (gtarp_seasons, gtarp_season_archive) which
-- it self-creates at boot. Every read against a foreign ledger is a
-- pcall-guarded SELECT, so a schema drift on someone else's table degrades to
-- "that ladder is empty," never an error that touches gameplay.
--
-- The ONLY writes this resource ever issues target gtarp_seasons and
-- gtarp_season_archive. It never writes to gtarp_gangs, gtarp_turf,
-- gtarp_drugs_sales, gtarp_chopshop_sales, or gtarp_laundering_runs.
-- ============================================================================

local seasonCache, seasonCacheAt = nil, 0   -- GetCurrentSeason() cache
local ladderCache = {}                       -- [key] = { seasonId, at, rows }
local lastRun = {}                           -- [src] = ts (public-command cooldown)

local function now() return os.time() end

-- Console prints; players get a single-line toast. Multi-line scoreboard
-- output goes through Bridge.Reply (one gtarp_ui panel) instead, so these
-- single informational/error lines are the only thing echo handles now.
local function echo(src, line)
    if not src or src == 0 then
        print('[gtarp_season] ' .. line)
    else
        Bridge.Notify(src, 'Season', line, 'inform')
    end
end

local function cooldown(src)
    if not src or src == 0 then return true end
    local t = now()
    if t - (lastRun[src] or 0) < Config.CmdCooldownSec then return false end
    lastRun[src] = t
    return true
end

-- ---------------------------------------------------------------------------
-- Boot DDL: self-create this resource's two tables (CREATE TABLE IF NOT
-- EXISTS, InnoDB / utf8mb4 to match gtarp_turf 0013). pcall-guarded so a DB
-- hiccup logs loudly rather than crashing the resource.
-- ---------------------------------------------------------------------------
local function ensureTables()
    local ok, err = pcall(function()
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `gtarp_seasons` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    starts_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ends_at TIMESTAMP NULL DEFAULT NULL,
    active TINYINT(1) NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_seasons_active (active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `gtarp_season_archive` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    season_id INT UNSIGNED NOT NULL,
    ladder VARCHAR(32) NOT NULL,
    rank_pos TINYINT UNSIGNED NOT NULL,
    subject_type VARCHAR(16) NOT NULL,
    subject_id VARCHAR(64) NOT NULL,
    label VARCHAR(96) NULL,
    score BIGINT NOT NULL DEFAULT 0,
    archived_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_season_archive_season (season_id, ladder, rank_pos)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
    end)
    if not ok then
        print(('[gtarp_season] table ensure FAILED -> %s'):format(tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- Season identity. The single active season row, or nil. Cached for
-- Config.SeasonCacheSec; invalidated on open/close.
-- ---------------------------------------------------------------------------
local function GetCurrentSeason()
    if seasonCache ~= nil and (now() - seasonCacheAt) < Config.SeasonCacheSec then
        return seasonCache or nil
    end
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT id, name, starts_at, ends_at FROM gtarp_seasons WHERE active = 1 ORDER BY id DESC LIMIT 1')
    end)
    seasonCache, seasonCacheAt = row or false, now()
    return row
end

local function invalidate()
    seasonCache, seasonCacheAt = nil, 0
    ladderCache = {}
end

-- ---------------------------------------------------------------------------
-- The four read-only ladders. Each run(startsAt, limit) returns a normalised
-- list { subject_id, label, score, display }. All pcall-guarded; a failed
-- query yields an empty board, never an error.
--
-- Windowing (confirmed against the real sql/ files):
--   rep   -> gtarp_gangs.rep            CURRENT standings (no rep event ledger
--                                       exists to window on; captured at close)
--   turf  -> gtarp_turf owner counts    CURRENT holdings (one row per zone,
--                                       no capture-history ledger exists)
--   drugs -> gtarp_drugs_sales.created_at   windowed on starts_at
--   dirty -> gtarp_laundering_runs.created_at + gtarp_chopshop_sales.sold_at
--                                       both windowed on starts_at
-- ---------------------------------------------------------------------------
local Ladders = {}

-- Ladder A: gang reputation (current standings).
Ladders.rep = { subject = 'gang', run = function(_startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT name, tag, rep AS score FROM gtarp_gangs WHERE rep > 0 ORDER BY rep DESC, id ASC LIMIT ?',
            { limit })
    end)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local score = tonumber(r.score) or 0
        local tag = (r.tag and r.tag ~= '') and ('[' .. r.tag .. '] ') or ''
        out[#out + 1] = {
            subject_id = r.name,
            label      = tag .. (r.name or '?'),
            score      = score,
            display    = ('%d rep'):format(score),
        }
    end
    return out
end }

-- Ladder B: turf held (current holdings).
Ladders.turf = { subject = 'gang', run = function(_startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            "SELECT owner_gang AS subject_id, COUNT(*) AS score FROM gtarp_turf "
            .. "WHERE owner_gang IS NOT NULL AND owner_gang <> '' "
            .. "GROUP BY owner_gang ORDER BY score DESC, owner_gang ASC LIMIT ?",
            { limit })
    end)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local score = tonumber(r.score) or 0
        out[#out + 1] = {
            subject_id = r.subject_id,
            label      = r.subject_id or '?',
            score      = score,
            display    = ('%d zones'):format(score),
        }
    end
    return out
end }

-- Ladder C: drug empire (net dirty cash + units moved), windowed on starts_at.
Ladders.drugs = { subject = 'citizen', run = function(startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT citizenid AS subject_id, SUM(net_dirty) AS dirty, SUM(units) AS units, '
            .. 'SUM(net_dirty) AS score FROM gtarp_drugs_sales WHERE created_at >= ? '
            .. 'GROUP BY citizenid ORDER BY score DESC, units DESC LIMIT ?',
            { startsAt, limit })
    end)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local dirty = tonumber(r.dirty) or 0
        local units = tonumber(r.units) or 0
        out[#out + 1] = {
            subject_id = r.subject_id,
            label      = r.subject_id or '?',
            score      = tonumber(r.score) or 0,
            display    = ('$%d / %du'):format(dirty, units),
        }
    end
    return out
end }

-- Ladder D: dirtiest hustler (laundered dirty-in + chop payouts per citizen),
-- both legs windowed on starts_at (chopshop windows on sold_at, not created_at).
Ladders.dirty = { subject = 'citizen', run = function(startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT subject_id, SUM(v) AS score FROM ( '
            .. 'SELECT citizenid AS subject_id, dirty_in AS v FROM gtarp_laundering_runs WHERE created_at >= ? '
            .. 'UNION ALL '
            .. 'SELECT seller_citizenid AS subject_id, payout AS v FROM gtarp_chopshop_sales WHERE sold_at >= ? '
            .. ') t GROUP BY subject_id ORDER BY score DESC LIMIT ?',
            { startsAt, startsAt, limit })
    end)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local score = tonumber(r.score) or 0
        out[#out + 1] = {
            subject_id = r.subject_id,
            label      = r.subject_id or '?',
            score      = score,
            display    = ('$%d'):format(score),
        }
    end
    return out
end }

-- Serve a ladder's top MaxTopN rows from cache (per season), sliced by callers.
local function getLadder(key, s)
    local c = ladderCache[key]
    if c and c.seasonId == s.id and (now() - c.at) < Config.QueryCacheSec then
        return c.rows
    end
    local rows = Ladders[key].run(s.starts_at, Config.MaxTopN)
    ladderCache[key] = { seasonId = s.id, at = now(), rows = rows }
    return rows
end

-- ---------------------------------------------------------------------------
-- Personal / crew standing helpers for /season. Each returns rank, score.
-- rank of one subject without scanning the whole board (spec Section 6).
-- ---------------------------------------------------------------------------
local function drugsStanding(cid, startsAt)
    local rank, score
    pcall(function()
        local own = MySQL.single.await(
            'SELECT COALESCE(SUM(net_dirty), 0) AS s FROM gtarp_drugs_sales WHERE created_at >= ? AND citizenid = ?',
            { startsAt, cid })
        score = own and tonumber(own.s) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. 'SELECT citizenid, SUM(net_dirty) AS s FROM gtarp_drugs_sales WHERE created_at >= ? GROUP BY citizenid '
                .. ') b WHERE b.s > ?',
                { startsAt, score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

local function dirtyStanding(cid, startsAt)
    local rank, score
    pcall(function()
        local own = MySQL.single.await(
            'SELECT COALESCE(SUM(v), 0) AS s FROM ( '
            .. 'SELECT dirty_in AS v FROM gtarp_laundering_runs WHERE created_at >= ? AND citizenid = ? '
            .. 'UNION ALL '
            .. 'SELECT payout AS v FROM gtarp_chopshop_sales WHERE sold_at >= ? AND seller_citizenid = ? '
            .. ') t',
            { startsAt, cid, startsAt, cid })
        score = own and tonumber(own.s) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. 'SELECT subject_id, SUM(v) AS s FROM ( '
                .. 'SELECT citizenid AS subject_id, dirty_in AS v FROM gtarp_laundering_runs WHERE created_at >= ? '
                .. 'UNION ALL '
                .. 'SELECT seller_citizenid AS subject_id, payout AS v FROM gtarp_chopshop_sales WHERE sold_at >= ? '
                .. ') u GROUP BY subject_id '
                .. ') b WHERE b.s > ?',
                { startsAt, startsAt, score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

local function repStanding(crewName)
    local rank, score
    pcall(function()
        local own = MySQL.single.await('SELECT rep FROM gtarp_gangs WHERE name = ? LIMIT 1', { crewName })
        score = own and tonumber(own.rep) or 0
        if score > 0 then
            local r = MySQL.single.await('SELECT COUNT(*) + 1 AS rank_pos FROM gtarp_gangs WHERE rep > ?', { score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

local function turfStanding(crewName)
    local rank, score
    pcall(function()
        local own = MySQL.single.await('SELECT COUNT(*) AS c FROM gtarp_turf WHERE owner_gang = ?', { crewName })
        score = own and tonumber(own.c) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. "SELECT owner_gang, COUNT(*) AS c FROM gtarp_turf "
                .. "WHERE owner_gang IS NOT NULL AND owner_gang <> '' GROUP BY owner_gang "
                .. ') b WHERE b.c > ?',
                { score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

-- ---------------------------------------------------------------------------
-- Optional gtarp_discord feed hook. OFF by default (Config.DiscordEnable),
-- soft (guarded by GetResourceState), and never errors outward.
-- ---------------------------------------------------------------------------
local function announceSeason(title, desc, fields)
    if not Config.DiscordEnable then return end
    if GetResourceState('gtarp_discord') ~= 'started' then return end
    pcall(function()
        exports.gtarp_discord:Announce(Config.DiscordFeed, {
            title = title, description = desc, fields = fields or {},
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Commands (server-authoritative, rate-limited, read-only except open/close).
-- ---------------------------------------------------------------------------

-- /season: current season plus the caller's own standing.
local function cmdSeason(src)
    local s = GetCurrentSeason()
    if not s then
        echo(src, 'No season is running right now.')
        return
    end
    if not cooldown(src) then
        Bridge.Notify(src, 'Season', 'Give it a moment.', 'error')
        return
    end
    local lines = {
        ('=== %s ==='):format(s.name),
        ('Running since %s'):format(tostring(s.starts_at)),
    }

    local cid = Bridge.GetCitizenId(src)
    if not cid then Bridge.Reply(src, lines); return end
    local startsAt = s.starts_at

    local dRank, dScore = drugsStanding(cid, startsAt)
    lines[#lines + 1] = dScore > 0
        and ('Drug Empire: #%s ($%d dirty)'):format(tostring(dRank or '?'), dScore)
        or  'Drug Empire: no activity yet'

    local xRank, xScore = dirtyStanding(cid, startsAt)
    lines[#lines + 1] = xScore > 0
        and ('Dirtiest Hustler: #%s ($%d)'):format(tostring(xRank or '?'), xScore)
        or  'Dirtiest Hustler: no activity yet'

    local crew = Bridge.GetCrew(cid)
    if crew and crew.name then
        local rRank, rScore = repStanding(crew.name)
        lines[#lines + 1] = rScore > 0
            and ('%s reputation: #%s (%d rep)'):format(crew.name, tostring(rRank or '?'), rScore)
            or  (crew.name .. ' reputation: unranked')
        local tRank, tScore = turfStanding(crew.name)
        lines[#lines + 1] = tScore > 0
            and ('%s turf: #%s (%d zones)'):format(crew.name, tostring(tRank or '?'), tScore)
            or  (crew.name .. ' turf: no zones held')
    end
    Bridge.Reply(src, lines)
end

-- /seasontop <ladder> [n]: the top N of one ladder.
local function cmdSeasonTop(src, args)
    local s = GetCurrentSeason()
    if not s then
        echo(src, 'No season is running right now.')
        return
    end
    local key = tostring(args[1] or ''):lower()
    if not Config.Ladders[key] or not Ladders[key] then
        echo(src, 'Ladders: ' .. table.concat(Config.LadderOrder, ', '))
        return
    end
    local n = math.floor(tonumber(args[2]) or Config.TopN)
    if n ~= n or n < 1 then n = 1 end
    if n > Config.MaxTopN then n = Config.MaxTopN end
    if not cooldown(src) then
        Bridge.Notify(src, 'Season', 'Give it a moment.', 'error')
        return
    end

    local rows = getLadder(key, s)
    if #rows == 0 then
        echo(src, ('%s: no entries yet.'):format(Config.Ladders[key].title))
        return
    end
    local lines = { ('=== %s: %s ==='):format(s.name, Config.Ladders[key].title) }
    local shown = math.min(n, #rows)
    for i = 1, shown do
        local r = rows[i]
        lines[#lines + 1] = ('%d. %s (%s)'):format(i, r.label, r.display)
    end
    Bridge.Reply(src, lines)
end

-- /seasonopen <name> (admin): opens a season; refuses if one is already open.
local function cmdSeasonOpen(src, args)
    if not Bridge.IsAdmin(src) then
        echo(src, 'You are not authorised to open a season.')
        return
    end
    local name = table.concat(args, ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #name < 1 or #name > 64 then
        echo(src, 'Usage: /seasonopen <name> (1 to 64 characters)')
        return
    end
    local cur = GetCurrentSeason()
    if cur then
        echo(src, ('A season is already active ("%s"). Close it first with /seasonclose.'):format(cur.name))
        return
    end
    local newId
    local ok = pcall(function()
        newId = MySQL.insert.await(
            'INSERT INTO gtarp_seasons (name, starts_at, active) VALUES (?, NOW(), 1)', { name })
    end)
    if not ok or not newId then
        echo(src, 'Could not open the season (DB write failed).')
        return
    end
    invalidate()
    echo(src, ('Season "%s" opened (id %d).'):format(name, newId))
    announceSeason('Season opened', ('A new season has begun: %s'):format(name), nil)
end

-- /seasonclose (admin): snapshots each ladder into the archive, then stamps
-- ends_at and deactivates. The only writes here target this resource's tables.
local function cmdSeasonClose(src)
    if not Bridge.IsAdmin(src) then
        echo(src, 'You are not authorised to close a season.')
        return
    end
    local s = GetCurrentSeason()
    if not s then
        echo(src, 'No season is running right now.')
        return
    end
    local startsAt = s.starts_at
    local recapFields = {}

    -- Claim the close FIRST: flip active atomically before writing any archive
    -- row. If this affects 0 rows (already closed, lost a concurrent race, or a
    -- transient DB error), we bail without archiving, so a re-run or an
    -- interleaved second /seasonclose can never duplicate the archive.
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'UPDATE gtarp_seasons SET active = 0, ends_at = NOW() WHERE id = ? AND active = 1', { s.id })
    end)
    if affected ~= 1 then
        invalidate()
        echo(src, 'Could not close the season (already closed or DB write failed). Check gtarp_seasons.')
        return
    end

    -- The four ladders read from live tables that closing does not mutate, and
    -- starts_at is unchanged, so capturing the snapshot AFTER the active flip
    -- yields the same standings: the reorder is snapshot-safe.
    for _, key in ipairs(Config.LadderOrder) do
        local meta = Config.Ladders[key]
        local L = Ladders[key]
        if meta and L then
            local rows = L.run(startsAt, Config.TopN)
            for pos, r in ipairs(rows) do
                pcall(function()
                    MySQL.insert.await(
                        'INSERT INTO gtarp_season_archive '
                        .. '(season_id, ladder, rank_pos, subject_type, subject_id, label, score) '
                        .. 'VALUES (?, ?, ?, ?, ?, ?, ?)',
                        { s.id, key, pos, meta.subject, tostring(r.subject_id), r.label, r.score })
                end)
            end
            if rows[1] then
                recapFields[#recapFields + 1] = {
                    name = meta.title,
                    value = ('#1 %s (%s)'):format(rows[1].label, rows[1].display),
                    inline = false,
                }
            end
        end
    end

    invalidate()
    echo(src, ('Season "%s" closed and archived.'):format(s.name))
    announceSeason(('Season "%s" closed'):format(s.name), 'Final standings archived.', recapFields)
end

local function registerCommands()
    Bridge.RegisterCommand('season',      function(source) cmdSeason(source) end)
    Bridge.RegisterCommand('seasontop',   function(source, args) cmdSeasonTop(source, args) end)
    Bridge.RegisterCommand('seasonopen',  function(source, args) cmdSeasonOpen(source, args) end)
    Bridge.RegisterCommand('seasonclose', function(source) cmdSeasonClose(source) end)
end

-- ---------------------------------------------------------------------------
-- Boot.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ensureTables()
    registerCommands()
    local s = GetCurrentSeason()
    print(('[gtarp_season] online: %s'):format(
        s and ('season "%s" active since %s'):format(s.name, tostring(s.starts_at))
          or 'no active season (open one with /seasonopen <name>)'))
end)

-- ---------------------------------------------------------------------------
-- Server-only export: the current active season row, or nil.
-- ---------------------------------------------------------------------------
exports('GetCurrentSeason', function()
    local s = GetCurrentSeason()
    if not s then return nil end
    return { id = s.id, name = s.name, starts_at = s.starts_at, ends_at = s.ends_at }
end)
