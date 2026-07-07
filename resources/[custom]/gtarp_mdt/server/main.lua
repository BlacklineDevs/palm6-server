-- ============================================================================
-- gtarp_mdt/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The police Mobile Data Terminal: the in-game READER for the case files
-- the city's systems already produce (insurance fraud, witness canvasses,
-- counterfeit leads, pumpcoin rugs — all landing in gtarp_evidence), plus
-- BOLO broadcasts and written reports. Every command is gated on-duty
-- police + carrying the mdt_tablet item, and every read/write happens
-- server-side — there is no client script at all.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts } per-source rate limits

-- Resolved GetMDT() contract (qbx_police_overrides when running, else
-- Config.MDTDefaults). Resolved once at boot — the override resource
-- starts before us in custom.cfg.
local MDT = nil

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_mdt] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- Common gate: rate limit, on-duty police, tablet in hand. Returns
-- citizenid or nil (having already told the caller what's missing).
local function gate(src, key)
    if src == 0 then return nil end
    if not rl(src, key) then return nil end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'MDT', 'You need to be on duty as police.', 'error')
        return nil
    end
    if not Bridge.HasItem(src, Config.TabletItem) then
        Bridge.Notify(src, 'MDT', 'You are not carrying your MDT tablet.', 'error')
        return nil
    end
    return Bridge.GetCitizenId(src)
end

local function activeBoloCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS n FROM gtarp_mdt_bolos WHERE resolved_at IS NULL AND expires_at > NOW()')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function reportCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM gtarp_mdt_reports')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function openCases(limit)
    if not Bridge.ResourceStarted('gtarp_evidence') then return nil end
    local rows
    pcall(function()
        rows = exports.gtarp_evidence:ListCases('open', limit)
    end)
    return type(rows) == 'table' and rows or nil
end

-- ---------------------------------------------------------------------------
-- /mdt — one-glance desk summary
-- ---------------------------------------------------------------------------
local function cmdMdt(src)
    if not gate(src, 'mdt') then return end
    local lines = {}
    local bolos = activeBoloCount()
    lines[#lines + 1] = ('%d active BOLO(s) — /bolos to list, /bolo [text] to issue'):format(bolos)
    lines[#lines + 1] = ('%d active warrant(s) — /warrants to list'):format(activeWarrantCount())
    lines[#lines + 1] = ('%d call(s) in 24h — /calls for the 911 log'):format(calls24h())
    local cases = openCases(Config.Cases.ListLimit)
    if cases then
        lines[#lines + 1] = ('%d open case file(s)%s — /mdtcases to list'):format(
            #cases, #cases >= Config.Cases.ListLimit and '+' or '')
    else
        lines[#lines + 1] = 'case system offline'
    end
    lines[#lines + 1] = 'file paperwork: /mdtreport [case# or 0] [text]'
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /bolo <text...>  — issue; broadcast to on-duty police + police feed
-- ---------------------------------------------------------------------------
local function cmdBolo(src, args)
    local cid = gate(src, 'bolo')
    if not cid then return end
    local text = table.concat(args, ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #text < Config.Bolo.MinChars or #text > Config.Bolo.MaxChars then
        Bridge.Notify(src, 'MDT',
            ('BOLO text must be %d-%d characters.'):format(Config.Bolo.MinChars, Config.Bolo.MaxChars), 'error')
        return
    end

    local durMin = tonumber(MDT.bolo_default_duration_minutes) or 60
    local officer = Bridge.GetPlayerName(src)
    local ok, boloId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_mdt_bolos (citizenid, officer_name, body, expires_at)
            VALUES (?, ?, ?, NOW() + INTERVAL ? MINUTE)
        ]], { cid, officer, text, durMin })
    end)
    if not ok or not boloId then
        Bridge.Notify(src, 'MDT', 'BOLO system is down — nothing was issued.', 'error')
        return
    end

    Bridge.NotifyPolice('BOLO #' .. boloId, text, 'inform')
    if Bridge.ResourceStarted('gtarp_discord') then
        pcall(function()
            exports.gtarp_discord:Announce('police', {
                title = ('BOLO #%d issued'):format(boloId),
                description = text,
                fields = {
                    { name = 'Officer', value = officer, inline = true },
                    { name = 'Expires', value = ('%d min'):format(durMin), inline = true },
                },
            })
        end)
    end
    dbg(('bolo #%d by %s: %s'):format(boloId, cid, text))
end

-- ---------------------------------------------------------------------------
-- /bolos — list active
-- ---------------------------------------------------------------------------
local function cmdBolos(src)
    if not gate(src, 'bolos') then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, officer_name, body,
                   TIMESTAMPDIFF(MINUTE, NOW(), expires_at) AS mins_left
            FROM gtarp_mdt_bolos
            WHERE resolved_at IS NULL AND expires_at > NOW()
            ORDER BY id DESC LIMIT ?
        ]], { Config.Bolo.ListLimit }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no active BOLOs' })
        return
    end
    local lines = {}
    for _, b in ipairs(rows) do
        lines[#lines + 1] = ('#%d [%dm left] %s — %s'):format(
            b.id, math.max(0, tonumber(b.mins_left) or 0), b.body, b.officer_name)
    end
    lines[#lines + 1] = '/boloclear [#] to resolve'
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /boloclear <id> — any on-duty officer can resolve
-- ---------------------------------------------------------------------------
local function cmdBoloClear(src, args)
    local cid = gate(src, 'boloclear')
    if not cid then return end
    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'MDT', 'Usage: /boloclear [bolo #]', 'error')
        return
    end
    local cleared = false
    pcall(function()
        cleared = MySQL.update.await(
            'UPDATE gtarp_mdt_bolos SET resolved_at = NOW(), resolved_by = ? WHERE id = ? AND resolved_at IS NULL',
            { cid, id }) == 1
    end)
    if cleared then
        Bridge.Notify(src, 'MDT', ('BOLO #%d resolved.'):format(id), 'success')
    else
        Bridge.Notify(src, 'MDT', 'No active BOLO with that number.', 'error')
    end
end

-- ---------------------------------------------------------------------------
-- /mdtcases — open case files (gtarp_evidence, read via exports only)
-- ---------------------------------------------------------------------------
local function cmdCases(src)
    if not gate(src, 'mdtcases') then return end
    local cases = openCases(Config.Cases.ListLimit)
    if not cases then
        Bridge.Reply(src, { 'case system offline' })
        return
    end
    if #cases == 0 then
        Bridge.Reply(src, { 'no open case files' })
        return
    end
    local lines = {}
    for _, c in ipairs(cases) do
        lines[#lines + 1] = ('case %d — %s (%d suspect(s))'):format(
            c.id, c.title, tonumber(c.suspects) or 0)
    end
    lines[#lines + 1] = '/mdtcase [#] for the file'
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /mdtcase <id> — full case file
-- ---------------------------------------------------------------------------
local function cmdCase(src, args)
    if not gate(src, 'mdtcase') then return end
    if not Bridge.ResourceStarted('gtarp_evidence') then
        Bridge.Reply(src, { 'case system offline' })
        return
    end
    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'MDT', 'Usage: /mdtcase [case #]', 'error')
        return
    end
    local c
    pcall(function() c = exports.gtarp_evidence:GetCase(id) end)
    if type(c) ~= 'table' then
        Bridge.Notify(src, 'MDT', 'No case file with that number.', 'error')
        return
    end

    local lines = {}
    lines[#lines + 1] = ('case %d [%s] %s'):format(c.id, c.status, c.title)
    lines[#lines + 1] = ('opened %s by %s'):format(tostring(c.created_at), c.created_by_name ~= '' and c.created_by_name or c.created_by)
    for _, s in ipairs(c.suspects or {}) do
        if s.citizenid then
            local w = activeWarrantsFor(s.citizenid)
            lines[#lines + 1] = ('suspect: citizen %s%s'):format(s.citizenid,
                #w > 0 and (' — ACTIVE WARRANT #%d'):format(w[1].id) or '')
        else
            lines[#lines + 1] = ('suspect (unidentified): %s'):format(tostring(s.descriptor))
        end
    end
    local shown = 0
    for _, e in ipairs(c.entries or {}) do
        if shown >= Config.Cases.EntryLines then break end
        shown = shown + 1
        local desc = tostring(e.description or '')
        if #desc > Config.Cases.EntryTrim then desc = desc:sub(1, Config.Cases.EntryTrim) .. '…' end
        lines[#lines + 1] = ('[%s/%s] %s'):format(e.kind or 'note', e.source or '?', desc)
    end
    if #(c.entries or {}) > shown then
        lines[#lines + 1] = ('… %d more entr(ies) on file'):format(#c.entries - shown)
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- Warrants (v0.2.0) — the paper trail on top of qbx_police's physical
-- /cuff //jail. A warrant is an open order naming a citizen; a booking is
-- the paperwork filed when the arrest actually happens, and it auto-serves
-- that citizen's active warrants.
-- ---------------------------------------------------------------------------

local function activeWarrantCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM gtarp_mdt_warrants WHERE status = 'active'")
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function bookingCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM gtarp_mdt_bookings')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function activeWarrantsFor(citizenid)
    local rows = {}
    pcall(function()
        rows = MySQL.query.await(
            "SELECT id, reason FROM gtarp_mdt_warrants WHERE citizenid = ? AND status = 'active'",
            { citizenid }) or {}
    end)
    return rows
end

-- Optional case reference shared by /warrant and /book: 0 = none, >0 must
-- be a real case. Returns validated caseId (0 for none) or nil on error.
local function refCase(src, raw)
    local caseId = tonumber(raw)
    if not caseId or caseId < 0 then
        return nil
    end
    if caseId > 0 then
        local c
        pcall(function() c = exports.gtarp_evidence:GetCase(caseId) end)
        if type(c) ~= 'table' then
            Bridge.Notify(src, 'MDT', 'No case file with that number (use 0 for none).', 'error')
            return nil
        end
    end
    return caseId
end

-- Core issuance shared by /warrant and the IssueWarrant export. Caller
-- has already validated the citizen, the reason bounds, and the
-- one-active-per-citizen rule. Returns warrantId or nil.
local function issueWarrant(target, citizenName, caseId, reason, issuerCid, officerLabel)
    local ok, warrantId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_mdt_warrants (citizenid, citizen_name, issued_by, officer_name, case_id, reason)
            VALUES (?, ?, ?, ?, ?, ?)
        ]], { target, citizenName, issuerCid, officerLabel, caseId > 0 and caseId or nil, reason })
    end)
    if not ok or not warrantId then return nil end

    if caseId > 0 and Bridge.ResourceStarted('gtarp_evidence') then
        pcall(function()
            exports.gtarp_evidence:AppendEntry(caseId, 'warrant',
                { warrant_id = warrantId, citizenid = target, reason = reason, officer = officerLabel },
                'gtarp_mdt')
        end)
    end
    Bridge.NotifyPolice(('Warrant #%d'):format(warrantId),
        ('%s — %s'):format(citizenName, reason), 'inform')
    if Bridge.ResourceStarted('gtarp_discord') then
        pcall(function()
            exports.gtarp_discord:Announce('police', {
                title = ('Warrant #%d issued'):format(warrantId),
                description = ('%s — %s'):format(citizenName, reason),
                fields = { { name = 'Officer', value = officerLabel, inline = true } },
            })
        end)
    end
    return warrantId
end

-- /warrant <citizenid> <case#|0> <reason...>
local function cmdWarrant(src, args)
    local cid = gate(src, 'warrant')
    if not cid then return end
    local target = tostring(args[1] or '')
    local caseId = refCase(src, args[2])
    local reason = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    if target == '' or not caseId or #reason < Config.Warrants.ReasonMinChars then
        Bridge.Notify(src, 'MDT', 'Usage: /warrant [citizenid] [case# or 0] [reason]', 'error')
        return
    end
    if #reason > Config.Warrants.ReasonMaxChars then
        Bridge.Notify(src, 'MDT',
            ('Warrant reason caps at %d characters.'):format(Config.Warrants.ReasonMaxChars), 'error')
        return
    end

    local citizenName = Bridge.GetCitizenName(target)
    if not citizenName then
        Bridge.Notify(src, 'MDT', 'No citizen with that id on record.', 'error')
        return
    end
    local existing = activeWarrantsFor(target)
    if #existing > 0 then
        Bridge.Notify(src, 'MDT',
            ('Citizen already has active warrant #%d — /book serves it.'):format(existing[1].id), 'error')
        return
    end

    local warrantId = issueWarrant(target, citizenName, caseId, reason, cid, Bridge.GetPlayerName(src))
    if not warrantId then
        Bridge.Notify(src, 'MDT', 'Warrant system is down — nothing was issued.', 'error')
        return
    end
    dbg(('warrant #%d on %s by %s'):format(warrantId, target, cid))
end

-- /warrants — active list
local function cmdWarrants(src)
    if not gate(src, 'warrants') then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, citizenid, citizen_name, reason, case_id,
                   TIMESTAMPDIFF(HOUR, created_at, NOW()) AS age_h
            FROM gtarp_mdt_warrants WHERE status = 'active'
            ORDER BY id DESC LIMIT ?
        ]], { Config.Warrants.ListLimit }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no active warrants' })
        return
    end
    local lines = {}
    for _, w in ipairs(rows) do
        lines[#lines + 1] = ('#%d %s (%s) — %s [%dh old%s]'):format(
            w.id, w.citizen_name, w.citizenid, w.reason,
            tonumber(w.age_h) or 0,
            w.case_id and (', case ' .. w.case_id) or '')
    end
    lines[#lines + 1] = '/book [citizenid] [case# or 0] [charges] serves — /warrantclear [#] drops'
    Bridge.Reply(src, lines)
end

-- /warrantclear <id> — drop without an arrest
local function cmdWarrantClear(src, args)
    local cid = gate(src, 'warrantclear')
    if not cid then return end
    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'MDT', 'Usage: /warrantclear [warrant #]', 'error')
        return
    end
    local cleared = false
    pcall(function()
        cleared = MySQL.update.await(
            "UPDATE gtarp_mdt_warrants SET status = 'dropped', resolved_at = NOW(), resolved_by = ? WHERE id = ? AND status = 'active'",
            { cid, id }) == 1
    end)
    if cleared then
        Bridge.Notify(src, 'MDT', ('Warrant #%d dropped.'):format(id), 'success')
    else
        Bridge.Notify(src, 'MDT', 'No active warrant with that number.', 'error')
    end
end

-- /book <citizenid> <case#|0> <charges...> — arrest paperwork; auto-serves
-- the citizen's active warrants. The physical jailing stays qbx_police's.
local function cmdBook(src, args)
    local cid = gate(src, 'book')
    if not cid then return end
    local target = tostring(args[1] or '')
    local caseId = refCase(src, args[2])
    local charges = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    if target == '' or not caseId or #charges < Config.Warrants.ChargesMin then
        Bridge.Notify(src, 'MDT', 'Usage: /book [citizenid] [case# or 0] [charges]', 'error')
        return
    end
    if #charges > Config.Warrants.ChargesMax then
        Bridge.Notify(src, 'MDT',
            ('Charges text caps at %d characters.'):format(Config.Warrants.ChargesMax), 'error')
        return
    end

    local citizenName = Bridge.GetCitizenName(target)
    if not citizenName then
        Bridge.Notify(src, 'MDT', 'No citizen with that id on record.', 'error')
        return
    end

    local warrants = activeWarrantsFor(target)
    local officer = Bridge.GetPlayerName(src)
    local ok, bookingId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO gtarp_mdt_bookings (citizenid, citizen_name, booked_by, officer_name, case_id, warrant_id, charges)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]], { target, citizenName, cid, officer,
              caseId > 0 and caseId or nil,
              warrants[1] and warrants[1].id or nil, charges })
    end)
    if not ok or not bookingId then
        Bridge.Notify(src, 'MDT', 'Booking system is down — nothing was filed.', 'error')
        return
    end

    local served = 0
    for _, w in ipairs(warrants) do
        pcall(function()
            served = served + (tonumber(MySQL.update.await(
                "UPDATE gtarp_mdt_warrants SET status = 'served', resolved_at = NOW(), resolved_by = ? WHERE id = ? AND status = 'active'",
                { cid, w.id })) or 0)
        end)
    end

    if caseId > 0 and Bridge.ResourceStarted('gtarp_evidence') then
        pcall(function()
            exports.gtarp_evidence:AppendEntry(caseId, 'booking',
                { booking_id = bookingId, citizenid = target, charges = charges,
                  officer = officer, warrants_served = served }, 'gtarp_mdt')
        end)
    end

    local tSrc = Bridge.GetSourceByCitizenId(target)
    if tSrc then
        Bridge.Notify(tSrc, 'Booking', ('You were booked: %s'):format(charges), 'error')
    end
    if Bridge.ResourceStarted('gtarp_discord') then
        pcall(function()
            exports.gtarp_discord:Announce('police', {
                title = ('Booking #%d — %s'):format(bookingId, citizenName),
                description = charges,
                fields = {
                    { name = 'Officer', value = officer, inline = true },
                    { name = 'Warrants served', value = tostring(served), inline = true },
                },
            })
        end)
    end
    Bridge.Notify(src, 'MDT',
        ('Booking #%d filed on %s%s.'):format(bookingId, citizenName,
            served > 0 and (', %d warrant(s) served'):format(served) or ''), 'success')
    dbg(('booking #%d on %s by %s (%d warrants served)'):format(bookingId, target, cid, served))
end

-- ---------------------------------------------------------------------------
-- /mdtreport <caseId|0> <text...> — written paperwork; case-linked reports
-- also land in the evidence file via the frozen AppendEntry export
-- ---------------------------------------------------------------------------
local function cmdReport(src, args)
    local cid = gate(src, 'mdtreport')
    if not cid then return end
    local caseId = tonumber(args[1])
    if not caseId then
        Bridge.Notify(src, 'MDT', 'Usage: /mdtreport [case # or 0] [report text]', 'error')
        return
    end
    local body = table.concat(args, ' ', 2):gsub('^%s+', ''):gsub('%s+$', '')
    local minChars = tonumber(MDT.report_min_chars) or 20
    if #body < minChars then
        Bridge.Notify(src, 'MDT',
            ('Reports need at least %d characters — write it up properly.'):format(minChars), 'error')
        return
    end
    if #body > Config.ReportMaxChars then
        Bridge.Notify(src, 'MDT', ('Reports cap at %d characters.'):format(Config.ReportMaxChars), 'error')
        return
    end

    -- Case-linked reports must reference a real case.
    if caseId > 0 then
        local c
        pcall(function() c = exports.gtarp_evidence:GetCase(caseId) end)
        if type(c) ~= 'table' then
            Bridge.Notify(src, 'MDT', 'No case file with that number (use 0 for a standalone report).', 'error')
            return
        end
    end

    local officer = Bridge.GetPlayerName(src)
    local ok, reportId = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO gtarp_mdt_reports (citizenid, officer_name, case_id, body) VALUES (?, ?, ?, ?)',
            { cid, officer, caseId > 0 and caseId or nil, body })
    end)
    if not ok or not reportId then
        Bridge.Notify(src, 'MDT', 'Filing failed — the report was not saved.', 'error')
        return
    end

    if caseId > 0 and Bridge.ResourceStarted('gtarp_evidence') then
        pcall(function()
            exports.gtarp_evidence:AppendEntry(caseId, 'report',
                { report_id = reportId, officer = officer, body = body }, 'gtarp_mdt')
        end)
    end
    Bridge.Notify(src, 'MDT',
        caseId > 0 and ('Report #%d filed to case %d.'):format(reportId, caseId)
                   or ('Report #%d filed.'):format(reportId), 'success')
    dbg(('report #%d by %s (case %s)'):format(reportId, cid, tostring(caseId)))
end

-- ---------------------------------------------------------------------------
-- Dispatch call history (v0.3.0) — passive recorder on the recipe's
-- central alert funnel. Known coverage gap, documented in README: the
-- two producers that TriggerClientEvent the officer notify directly
-- (qbx_truckrobbery, one qbx_police command) never touch the server
-- funnel and are not recorded.
-- ---------------------------------------------------------------------------

local lastCallBySrc = {}   -- [src or 0] = ts, flood guard on the recorder

local function calls24h()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS n FROM gtarp_mdt_calls WHERE created_at >= NOW() - INTERVAL 24 HOUR')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function pruneCalls()
    pcall(function()
        MySQL.update.await(
            'DELETE FROM gtarp_mdt_calls WHERE created_at < NOW() - INTERVAL ? DAY',
            { Config.Calls.RetentionDays })
    end)
end

local function recordCall(text, src, coords)
    if not Config.Calls.Enabled then return end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return end
    if #text > Config.Calls.TextMax then text = text:sub(1, Config.Calls.TextMax) end

    local key = src or 0
    local t = now()
    if (lastCallBySrc[key] or 0) + Config.Calls.PerSourceCdSec > t then return end
    lastCallBySrc[key] = t

    local label = ''
    if src then
        local cid = Bridge.GetCitizenId(src)
        label = cid and ('citizen %s'):format(cid) or ''
    end
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO gtarp_mdt_calls (text, x, y, z, src_label) VALUES (?, ?, ?, ?, ?)',
            { text, coords and coords.x or nil, coords and coords.y or nil,
              coords and coords.z or nil, label })
    end)
    dbg(('call logged: %s'):format(text))
end

-- /calls [n] — recent 911 traffic
local function cmdCalls(src, args)
    if not gate(src, 'calls') then return end
    local n = math.min(math.max(math.floor(tonumber(args[1]) or Config.Calls.ListDefault), 1),
        Config.Calls.ListMax)
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, text, src_label,
                   TIMESTAMPDIFF(MINUTE, created_at, NOW()) AS age_m
            FROM gtarp_mdt_calls ORDER BY id DESC LIMIT ?
        ]], { n }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no calls on the log' })
        return
    end
    local lines = {}
    for _, c in ipairs(rows) do
        lines[#lines + 1] = ('#%d [%dm ago] %s%s'):format(
            c.id, tonumber(c.age_m) or 0, c.text,
            c.src_label ~= '' and (' — ' .. c.src_label) or '')
    end
    Bridge.Reply(src, lines)
end

CreateThread(function()
    while true do
        Wait(12 * 3600 * 1000)
        pruneCalls()
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    MDT = Bridge.GetMDTContract() or Config.MDTDefaults
    if MDT.enabled == false then
        print('[gtarp_mdt] disabled by the qbx_police_overrides MDT contract (enabled=false) — no commands registered')
        return
    end

    Bridge.RegisterCommand('mdt', function(source) cmdMdt(source) end)
    Bridge.RegisterCommand('bolo', function(source, args) cmdBolo(source, args) end)
    Bridge.RegisterCommand('bolos', function(source) cmdBolos(source) end)
    Bridge.RegisterCommand('boloclear', function(source, args) cmdBoloClear(source, args) end)
    Bridge.RegisterCommand('mdtcases', function(source) cmdCases(source) end)
    Bridge.RegisterCommand('mdtcase', function(source, args) cmdCase(source, args) end)
    Bridge.RegisterCommand('mdtreport', function(source, args) cmdReport(source, args) end)
    Bridge.RegisterCommand('warrant', function(source, args) cmdWarrant(source, args) end)
    Bridge.RegisterCommand('warrants', function(source) cmdWarrants(source) end)
    Bridge.RegisterCommand('warrantclear', function(source, args) cmdWarrantClear(source, args) end)
    Bridge.RegisterCommand('book', function(source, args) cmdBook(source, args) end)
    Bridge.RegisterCommand('calls', function(source, args) cmdCalls(source, args) end)

    if Config.Calls.Enabled then
        Bridge.OnPoliceAlert(recordCall)
        pruneCalls()
    end

    print(('[gtarp_mdt] desk online — %d active BOLO(s), %d active warrant(s), %d report(s), %d booking(s), %d call(s)/24h; contract %s, case system %s, call log %s')
        :format(activeBoloCount(), activeWarrantCount(), reportCount(), bookingCount(), calls24h(),
            Bridge.GetMDTContract() and 'qbx_police_overrides' or 'built-in defaults',
            Bridge.ResourceStarted('gtarp_evidence') and 'ONLINE' or 'offline',
            Config.Calls.Enabled and 'ON' or 'off'))
end)

-- ADDITIVE export — sibling systems (gtarp_citations' overdue escalation)
-- put warrants in the ledger without touching its tables. Same
-- never-change-signature rule as gtarp_evidence's exports.
--
-- IssueWarrant(citizenid: string, reason: string, officerLabel: string)
--   -> warrantId: number|nil
-- nil when: no such citizen, citizen already has an active warrant, or
-- reason out of bounds. No case linkage from this path (pass through
-- /warrant for that).
exports('IssueWarrant', function(citizenid, reason, officerLabel)
    citizenid = tostring(citizenid or '')
    reason = tostring(reason or '')
    officerLabel = tostring(officerLabel or 'System')
    if citizenid == '' or #reason < Config.Warrants.ReasonMinChars
        or #reason > Config.Warrants.ReasonMaxChars then
        return nil
    end
    local citizenName = Bridge.GetCitizenName(citizenid)
    if not citizenName then return nil end
    if #activeWarrantsFor(citizenid) > 0 then return nil end
    return issueWarrant(citizenid, citizenName, 0, reason, 'system', officerLabel)
end)

-- ADDITIVE exports for gtarp_legal (rap sheets + expungement). Sealed
-- bookings stay in the table (police desk stats count them) but leave
-- the rap-sheet surface. Same never-change-signature rule.

-- GetBookingsFor(citizenid) -> { {id, charges, officer_name, booked_at,
--   case_id}, ... } — unsealed only, newest first, capped at 25.
exports('GetBookingsFor', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return {} end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, charges, officer_name, booked_at, case_id
            FROM gtarp_mdt_bookings
            WHERE citizenid = ? AND sealed_at IS NULL
            ORDER BY id DESC LIMIT 25
        ]], { citizenid }) or {}
    end)
    for _, r in ipairs(rows) do r.booked_at = tostring(r.booked_at) end
    return rows
end)

-- HasActiveWarrant(citizenid) -> boolean
exports('HasActiveWarrant', function(citizenid)
    return #activeWarrantsFor(tostring(citizenid or '')) > 0
end)

-- GetBooking(bookingId) -> { id, citizenid, charges, booked_at,
--   age_hours, sealed } | nil
exports('GetBooking', function(bookingId)
    bookingId = tonumber(bookingId)
    if not bookingId then return nil end
    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT id, citizenid, charges, booked_at,
                   TIMESTAMPDIFF(HOUR, booked_at, NOW()) AS age_hours,
                   (sealed_at IS NOT NULL) AS sealed
            FROM gtarp_mdt_bookings WHERE id = ?
        ]], { bookingId })
    end)
    if not row then return nil end
    return {
        id = row.id,
        citizenid = row.citizenid,
        charges = row.charges,
        booked_at = tostring(row.booked_at),
        age_hours = tonumber(row.age_hours) or 0,
        sealed = (tonumber(row.sealed) or 0) == 1,
    }
end)

-- SealBooking(bookingId) -> boolean — marks a booking expunged. Only
-- gtarp_legal's granted petitions call this; idempotent-safe (sealing a
-- sealed row returns false).
exports('SealBooking', function(bookingId)
    bookingId = tonumber(bookingId)
    if not bookingId then return false end
    local sealed = false
    pcall(function()
        sealed = MySQL.update.await(
            'UPDATE gtarp_mdt_bookings SET sealed_at = NOW() WHERE id = ? AND sealed_at IS NULL',
            { bookingId }) == 1
    end)
    return sealed
end)

---Desk counts for devtest and future consumers.
exports('GetSummary', function()
    return {
        activeBolos = activeBoloCount(),
        reports = reportCount(),
        activeWarrants = activeWarrantCount(),
        bookings = bookingCount(),
        calls24h = calls24h(),
    }
end)
