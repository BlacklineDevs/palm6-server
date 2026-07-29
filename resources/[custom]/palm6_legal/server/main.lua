-- ============================================================================
-- palm6_legal/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The civilian counterweight to the police paperwork stack. /record shows
-- what the city has on you — bookings (palm6_mdt), open citations
-- (palm6_citations), active warrant flag. /expunge petitions to seal an
-- old booking: filed at the courthouse for a non-refundable fee,
-- eligibility checked at filing AND re-checked at resolution (a warrant
-- picked up while the petition processes gets it denied — court costs
-- kept). On-duty lawyers can pull records and file for clients, which
-- gives the recipe's defined-but-inert lawyer job its first mechanic.
--
-- All sibling data access is exports-only: palm6_mdt GetBookingsFor /
-- HasActiveWarrant / SealBooking, palm6_citations GetOpenFor. This
-- resource never touches those tables.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts }

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Same shape as palm6_courier and palm6_ems:
-- Wait-for-oxmysql on the caller's thread, per-statement pcall, IF NOT EXISTS
-- so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- palm6_legal_petitions at all. The failure is SILENT and it eats money: the
-- filer is charged the court fee BEFORE the INSERT, and that INSERT is
-- pcall'd, so the fee is gone and no petition exists to ever rule on. On the
-- live box this statement is a pure no-op.
--
-- The CREATE TABLE is copied VERBATIM from sql/0026_legal.sql. That file also
-- carries an ADD COLUMN sealed_at on palm6_mdt_bookings; that column is NOT
-- created here because this resource never touches the bookings table (all
-- sibling access is exports-only, see the module header) and palm6_mdt owns
-- that schema.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_legal_petitions` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    booking_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,          -- the subject of the booking
    filed_by VARCHAR(64) NOT NULL,           -- who filed (subject or lawyer)
    filed_by_name VARCHAR(100) NOT NULL DEFAULT '',
    fee INT UNSIGNED NOT NULL,
    status ENUM('processing','granted','denied') NOT NULL DEFAULT 'processing',
    denial_reason VARCHAR(120) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    due_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_legal_petitions_status_due (status, due_at),
    INDEX idx_palm6_legal_petitions_booking (booking_id),
    INDEX idx_palm6_legal_petitions_citizen (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_legal] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_legal] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function bookingsFor(cid)
    if not Bridge.ResourceStarted('palm6_mdt') then return nil end
    local rows
    pcall(function() rows = exports.palm6_mdt:GetBookingsFor(cid) end)
    return type(rows) == 'table' and rows or nil
end

local function hasWarrant(cid)
    if not Bridge.ResourceStarted('palm6_mdt') then return false end
    local w = false
    pcall(function() w = exports.palm6_mdt:HasActiveWarrant(cid) == true end)
    return w
end

local function openCitations(cid)
    if not Bridge.ResourceStarted('palm6_citations') then return { count = 0, total = 0 } end
    local out = { count = 0, total = 0 }
    pcall(function()
        local r = exports.palm6_citations:GetOpenFor(cid)
        if type(r) == 'table' then
            out.count = tonumber(r.count) or 0
            out.total = tonumber(r.total) or 0
        end
    end)
    return out
end

local function petitionCounts()
    local processing, granted = 0, 0
    pcall(function()
        local r = MySQL.single.await([[
            SELECT SUM(status = 'processing') AS p, SUM(status = 'granted') AS g
            FROM palm6_legal_petitions
        ]])
        if r then
            processing = tonumber(r.p) or 0
            granted = tonumber(r.g) or 0
        end
    end)
    return processing, granted
end

-- Resolve the record subject for a command: yourself by default, or —
-- for an on-duty lawyer — a client's citizenid passed as an argument.
-- Returns citizenid, displayName or nil (having told the caller why).
local function resolveSubject(src, arg)
    local selfCid = Bridge.GetCitizenId(src)
    if not selfCid then return nil end
    local target = tostring(arg or '')
    if target == '' or target == selfCid then
        return selfCid, Bridge.GetPlayerName(src)
    end
    if not Bridge.IsOnDutyLawyer(src) then
        Bridge.Notify(src, 'Legal', 'Only an on-duty lawyer can pull someone else\'s record.', 'error')
        return nil
    end
    local name = Bridge.GetCitizenName(target)
    if not name then
        Bridge.Notify(src, 'Legal', 'No citizen with that id on record.', 'error')
        return nil
    end
    return target, name
end

-- ---------------------------------------------------------------------------
-- /record [citizenid] — the rap sheet
-- ---------------------------------------------------------------------------
local function cmdRecord(src, args)
    if src == 0 then return end
    if not rl(src, 'record') then return end
    local cid, name = resolveSubject(src, args[1])
    if not cid then return end

    local lines = { ('record — %s'):format(name) }
    local bookings = bookingsFor(cid)
    if bookings == nil then
        lines[#lines + 1] = 'booking records offline'
    elseif #bookings == 0 then
        lines[#lines + 1] = 'no bookings on record'
    else
        for _, b in ipairs(bookings) do
            lines[#lines + 1] = ('booking #%d — %s (%s)%s'):format(
                b.id, b.charges, tostring(b.booked_at),
                b.case_id and (' [case ' .. b.case_id .. ']') or '')
        end
    end
    local cit = openCitations(cid)
    if cit.count > 0 then
        lines[#lines + 1] = ('%d open citation(s), $%d owed'):format(cit.count, cit.total)
    end
    if hasWarrant(cid) then
        lines[#lines + 1] = 'ACTIVE WARRANT out'
    end
    if bookings and #bookings > 0 then
        lines[#lines + 1] = '/expunge [booking#] at the courthouse to petition'
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /expunge <booking#> — file a petition (self, or lawyer for a client)
-- ---------------------------------------------------------------------------
local function cmdExpunge(src, args)
    if src == 0 then return end
    if not rl(src, 'expunge') then return end
    local filerCid = Bridge.GetCitizenId(src)
    if not filerCid then return end

    local pos = Bridge.GetCoords(src)
    if not pos or Bridge.Distance(pos, Config.Courthouse.coords) > Config.Courthouse.radius then
        Bridge.Notify(src, 'Legal', ('Petitions are filed at %s.'):format(Config.Courthouse.label), 'error')
        return
    end
    local bookingId = tonumber(args[1])
    if not bookingId then
        Bridge.Notify(src, 'Legal', 'Usage: /expunge [booking #]', 'error')
        return
    end
    if not Bridge.ResourceStarted('palm6_mdt') then
        Bridge.Reply(src, { 'booking records offline' })
        return
    end

    -- The booking must exist, be unsealed, be old enough, and belong to
    -- the filer — unless an on-duty lawyer is filing for the subject.
    -- Exports-only: palm6_mdt owns its tables.
    local booking
    pcall(function() booking = exports.palm6_mdt:GetBooking(bookingId) end)
    if type(booking) ~= 'table' or booking.sealed then
        Bridge.Notify(src, 'Legal', 'No unsealed booking with that number.', 'error')
        return
    end
    local subjectCid = booking.citizenid
    if subjectCid ~= filerCid and not Bridge.IsOnDutyLawyer(src) then
        Bridge.Notify(src, 'Legal', 'Only an on-duty lawyer can file for someone else.', 'error')
        return
    end

    local E = Config.Expunge
    if booking.age_hours < E.MinBookingAgeH then
        Bridge.Notify(src, 'Legal',
            ('The court only hears petitions on bookings older than %d days.'):format(
                math.floor(E.MinBookingAgeH / 24)), 'error')
        return
    end
    if hasWarrant(subjectCid) then
        Bridge.Notify(src, 'Legal', 'The subject has an active warrant — the court won\'t hear it.', 'error')
        return
    end
    local cit = openCitations(subjectCid)
    if cit.count > 0 then
        Bridge.Notify(src, 'Legal',
            ('The subject owes $%d in open citations — settle those first.'):format(cit.total), 'error')
        return
    end

    -- One processing petition per booking.
    local pending
    pcall(function()
        pending = MySQL.single.await(
            "SELECT id FROM palm6_legal_petitions WHERE booking_id = ? AND status = 'processing'",
            { bookingId })
    end)
    if pending then
        Bridge.Notify(src, 'Legal', ('Petition #%d on that booking is already before the court.'):format(pending.id), 'error')
        return
    end

    if not Bridge.ChargeBank(src, E.Fee, 'expungement-filing') then
        Bridge.Notify(src, 'Legal', ('Filing costs $%d (bank), non-refundable.'):format(E.Fee), 'error')
        return
    end

    local ok, petitionId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_legal_petitions (booking_id, citizenid, filed_by, filed_by_name, fee, due_at)
            VALUES (?, ?, ?, ?, ?, NOW() + INTERVAL ? SECOND)
        ]], { bookingId, subjectCid, filerCid, Bridge.GetPlayerName(src), E.Fee, E.ProcessingSec })
    end)
    if not ok or not petitionId then
        -- The fee was taken; refund since nothing was filed.
        Bridge.CreditBankByCitizenId(filerCid, E.Fee, 'expungement-filing-refund')
        Bridge.Notify(src, 'Legal', 'Filing failed — you were refunded.', 'error')
        return
    end

    Bridge.Notify(src, 'Legal',
        ('Petition #%d filed on booking #%d — the court rules in ~%d minutes.')
        :format(petitionId, bookingId, math.ceil(E.ProcessingSec / 60)), 'success')
    if Bridge.ResourceStarted('palm6_discord') then
        pcall(function()
            exports.palm6_discord:Announce('police', {
                title = ('Expungement petition #%d filed'):format(petitionId),
                description = ('Booking #%d is before the court.'):format(bookingId),
            })
        end)
    end

    -- In-world civic bulletin (public facts only) via the palm6-bot feed. The
    -- bot narrates the court docket into #doj-notices. Soft-dep + pcall so a
    -- missing/broken cityfeed never breaks a filing. PUBLIC FACTS ONLY: a case
    -- reference + a hearing phrase, never a citizenid/booking-subject id.
    -- Shape is documented in the palm6_cityfeed README (court_date example), so
    -- this is convar-gated ON by default. `hearing_date` is a narration phrase,
    -- not a raw timestamp — the petition rules ~ProcessingSec after filing.
    if GetResourceState('palm6_cityfeed') == 'started'
        and GetConvar('palm6:cityfeed_court', 'true') == 'true' then
        pcall(function()
            exports.palm6_cityfeed:Emit({
                type = 'court_date',
                case_ref = ('Petition #%d'):format(petitionId),
                hearing_date = 'today',
            })
        end)
    end
    dbg(('petition #%d by %s on booking %d'):format(petitionId, filerCid, bookingId))
end

-- ---------------------------------------------------------------------------
-- /sentence <citizenid|*> <booking#> [code...] : the review step (v0.2.0).
-- SHIPS OFF.
--
-- Prints a recommended sentence and fine for a booking, WITH the arithmetic
-- that produced it. Read-only in the strongest sense: it selects, it computes,
-- it replies to the caller. It does not jail, fine, charge, seal, or notify
-- the subject. The physical side belongs to qbx_police, which is not in this
-- repo (see README.md).
--
-- Three privacy properties hold here and are load-bearing:
--   * you must already know the subject's citizenid (or hold the court ace),
--     so the booking number cannot be walked as an identity oracle;
--   * a sealed (expunged) booking is invisible to everything below the court
--     ace, and its refusal is worded identically to "no such booking", so the
--     refusal itself does not confirm that an expungement happened;
--   * priors are counted from UNSEALED rows only (palm6_mdt's priorsFor), so
--     the printed prior count cannot betray a sealed booking either.
--
-- Staff audit sink, same soft pattern palm6_mdt uses for bookings: never let a
-- missing or broken sink fail the command. palm6_staff's Log is not internally
-- pcall'd, so the pcall here is load-bearing rather than decorative.
-- ---------------------------------------------------------------------------
local function auditLog(action, actorSrc, targetSrc, detail)
    if not Bridge.ResourceStarted('palm6_staff') then return end
    pcall(function()
        exports.palm6_staff:Log(action, actorSrc, targetSrc, detail)
    end)
end

-- Who may pull a recommendation, and AT WHAT TIER. Console and the ace are
-- 'court', the operator-granted audit tier: the only one that can read a
-- sealed booking or pass `*` instead of a citizenid. The three job branches are
-- 'job': they still have to name the subject they are looking up. Every branch
-- FAILS CLOSED: an ungranted ace and a mistyped job name both simply do not
-- match, and an unmatched caller gets tier nil.
local function sentenceGate(src)
    if src == 0 then return 'court' end
    local S = Config.Sentencing
    if Bridge.IsAceAllowed(src, S.Ace) then return 'court' end
    if S.AllowJudge and Bridge.IsOnDutyJudge(src) then return 'job' end
    if S.AllowLawyer and Bridge.IsOnDutyLawyer(src) then return 'job' end
    if S.AllowPolice and Bridge.IsOnDutyPolice(src) then return 'job' end
    return nil
end

-- Rolling lookup budget + audit de-dup, per source. One record per source,
-- reset wholesale when its window expires, so nothing here grows without
-- bound: `logged` can only ever hold MaxPerWindow keys before the reset drops
-- the whole record.
--
-- This is a SEPARATE control from rl() above. rl() spaces requests 5s apart,
-- which does nothing against a patient loop; this caps how many distinct
-- records one source can pull in a window at all.
local sentenceWindow = {}   -- [src] = { start = ts, n = 0, logged = {} }

local function sentenceBudget(src)
    if src == 0 then return true end   -- server console, not a player surface
    local S = Config.Sentencing
    local windowSec = tonumber(S.WindowSec) or 300
    local maxPer = tonumber(S.MaxPerWindow) or 8
    local t = now()
    local w = sentenceWindow[src]
    if not w or (t - w.start) >= windowSec then
        w = { start = t, n = 0, logged = {} }
        sentenceWindow[src] = w
    end
    if w.n >= maxPer then return false, math.max(1, windowSec - (t - w.start)) end
    w.n = w.n + 1
    return true
end

-- True the first time this source is told about this booking in the current
-- window. Keeps a read-only command from becoming a Discord webhook loop.
local function auditFirstSeen(src, bookingId)
    if src == 0 then return true end
    local w = sentenceWindow[src]
    if not w then return true end
    local key = tostring(bookingId)
    if w.logged[key] then return false end
    w.logged[key] = true
    return true
end

-- Citizenids are typed in chat. Normalise for comparison only; the value that
-- gets printed is always the one the database returned, never the typed one.
local function sameCitizen(a, b)
    local x = tostring(a or ''):gsub('%s+', ''):upper()
    local y = tostring(b or ''):gsub('%s+', ''):upper()
    return x ~= '' and x == y
end

local function cmdSentence(src, args)
    if src ~= 0 and not rl(src, 'sentence') then return end
    local tier = sentenceGate(src)
    if not tier then
        Bridge.Notify(src, 'Legal',
            'Only the court, an on-duty judge or lawyer, or on-duty police can pull a sentencing recommendation.', 'error')
        return
    end
    local subject = tostring(args[1] or ''):gsub('%s+', '')
    local bookingId = tonumber(args[2])
    if subject == '' or not bookingId then
        Bridge.Reply(src, {
            ('Usage: /%s [citizenid] [booking #] [charge code...]'):format(Config.Sentencing.Command),
            'you have to know whose booking it is: the citizenid must match the record',
            'with no codes it lists the codes found in the booking text, but will not price them',
        })
        return
    end

    -- `*` means "whoever this booking belongs to" and is the court tier only.
    -- It is the enumeration primitive, so it is gated exactly like sealed
    -- access: an operator-granted ace, or the server console.
    local anySubject = (subject == '*')
    if anySubject and tier ~= 'court' then
        Bridge.Notify(src, 'Legal',
            'Only the court can pull a booking without naming the citizen it belongs to.', 'error')
        return
    end

    if not Bridge.ResourceStarted('palm6_mdt') then
        Bridge.Reply(src, { 'booking records offline' })
        return
    end

    -- Budget is spent HERE, on the last line before a record is actually read.
    -- Everything above this point is either a usage mistake or a hard denial and
    -- reveals nothing, so a fat-fingered officer does not burn their allowance;
    -- everything below it is a well-formed request for somebody's record and
    -- costs the same whether it finds a row or not, so a prober gains nothing by
    -- aiming at ids that miss.
    local within, waitSec = sentenceBudget(src)
    if not within then
        Bridge.Notify(src, 'Legal',
            ('That is too many record pulls at once. Try again in %d second(s).'):format(waitSec), 'error')
        return
    end

    -- Codes are everything after the booking number. Soft cross-resource call,
    -- house idiom: palm6_mdt owns the bookings table and the calculator, and
    -- this resource never touches either directly.
    local codes = {}
    for i = 3, #args do codes[#codes + 1] = args[i] end

    -- allowSealed is the court tier ONLY. A sealed booking is one a player paid
    -- the court fee to bury; for everybody else palm6_mdt returns nil for it,
    -- which lands on the same branch as a booking that never existed.
    local rec
    pcall(function()
        rec = exports.palm6_mdt:RecommendForBooking(bookingId, codes,
            { allowSealed = (tier == 'court') })
    end)

    -- ONE message covers no-such-booking, sealed-and-you-are-not-the-court, and
    -- wrong-citizenid. That is deliberate: a distinct "that booking belongs to
    -- someone else" would confirm the booking exists and hand back exactly the
    -- enumeration signal the citizenid argument is here to remove, and a
    -- distinct "that record is sealed" would confirm an expungement.
    local denied = (type(rec) ~= 'table')
        or (not anySubject and not sameCitizen(subject, rec.citizenid))
    if denied then
        Bridge.Reply(src, {
            'no recommendation available for that booking',
            'either no booking with that number for that citizen, or the charge catalogue is switched off',
        })
        return
    end

    local r = rec.result
    local lines = {
        ('sentencing review — booking #%d, %s (%s)'):format(
            rec.bookingId,
            (rec.citizenName and rec.citizenName ~= '') and rec.citizenName or 'unknown citizen',
            rec.citizenid),
        ('filed charges: %s'):format(rec.charges),
    }
    if rec.sealed then
        -- Only the court tier can reach this line at all (palm6_mdt returns nil
        -- for a sealed booking otherwise), and it must never read as live.
        lines[#lines + 1] = 'NOTE: this booking is SEALED (expunged) — it is not a live charge'
    end

    if not r or not r.ok then
        lines[#lines + 1] = ('no recommendation: %s'):format(
            (r and r.reason) or 'the calculator returned nothing')
        lines[#lines + 1] = ('give codes explicitly: /%s %s %d [code...]'):format(
            Config.Sentencing.Command, rec.citizenid, rec.bookingId)
        if r and #r.unknown > 0 then
            lines[#lines + 1] = ('unrecognised: %s'):format(table.concat(r.unknown, ', '))
        end
        -- Suggestions, clearly marked as not a sentence. The scan is literal
        -- whole-token matching, so it can only ever see the one-word codes, and
        -- on the shipped catalogue those are the mild ones. Naming the codes it
        -- structurally cannot find is the difference between a hint and a trap.
        -- The unmatchable list comes from palm6_mdt's live catalogue, so it
        -- stays accurate if an operator edits the charge codes.
        if rec.suggested and #rec.suggested > 0 then
            lines[#lines + 1] = ('found in the booking text (NOT priced, check it yourself): %s')
                :format(table.concat(rec.suggested, ', '))
        end
        if rec.unmatchable and #rec.unmatchable > 0 then
            lines[#lines + 1] = ('the text scan cannot find these codes in ordinary prose, so check the charges by hand: %s')
                :format(table.concat(rec.unmatchable, ', '))
        end
        Bridge.Reply(src, lines)
        return
    end

    lines[#lines + 1] = ('charge codes: %s'):format(table.concat(rec.codes, ', '))
    lines[#lines + 1] = ('RECOMMENDED: %d %s and $%d'):format(r.sentence, r.unit, r.fine)
    lines[#lines + 1] = 'why:'
    for _, b in ipairs(r.breakdown) do
        lines[#lines + 1] = '  ' .. b
    end
    -- The honest footer. Nobody should read this output and believe the
    -- sentence has been carried out.
    lines[#lines + 1] = 'this is a RECOMMENDATION only — nothing has been applied to this citizen'

    Bridge.Reply(src, lines)

    -- Successful lookups only, de-duplicated per window. GetSourceByCitizenId
    -- sweeps every online player, so it is called only when a row is actually
    -- going to be written.
    if Config.Sentencing.Audit and auditFirstSeen(src, rec.bookingId) then
        auditLog('legal_sentence_review', src, Bridge.GetSourceByCitizenId(rec.citizenid),
            ('booking #%d on %s (%s): recommended %d %s + $%d from [%s], %d prior(s) counted, multiplier %d%%')
            :format(rec.bookingId, rec.citizenName, rec.citizenid,
                r.sentence, r.unit, r.fine, table.concat(rec.codes, ' '),
                r.priors, r.multPct))
    end
    dbg(('sentence review on booking %d by %s'):format(
        rec.bookingId, src == 0 and 'console' or tostring(Bridge.GetCitizenId(src))))
end

-- ---------------------------------------------------------------------------
-- Resolver sweep — re-checks eligibility at ruling time, then seals
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait((Config.Expunge.SweepSec or 60) * 1000)
        local due = {}
        pcall(function()
            due = MySQL.query.await(
                "SELECT id, booking_id, citizenid FROM palm6_legal_petitions WHERE status = 'processing' AND due_at <= NOW()") or {}
        end)
        for _, p in ipairs(due) do
            -- Rule (mark) BEFORE sealing so a crash can't double-rule;
            -- eligibility re-checked here — the world may have changed
            -- while the petition processed.
            local reason
            if hasWarrant(p.citizenid) then
                reason = 'active warrant at ruling'
            else
                local cit = openCitations(p.citizenid)
                if cit.count > 0 then reason = 'open citations at ruling' end
            end

            local marked = false
            pcall(function()
                marked = MySQL.update.await(
                    "UPDATE palm6_legal_petitions SET status = ?, denial_reason = ?, resolved_at = NOW() WHERE id = ? AND status = 'processing'",
                    { reason and 'denied' or 'granted', reason, p.id }) == 1
            end)
            if marked then
                local tSrc = Bridge.GetSourceByCitizenId(p.citizenid)
                if not reason then
                    local sealed = false
                    pcall(function() sealed = exports.palm6_mdt:SealBooking(p.booking_id) == true end)
                    if tSrc then
                        Bridge.Notify(tSrc, 'Legal',
                            sealed and ('Petition #%d GRANTED — booking #%d is sealed.'):format(p.id, p.booking_id)
                                    or ('Petition #%d granted but sealing failed — contact staff.'):format(p.id),
                            sealed and 'success' or 'error')
                    end
                    dbg(('petition #%d granted (sealed=%s)'):format(p.id, tostring(sealed)))
                else
                    if tSrc then
                        Bridge.Notify(tSrc, 'Legal',
                            ('Petition #%d DENIED — %s. Court costs are not refunded.'):format(p.id, reason), 'error')
                    end
                    dbg(('petition #%d denied: %s'):format(p.id, reason))
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('record', function(source, args) cmdRecord(source, args) end)
Bridge.RegisterCommand('expunge', function(source, args) cmdExpunge(source, args) end)
-- Registered only when sentencing is switched on, so with the flag off the
-- command name is not claimed at all.
if Config.Sentencing.Enabled then
    Bridge.RegisterCommand(Config.Sentencing.Command, function(source, args) cmdSentence(source, args) end)
    -- Drop the departed source's lookup budget. Registered INSIDE this branch
    -- on purpose: with the flag off, palm6_legal must add no handler and no
    -- observable behaviour at all beyond its boot banner. lastAction is left
    -- alone here so /record and /expunge cooldowns behave exactly as they did.
    AddEventHandler('playerDropped', function()
        sentenceWindow[source] = nil
    end)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Runs on its own thread because ensureSchema has to Wait for oxmysql's
    -- connection before any query, and petitionCounts must not run before the
    -- table is guaranteed to exist. Nothing is cached at boot (every read is
    -- per-command), so no command needs a bootReady gate; the resolver sweep
    -- above does not touch the DB until its first Config.Expunge.SweepSec
    -- tick, which is well after this thread has finished.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- Banner FIRST, with nothing that can throw between it and
        -- ensureSchema(). It exists to diagnose the fresh-box case where the
        -- table is absent, which is otherwise completely silent: /expunge
        -- charges the court fee and then loses the petition.
        if not SchemaReady then
            print('^1[palm6_legal] schema MISSING - expungement petitions are LOST after charging on this box.^0')
        end
        local processing, granted = petitionCounts()
        print(('[palm6_legal] court open — %d petition(s) before the court, %d granted all-time; records %s, sentencing review %s')
            :format(processing, granted,
                Bridge.ResourceStarted('palm6_mdt') and 'ONLINE' or 'offline',
                Config.Sentencing.Enabled and ('ON (/' .. Config.Sentencing.Command .. ')') or 'off'))
    end)
end)

---Petition counts for devtest and future consumers.
exports('GetSummary', function()
    local processing, granted = petitionCounts()
    return { processing = processing, granted = granted }
end)

---The name of the registered sentencing review command.
---
---Exists so palm6_mdt's /charges can point officers at a command that is
---actually there, under the name it is actually registered under. The two flags
---live in independent resources and the name is configurable (same
---last-registration-wins reasoning as Config.Identify.Command), so /charges
---printing a hardcoded "/sentence" was advertising a command that may not
---exist. Additive and read-only; returns a string, never the Config table.
---
---Registered ONLY when sentencing is on, alongside the command itself, so the
---flag-off path adds no export either. A consumer that pcalls a missing export
---and one that reads a nil from a present export land on the same branch, so
---gating the registration costs nothing and keeps "flag off changes nothing"
---literally true.
if Config.Sentencing.Enabled then
    exports('GetSentenceCommand', function()
        return tostring(Config.Sentencing.Command)
    end)
end
