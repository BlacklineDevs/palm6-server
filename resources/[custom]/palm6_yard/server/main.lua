-- ============================================================================
-- palm6_yard/server/main.lua — the Bolingbroke prison economy (server-auth).
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for ALL framework /
-- inventory / jail / warrant / native access; oxmysql (MySQL.*) for our own
-- palm6_yard_* tables only. No direct framework / native calls here (§6 gate).
--
-- Three server-authoritative net handlers (rate-limited by palm6_eventguard):
--   doLabor       — shave the caller's OWN sentence. The shave is computed here
--                   from the sentence BASELINE (never the client), capped at
--                   50% of the baseline, applied via xt-prison + persisted, and
--                   paid a below-street trickle AFTER the shave is banked. A
--                   PERSISTED per-character cooldown blocks relog-to-reset.
--   buyCommissary — buy-only cash shop. Price is server-owned; money is removed
--                   BEFORE the item is granted (consume-before-grant) with a
--                   refund ladder; a daily per-item cap kills the resale loop.
--   postBail      — superlinear pretrial release. Money is removed BEFORE the
--                   release; on release we re-issue an mdt warrant (the skip
--                   flag → palm6_bounty auto-posts a state contract) and stamp a
--                   re-arrest cooldown. Refund ladder if release fails.
--
-- ANTI-EXPLOIT: never trust a client 'I am free' or a client shave/price/amount;
-- proximity is re-derived from the caller's ped; the shave is 50%-capped so jail
-- always costs; inputs consumed before outputs granted; NaN/negative guards on
-- every number; atomic cooldown set BEFORE any yield; all SQL parameterized.
-- ============================================================================

local enabled  = false   -- flipped true at boot iff all required items exist
local memLabor = {}      -- [src] = ts  (same-tick atomic guard, pre-yield)
local memBuy   = {}      -- [src] = ts
local memBail  = {}      -- [src] = ts

local commissaryIndex = {}   -- [item] = { item, label, price }

local function now() return os.time() end
local function today() return tonumber(os.date('%Y%m%d')) or 0 end

local function dbg(msg)
    if Config.Debug then print('[palm6_yard] ' .. msg) end
end

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- every statement IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with none of
-- the four yard tables. Every query here is pcall-wrapped, so the failure is
-- SILENT and it fails OPEN on the guards that matter: the persisted labor
-- cooldown never records, so relog-to-reset-labor is back; the sentence
-- baseline never persists, so the 50% shave cap resets on every task; the
-- commissary daily cap reads 0 bought forever; and the bail re-arrest cooldown
-- other systems consult always answers "no cooldown". The console prints
-- "prison economy online" throughout. On the live box (0047 already applied by
-- hand) these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0047_yard.sql. Those statements carry no
-- ENGINE/CHARSET clause, so these do not either.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- The tables THIS resource owns and can answer for. Only these feed
    -- SchemaReady. NOT included: xt_prison, the jail clock itself, which is
    -- created and owned by the xt-prison resource (see the note at the top of
    -- sql/0047_yard.sql). This resource only reaches it through the bridge.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS palm6_yard_sentence (
    citizenid        VARCHAR(64) NOT NULL PRIMARY KEY,
    baseline_minutes INT         NOT NULL DEFAULT 0,
    shaved_minutes   INT         NOT NULL DEFAULT 0,
    updated_at       BIGINT      NOT NULL DEFAULT 0
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS palm6_yard_labor (
    citizenid       VARCHAR(64) NOT NULL PRIMARY KEY,
    last_task_at    BIGINT      NOT NULL DEFAULT 0,
    tasks_completed INT         NOT NULL DEFAULT 0
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS palm6_yard_commissary_log (
    citizenid VARCHAR(64) NOT NULL,
    item      VARCHAR(64) NOT NULL,
    ymd       INT         NOT NULL,
    qty       INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (citizenid, item, ymd)
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS palm6_yard_bail (
    id               INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid        VARCHAR(64) NOT NULL,
    amount           INT         NOT NULL,
    released_minutes INT         NOT NULL,
    rearrest_until   BIGINT      NOT NULL DEFAULT 0,
    created_at       BIGINT      NOT NULL DEFAULT 0,
    INDEX idx_palm6_yard_bail_cid (citizenid)
)
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_yard] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- A finite, non-negative number? Guards every money / time computation.
local function sane(n)
    return type(n) == 'number' and n == n and n >= 0 and n < math.huge
end

-- Server-side proximity: the caller's REAL ped vs a station coord. Never trust
-- a client-supplied position (the client sends none).
local function nearStation(src, coords)
    local c = Bridge.GetCoords(src)
    if not c or not coords then return false end
    return Bridge.Distance(c, coords) <= (Config.InteractRadius + Config.ProximitySlack)
end

-- ===========================================================================
-- LABOR — shave your own sentence
-- ===========================================================================
RegisterNetEvent('palm6_yard:server:doLabor', function()
    local src = source

    -- Same-tick atomic guard set BEFORE any yield: two fires in one frame can't
    -- both pass. (The PERSISTED cooldown below is the anti-relog gate.)
    local t = now()
    if (memLabor[src] or 0) + Config.Labor.CooldownSec > t then return end
    memLabor[src] = t

    if not enabled then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Must actually be serving time (statebag read, no yield). Never trust a
    -- client claim of being jailed / free.
    local jailMin = Bridge.GetJailMinutes(src)
    if jailMin <= 0 then
        Bridge.Notify(src, Config.Labor.Label, 'You are not serving a sentence.', 'error')
        return
    end

    -- Server-side proximity to the labor yard.
    if not nearStation(src, Config.Coords.Labor) then
        Bridge.Notify(src, Config.Labor.Label, 'You are not at the labor yard.', 'error')
        return
    end

    -- PERSISTED cooldown — atomic check-and-set. INSERT IGNORE guarantees a row
    -- exists, then a guarded UPDATE claims the slot only if the last task is
    -- older than the cooldown. Two racers: one UPDATE moves last_task_at to now,
    -- the other sees now > now-cd and affects 0 rows. Surviving a relog because
    -- last_task_at lives in the DB, not the session.
    pcall(function()
        MySQL.query.await(
            'INSERT IGNORE INTO palm6_yard_labor (citizenid, last_task_at, tasks_completed) VALUES (?, 0, 0)',
            { cid })
    end)
    local claimed = 0
    pcall(function()
        claimed = MySQL.update.await(
            'UPDATE palm6_yard_labor SET last_task_at = ?, tasks_completed = tasks_completed + 1 '
            .. 'WHERE citizenid = ? AND last_task_at <= ?',
            { t, cid, t - Config.Labor.CooldownSec }) or 0
    end)
    if claimed ~= 1 then
        Bridge.Notify(src, Config.Labor.Label, 'Catch your breath before the next task.', 'error')
        return
    end

    -- Sentence baseline (palm6_yard_sentence). A NEW/longer sentence (current
    -- jailTime above the stored baseline) resets baseline + shaved so a fresh
    -- stint gets a fresh 50% budget.
    local baseline, shaved = jailMin, 0
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT baseline_minutes, shaved_minutes FROM palm6_yard_sentence WHERE citizenid = ?', { cid })
    end)
    if not row then
        pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_yard_sentence (citizenid, baseline_minutes, shaved_minutes, updated_at) '
                .. 'VALUES (?, ?, 0, ?) ON DUPLICATE KEY UPDATE baseline_minutes = VALUES(baseline_minutes), '
                .. 'shaved_minutes = 0, updated_at = VALUES(updated_at)',
                { cid, baseline, t })
        end)
    else
        baseline = tonumber(row.baseline_minutes) or jailMin
        shaved   = tonumber(row.shaved_minutes) or 0
        if not sane(baseline) then baseline = jailMin end
        if not sane(shaved) then shaved = 0 end
        if jailMin > baseline then
            baseline, shaved = jailMin, 0
            pcall(function()
                MySQL.update.await(
                    'UPDATE palm6_yard_sentence SET baseline_minutes = ?, shaved_minutes = 0, updated_at = ? WHERE citizenid = ?',
                    { baseline, t, cid })
            end)
        end
    end

    -- Shave budget: 50% of the baseline, minus what has already been shaved.
    -- jail must always cost something, so a fully-shaved sentence pays only.
    local budget = math.floor(Config.Labor.ShaveCapPct * baseline) - shaved
    -- Hard floor tied to the CURRENT sentence: never let a stale/oversized
    -- baseline authorise shaving the live jail time below (1 - cap) of that
    -- baseline. A player who had a LONG prior sentence (baseline persisted high,
    -- few tasks → shaved low) and then catches a SHORT new one leaves the old
    -- palm6_yard_sentence row in place — jailMin never exceeds the stale baseline,
    -- so the upward reset above never fires and the plain 'cap - shaved' budget
    -- (e.g. 49) dwarfs the new sentence, letting it be worked to zero. Binding the
    -- budget to (jailMin - floorMin) keeps jail costing on the live clock even when
    -- the baseline is stale; served time (jailMin already under the floor) yields 0.
    local floorMin = math.floor((1 - Config.Labor.ShaveCapPct) * baseline)
    local roomToFloor = jailMin - floorMin
    if roomToFloor < budget then budget = roomToFloor end
    if not sane(budget) then budget = 0 end
    local shave = 0
    if budget > 0 then shave = math.min(Config.Labor.ShaveMinutes, budget) end
    if shave < 0 then shave = 0 end

    -- Apply the shave (if any) BEFORE paying — the sentence reduction is the
    -- headline reward; pay is the trickle. Only bank the shaved total if
    -- xt-prison actually accepted the new time and we persisted it.
    local applied = 0
    if shave > 0 then
        local newTime = jailMin - shave
        if newTime < 0 then newTime = 0 end
        if Bridge.SetJailMinutes(src, newTime) then
            Bridge.PersistJailMinutes(cid, newTime)
            applied = shave
            pcall(function()
                MySQL.update.await(
                    'UPDATE palm6_yard_sentence SET shaved_minutes = shaved_minutes + ?, updated_at = ? WHERE citizenid = ?',
                    { applied, t, cid })
            end)
        end
    end

    -- Pay the below-street trickle for completing the task (the labor happened
    -- regardless of whether there was any shave budget left).
    Bridge.AddMoney(src, 'cash', Config.Labor.Pay, 'yard-labor')

    if applied > 0 then
        Bridge.Notify(src, Config.Labor.Label,
            ('Task done — sentence cut by %d min, +$%d.'):format(applied, Config.Labor.Pay), 'success')
    else
        Bridge.Notify(src, Config.Labor.Label,
            ('Task done — +$%d. (Sentence reduction is capped for this stint.)'):format(Config.Labor.Pay), 'inform')
    end
    dbg(('%s labor: shave=%d pay=%d jail=%d baseline=%d'):format(cid, applied, Config.Labor.Pay, jailMin, baseline))
end)

-- ===========================================================================
-- COMMISSARY — buy-only cash shop
-- ===========================================================================
RegisterNetEvent('palm6_yard:server:buyCommissary', function(item, qty)
    local src = source

    -- Same-tick / concurrent-buy guard set BEFORE any yield: serialises one
    -- player so two in-flight buys can't both pass the daily-cap read.
    local t = now()
    if (memBuy[src] or 0) + Config.Commissary.CooldownSec > t then return end
    memBuy[src] = t

    if not enabled then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Server-owned item + price. A modified client naming an off-menu item is
    -- rejected here; the price is NEVER read from the client.
    local entry = commissaryIndex[item]
    if not entry then
        Bridge.Notify(src, Config.Commissary.Label, 'That is not sold here.', 'error')
        return
    end

    qty = tonumber(qty)
    if not qty or qty ~= qty then return end
    qty = math.floor(qty)
    if qty < 1 or qty > Config.Commissary.DailyCapPerItem then
        Bridge.Notify(src, Config.Commissary.Label, 'Invalid quantity.', 'error')
        return
    end

    if not nearStation(src, Config.Coords.Commissary) then
        Bridge.Notify(src, Config.Commissary.Label, 'You are not at the commissary window.', 'error')
        return
    end

    -- Daily per-item cap (palm6_yard_commissary_log). Clamp the buy to what is
    -- left today so a big order still partially fills rather than bouncing.
    local ymd = today()
    local sold = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT qty FROM palm6_yard_commissary_log WHERE citizenid = ? AND item = ? AND ymd = ?',
            { cid, item, ymd })
        if r then sold = tonumber(r.qty) or 0 end
    end)
    if not sane(sold) then sold = 0 end
    local remaining = Config.Commissary.DailyCapPerItem - sold
    if remaining <= 0 then
        Bridge.Notify(src, Config.Commissary.Label, 'Daily limit reached for that item.', 'error')
        return
    end
    if qty > remaining then qty = remaining end

    local price = tonumber(entry.price)
    if not sane(price) or price <= 0 then return end
    local total = price * qty
    if not sane(total) or total <= 0 then return end

    -- Room check first (avoids removing money we'd only have to refund), then
    -- consume-before-grant: take the cash, then hand over the item; refund on
    -- any grant failure.
    if not Bridge.CanCarry(src, item, qty) then
        Bridge.Notify(src, Config.Commissary.Label, 'You cannot carry that.', 'error')
        return
    end
    if not Bridge.RemoveMoney(src, Config.Commissary.Account, total, 'yard-commissary') then
        Bridge.Notify(src, Config.Commissary.Label, 'You cannot afford that.', 'error')
        return
    end
    if not Bridge.AddItem(src, item, qty) then
        Bridge.AddMoney(src, Config.Commissary.Account, total, 'yard-commissary-refund')
        Bridge.Notify(src, Config.Commissary.Label, 'No room for that — refunded.', 'error')
        return
    end

    -- Log the sale for the daily cap (best-effort; the payout already happened,
    -- so a dropped insert can only UNDER-count the cap, never dupe money).
    pcall(function()
        MySQL.query.await(
            'INSERT INTO palm6_yard_commissary_log (citizenid, item, ymd, qty) VALUES (?, ?, ?, ?) '
            .. 'ON DUPLICATE KEY UPDATE qty = qty + VALUES(qty)',
            { cid, item, ymd, qty })
    end)

    Bridge.Notify(src, Config.Commissary.Label,
        ('Bought %dx %s for $%d.'):format(qty, entry.label, total), 'success')
    dbg(('%s bought %dx %s ($%d)'):format(cid, qty, item, total))
end)

-- ===========================================================================
-- BAIL — superlinear pretrial release
-- ===========================================================================
RegisterNetEvent('palm6_yard:server:postBail', function()
    local src = source

    local t = now()
    if (memBail[src] or 0) + Config.Bail.CooldownSec > t then return end
    memBail[src] = t

    if not enabled then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Must be serving time (server truth). Never trust a client 'free' claim.
    local jailMin = Bridge.GetJailMinutes(src)
    if jailMin <= 0 then
        Bridge.Notify(src, Config.Bail.Label, 'You are not serving a sentence.', 'error')
        return
    end

    if not nearStation(src, Config.Coords.Bail) then
        Bridge.Notify(src, Config.Bail.Label, 'You are not at the bail terminal.', 'error')
        return
    end

    -- Superlinear price with a hard floor. Guard every number.
    local remainingSec = jailMin * 60
    if not sane(remainingSec) then return end
    local bail = Config.Bail.Base + math.floor((remainingSec ^ Config.Bail.Exp) * Config.Bail.K)
    if not sane(bail) then return end
    if bail < Config.Bail.Floor then bail = Config.Bail.Floor end
    if bail <= 0 then return end

    -- Consume BEFORE release. RemoveMoney is the funds check (atomic).
    if not Bridge.RemoveMoney(src, Config.Bail.Account, bail, 'yard-bail') then
        Bridge.Notify(src, Config.Bail.Label,
            ('Bail is $%d — you cannot cover it.'):format(bail), 'error')
        return
    end

    -- Release (grant). If xt-prison refuses, refund and abort — nothing else has
    -- happened yet, so this is the whole refund ladder.
    if not Bridge.SetJailMinutes(src, 0) then
        Bridge.AddMoney(src, Config.Bail.Account, bail, 'yard-bail-refund')
        Bridge.Notify(src, Config.Bail.Label, 'The terminal jammed — bail refunded.', 'error')
        return
    end
    -- jailTime is now 0. Return confiscated items FIRST: ReturnPrisonItems fires
    -- xt-prison's returnItems handler, which reads the AMBIENT `source`, and the
    -- PersistJailMinutes MySQL await clobbers that ambient global (the exact hazard
    -- the bridge documents for saveJailTime). Persisting AFTER the return keeps the
    -- ambient source intact for the item hand-back so items can't be returned to
    -- the wrong player / dropped. (returnItems would BAN if jailTime were still
    -- > 0, so this still runs AFTER SetJailMinutes(0) above.)
    Bridge.ReturnPrisonItems(src)
    Bridge.PersistJailMinutes(cid, 0)

    -- Bail is a SKIP, not a clean slate: re-issue an mdt warrant so the skipper
    -- is re-wanted. palm6_bounty auto-posts a state contract on its own 180s
    -- sweep — we wire nothing there. Idempotent (nil if already wanted).
    Bridge.IssueWarrant(cid, Config.Bail.WarrantReason, Config.Bail.OfficerLabel)

    -- Audit + re-arrest cooldown (read by the arrest side to kill the
    -- bail-then-instant-crime loop). Best-effort.
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_yard_bail (citizenid, amount, released_minutes, rearrest_until, created_at) '
            .. 'VALUES (?, ?, ?, ?, ?)',
            { cid, bail, jailMin, t + Config.Bail.RearrestCooldownSec, t })
    end)

    Bridge.Notify(src, Config.Bail.Label,
        ('Bail posted ($%d). You are released — but a warrant is out for skipping court.'):format(bail), 'success')
    dbg(('%s bailed for $%d (had %d min)'):format(cid, bail, jailMin))
end)

-- ===========================================================================
-- Re-arrest cooldown query (export for the arrest side, if it wants it)
-- ===========================================================================
-- Seconds remaining on this citizen's post-bail re-arrest grace, or 0.
exports('RearrestGraceLeft', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return 0 end
    local until_ = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT MAX(rearrest_until) AS u FROM palm6_yard_bail WHERE citizenid = ?', { citizenid })
        if r then until_ = tonumber(r.u) or 0 end
    end)
    local left = until_ - now()
    return left > 0 and left or 0
end)

-- ===========================================================================
-- boot: self-disable loudly if a required item is missing (mirror palm6_drugs)
-- ===========================================================================
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The WHOLE boot sequence runs on this thread, not just the schema step.
    -- ensureSchema has to Wait for oxmysql's connection before it can issue any
    -- query, and `enabled` is this resource's existing boot gate: doLabor,
    -- buyCommissary and postBail all refuse while it is false. Flipping it only
    -- after the boot work completes is what keeps the Wait from opening a
    -- window where labor runs with no persisted cooldown table behind it. The
    -- cost is that the yard is closed for the first ~3s after an
    -- `ensure palm6_yard`, the same state it already reports when a required
    -- item is missing.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first

        for _, c in ipairs(Config.Commissary.Items) do commissaryIndex[c.item] = c end

        if not Bridge.ResourceStarted('xt-prison') then
            print('^1[palm6_yard] FATAL: the jail system is not started — the yard has no sentence to work on. Disabled.^0')
            return
        end

        local missing = {}
        for _, item in ipairs(Config.RequiredItems) do
            if not Bridge.ItemExists(item) then missing[#missing + 1] = item end
        end
        if #missing > 0 then
            table.sort(missing)
            print(('^1[palm6_yard] FATAL: %d required item(s) not registered in the item registry — yard disabled. '
                .. 'Add to the shared items file: %s^0'):format(#missing, table.concat(missing, ', ')))
            return
        end

        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It is the only line that can report the fresh-box
        -- case: every yard query is pcall'd, so a missing table prints exactly
        -- the same "prison economy online" line a healthy box prints.
        if not SchemaReady then
            print('^1[palm6_yard] schema MISSING - labor cooldowns, shave caps, commissary caps ' ..
                  'and bail re-arrest cooldowns are ALL unenforced on this box.^0')
        end

        enabled = true
        print(('[palm6_yard] prison economy online — labor pay $%d/%ds (shave %d min, cap %d%%), '
            .. '%d commissary item(s), bail floor $%d')
            :format(Config.Labor.Pay, Config.Labor.CooldownSec, Config.Labor.ShaveMinutes,
                math.floor(Config.Labor.ShaveCapPct * 100), #Config.Commissary.Items, Config.Bail.Floor))
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    memLabor[src] = nil
    memBuy[src]   = nil
    memBail[src]  = nil
end)

-- ---------------------------------------------------------------------------
-- Summary export (palm6_economy / palm6_devtest — informational, CLEAN cash).
-- ---------------------------------------------------------------------------
exports('GetSummary', function()
    local out = { enabled = enabled, laborTasks = 0, bailsPosted = 0, bailTotal = 0 }
    pcall(function()
        local l = MySQL.single.await('SELECT COALESCE(SUM(tasks_completed),0) AS n FROM palm6_yard_labor')
        out.laborTasks = l and tonumber(l.n) or 0
        local b = MySQL.single.await('SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s FROM palm6_yard_bail')
        out.bailsPosted = b and tonumber(b.c) or 0
        out.bailTotal   = b and tonumber(b.s) or 0
    end)
    return out
end)
