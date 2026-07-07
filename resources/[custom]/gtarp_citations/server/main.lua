-- ============================================================================
-- gtarp_citations/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- Debt with memory. The recipe's instant billing (police:server:BillPlayer,
-- radar fines) debits online-and-nearby targets and records nothing — a
-- target who can't pay walks away clean. A citation is a ledger row on
-- the CITIZEN (online or offline), payable later at city hall, and it
-- escalates to a gtarp_mdt warrant when it goes overdue.
--
-- No client-trusted net events: /cite acts on server-validated citizen
-- records, /payfine on the payer's own server-read position and bank.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts }

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_citations] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function unpaidCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_citations WHERE status IN ('unpaid','escalated')")
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function paidCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_citations WHERE status = 'paid'")
        n = r and tonumber(r.n) or 0
    end)
    return n
end

-- ---------------------------------------------------------------------------
-- /cite <citizenid> <amount> <reason...> — police + tablet
-- ---------------------------------------------------------------------------
local function cmdCite(src, args)
    if src == 0 then return end
    if not rl(src, 'cite') then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Citations', 'You need to be on duty as police.', 'error')
        return
    end
    if not Bridge.HasItem(src, Config.TabletItem) then
        Bridge.Notify(src, 'Citations', 'You are not carrying your MDT tablet.', 'error')
        return
    end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local target = tostring(args[1] or '')
    local amount = math.floor(tonumber(args[2]) or 0)
    local reason = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    local C = Config.Citation
    if target == '' or amount < C.MinAmount or amount > C.MaxAmount
        or #reason < C.ReasonMin or #reason > C.ReasonMax then
        Bridge.Notify(src, 'Citations',
            ('Usage: /cite [citizenid] [$%d-%d] [reason %d-%d chars]')
            :format(C.MinAmount, C.MaxAmount, C.ReasonMin, C.ReasonMax), 'error')
        return
    end

    local citizenName = Bridge.GetCitizenName(target)
    if not citizenName then
        Bridge.Notify(src, 'Citations', 'No citizen with that id on record.', 'error')
        return
    end

    local officer = Bridge.GetPlayerName(src)
    local ok, citationId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_citations (citizenid, citizen_name, issued_by, officer_name, amount, reason, due_at)
            VALUES (?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? HOUR)
        ]], { target, citizenName, cid, officer, amount, reason, C.DueHours })
    end)
    if not ok or not citationId then
        Bridge.Notify(src, 'Citations', 'Citation system is down — nothing was written.', 'error')
        return
    end

    Bridge.Notify(src, 'Citations',
        ('Citation #%d written: %s, $%d — due in %dh.'):format(citationId, citizenName, amount, C.DueHours), 'success')
    local tSrc = Bridge.GetSourceByCitizenId(target)
    if tSrc then
        Bridge.Notify(tSrc, 'Citation',
            ('You were cited $%d: %s. Pay at %s within %dh (/fines) or a warrant follows.')
            :format(amount, reason, Config.PayDesk.label, C.DueHours), 'error')
    end
    dbg(('citation #%d on %s by %s ($%d)'):format(citationId, target, cid, amount))
end

-- ---------------------------------------------------------------------------
-- /fines — the caller's own open citations
-- ---------------------------------------------------------------------------
local function cmdFines(src)
    if src == 0 then return end
    if not rl(src, 'fines') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, amount, reason, status,
                   TIMESTAMPDIFF(HOUR, NOW(), due_at) AS hrs_left
            FROM gtarp_citations
            WHERE citizenid = ? AND status IN ('unpaid','escalated')
            ORDER BY id DESC LIMIT ?
        ]], { cid, Config.Citation.ListLimit }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no outstanding fines' })
        return
    end
    local lines = {}
    local total = 0
    for _, c in ipairs(rows) do
        total = total + (tonumber(c.amount) or 0)
        local hrs = tonumber(c.hrs_left) or 0
        lines[#lines + 1] = ('#%d $%d — %s [%s]'):format(
            c.id, c.amount, c.reason,
            c.status == 'escalated' and 'OVERDUE — WARRANT OUT'
                or (hrs >= 0 and ('due in %dh'):format(hrs) or 'OVERDUE'))
    end
    lines[#lines + 1] = ('total owed $%d — /payfine [#] at %s'):format(total, Config.PayDesk.label)
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /payfine <id> — settle at city hall from bank
-- ---------------------------------------------------------------------------
local function cmdPayFine(src, args)
    if src == 0 then return end
    if not rl(src, 'payfine') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local pos = Bridge.GetCoords(src)
    if not pos or Bridge.Distance(pos, Config.PayDesk.coords) > Config.PayDesk.radius then
        Bridge.Notify(src, 'Citations', ('Fines are paid at %s.'):format(Config.PayDesk.label), 'error')
        return
    end
    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'Citations', 'Usage: /payfine [citation #]', 'error')
        return
    end

    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, amount, status FROM gtarp_citations WHERE id = ? AND citizenid = ? AND status IN ('unpaid','escalated')",
            { id, cid })
    end)
    if not row then
        Bridge.Notify(src, 'Citations', 'No open citation of yours with that number.', 'error')
        return
    end

    local amount = tonumber(row.amount) or 0
    if not Bridge.ChargeBank(src, amount, 'citation-payment') then
        Bridge.Notify(src, 'Citations', ('You need $%d in the bank.'):format(amount), 'error')
        return
    end

    -- Settle AFTER a successful charge; if the settle write fails the row
    -- stays open and support can see the charge in the money log — the
    -- recoverable failure, not a silent double-settle.
    local settled = false
    pcall(function()
        settled = MySQL.update.await(
            "UPDATE gtarp_citations SET status = 'paid', paid_at = NOW() WHERE id = ? AND status IN ('unpaid','escalated')",
            { id }) == 1
    end)
    if settled then
        Bridge.CreditPoliceAccount(Config.PoliceAccount, amount)
        Bridge.Notify(src, 'Citations',
            ('Citation #%d settled — $%d. A standing warrant for the fine is not lifted automatically; talk to the police.'):format(id, amount), 'success')
    else
        Bridge.Notify(src, 'Citations', 'Payment took but the ledger did not update — contact staff.', 'error')
    end
    dbg(('citation #%d paid by %s ($%d)'):format(id, cid, amount))
end

-- ---------------------------------------------------------------------------
-- Overdue sweep — unpaid past due escalates ONCE to a gtarp_mdt warrant
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait((Config.Escalation.SweepSec or 300) * 1000)
        if Config.Escalation.Enabled and Bridge.ResourceStarted('gtarp_mdt') then
            local due = {}
            pcall(function()
                due = MySQL.query.await(
                    "SELECT id, citizenid, citizen_name, amount, reason FROM gtarp_citations WHERE status = 'unpaid' AND due_at <= NOW()") or {}
            end)
            for _, c in ipairs(due) do
                -- Mark escalated BEFORE issuing so a crash can't spam
                -- warrants; IssueWarrant returning nil (citizen already
                -- has one) still counts as escalated — the debt stays
                -- open either way.
                local marked = false
                pcall(function()
                    marked = MySQL.update.await(
                        "UPDATE gtarp_citations SET status = 'escalated', escalated_at = NOW() WHERE id = ? AND status = 'unpaid'",
                        { c.id }) == 1
                end)
                if marked then
                    local warrantId
                    pcall(function()
                        warrantId = exports.gtarp_mdt:IssueWarrant(c.citizenid,
                            ('unpaid citation #%d — $%d, %s'):format(c.id, c.amount, c.reason),
                            'City Hall Collections')
                    end)
                    if warrantId then
                        pcall(function()
                            MySQL.update.await(
                                'UPDATE gtarp_citations SET warrant_id = ? WHERE id = ?',
                                { warrantId, c.id })
                        end)
                    end
                    local tSrc = Bridge.GetSourceByCitizenId(c.citizenid)
                    if tSrc then
                        Bridge.Notify(tSrc, 'Citation',
                            ('Citation #%d is overdue — a warrant has been issued.'):format(c.id), 'error')
                    end
                    dbg(('citation #%d escalated (warrant %s)'):format(c.id, tostring(warrantId)))
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('cite', function(source, args) cmdCite(source, args) end)
Bridge.RegisterCommand('fines', function(source) cmdFines(source) end)
Bridge.RegisterCommand('payfine', function(source, args) cmdPayFine(source, args) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print(('[gtarp_citations] ledger open — %d open, %d settled; escalation %s')
        :format(unpaidCount(), paidCount(),
            (Config.Escalation.Enabled and Bridge.ResourceStarted('gtarp_mdt'))
                and 'ONLINE (gtarp_mdt warrants)' or 'off'))
end)

---Ledger counts for devtest and future consumers.
exports('GetSummary', function()
    return { open = unpaidCount(), settled = paidCount() }
end)

-- ADDITIVE export for gtarp_legal (expungement eligibility). Same
-- never-change-signature rule.
-- GetOpenFor(citizenid) -> { count, total } over unpaid + escalated.
exports('GetOpenFor', function(citizenid)
    citizenid = tostring(citizenid or '')
    local out = { count = 0, total = 0 }
    if citizenid == '' then return out end
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM gtarp_citations WHERE citizenid = ? AND status IN ('unpaid','escalated')",
            { citizenid })
        if r then
            out.count = tonumber(r.n) or 0
            out.total = tonumber(r.total) or 0
        end
    end)
    return out
end)
