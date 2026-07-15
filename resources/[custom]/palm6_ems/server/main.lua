-- ============================================================================
-- palm6_ems/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (the bridge gate).
--
-- Debt with memory, same model as palm6_citations: an EMS bill is a ledger
-- row on the PATIENT, settled later from bank via /paymedbill. /emsbill
-- never debits the patient directly, so a patient who is broke at the scene
-- still leaves a trace. Billing follows a real on-scene encounter (online
-- patient, near the medic), which is the deliberate difference from /cite.
--
-- No client-trusted net events: the client supplies only a player id and a
-- raw amount string, both re-validated server-side. Identity, coords, and
-- bank are all server-read.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts }

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_ems] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function unpaidCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_ems_bills WHERE status = 'unpaid'")
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function outstandingSum()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COALESCE(SUM(amount), 0) AS total FROM palm6_ems_bills WHERE status = 'unpaid'")
        n = r and tonumber(r.total) or 0
    end)
    return n
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors the palm6_dbmigrate pattern:
-- Wait(3000), per-statement pcall, CREATE TABLE IF NOT EXISTS. A new sql/
-- file would NOT auto-apply on the unreachable prod DB, so the resource
-- creates its own tables at boot. Re-runs are harmless no-ops.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_ems_bills` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    patient_citizenid VARCHAR(64) NOT NULL,
    patient_name VARCHAR(100) NOT NULL DEFAULT '',
    medic_citizenid VARCHAR(64) NOT NULL,
    medic_name VARCHAR(100) NOT NULL DEFAULT '',
    amount INT UNSIGNED NOT NULL,
    reason VARCHAR(160) NOT NULL,
    status ENUM('unpaid','paid') NOT NULL DEFAULT 'unpaid',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_ems_bills_patient (patient_citizenid, status),
    INDEX idx_palm6_ems_bills_medic (medic_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_ems_treatments` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    patient_citizenid VARCHAR(64) NOT NULL,
    medic_citizenid VARCHAR(64) NOT NULL,
    kind ENUM('treat','revive','bill') NOT NULL DEFAULT 'treat',
    note VARCHAR(160) NOT NULL DEFAULT '',
    bill_id INT UNSIGNED DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_ems_treatments_patient (patient_citizenid),
    INDEX idx_palm6_ems_treatments_medic (medic_citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print(('[palm6_ems] schema init FAILED -> %s'):format(tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shared gate: rate-limit, on-duty medic, optional tablet item. Returns the
-- medic's citizenid or nil (having already told the caller what is missing).
-- Adapted from palm6_mdt's gate().
-- ---------------------------------------------------------------------------
local function gate(src, key)
    if src == 0 then return nil end
    if not rl(src, key) then return nil end
    if not Bridge.IsOnDutyMedic(src) then
        Bridge.Notify(src, 'EMS', 'You need to be on duty as ambulance.', 'error')
        return nil
    end
    if Config.RequireItem and not Bridge.HasItem(src, Config.TabletItem) then
        Bridge.Notify(src, 'EMS', 'You are not carrying your EMS tablet.', 'error')
        return nil
    end
    return Bridge.GetCitizenId(src)
end

-- Optional Discord announce for a written bill. Soft, OFF by default.
local function announceBill(billId, patientName, medicName, amount, reason)
    if Config.Discord.Enabled and Bridge.ResourceStarted('palm6_discord') then
        pcall(function()
            exports.palm6_discord:Announce(Config.Discord.Feed, {
                title = ('EMS bill #%d - %s'):format(billId, patientName),
                description = reason,
                fields = {
                    { name = 'Amount', value = ('$%d'):format(amount), inline = true },
                    { name = 'Medic',  value = medicName, inline = true },
                },
            })
        end)
    end
end

-- ---------------------------------------------------------------------------
-- /emsbill <playerid> <amount> <reason...> - on-duty medic bills a present,
-- online patient they are standing next to. Writes an UNPAID ledger row;
-- settlement is the separate /paymedbill step.
-- ---------------------------------------------------------------------------
local function cmdEmsBill(src, args)
    local medicCid = gate(src, 'emsbill')
    if not medicCid then return end

    local targetId = tonumber(args[1])
    local amount = math.floor(tonumber(args[2]) or 0)
    local reason = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    local C = Config.Bill
    if not targetId or amount < C.MinAmount or amount > C.MaxAmount
        or #reason < C.ReasonMin or #reason > C.ReasonMax then
        Bridge.Notify(src, 'EMS',
            ('Usage: /emsbill [playerid] [$%d-%d] [reason %d-%d chars]')
            :format(C.MinAmount, C.MaxAmount, C.ReasonMin, C.ReasonMax), 'error')
        return
    end

    local patientCid = Bridge.GetCitizenIdOf(targetId)
    if not patientCid then
        Bridge.Notify(src, 'EMS', 'No such player.', 'error')
        return
    end

    -- Self-bill prevention.
    if patientCid == medicCid then
        Bridge.Notify(src, 'EMS', 'You cannot bill yourself.', 'error')
        return
    end

    -- Proximity: both coords server-read from peds, no client-claimed position.
    local a = Bridge.GetCoords(src)
    local b = Bridge.GetCoords(targetId)
    if not a or not b or Bridge.Distance(a, b) > C.BillRadius then
        Bridge.Notify(src, 'EMS', 'Stand next to the patient to bill them.', 'error')
        return
    end

    local patientName = Bridge.GetPlayerName(targetId)
    local medicName = Bridge.GetPlayerName(src)

    local ok, billId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_ems_bills
                (patient_citizenid, patient_name, medic_citizenid, medic_name, amount, reason)
            VALUES (?, ?, ?, ?, ?, ?)
        ]], { patientCid, patientName, medicCid, medicName, amount, reason })
    end)
    if not ok or not billId then
        Bridge.Notify(src, 'EMS', 'EMS billing is down - nothing was written.', 'error')
        return
    end

    Bridge.Notify(src, 'EMS',
        ('Bill #%d written: %s, $%d.'):format(billId, patientName, amount), 'success')
    Bridge.Notify(targetId, 'EMS',
        ('You were billed $%d by EMS: %s. Pay with /paymedbill %d.'):format(amount, reason, billId), 'error')

    if Config.LogTreatments then
        pcall(function()
            MySQL.insert.await([[
                INSERT INTO palm6_ems_treatments (patient_citizenid, medic_citizenid, kind, note, bill_id)
                VALUES (?, ?, 'bill', ?, ?)
            ]], { patientCid, medicCid, reason, billId })
        end)
    end

    announceBill(billId, patientName, medicName, amount, reason)

    -- In-world civic bulletin (public facts only) via the palm6-bot feed. The
    -- bot narrates an on-scene medical encounter into #palm-medical-ems. Soft-
    -- dep + pcall: a missing/broken cityfeed never touches the billing path.
    -- Payload shape matches EmsEventSchema (palm6-bot/src/events/types.ts):
    -- incident_type (required), outcome + case_ref (optional). The router
    -- hardcodes the "Palm Medical EMS" label and never renders a patient name,
    -- so NO character_name/agency/amount/citizenid is sent. Convar-gated (OFF
    -- by default; enable in-game after verifying a 200 {received:true}).
    if GetResourceState('palm6_cityfeed') == 'started'
        and GetConvar('palm6:cityfeed_ems', 'false') == 'true' then
        pcall(function()
            exports.palm6_cityfeed:Emit({
                type = 'ems',
                incident_type = 'medical call',
                outcome = 'patient treated',
                case_ref = ('EMS-%d'):format(billId),
            })
        end)
    end
    dbg(('bill #%d on %s by %s ($%d)'):format(billId, patientCid, medicCid, amount))
end

-- ---------------------------------------------------------------------------
-- /medbills - the caller's own outstanding EMS bills (no on-duty gate: any
-- citizen may read their own debt).
-- ---------------------------------------------------------------------------
local function cmdMedBills(src)
    if src == 0 then return end
    if not rl(src, 'medbills') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, amount, reason,
                   TIMESTAMPDIFF(HOUR, created_at, NOW()) AS age_h
            FROM palm6_ems_bills
            WHERE patient_citizenid = ? AND status = 'unpaid'
            ORDER BY id DESC LIMIT ?
        ]], { cid, Config.Bill.ListLimit }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no outstanding medical bills' })
        return
    end
    local lines = {}
    local total = 0
    for _, b in ipairs(rows) do
        total = total + (tonumber(b.amount) or 0)
        lines[#lines + 1] = ('#%d $%d - %s [%dh ago]'):format(
            b.id, b.amount, b.reason, tonumber(b.age_h) or 0)
    end
    lines[#lines + 1] = ('total owed $%d - /paymedbill [#] to settle'):format(total)
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /paymedbill <id> - settle one of the caller's own bills from bank. No
-- pay-desk location requirement (a medical bill is not tied to city hall).
-- ---------------------------------------------------------------------------
local function cmdPayMedBill(src, args)
    if src == 0 then return end
    if not rl(src, 'paymedbill') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'EMS', 'Usage: /paymedbill [bill #]', 'error')
        return
    end

    -- Ownership enforced in the WHERE: a player can only pay THEIR OWN bill.
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, amount FROM palm6_ems_bills WHERE id = ? AND patient_citizenid = ? AND status = 'unpaid'",
            { id, cid })
    end)
    if not row then
        Bridge.Notify(src, 'EMS', 'No open bill of yours with that number.', 'error')
        return
    end

    local amount = tonumber(row.amount) or 0
    if not Bridge.ChargeBank(src, amount, 'ems-bill-payment') then
        Bridge.Notify(src, 'EMS', ('You need $%d in the bank.'):format(amount), 'error')
        return
    end

    -- Settle AFTER a successful charge; a status-guarded UPDATE so a
    -- double-fire cannot double-settle. A failed settle leaves the row open
    -- with the charge visible in the money log, not a silent double-settle.
    local settled = false
    pcall(function()
        settled = MySQL.update.await(
            "UPDATE palm6_ems_bills SET status = 'paid', resolved_at = NOW() WHERE id = ? AND status = 'unpaid'",
            { id }) == 1
    end)
    if settled then
        Bridge.CreditEmsAccount(Config.EmsAccount, amount)
        Bridge.Notify(src, 'EMS',
            ('Bill #%d settled - $%d.'):format(id, amount), 'success')
    else
        Bridge.Notify(src, 'EMS', 'Payment took but the ledger did not update - contact staff.', 'error')
    end
    dbg(('bill #%d paid by %s ($%d)'):format(id, cid, amount))
end

-- ---------------------------------------------------------------------------
-- /emscalls [n] - on-duty medic reads recent 911 traffic from
-- palm6_mdt_calls (READ-ONLY; this resource never writes that table). The
-- table has no status column, so "recent" is a time window, matching how
-- palm6_mdt's own /calls reads it.
-- ---------------------------------------------------------------------------
local function cmdEmsCalls(src, args)
    local cid = gate(src, 'emscalls')
    if not cid then return end

    if not Bridge.ResourceStarted('palm6_mdt') then
        Bridge.Reply(src, { 'dispatch log offline' })
        return
    end

    local n = clamp(math.floor(tonumber(args[1]) or Config.Calls.ListDefault), 1, Config.Calls.ListMax)
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, text, src_label,
                   TIMESTAMPDIFF(MINUTE, created_at, NOW()) AS age_m
            FROM palm6_mdt_calls
            WHERE created_at >= NOW() - INTERVAL ? HOUR
            ORDER BY id DESC LIMIT ?
        ]], { Config.Calls.WindowHours, n }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no recent calls on the log' })
        return
    end
    local lines = {}
    for _, c in ipairs(rows) do
        lines[#lines + 1] = ('#%d [%dm ago] %s%s'):format(
            c.id, tonumber(c.age_m) or 0, c.text,
            (c.src_label and c.src_label ~= '') and (' - ' .. c.src_label) or '')
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /treat <playerid> [note...] - OPTIONAL on-scene treatment record. Logs a
-- row only; it does NOT revive, heal, or alter health/death state (that
-- lives in qbx_ambulancejob, which this resource must not edit).
-- ---------------------------------------------------------------------------
local function cmdTreat(src, args)
    local medicCid = gate(src, 'treat')
    if not medicCid then return end
    if not Config.LogTreatments then
        Bridge.Notify(src, 'EMS', 'Treatment logging is disabled.', 'error')
        return
    end

    local targetId = tonumber(args[1])
    if not targetId then
        Bridge.Notify(src, 'EMS', 'Usage: /treat [playerid] [note]', 'error')
        return
    end

    local patientCid = Bridge.GetCitizenIdOf(targetId)
    if not patientCid then
        Bridge.Notify(src, 'EMS', 'No such player.', 'error')
        return
    end
    if patientCid == medicCid then
        Bridge.Notify(src, 'EMS', 'You cannot treat yourself.', 'error')
        return
    end

    local a = Bridge.GetCoords(src)
    local b = Bridge.GetCoords(targetId)
    if not a or not b or Bridge.Distance(a, b) > Config.Bill.BillRadius then
        Bridge.Notify(src, 'EMS', 'Stand next to the patient to treat them.', 'error')
        return
    end

    local note = table.concat(args, ' ', 2):gsub('^%s+', ''):gsub('%s+$', '')
    if #note > Config.Bill.ReasonMax then note = note:sub(1, Config.Bill.ReasonMax) end

    local ok = pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_ems_treatments (patient_citizenid, medic_citizenid, kind, note)
            VALUES (?, ?, 'treat', ?)
        ]], { patientCid, medicCid, note })
    end)
    if not ok then
        Bridge.Notify(src, 'EMS', 'EMS logging is down - nothing was written.', 'error')
        return
    end

    Bridge.Notify(src, 'EMS', ('Treatment logged for %s.'):format(Bridge.GetPlayerName(targetId)), 'success')
    Bridge.Notify(targetId, 'EMS', 'A medic recorded treating you on scene.', 'inform')
    dbg(('treat on %s by %s'):format(patientCid, medicCid))
end

-- ---------------------------------------------------------------------------
-- Boot: create tables, register commands, print banner. Uses the
-- palm6_dbmigrate Wait(3000) pattern so oxmysql's connection is up first.
-- ---------------------------------------------------------------------------
-- Commands register at load (matching palm6_citations), NOT behind the
-- Wait(3000). RegisterCommand is a pure native that needs no DB, so holding it
-- behind the oxmysql-connect delay left a ~3s window after `restart palm6_ems`
-- where typing a command silently did nothing (command unregistered -> chat
-- swallows it -> works only on the retype). Only the DDL needs the DB-connect
-- wait, so ensureSchema stays inside the thread.
Bridge.RegisterCommand('emsbill', function(source, args) cmdEmsBill(source, args) end)
Bridge.RegisterCommand('medbills', function(source) cmdMedBills(source) end)
Bridge.RegisterCommand('paymedbill', function(source, args) cmdPayMedBill(source, args) end)
Bridge.RegisterCommand('emscalls', function(source, args) cmdEmsCalls(source, args) end)
if Config.LogTreatments then
    Bridge.RegisterCommand('treat', function(source, args) cmdTreat(source, args) end)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()

        print(('[palm6_ems] billing open - %d unpaid bill(s), $%d outstanding; dispatch reader %s')
            :format(unpaidCount(), outstandingSum(),
                Bridge.ResourceStarted('palm6_mdt') and 'ONLINE (palm6_mdt)' or 'offline'))
    end)
end)

-- ---------------------------------------------------------------------------
-- Additive exports (never-change-signature rule, matching citations).
-- ---------------------------------------------------------------------------
exports('GetSummary', function()
    return { unpaid = unpaidCount(), outstanding = outstandingSum() }
end)

-- GetOpenFor(citizenid) -> { count, total } over that citizen's unpaid bills,
-- so a future rap-sheet or onboarding surface can read EMS debt the same way
-- palm6_legal reads citation debt via palm6_citations:GetOpenFor.
exports('GetOpenFor', function(citizenid)
    citizenid = tostring(citizenid or '')
    local out = { count = 0, total = 0 }
    if citizenid == '' then return out end
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM palm6_ems_bills WHERE patient_citizenid = ? AND status = 'unpaid'",
            { citizenid })
        if r then
            out.count = tonumber(r.n) or 0
            out.total = tonumber(r.total) or 0
        end
    end)
    return out
end)
