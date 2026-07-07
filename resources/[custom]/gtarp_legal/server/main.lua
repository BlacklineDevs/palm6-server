-- ============================================================================
-- gtarp_legal/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The civilian counterweight to the police paperwork stack. /record shows
-- what the city has on you — bookings (gtarp_mdt), open citations
-- (gtarp_citations), active warrant flag. /expunge petitions to seal an
-- old booking: filed at the courthouse for a non-refundable fee,
-- eligibility checked at filing AND re-checked at resolution (a warrant
-- picked up while the petition processes gets it denied — court costs
-- kept). On-duty lawyers can pull records and file for clients, which
-- gives the recipe's defined-but-inert lawyer job its first mechanic.
--
-- All sibling data access is exports-only: gtarp_mdt GetBookingsFor /
-- HasActiveWarrant / SealBooking, gtarp_citations GetOpenFor. This
-- resource never touches those tables.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts }

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_legal] ' .. msg) end
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
    if not Bridge.ResourceStarted('gtarp_mdt') then return nil end
    local rows
    pcall(function() rows = exports.gtarp_mdt:GetBookingsFor(cid) end)
    return type(rows) == 'table' and rows or nil
end

local function hasWarrant(cid)
    local w = false
    pcall(function() w = exports.gtarp_mdt:HasActiveWarrant(cid) == true end)
    return w
end

local function openCitations(cid)
    if not Bridge.ResourceStarted('gtarp_citations') then return { count = 0, total = 0 } end
    local out = { count = 0, total = 0 }
    pcall(function()
        local r = exports.gtarp_citations:GetOpenFor(cid)
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
            FROM gtarp_legal_petitions
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
    if not Bridge.ResourceStarted('gtarp_mdt') then
        Bridge.Reply(src, { 'booking records offline' })
        return
    end

    -- The booking must exist, be unsealed, be old enough, and belong to
    -- the filer — unless an on-duty lawyer is filing for the subject.
    -- Exports-only: gtarp_mdt owns its tables.
    local booking
    pcall(function() booking = exports.gtarp_mdt:GetBooking(bookingId) end)
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
            "SELECT id FROM gtarp_legal_petitions WHERE booking_id = ? AND status = 'processing'",
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
            INSERT INTO gtarp_legal_petitions (booking_id, citizenid, filed_by, filed_by_name, fee, due_at)
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
    if Bridge.ResourceStarted('gtarp_discord') then
        pcall(function()
            exports.gtarp_discord:Announce('police', {
                title = ('Expungement petition #%d filed'):format(petitionId),
                description = ('Booking #%d is before the court.'):format(bookingId),
            })
        end)
    end
    dbg(('petition #%d by %s on booking %d'):format(petitionId, filerCid, bookingId))
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
                "SELECT id, booking_id, citizenid FROM gtarp_legal_petitions WHERE status = 'processing' AND due_at <= NOW()") or {}
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
                    "UPDATE gtarp_legal_petitions SET status = ?, denial_reason = ?, resolved_at = NOW() WHERE id = ? AND status = 'processing'",
                    { reason and 'denied' or 'granted', reason, p.id }) == 1
            end)
            if marked then
                local tSrc = Bridge.GetSourceByCitizenId(p.citizenid)
                if not reason then
                    local sealed = false
                    pcall(function() sealed = exports.gtarp_mdt:SealBooking(p.booking_id) == true end)
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

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local processing, granted = petitionCounts()
    print(('[gtarp_legal] court open — %d petition(s) before the court, %d granted all-time; records %s')
        :format(processing, granted,
            Bridge.ResourceStarted('gtarp_mdt') and 'ONLINE' or 'offline'))
end)

---Petition counts for devtest and future consumers.
exports('GetSummary', function()
    local processing, granted = petitionCounts()
    return { processing = processing, granted = granted }
end)
