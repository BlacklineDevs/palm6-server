-- ============================================================================
-- palm6_heat/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access; every other line is framework-free. Owns exactly ONE table,
-- palm6_heat_state, which it self-creates at boot (CREATE TABLE IF NOT EXISTS —
-- CI never touches the DB, so this must be idempotent and boot-safe, the
-- palm6_ems pattern). Reads/writes nothing else, so a fault here cannot touch
-- the crime layer.
--
-- MODEL
--   heat is an INT stored with the row's updated_at. Effective heat is derived
--   on READ:  eff = max(0, stored - floor(minutes_since_update * DecayPerMin)).
--   The DB is written only when heat is ADDED (AddHeat) or a fully-decayed row
--   is swept — never once-per-tick-per-citizen. Arrest/death do NOT clear heat;
--   only time does.
--
-- SURFACE
--   exports.palm6_heat:AddHeat(citizenid, amount, reason, name?) -> { heat, tier }
--   exports.palm6_heat:GetHeat(citizenid)  -> integer effective heat
--   exports.palm6_heat:GetTier(citizenid)  -> tier string (see Config.Tiers)
--   exports.palm6_heat:GetTop(limit?)      -> ordered hottest list (dispatch, season)
--   exports.palm6_heat:GetSummary()        -> economy-meter rollup
--   /heat   (on-duty police) : live priority board of the hottest citizens
--   /myheat (any citizen)    : your own heat, tier, and cool-down ETA
-- ============================================================================

local READY = false            -- flips true once the table is confirmed present
local lastAction = {}          -- [src] = { [key] = ts } rate-limit ledger
-- Reclaim the rate-limit entry on disconnect so the ledger can't grow unbounded
-- with stale sources (the palm6_wanted / palm6_laundering convention).
AddEventHandler('playerDropped', function() lastAction[source] = nil end)

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_heat] ' .. msg) end
end

local function rl(src, key)
    if src == 0 then return true end
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function trim(s)
    s = tostring(s or ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #s > Config.TextClamp then return s:sub(1, Config.TextClamp - 1) .. '\226\128\166' end
    return s
end

-- ---------------------------------------------------------------------------
-- Pure helpers (no DB, no framework) — trivially unit-testable.
-- ---------------------------------------------------------------------------

-- Effective heat given the stored value and seconds elapsed since updated_at.
local function decayed(storedHeat, ageSec)
    local h = math.floor(tonumber(storedHeat) or 0)
    local age = tonumber(ageSec) or 0
    local lost = math.floor((age / 60.0) * Config.DecayPerMin)
    local eff = h - lost
    if eff < 0 then eff = 0 end
    return eff
end

-- Highest tier whose threshold the heat meets (Config.Tiers is sorted desc).
local function tierOf(heat)
    for _, t in ipairs(Config.Tiers) do
        if heat >= t.min then return t end
    end
    return Config.Tiers[#Config.Tiers]   -- CLEAN fallback (min = 0)
end

-- Minutes until `heat` decays to 0 at the configured rate (for /myheat).
local function coolMinutes(heat)
    if heat <= 0 or Config.DecayPerMin <= 0 then return 0 end
    return math.ceil(heat / Config.DecayPerMin)
end

-- ---------------------------------------------------------------------------
-- Boot: self-create the table. Idempotent, guarded, blocks the surface until
-- confirmed so an AddHeat racing a slow DB can't hit a missing table.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local ok, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `palm6_heat_state` (
                `citizenid`    VARCHAR(64)  NOT NULL,
                `citizen_name` VARCHAR(96)  DEFAULT NULL,
                `heat`         INT UNSIGNED NOT NULL DEFAULT 0,
                `lifetime`     BIGINT UNSIGNED NOT NULL DEFAULT 0,
                `last_reason`  VARCHAR(64)  DEFAULT NULL,
                `updated_at`   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`),
                KEY `idx_heat` (`heat`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if ok then
        READY = true
        dbg('schema ready (palm6_heat_state)')
    else
        print(('[palm6_heat] FATAL: could not create palm6_heat_state (%s). Resource is inert until the DB is reachable.'):format(tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- AddHeat — the one write path. Settles decay on the existing row, adds the
-- (clamped) amount, re-bases updated_at to NOW(). Server-authoritative; safe
-- against garbage input (returns nil on a no-op rather than throwing).
-- ---------------------------------------------------------------------------
local function addHeat(citizenid, amount, reason, name)
    if not READY then return nil end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    amount = math.floor(tonumber(amount) or 0)
    -- DEFENSIVE ONLY, unreachable from any wire that exists today: every one of
    -- the ten callers passes a config integer or integer arithmetic, so nothing
    -- can hand us NaN. Kept because NaN survives BOTH guards below (NaN <= 0 is
    -- false, NaN > cap is false) and math.floor(0/0) is still NaN, so if a
    -- future caller ever computed one it would reach the INT UNSIGNED column
    -- unclamped and there would be no other line to stop it. `x ~= x` is true
    -- only for NaN; math.huge is already caught by the cap.
    if amount ~= amount then return nil end
    if amount <= 0 then return nil end
    if amount > Config.MaxAddPerCall then amount = Config.MaxAddPerCall end
    -- Also defensive, and inert under the shipped config: MaxAddPerCall (60) is
    -- below HeatCap (150), so the line above already clamps harder than this
    -- one. It only ever fires if an operator raises MaxAddPerCall above
    -- HeatCap, and then it matters, because the INSERT branch below writes
    -- `amount` straight into a fresh row with no ON DUPLICATE cap to catch it.
    if amount > Config.HeatCap then amount = Config.HeatCap end
    reason = trim(reason ~= nil and reason or 'crime')
    if name == nil then name = Bridge.GetNameByCitizenId(citizenid) end
    if name ~= nil then name = trim(name) end

    -- ATOMIC settle-and-add. The old shape SELECTed the row, decayed it in Lua,
    -- then wrote `heat = VALUES(heat)`, an ASSIGN and not an increment, so two
    -- adds landing on the same citizen across that SELECT's yield silently lost
    -- one of them. With the heat layer now wired into a dozen crime paths the
    -- race is real, so the decay is expressed in SQL (the same
    -- FLOOR(age / 60 * rate) shape the sweep below already uses) and settle +
    -- add + cap all happen inside ONE statement. MySQL evaluates ON DUPLICATE
    -- assignments left to right, so `updated_at` still holds the OLD timestamp
    -- while `heat` is computed, which is exactly what the decay term needs.
    --
    -- NOT bit-identical to the Lua `decayed()` helper: MySQL evaluates
    -- `age / 60` as DECIMAL truncated at div_precision_increment (4dp) while
    -- Lua uses an IEEE double, so at age = 80s and rate = 0.75 SQL floors
    -- 1.3333 * 0.75 = 0.999975 to 0 where Lua floors 1.0 to 1. The two agree
    -- everywhere except on that boundary and the drift is at most 1 point,
    -- which is below the granularity of every tier threshold. Pre-existing on
    -- the sweep; called out here because this write path now depends on it too.
    local wrote = pcall(function()
        MySQL.query.await([[
            INSERT INTO palm6_heat_state (citizenid, citizen_name, heat, lifetime, last_reason, updated_at)
            VALUES (?, ?, ?, ?, ?, NOW())
            ON DUPLICATE KEY UPDATE
                citizen_name = COALESCE(VALUES(citizen_name), citizen_name),
                heat         = LEAST(?, GREATEST(0, CAST(heat AS SIGNED)
                                     - FLOOR(TIMESTAMPDIFF(SECOND, updated_at, NOW()) / 60 * ?))
                                     + VALUES(heat)),
                lifetime     = lifetime + VALUES(lifetime),
                last_reason  = VALUES(last_reason),
                updated_at   = NOW()
        ]], { citizenid, name, amount, amount, reason, Config.HeatCap, Config.DecayPerMin })
    end)
    if not wrote then return nil end

    -- Read the settled total back so the frozen { heat, tier } return stays
    -- exact now that Lua no longer computes it. The row was just re-based to
    -- NOW(), so nothing decays between the write and this read.
    --
    -- NO FALLBACK VALUE ON PURPOSE. This used to fall back to `amount`, which
    -- is only the floor of what the row holds: a citizen sitting at 140 who
    -- takes a +3 would have been handed { heat = 3, tier = 'CLEAN' }, a tier
    -- that is not merely stale but wrong in the direction that matters. The
    -- pre-atomic code returned nil when it could not name the total and this
    -- keeps that contract: nil means "no reading", not "no write" (the write
    -- above already landed and is the durable fact).
    --
    -- COST: one extra round-trip per AddHeat, i.e. per crime payout across ten
    -- wires. No caller reads the return today (grep: zero consumers); it is paid
    -- to keep the documented export contract exact rather than to serve a
    -- consumer. If that trade ever stops being worth it, drop the read and the
    -- return together, not the read alone.
    local new
    pcall(function()
        local row = MySQL.single.await(
            'SELECT heat FROM palm6_heat_state WHERE citizenid = ?', { citizenid })
        if row and row.heat then new = math.floor(tonumber(row.heat) or 0) end
    end)
    if not new then
        dbg(('+%d heat -> %s (%s) [write ok, read-back failed]'):format(amount, citizenid, reason))
        return nil
    end

    dbg(('+%d heat -> %s (%s) [%d/%d]'):format(amount, citizenid, reason, new, Config.HeatCap))
    return { heat = new, tier = tierOf(new).tier }
end

-- Read a single citizen's effective heat (no write).
local function getHeat(citizenid)
    if not READY or type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    local eff = 0
    pcall(function()
        local row = MySQL.single.await(
            'SELECT heat, TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS age FROM palm6_heat_state WHERE citizenid = ?',
            { citizenid })
        if row then eff = decayed(row.heat, row.age) end
    end)
    return eff
end

-- Hottest citizens, decay-correct. Over-fetch ScanCap by stored heat, decay each
-- in Lua, drop the cold, re-sort by effective, return the top `limit`.
local function getTop(limit)
    limit = math.floor(tonumber(limit) or Config.Board.Top)
    if limit < 1 then limit = 1 end
    local out = {}
    if not READY then return out end
    pcall(function()
        local rows = MySQL.query.await([[
            SELECT citizenid, citizen_name, heat, last_reason,
                   TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS age
            FROM palm6_heat_state
            ORDER BY heat DESC
            LIMIT ?
        ]], { Config.Board.ScanCap }) or {}
        for _, r in ipairs(rows) do
            local eff = decayed(r.heat, r.age)
            if eff > 0 then
                out[#out + 1] = {
                    citizenid = r.citizenid,
                    name      = r.citizen_name,
                    heat      = eff,
                    tier      = tierOf(eff).tier,
                    reason    = r.last_reason,
                }
            end
        end
    end)
    table.sort(out, function(a, b) return a.heat > b.heat end)
    while #out > limit do out[#out] = nil end
    return out
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- /heat — on-duty police only. Live priority board of the hottest citizens.
local function cmdHeat(src, _args)
    if src ~= 0 and not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Heat', 'Dispatch board is police-only.', 'error')
        return
    end
    if not rl(src, 'heat') then return end

    local top = getTop(Config.Board.Top)
    local lines = { ('=== Heat Board (top %d) ==='):format(Config.Board.Top) }
    if #top == 0 then
        lines[#lines + 1] = '  (the city is quiet)'
    else
        for i, e in ipairs(top) do
            lines[#lines + 1] = ('  %d. %s — %s (%d)%s'):format(
                i,
                (e.name and e.name ~= '') and e.name or ('cid:' .. tostring(e.citizenid)),
                e.tier, e.heat,
                (e.reason and e.reason ~= '') and (' · ' .. trim(e.reason)) or '')
        end
    end
    Bridge.Reply(src, 'Heat', { 235, 120, 90 }, lines)
    dbg(('heat board pulled by %s'):format(src == 0 and 'console' or Bridge.GetPlayerName(src)))
end

-- /myheat — any citizen. Own heat, tier, and cool-down ETA.
local function cmdMyHeat(src, _args)
    if src == 0 then
        print('[palm6_heat] /myheat is a character self-check, run it in-game.')
        return
    end
    if not rl(src, 'myheat') then return end
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then
        Bridge.Notify(src, 'Heat', 'Could not read your character. Try again in a moment.', 'error')
        return
    end
    local h = getHeat(citizenid)
    local t = tierOf(h)
    local lines = { '=== Your Heat ===' }
    lines[#lines + 1] = ('  Level: %s (%d/%d)'):format(t.label, h, Config.HeatCap)
    if h <= 0 then
        lines[#lines + 1] = '  You are off the radar. Keep it that way.'
    else
        lines[#lines + 1] = ('  Cools off in ~%d min of laying low.'):format(coolMinutes(h))
        if t.tier == 'WANTED' or t.tier == 'HOT' then
            lines[#lines + 1] = '  Every cop in the city has eyes out for you.'
        end
    end
    Bridge.Reply(src, 'Heat', t.color, lines)
    dbg(('self-check by %s (%d)'):format(Bridge.GetPlayerName(src), h))
end

-- ---------------------------------------------------------------------------
-- Sweep: settle rows that have fully decayed to 0, then prune the long-dead.
--
-- This used to DELETE the fully-decayed row outright, on the reasoning that
-- correctness never depends on the sweep because reads re-derive heat from
-- updated_at. That is true of `heat` and FALSE of `lifetime`: lifetime is a
-- cumulative career total that GetSummary sums and README.md documents as part
-- of the frozen export contract, and the DELETE destroyed it. Since every
-- citizen fully cools within ~3h20m at cap, every row was eventually swept, so
-- lifetime could never mean anything. Zero the heat instead and keep the row.
--
-- HONEST SCOPE: GetSummary has no in-repo caller today (its documented consumer,
-- palm6_economy's crime-layer rollup, is not built). This is a contract fix, not
-- a bug anyone has felt yet. `lifetime` is published in README.md as part of a
-- frozen export, and a field that silently resets every few hours cannot be
-- published. Do not read this comment as "something was visibly broken".
--
-- COST: the retained window grows from ~3h20m of rows to SweepRetainDays. That
-- is not a row-count multiplier: PRIMARY KEY (citizenid) means at most ONE row
-- per character ever exists, so the ceiling only moves from "characters who
-- committed a crime in the last 3h20m" to "characters who committed a crime in
-- the last 30 days". Both are bounded by the size of the playerbase.
--
-- The UPDATE does not touch updated_at (the column declares an explicit DEFAULT
-- and no ON UPDATE clause, so MySQL does not auto-bump it), and even if a
-- server's sql_mode did bump it, a row at heat 0 decays to 0 either way, so
-- effective heat is unaffected.
-- ---------------------------------------------------------------------------
local function sweep()
    if not READY then return end
    pcall(function()
        MySQL.query.await([[
            UPDATE palm6_heat_state
            SET heat = 0
            WHERE heat > 0
              AND heat <= FLOOR(TIMESTAMPDIFF(SECOND, updated_at, NOW()) / 60 * ?)
        ]], { Config.DecayPerMin })
    end)
    -- Long-TTL prune so the table still cannot grow without bound. A row that
    -- has sat at zero for RetainDays belongs to a citizen who has committed no
    -- crime in that long; losing their lifetime total is the accepted trade.
    pcall(function()
        MySQL.query.await([[
            DELETE FROM palm6_heat_state
            WHERE heat = 0 AND updated_at < DATE_SUB(NOW(), INTERVAL ? DAY)
        ]], { Config.SweepRetainDays })
    end)
end

-- ---------------------------------------------------------------------------
-- Boot + loops
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ensureSchema()
    Bridge.RegisterCommand(Config.Command.Police, function(source, args) cmdHeat(source, args) end)
    Bridge.RegisterCommand(Config.Command.Self, function(source, args) cmdMyHeat(source, args) end)
    print(('[palm6_heat] online — /%s (police board), /%s (self). Decay %.2f/min, cap %d.')
        :format(Config.Command.Police, Config.Command.Self, Config.DecayPerMin, Config.HeatCap))
    CreateThread(function()
        while true do
            Wait(Config.SweepIntervalMs)
            sweep()
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Exports (frozen signatures).
-- ---------------------------------------------------------------------------

-- The one write path for crime resources. amount is clamped to Config.MaxAddPerCall;
-- name is optional (falls back to an online lookup). Returns { heat, tier } or nil.
exports('AddHeat', function(citizenid, amount, reason, name)
    return addHeat(citizenid, amount, reason, name)
end)

-- Effective heat integer for a citizen (0 if unknown/clean).
exports('GetHeat', function(citizenid)
    return getHeat(citizenid)
end)

-- Tier string for a citizen (see Config.Tiers): 'CLEAN'|'COOL'|'WARM'|'HOT'|'WANTED'.
exports('GetTier', function(citizenid)
    return tierOf(getHeat(citizenid)).tier
end)

-- Ordered hottest list for dispatch priority + the season Most-Wanted ladder.
-- Each entry: { citizenid, name, heat, tier, reason }.
exports('GetTop', function(limit)
    return getTop(limit)
end)

-- Economy-meter rollup (palm6_economy reads GetSummary across the crime layer).
exports('GetSummary', function()
    local out = { tracked = 0, warm = 0, hot = 0, wanted = 0, lifetime = 0 }
    if not READY then return out end
    pcall(function()
        local rows = MySQL.query.await([[
            SELECT heat, TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS age, lifetime
            FROM palm6_heat_state
        ]]) or {}
        for _, r in ipairs(rows) do
            local eff = decayed(r.heat, r.age)
            out.lifetime = out.lifetime + (tonumber(r.lifetime) or 0)
            if eff > 0 then
                out.tracked = out.tracked + 1
                local tier = tierOf(eff).tier
                if tier == 'WANTED' then out.wanted = out.wanted + 1
                elseif tier == 'HOT' then out.hot = out.hot + 1
                elseif tier == 'WARM' then out.warm = out.warm + 1 end
            end
        end
    end)
    return out
end)
