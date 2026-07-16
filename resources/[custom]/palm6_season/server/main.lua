-- ============================================================================
-- palm6_season/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for framework / native
-- access; owns its OWN two tables (palm6_seasons, palm6_season_archive) which
-- it self-creates at boot. Every read against a foreign ledger is a
-- pcall-guarded SELECT, so a schema drift on someone else's table degrades to
-- "that ladder is empty," never an error that touches gameplay.
--
-- The ONLY writes this resource ever issues target palm6_seasons and
-- palm6_season_archive. It never writes to palm6_gangs, palm6_turf,
-- palm6_drugs_sales, palm6_chopshop_sales, or palm6_laundering_runs.
-- ============================================================================

local seasonCache, seasonCacheAt = nil, 0   -- GetCurrentSeason() cache
local ladderCache = {}                       -- [key] = { seasonId, at, rows }
local lastRun = {}                           -- [src] = ts (public-command cooldown)

local function now() return os.time() end

-- Console prints; players get a single-line toast. Multi-line scoreboard
-- output goes through Bridge.Reply (one palm6_ui panel) instead, so these
-- single informational/error lines are the only thing echo handles now.
local function echo(src, line)
    if not src or src == 0 then
        print('[palm6_season] ' .. line)
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
-- EXISTS, InnoDB / utf8mb4 to match palm6_turf 0013). pcall-guarded so a DB
-- hiccup logs loudly rather than crashing the resource.
-- ---------------------------------------------------------------------------
local function ensureTables()
    local ok, err = pcall(function()
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `palm6_seasons` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    starts_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ends_at TIMESTAMP NULL DEFAULT NULL,
    active TINYINT(1) NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_seasons_active (active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `palm6_season_archive` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    season_id INT UNSIGNED NOT NULL,
    ladder VARCHAR(32) NOT NULL,
    rank_pos TINYINT UNSIGNED NOT NULL,
    subject_type VARCHAR(16) NOT NULL,
    subject_id VARCHAR(64) NOT NULL,
    label VARCHAR(96) NULL,
    score BIGINT NOT NULL DEFAULT 0,
    archived_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_season_archive_season (season_id, ladder, rank_pos)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `palm6_season_rewards` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    season_id INT UNSIGNED NOT NULL,
    ladder VARCHAR(32) NOT NULL,
    rank_pos TINYINT UNSIGNED NOT NULL,
    subject_type VARCHAR(16) NOT NULL,
    subject_id VARCHAR(64) NOT NULL,
    amount BIGINT NOT NULL,
    claimed TINYINT(1) NOT NULL DEFAULT 0,
    claimed_by VARCHAR(64) NULL,
    claimed_at TIMESTAMP NULL DEFAULT NULL,
    paid TINYINT(1) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_palm6_season_reward (season_id, ladder, rank_pos),
    INDEX idx_palm6_season_rewards_subject (subject_type, subject_id, claimed)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
    end)
    if not ok then
        print(('[palm6_season] table ensure FAILED -> %s'):format(tostring(err)))
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
            'SELECT id, name, starts_at, ends_at FROM palm6_seasons WHERE active = 1 ORDER BY id DESC LIMIT 1')
    end)
    seasonCache, seasonCacheAt = row or false, now()
    return row
end

local function invalidate()
    seasonCache, seasonCacheAt = nil, 0
    ladderCache = {}
end

-- ---------------------------------------------------------------------------
-- The read-only ladders. Each run(startsAt, limit) returns a normalised
-- list { subject_id, label, score, display }. All pcall-guarded; a failed
-- query yields an empty board, never an error.
--
-- Windowing (confirmed against the real sql/ files):
--   rep   -> palm6_gangs.rep            CURRENT standings (no rep event ledger
--                                       exists to window on; captured at close)
--   turf  -> palm6_turf owner counts    CURRENT holdings (one row per zone,
--                                       no capture-history ledger exists)
--   drugs -> palm6_drugs_sales.created_at   windowed on starts_at
--   dirty -> palm6_laundering_runs.created_at + palm6_chopshop_sales.sold_at
--                                       both windowed on starts_at
-- ---------------------------------------------------------------------------
local Ladders = {}

-- Ladder A: gang reputation (current standings).
Ladders.rep = { subject = 'gang', run = function(_startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT name, tag, rep AS score FROM palm6_gangs WHERE rep > 0 ORDER BY rep DESC, id ASC LIMIT ?',
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
            "SELECT owner_gang AS subject_id, COUNT(*) AS score FROM palm6_turf "
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
            .. 'SUM(net_dirty) AS score FROM palm6_drugs_sales WHERE created_at >= ? '
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
            .. 'SELECT citizenid AS subject_id, dirty_in AS v FROM palm6_laundering_runs WHERE created_at >= ? '
            .. 'UNION ALL '
            .. 'SELECT seller_citizenid AS subject_id, payout AS v FROM palm6_chopshop_sales WHERE sold_at >= ? '
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

-- Ladder E: city pulse participation — season check-ins (palm6_pulse_checkins,
-- windowed on starts_at via the epoch-seconds ts). Each pulse window allows one
-- check-in per citizen (atomic UNIQUE), so this counts genuine engagement, not
-- spam. Gives pulse_points/check-ins a real payoff. Only populates once pulse is
-- active (Config.MinOnline players); an empty board otherwise.
Ladders.pulse = { subject = 'citizen', run = function(startsAt, limit)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT citizenid AS subject_id, COUNT(*) AS score FROM palm6_pulse_checkins '
            .. 'WHERE ts >= UNIX_TIMESTAMP(?) GROUP BY citizenid '
            .. 'ORDER BY score DESC, subject_id ASC LIMIT ?',
            { startsAt, limit })
    end)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local score = tonumber(r.score) or 0
        out[#out + 1] = {
            subject_id = r.subject_id,
            label      = r.subject_id or '?',
            score      = score,
            display    = ('%d check-ins'):format(score),
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
            'SELECT COALESCE(SUM(net_dirty), 0) AS s FROM palm6_drugs_sales WHERE created_at >= ? AND citizenid = ?',
            { startsAt, cid })
        score = own and tonumber(own.s) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. 'SELECT citizenid, SUM(net_dirty) AS s FROM palm6_drugs_sales WHERE created_at >= ? GROUP BY citizenid '
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
            .. 'SELECT dirty_in AS v FROM palm6_laundering_runs WHERE created_at >= ? AND citizenid = ? '
            .. 'UNION ALL '
            .. 'SELECT payout AS v FROM palm6_chopshop_sales WHERE sold_at >= ? AND seller_citizenid = ? '
            .. ') t',
            { startsAt, cid, startsAt, cid })
        score = own and tonumber(own.s) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. 'SELECT subject_id, SUM(v) AS s FROM ( '
                .. 'SELECT citizenid AS subject_id, dirty_in AS v FROM palm6_laundering_runs WHERE created_at >= ? '
                .. 'UNION ALL '
                .. 'SELECT seller_citizenid AS subject_id, payout AS v FROM palm6_chopshop_sales WHERE sold_at >= ? '
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
        local own = MySQL.single.await('SELECT rep FROM palm6_gangs WHERE name = ? LIMIT 1', { crewName })
        score = own and tonumber(own.rep) or 0
        if score > 0 then
            local r = MySQL.single.await('SELECT COUNT(*) + 1 AS rank_pos FROM palm6_gangs WHERE rep > ?', { score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

local function turfStanding(crewName)
    local rank, score
    pcall(function()
        local own = MySQL.single.await('SELECT COUNT(*) AS c FROM palm6_turf WHERE owner_gang = ?', { crewName })
        score = own and tonumber(own.c) or 0
        if score > 0 then
            local r = MySQL.single.await(
                'SELECT COUNT(*) + 1 AS rank_pos FROM ( '
                .. "SELECT owner_gang, COUNT(*) AS c FROM palm6_turf "
                .. "WHERE owner_gang IS NOT NULL AND owner_gang <> '' GROUP BY owner_gang "
                .. ') b WHERE b.c > ?',
                { score })
            rank = r and tonumber(r.rank_pos) or nil
        end
    end)
    return rank, score or 0
end

-- ---------------------------------------------------------------------------
-- Optional palm6_discord feed hook. OFF by default (Config.DiscordEnable),
-- soft (guarded by GetResourceState), and never errors outward.
-- ---------------------------------------------------------------------------
local function announceSeason(title, desc, fields)
    if not Config.DiscordEnable then return end
    if GetResourceState('palm6_discord') ~= 'started' then return end
    pcall(function()
        exports.palm6_discord:Announce(Config.DiscordFeed, {
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
            'INSERT INTO palm6_seasons (name, starts_at, active) VALUES (?, NOW(), 1)', { name })
    end)
    if not ok or not newId then
        echo(src, 'Could not open the season (DB write failed).')
        return
    end
    invalidate()
    echo(src, ('Season "%s" opened (id %d).'):format(name, newId))
    announceSeason('Season opened', ('A new season has begun: %s'):format(name), nil)
end

-- Resolve a player-run gang NAME to its leader's citizenid — the IMMUTABLE key
-- a gang prize is paid to. Gang names are reusable (freed on disband) and
-- mutable (/rename), so a prize must NEVER be keyed to a name. Soft cross-read
-- of palm6_gangs; nil if the gang is gone or the table is absent → no prize row.
local function resolveGangLeaderCid(gangName)
    if type(gangName) ~= 'string' or gangName == '' then return nil end
    if GetResourceState('palm6_gangs') ~= 'started' then return nil end
    local cid
    pcall(function()
        cid = MySQL.scalar.await('SELECT leader_cid FROM palm6_gangs WHERE name = ? LIMIT 1', { gangName })
    end)
    if cid and cid ~= '' then return cid end
    return nil
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

    -- Build ALL archive + claimable palm6_season_rewards rows BEFORE flipping the
    -- season inactive. Crash-recoverability: the season stays active=1 for the
    -- whole (yielding) build loop, so a crash/restart mid-loop leaves it OPEN and
    -- /seasonclose simply re-runs — the reward rows' UNIQUE(season_id,ladder,
    -- rank_pos) + INSERT IGNORE make that re-run dup-safe, so no ladder ever ends
    -- up with a missing prize (the old order flipped active=0 FIRST, so a crash
    -- mid-loop stranded later ladders' prizes with no way to re-run). The active=0
    -- flip is the LAST step and stays an atomic guarded UPDATE (WHERE active=1),
    -- so it is still the single terminal commit — two racing /seasonclose calls
    -- can each rebuild (archive rows may duplicate; prizes cannot, via the UNIQUE)
    -- but only ONE wins the flip and announces.
    for _, key in ipairs(Config.LadderOrder) do
        local meta = Config.Ladders[key]
        local L = Ladders[key]
        if meta and L then
            local rows = L.run(startsAt, Config.TopN)
            for pos, r in ipairs(rows) do
                pcall(function()
                    MySQL.insert.await(
                        'INSERT INTO palm6_season_archive '
                        .. '(season_id, ladder, rank_pos, subject_type, subject_id, label, score) '
                        .. 'VALUES (?, ?, ?, ?, ?, ?, ?)',
                        { s.id, key, pos, meta.subject, tostring(r.subject_id), r.label, r.score })
                end)
                -- Claimable prize for a top finisher (offline-safe: paid on
                -- /seasonclaim). INSERT IGNORE on the unique (season,ladder,pos)
                -- so a re-run can never double-post a prize. Gang-ladder prizes
                -- are keyed to the gang LEADER's citizenid (immutable) — never
                -- the gang name (reusable on disband, mutable on /rename), which
                -- would let a name-squatter steal it or a rename forfeit it.
                -- noPrize ladders (e.g. rep — farmable) archive but never pay.
                local prize = (not meta.noPrize) and Config.Rewards and Config.Rewards[pos] or nil
                if prize and prize > 0 and r.subject_id and tostring(r.subject_id) ~= '' then
                    local subjType, subjId = meta.subject, tostring(r.subject_id)
                    if subjType == 'gang' then
                        local leaderCid = resolveGangLeaderCid(subjId)
                        subjType = leaderCid and 'citizen' or nil  -- unresolvable gang → no prize
                        subjId = leaderCid
                    end
                    if subjType then
                        pcall(function()
                            -- paid=0 EXPLICIT (overrides the 0061 ADD COLUMN
                            -- DEFAULT 1 that backfills pre-deploy history as
                            -- already-settled): a freshly-minted prize is unpaid,
                            -- so the boot reconcile can recover it if a crash
                            -- strikes between /seasonclaim's claim and the credit.
                            MySQL.insert.await(
                                'INSERT IGNORE INTO palm6_season_rewards '
                                .. '(season_id, ladder, rank_pos, subject_type, subject_id, amount, paid) '
                                .. 'VALUES (?, ?, ?, ?, ?, ?, 0)',
                                { s.id, key, pos, subjType, subjId, prize })
                        end)
                    end
                end
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

    -- Terminal commit: flip the season inactive exactly once, atomically. If this
    -- affects 0 rows (already closed, a concurrent /seasonclose won the flip, or a
    -- transient DB error), we bail WITHOUT double-announcing. The archive/reward
    -- rows built above are already idempotent (prizes via UNIQUE + INSERT IGNORE),
    -- so a lost race or a re-run never mints a duplicate prize.
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'UPDATE palm6_seasons SET active = 0, ends_at = NOW() WHERE id = ? AND active = 1', { s.id })
    end)
    if affected ~= 1 then
        invalidate()
        echo(src, 'Could not close the season (already closed or DB write failed). Check palm6_seasons.')
        return
    end

    invalidate()
    echo(src, ('Season "%s" closed and archived.'):format(s.name))
    announceSeason(('Season "%s" closed'):format(s.name), 'Final standings archived.', recapFields)
end

-- ---------------------------------------------------------------------------
-- Recoverable prize settlement (claim-before-credit).
--
-- settleReward() is the ONE idempotent payout, called from BOTH the live
-- /seasonclaim path AND the boot reconcile. It CLAIMS the `paid` flag (flips
-- 0->1) BEFORE the bank credit, so a replay can NEVER double-pay: an
-- already-credited prize has paid=1 and this returns early. The credit is
-- offline-safe (CreditBankByCitizenId) because at reconcile time the owner is
-- usually logged off after the restart that stranded the payout.
--
-- Bias (matching palm6_fightclub's settle + /fcbet's consume-before-grant): a
-- crash in the tiny window AFTER claiming paid=1 but BEFORE the credit lands
-- costs that one prize — a rare self-inflicted shortfall, never a mint. On a
-- credit that fails outright (no crash) we release the paid claim so the prize
-- stays payable and a later /seasonclaim or the next boot reconcile retries.
--
-- NOTE: we intentionally CLAIM paid=1 BEFORE crediting (not "set paid=1 after a
-- confirmed AddBank"): marking after the credit would leave a crash window where
-- the money landed but paid=0, which the boot reconcile would then re-credit —
-- exactly the double-pay the claim-before-credit rule forbids. Correctness over
-- the (already tiny) shortfall bias.
local function settleReward(rewardId, citizenId, amount)
    local amt = tonumber(amount) or 0
    -- Atomic claim: only the run that flips paid 0->1 proceeds to the credit.
    local claimedPaid = false
    pcall(function()
        claimedPaid = MySQL.update.await(
            'UPDATE palm6_season_rewards SET paid = 1 WHERE id = ? AND paid = 0', { rewardId }) == 1
    end)
    if not claimedPaid then return false end  -- already paid by another run

    local credited = false
    if amt > 0 and citizenId and citizenId ~= '' then
        credited = Bridge.CreditBankByCitizenId(citizenId, amt, 'season-prize')
    end
    if not credited then
        -- Credit failed outright (not a crash) — release the paid claim so the
        -- prize stays payable for a retry. On an actual crash between the claim
        -- and here this line never runs, and reconcile skips paid=1 (the bias).
        pcall(function()
            MySQL.update.await(
                'UPDATE palm6_season_rewards SET paid = 0 WHERE id = ? AND paid = 1', { rewardId })
        end)
        return false
    end
    return true
end

-- /seasonclaim — bank any unclaimed season prizes the caller is owed. Every
-- prize is keyed to a citizenid (gang prizes are paid to the leader's citizenid,
-- resolved at close), so a prize matches its owner by an immutable identity.
-- Each pays exactly once — an atomic claimed-flag flip marks it consumed for the
-- claimed=0 filter, then settleReward's paid-before-credit claim gates the bank
-- credit; a failed credit reverts BOTH flags so nothing is ever left claimed but
-- unpaid, and a hard crash between the claim and the credit is recovered on the
-- next boot (reconcileUnpaid re-drives claimed=1 AND paid=0 rows idempotently).
local function cmdSeasonClaim(src)
    if not cooldown(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT id, amount FROM palm6_season_rewards "
            .. "WHERE claimed = 0 AND subject_type = 'citizen' AND subject_id = ?",
            { cid }) or {}
    end)
    if not ok then
        Bridge.Notify(src, 'Season', 'Could not check your prizes — try again.', 'error'); return
    end

    local paid, total = 0, 0
    for _, row in ipairs(rows) do
        -- Atomically claim THIS row before paying (the == 1 guard prevents a
        -- concurrent second claim from double-paying).
        local claimedOk = false
        pcall(function()
            claimedOk = MySQL.update.await(
                'UPDATE palm6_season_rewards SET claimed = 1, claimed_by = ?, claimed_at = NOW() '
                .. 'WHERE id = ? AND claimed = 0', { cid, row.id }) == 1
        end)
        if claimedOk then
            if settleReward(row.id, cid, row.amount) then
                paid = paid + 1
                total = total + (tonumber(row.amount) or 0)
            else
                -- Credit did not land — revert the claim so the prize stays
                -- claimable (settleReward already released its own paid claim).
                pcall(function()
                    MySQL.update.await(
                        'UPDATE palm6_season_rewards SET claimed = 0, claimed_by = NULL, claimed_at = NULL '
                        .. 'WHERE id = ? AND claimed_by = ?', { row.id, cid })
                end)
            end
        end
    end

    if paid > 0 then
        Bridge.Notify(src, 'Season', ('Claimed %d season prize(s): $%s banked.'):format(paid, total), 'success')
    else
        Bridge.Notify(src, 'Season', 'You have no season prizes to claim.', 'inform')
    end
end

-- Boot reconcile — re-drive any prize that was claimed (claimed=1) but whose
-- bank credit never landed (paid=0), i.e. a hard crash struck between the
-- claimed=1 commit and the credit. Idempotent: settleReward claims paid=1 before
-- crediting, so this pays ONLY what a crash left owing and never double-pays an
-- already-paid prize. Delayed in onResourceStart so palm6_dbmigrate's 0061 ALTER
-- (the `paid` column) has landed before the WHERE paid=0 query runs — before
-- that the query would error (pcall-swallowed) and recover nothing.
local function reconcileUnpaid()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            "SELECT id, subject_id, amount FROM palm6_season_rewards "
            .. "WHERE claimed = 1 AND paid = 0 AND subject_type = 'citizen'") or {}
    end)
    local recovered = 0
    for _, row in ipairs(pending) do
        if settleReward(row.id, row.subject_id, row.amount) then
            recovered = recovered + 1
            local s = Bridge.GetSourceByCitizenId(row.subject_id)
            if s then
                Bridge.Notify(s, 'Season',
                    ('Recovered an unpaid season prize: $%s banked.'):format(tostring(row.amount)), 'success')
            end
        end
    end
    if recovered > 0 then
        print(('[palm6_season] boot reconcile paid %d interrupted season prize(s)'):format(recovered))
    end
end

local function registerCommands()
    Bridge.RegisterCommand('season',      function(source) cmdSeason(source) end)
    Bridge.RegisterCommand('seasontop',   function(source, args) cmdSeasonTop(source, args) end)
    Bridge.RegisterCommand('seasonclaim', function(source) cmdSeasonClaim(source) end)
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
    -- Auto-open a default season so the ladders/rewards are live out-of-box.
    if not s and Config.AutoOpenDefaultSeason then
        local ok, newId = pcall(function()
            return MySQL.insert.await(
                'INSERT INTO palm6_seasons (name, starts_at, active) VALUES (?, NOW(), 1)',
                { Config.DefaultSeasonName })
        end)
        if ok and newId then
            invalidate()
            s = GetCurrentSeason()
            print(('[palm6_season] auto-opened default season "%s" (id %s)'):format(
                Config.DefaultSeasonName, tostring(newId)))
        end
    end
    print(('[palm6_season] online: %s'):format(
        s and ('season "%s" active since %s'):format(s.name, tostring(s.starts_at))
          or 'no active season (open one with /seasonopen <name>)'))

    -- Recover any prize claimed=1 whose bank credit was interrupted by the last
    -- restart. Delayed so oxmysql + palm6_dbmigrate's 0061 `paid` column are up
    -- first (before that the WHERE paid=0 query errors and recovers nothing).
    -- Non-time-critical, so wait it out.
    CreateThread(function()
        Wait(8000)
        reconcileUnpaid()
    end)
end)

-- ---------------------------------------------------------------------------
-- Server-only export: the current active season row, or nil.
-- ---------------------------------------------------------------------------
exports('GetCurrentSeason', function()
    local s = GetCurrentSeason()
    if not s then return nil end
    return { id = s.id, name = s.name, starts_at = s.starts_at, ends_at = s.ends_at }
end)
