-- ============================================================================
-- palm6_mdt/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The police Mobile Data Terminal: the in-game READER for the case files
-- the city's systems already produce (insurance fraud, witness canvasses,
-- counterfeit leads, pumpcoin rugs — all landing in palm6_evidence), plus
-- BOLO broadcasts and written reports. Every command is gated on-duty
-- police + carrying the mdt_tablet item, and every read/write happens
-- server-side — there is no client script at all.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts } per-source rate limits

-- Forward-declared: defined further down but called by cmdMdt/cmdCase above
-- their definitions. Declaring the locals here (before those callers) lets the
-- callers capture them as upvalues; the bare `function X` defs below assign
-- into these locals. Without this they resolved to nil globals and /mdt +
-- /mdtcase (on an identified suspect) errored on every call.
local activeWarrantCount, activeWarrantsFor, calls24h

-- Resolved GetMDT() contract (qbx_police_overrides when running, else
-- Config.MDTDefaults). Resolved once at boot — the override resource
-- starts before us in custom.cfg.
local MDT = nil

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_mdt] ' .. msg) end
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
            'SELECT COUNT(*) AS n FROM palm6_mdt_bolos WHERE resolved_at IS NULL AND expires_at > NOW()')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function reportCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_mdt_reports')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function openCases(limit)
    if not Bridge.ResourceStarted('palm6_evidence') then return nil end
    local rows
    pcall(function()
        rows = exports.palm6_evidence:ListCases('open', limit)
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
    -- Advertise the identification rung: without it an officer has no way to
    -- learn the citizenid every other command below wants. Each half is
    -- gated on its own Config flag so a command an operator switched off is
    -- never advertised here.
    local tools = {}
    if Config.Identify.Enabled then
        tools[#tools + 1] = ('identify who you are standing with: /%s'):format(Config.Identify.Command)
    end
    if Config.RunPlate.Enabled then
        tools[#tools + 1] = 'run a plate: /runplate [plate]'
    end
    if #tools > 0 then lines[#lines + 1] = table.concat(tools, '  -  ') end
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
            INSERT INTO palm6_mdt_bolos (citizenid, officer_name, body, expires_at)
            VALUES (?, ?, ?, NOW() + INTERVAL ? MINUTE)
        ]], { cid, officer, text, durMin })
    end)
    if not ok or not boloId then
        Bridge.Notify(src, 'MDT', 'BOLO system is down — nothing was issued.', 'error')
        return
    end

    Bridge.NotifyPolice('BOLO #' .. boloId, text, 'inform')
    if Bridge.ResourceStarted('palm6_discord') then
        pcall(function()
            exports.palm6_discord:Announce('police', {
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
            FROM palm6_mdt_bolos
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
            'UPDATE palm6_mdt_bolos SET resolved_at = NOW(), resolved_by = ? WHERE id = ? AND resolved_at IS NULL',
            { cid, id }) == 1
    end)
    if cleared then
        Bridge.Notify(src, 'MDT', ('BOLO #%d resolved.'):format(id), 'success')
    else
        Bridge.Notify(src, 'MDT', 'No active BOLO with that number.', 'error')
    end
end

-- ---------------------------------------------------------------------------
-- /mdtcases — open case files (palm6_evidence, read via exports only)
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
    if not Bridge.ResourceStarted('palm6_evidence') then
        Bridge.Reply(src, { 'case system offline' })
        return
    end
    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'MDT', 'Usage: /mdtcase [case #]', 'error')
        return
    end
    local c
    pcall(function() c = exports.palm6_evidence:GetCase(id) end)
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

function activeWarrantCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_mdt_warrants WHERE status = 'active'")
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function bookingCount()
    local n = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_mdt_bookings')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

function activeWarrantsFor(citizenid)
    local rows = {}
    pcall(function()
        rows = MySQL.query.await(
            "SELECT id, reason FROM palm6_mdt_warrants WHERE citizenid = ? AND status = 'active'",
            { citizenid }) or {}
    end)
    return rows
end

-- Staff audit sink. The whole police stack wrote to NO audit log - a booking
-- fired a Discord announce and a world-public cityfeed post naming a real
-- citizen with nothing an admin could later query. palm6_staff:Log is the
-- house sink four other resources already use (allowlist, devtest, eventguard,
-- onboarding); this is the police stack's first two entries.
--
-- Soft by house rule: never let a missing/broken audit sink fail a booking.
-- palm6_staff's log() is NOT internally pcall'd (its MySQL.insert.await can
-- throw), so the pcall here is load-bearing, not decorative.
local function auditLog(action, actorSrc, targetSrc, detail)
    if not Bridge.ResourceStarted('palm6_staff') then return end
    pcall(function()
        exports.palm6_staff:Log(action, actorSrc, targetSrc, detail)
    end)
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
        pcall(function() c = exports.palm6_evidence:GetCase(caseId) end)
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
            INSERT INTO palm6_mdt_warrants (citizenid, citizen_name, issued_by, officer_name, case_id, reason)
            VALUES (?, ?, ?, ?, ?, ?)
        ]], { target, citizenName, issuerCid, officerLabel, caseId > 0 and caseId or nil, reason })
    end)
    if not ok or not warrantId then return nil end

    if caseId > 0 and Bridge.ResourceStarted('palm6_evidence') then
        pcall(function()
            exports.palm6_evidence:AppendEntry(caseId, 'warrant',
                { warrant_id = warrantId, citizenid = target, reason = reason, officer = officerLabel },
                'palm6_mdt')
        end)
    end
    Bridge.NotifyPolice(('Warrant #%d'):format(warrantId),
        ('%s — %s'):format(citizenName, reason), 'inform')
    if Bridge.ResourceStarted('palm6_discord') then
        pcall(function()
            exports.palm6_discord:Announce('police', {
                title = ('Warrant #%d issued'):format(warrantId),
                description = ('%s — %s'):format(citizenName, reason),
                fields = { { name = 'Officer', value = officerLabel, inline = true } },
            })
        end)
    end
    return warrantId
end

-- ---------------------------------------------------------------------------
-- /id - who is this person? The rung the ladder was missing: every command
-- below wanted a citizenid, and an officer had no in-game way to learn one.
--
-- Server-authoritative by construction: the officer supplies NO argument, so
-- there is nothing to spoof. The server reads its own ped positions, picks the
-- nearest player inside Config.Identify.Radius, and replies to the officer
-- only. Police-gated by gate() (on duty + tablet) so this never becomes a
-- civilian doxx tool: the citizenid it prints is exactly what /warrant, /book
-- and /cite consume, and nobody outside the gate ever sees it.
-- ---------------------------------------------------------------------------
local function cmdId(src)
    if not gate(src, 'id') then return end
    local near = Bridge.NearestPlayer(src, Config.Identify.Radius)
    if not near or not near.citizenid then
        Bridge.Notify(src, 'MDT', 'Nobody close enough to identify - stand with them.', 'error')
        return
    end
    local lines = {
        ('%s - citizen %s'):format(near.name or 'Unknown citizen', near.citizenid),
    }
    local w = activeWarrantsFor(near.citizenid)
    if #w > 0 then
        lines[#lines + 1] = ('ACTIVE WARRANT #%d - %s'):format(w[1].id, w[1].reason)
        if #w > 1 then lines[#lines + 1] = ('… and %d more active warrant(s)'):format(#w - 1) end
    else
        lines[#lines + 1] = 'no active warrants'
    end
    -- All three take EITHER form now, so print the short server id an officer
    -- can realistically retype mid-scene. /warrant and /book resolve it in
    -- process via Bridge.ResolveTarget; /cite lives in palm6_citations and
    -- resolves it through this resource's ResolveTarget export. That export is
    -- started when this line prints, but NOT necessarily when the officer types
    -- the command seconds later, so palm6_citations soft-calls it and falls back
    -- to its own citizenid lookup ("No citizen with that id on record"). The
    -- citizenid is still on the first line above for anyone who wants to paste
    -- it instead.
    lines[#lines + 1] = ('/cite %d … | /warrant %d … | /book %d …'):format(
        near.src, near.src, near.src)
    Bridge.Reply(src, lines)
end

-- /warrant <citizenid|server id> <case#|0> <reason...>
local function cmdWarrant(src, args)
    local cid = gate(src, 'warrant')
    if not cid then return end
    local raw = tostring(args[1] or '')
    local caseId = refCase(src, args[2])
    local reason = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' or not caseId or #reason < Config.Warrants.ReasonMinChars then
        Bridge.Notify(src, 'MDT', 'Usage: /warrant [citizenid or server id] [case# or 0] [reason]', 'error')
        return
    end
    if #reason > Config.Warrants.ReasonMaxChars then
        Bridge.Notify(src, 'MDT',
            ('Warrant reason caps at %d characters.'):format(Config.Warrants.ReasonMaxChars), 'error')
        return
    end

    -- Accept EITHER a raw citizenid (unchanged, still works) or the online
    -- server id /id just printed. ResolveTarget only treats an all-digit
    -- argument as a server id when a live character actually sits on it, so a
    -- numeric citizenid still resolves as a citizenid.
    local target, citizenName = Bridge.ResolveTarget(raw)
    if not target or not citizenName then
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
    -- targetSrc is nil for an offline citizen - correct and expected here, a
    -- warrant is issued in absentia; the citizenid in `detail` is the durable
    -- link either way.
    auditLog('mdt_warrant', src, Bridge.GetSourceByCitizenId(target),
        ('warrant #%d on %s (%s), case %s: %s'):format(
            warrantId, citizenName, target, caseId > 0 and tostring(caseId) or 'none', reason))
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
            FROM palm6_mdt_warrants WHERE status = 'active'
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
            "UPDATE palm6_mdt_warrants SET status = 'dropped', resolved_at = NOW(), resolved_by = ? WHERE id = ? AND status = 'active'",
            { cid, id }) == 1
    end)
    if cleared then
        Bridge.Notify(src, 'MDT', ('Warrant #%d dropped.'):format(id), 'success')
    else
        Bridge.Notify(src, 'MDT', 'No active warrant with that number.', 'error')
    end
end

-- /book <citizenid|server id> <case#|0> <charges...> - arrest paperwork;
-- auto-serves the citizen's active warrants. Physical jailing stays
-- qbx_police's.
local function cmdBook(src, args)
    local cid = gate(src, 'book')
    if not cid then return end
    local raw = tostring(args[1] or '')
    local caseId = refCase(src, args[2])
    local charges = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' or not caseId or #charges < Config.Warrants.ChargesMin then
        Bridge.Notify(src, 'MDT', 'Usage: /book [citizenid or server id] [case# or 0] [charges]', 'error')
        return
    end
    if #charges > Config.Warrants.ChargesMax then
        Bridge.Notify(src, 'MDT',
            ('Charges text caps at %d characters.'):format(Config.Warrants.ChargesMax), 'error')
        return
    end

    -- Same cid-or-server-id resolution as /warrant (see the comment there).
    local target, citizenName = Bridge.ResolveTarget(raw)
    if not target or not citizenName then
        Bridge.Notify(src, 'MDT', 'No citizen with that id on record.', 'error')
        return
    end

    -- Presence gate (A24, SHIPS DARK - Config.Warrants.RequirePresence=false).
    -- Nothing in the booking path checked that the person being booked was
    -- anywhere near the officer, or even online, yet a booking fires a Discord
    -- announce and a world-public cityfeed post naming them. When flipped on,
    -- the citizen must be connected and within a generous desk-sized radius,
    -- both read server-side.
    -- Resolved ONCE and reused by both the presence gate below and the
    -- "you were booked" notify further down: GetSourceByCitizenId walks every
    -- connected player, and two walks for the same citizen in one command was
    -- pure duplication.
    local tSrc = Bridge.GetSourceByCitizenId(target)

    if Config.Warrants.RequirePresence then
        if not tSrc then
            Bridge.Notify(src, 'MDT', ('%s is not online - you cannot book them.'):format(citizenName), 'error')
            return
        end
        local d = Bridge.DistanceBetween(src, tSrc)
        if not d or d > Config.Warrants.PresenceRadius then
            Bridge.Notify(src, 'MDT',
                ('%s is not with you at the desk.'):format(citizenName), 'error')
            return
        end
    end

    -- Post-bail re-arrest grace (palm6_yard): someone who just posted bail can't
    -- be re-booked until their cooldown lapses — the designed anti-grief window
    -- so bail isn't pointless. Soft cross-read; no-op if palm6_yard is absent.
    if Bridge.ResourceStarted('palm6_yard') then
        local graceLeft = 0
        pcall(function() graceLeft = exports.palm6_yard:RearrestGraceLeft(target) or 0 end)
        if graceLeft > 0 then
            Bridge.Notify(src, 'MDT',
                ('%s just posted bail — re-arrest grace for ~%d more min; you cannot book them yet.'):format(
                    citizenName, math.ceil(graceLeft / 60)), 'error')
            return
        end
    end

    local warrants = activeWarrantsFor(target)
    local officer = Bridge.GetPlayerName(src)
    local ok, bookingId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_mdt_bookings (citizenid, citizen_name, booked_by, officer_name, case_id, warrant_id, charges)
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
                "UPDATE palm6_mdt_warrants SET status = 'served', resolved_at = NOW(), resolved_by = ? WHERE id = ? AND status = 'active'",
                { cid, w.id })) or 0)
        end)
    end

    if caseId > 0 and Bridge.ResourceStarted('palm6_evidence') then
        pcall(function()
            exports.palm6_evidence:AppendEntry(caseId, 'booking',
                { booking_id = bookingId, citizenid = target, charges = charges,
                  officer = officer, warrants_served = served }, 'palm6_mdt')
        end)
    end

    if tSrc then
        Bridge.Notify(tSrc, 'Booking', ('You were booked: %s'):format(charges), 'error')
    end
    if Bridge.ResourceStarted('palm6_discord') then
        pcall(function()
            exports.palm6_discord:Announce('police', {
                title = ('Booking #%d — %s'):format(bookingId, citizenName),
                description = charges,
                fields = {
                    { name = 'Officer', value = officer, inline = true },
                    { name = 'Warrants served', value = tostring(served), inline = true },
                },
            })
        end)
    end
    -- In-world civic bulletin (public facts only) via the palm6-bot feed. The
    -- bot narrates this into #pbpd-bulletin; complementary to the case-desk
    -- webhook above. Soft-dep: never breaks a booking if cityfeed is absent.
    if Bridge.ResourceStarted('palm6_cityfeed')
        and GetConvar('palm6:cityfeed_arrest', 'true') == 'true' then
        -- `charge` is operator free-text and reaches a WORLD-PUBLIC channel
        -- (#pbpd-bulletin). The bot's sanitizer is structural-only, so it will
        -- NOT strip a money figure typed into a value. Enforce the feed's own
        -- "never a take figure" invariant here by redacting $-amounts, and bound
        -- the length to the bot schema max (300) so a long charge list never
        -- silently 400-drops the whole civic post. The full charge stays intact
        -- in the booking record; only the public narration is scrubbed/capped.
        local publicCharge = (charges:gsub('%$%s*%d[%d,%.]*', '[amount]'))
        publicCharge = publicCharge:sub(1, 300)
        pcall(function()
            exports.palm6_cityfeed:Emit({
                type = 'arrest',
                case_ref = ('Booking #%d'):format(bookingId),
                charge = publicCharge,
                character_name = citizenName,
                agency = 'Palm6 Bay Police Department',
            })
        end)
    end
    auditLog('mdt_booking', src, tSrc,
        ('booking #%d on %s (%s), case %s, %d warrant(s) served: %s'):format(
            bookingId, citizenName, target, caseId > 0 and tostring(caseId) or 'none',
            served, charges))
    Bridge.Notify(src, 'MDT',
        ('Booking #%d filed on %s%s.'):format(bookingId, citizenName,
            served > 0 and (', %d warrant(s) served'):format(served) or ''), 'success')
    dbg(('booking #%d on %s by %s (%d warrants served)'):format(bookingId, target, cid, served))
end

-- ---------------------------------------------------------------------------
-- /runplate <plate> - the first police counterplay to the chop-shop loop.
-- palm6_chopshop keeps a real, persistent, queryable stolen-plate registry
-- that no officer could read; this is the read. Purely a lookup: it writes
-- nothing, takes nothing, and answers three questions an officer can act on -
-- is this plate reported stolen, who is it registered to, and does that owner
-- have warrants out.
--
-- Soft-dep on palm6_chopshop (GetResourceState + pcall, house idiom): with
-- the chop shop stopped the command still runs and simply says the registry
-- is offline rather than erroring.
-- ---------------------------------------------------------------------------
local function cmdRunPlate(src, args)
    if not gate(src, 'runplate') then return end
    local plate = tostring(args[1] or ''):upper():gsub('%s+', '')
    if plate == '' or #plate > Config.RunPlate.MaxLen then
        Bridge.Notify(src, 'MDT', 'Usage: /runplate [plate]', 'error')
        return
    end

    local lines = { ('plate %s'):format(plate) }

    local hot
    if Bridge.ResourceStarted('palm6_chopshop') then
        pcall(function() hot = exports.palm6_chopshop:IsStolen(plate) end)
        if type(hot) ~= 'table' then hot = nil end
    end
    if not hot then
        lines[#lines + 1] = 'stolen registry offline'
    elseif hot.stolen then
        lines[#lines + 1] = ('REPORTED STOLEN - since %s'):format(tostring(hot.since))
    else
        lines[#lines + 1] = 'no active stolen report'
    end

    -- Registered keeper, then that keeper's warrant status. An unregistered
    -- plate is the normal case for an NPC vehicle, so say so plainly.
    local owner = Bridge.GetPlateOwner(plate)
    if not owner then
        lines[#lines + 1] = 'not registered to any citizen'
    else
        lines[#lines + 1] = ('registered to %s (citizen %s)'):format(owner.name, owner.citizenid)
        local w = activeWarrantsFor(owner.citizenid)
        if #w > 0 then
            lines[#lines + 1] = ('owner has ACTIVE WARRANT #%d - %s'):format(w[1].id, w[1].reason)
        end
        -- When the registered keeper reported it stolen themselves, the keeper
        -- is the VICTIM, not the suspect. Say it out loud so nobody books the
        -- wrong person off a hot-plate hit.
        if hot and hot.stolen and hot.owner_citizenid == owner.citizenid then
            lines[#lines + 1] = 'the registered owner filed the theft report (victim, not suspect)'
        end
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- Charge catalogue (v0.4.0). SHIPS OFF (Config.Charges.Enabled=false).
--
-- /charges [class] prints the catalogue so an officer can learn the codes that
-- /sentence (palm6_legal) consumes. Read-only: it prints Config and touches
-- nothing else, so it cannot fail a booking or write a record.
-- ---------------------------------------------------------------------------
local function cmdCharges(src, args)
    if not gate(src, 'charges') then return end
    local want = tostring(args[1] or ''):lower():gsub('%s+', '')
    local lines = {}
    local shown = 0
    for _, class in ipairs(Config.Charges.ClassOrder) do
        if want == '' or want == class then
            local head = false
            for _, e in ipairs(Config.Charges.Catalogue) do
                if e.class == class then
                    if not head then
                        head = true
                        lines[#lines + 1] = ('--- %s ---'):format(class)
                    end
                    shown = shown + 1
                    lines[#lines + 1] = ('%-14s %s — %d %s, $%d'):format(
                        e.code, e.label, e.sentence, Config.Charges.SentenceUnit, e.fine)
                end
            end
        end
    end
    if shown == 0 then
        Bridge.Reply(src, {
            ('no charges in class %q'):format(want),
            ('classes: %s'):format(table.concat(Config.Charges.ClassOrder, ', ')),
        })
        return
    end
    -- Say plainly what these numbers are and are not. An officer reading a
    -- base sentence should not think it is what the suspect will serve.
    lines[#lines + 1] = 'these are BASE values; the recommendation applies concurrency and priors'
    -- The review command lives in palm6_legal, behind its OWN flag and its OWN
    -- configurable name. Hardcoding "/sentence" here advertised a command that
    -- does not exist whenever this catalogue is on and palm6_legal's sentencing
    -- is off, and drifted the moment an operator renamed it (which the configs
    -- themselves argue for: last RegisterCommand of a name wins on a ~157
    -- resource box). Ask the owning resource instead; soft, so a stopped
    -- palm6_legal, a palm6_legal with sentencing switched off (the export is
    -- registered only when the command is), or a broken call all degrade to one
    -- honest line rather than a lie.
    local reviewCmd
    if Bridge.ResourceStarted('palm6_legal') then
        pcall(function() reviewCmd = exports.palm6_legal:GetSentenceCommand() end)
    end
    if type(reviewCmd) == 'string' and reviewCmd ~= '' then
        lines[#lines + 1] = ('/%s [citizenid] [booking#] [code...] for a full recommendation and its arithmetic')
            :format(reviewCmd)
    else
        lines[#lines + 1] = 'the sentencing review command is not available on this box'
    end
    Bridge.Reply(src, lines)
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
        pcall(function() c = exports.palm6_evidence:GetCase(caseId) end)
        if type(c) ~= 'table' then
            Bridge.Notify(src, 'MDT', 'No case file with that number (use 0 for a standalone report).', 'error')
            return
        end
    end

    local officer = Bridge.GetPlayerName(src)
    local ok, reportId = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO palm6_mdt_reports (citizenid, officer_name, case_id, body) VALUES (?, ?, ?, ?)',
            { cid, officer, caseId > 0 and caseId or nil, body })
    end)
    if not ok or not reportId then
        Bridge.Notify(src, 'MDT', 'Filing failed — the report was not saved.', 'error')
        return
    end

    if caseId > 0 and Bridge.ResourceStarted('palm6_evidence') then
        pcall(function()
            exports.palm6_evidence:AppendEntry(caseId, 'report',
                { report_id = reportId, officer = officer, body = body }, 'palm6_mdt')
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

function calls24h()
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS n FROM palm6_mdt_calls WHERE created_at >= NOW() - INTERVAL 24 HOUR')
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function pruneCalls()
    pcall(function()
        MySQL.update.await(
            'DELETE FROM palm6_mdt_calls WHERE created_at < NOW() - INTERVAL ? DAY',
            { Config.Calls.RetentionDays })
    end)
end

-- Insert one row into the 911 log. Shared by the alert-funnel recorder
-- and the LogCall export (palm6_tips). Returns true on insert.
local function insertCall(text, coords, label)
    text = tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return false end
    if #text > Config.Calls.TextMax then text = text:sub(1, Config.Calls.TextMax) end
    -- src_label is VARCHAR(64). Clamp rather than let a long label throw under
    -- strict SQL mode, which the pcall below would swallow into a lost row.
    label = tostring(label or '')
    if #label > 64 then label = label:sub(1, 64) end
    local ok = false
    pcall(function()
        ok = MySQL.insert.await(
            'INSERT INTO palm6_mdt_calls (text, x, y, z, src_label) VALUES (?, ?, ?, ?, ?)',
            { text, coords and coords.x or nil, coords and coords.y or nil,
              coords and coords.z or nil, label }) ~= nil
    end)
    if ok then dbg(('call logged: %s'):format(text)) end
    return ok
end

-- Throttle for the dropped-alert console line: one print per window, so a
-- flood costs one line, not thousands, while a LEGITIMATE client-side producer
-- on the live box still shows up in the console within a minute of firing.
local lastProvenanceWarn = 0

local function recordCall(text, src, coords, serverRaised)
    if not Config.Calls.Enabled then return end

    -- A3: provenance. Notify is the recipe's business (separate handler,
    -- untouched); PERSISTING is ours. The DEFAULT behaviour is to keep the row
    -- and stamp it (see the label block below) because the qbx robbery
    -- producers raise this event client-side by design and dropping them would
    -- gut the 911 log. RequireServerProvenance is the opt-in hard drop for
    -- operators who would rather have no row than an unverified one; it bails
    -- before the cooldown bookkeeping so a client flood cannot burn a slot a
    -- real producer might want.
    if Config.Calls.RequireServerProvenance and not serverRaised then
        local t = now()
        if lastProvenanceWarn + 60 <= t then
            lastProvenanceWarn = t
            print(('^3[palm6_mdt] client-raised policeAlert NOT persisted (Config.Calls.RequireServerProvenance) - src=%s text=%q. If a real producer raises this client-side, flip that flag.^0')
                :format(tostring(src or '?'), tostring(text or ''):sub(1, 80)))
        end
        return
    end

    local key = src or 0
    local t = now()
    if (lastCallBySrc[key] or 0) + Config.Calls.PerSourceCdSec > t then return end
    lastCallBySrc[key] = t

    -- src_label is the row's provenance stamp, not just an attribution. A
    -- client-raised alert is marked `unverified` so an officer reading /calls
    -- can tell a dispatch a trusted server-side producer vouched for from one
    -- that arrived across the net boundary and could have been fabricated.
    -- Column is VARCHAR(64); the longest form here is well inside that.
    local label = ''
    if src then
        local cid = Bridge.GetCitizenId(src)
        label = cid and ('citizen %s'):format(cid) or ''
    end
    if not serverRaised then
        label = label ~= '' and (label .. ' (unverified)') or 'unverified'
    end
    insertCall(text, coords, label)
end

-- ---------------------------------------------------------------------------
-- Heat-aware dispatch priority (v0.5.0). See Config.CallPriority for the whole
-- rationale, including why this is derived at READ time and writes nothing.
--
-- Everything below is inert with Config.CallPriority.Enabled = false: the only
-- entry point is callPriorityFlags(), which returns nil on the first line, and
-- a nil flag set makes cmdCalls emit the exact bytes v0.4.0 emitted.
-- ---------------------------------------------------------------------------

-- [citizenid] = { tier = string, exp = ts }. Bounded by heatTierCacheCap.
local heatTierCache = {}
local heatTierCacheN = 0
local heatTierCacheCap = 256

-- Current palm6_heat tier for a citizen, or nil when the heat layer cannot
-- answer. Callers must have confirmed palm6_heat is started first.
--
-- GetTier is one indexed single-row read per citizen inside palm6_heat, so the
-- TTL cache is here to keep a spammed /calls from turning into a burst of
-- round trips. The cache is cleared wholesale when it reaches its cap rather
-- than evicted entry by entry: entries are tiny, expire on their own, and a
-- city never holds enough distinct 911 callers in one retention window for the
-- difference to matter.
local function heatTier(cid)
    local ttl = math.max(tonumber(Config.CallPriority.TierCacheSec) or 0, 0)
    local t = now()
    -- ttl 0 means "no cache" on BOTH ends, read as well as write, so the config
    -- comment stays exactly true even for an operator who changes the value on
    -- a running server rather than at boot.
    local hit = ttl > 0 and heatTierCache[cid] or nil
    if hit and hit.exp > t then return hit.tier end

    local tier
    -- Soft cross-resource read, house shape: the resource-state check is the
    -- caller's, the pcall is here. A throwing or half-booted palm6_heat leaves
    -- tier nil and the call is simply not priority.
    pcall(function() tier = exports.palm6_heat:GetTier(cid) end)
    if type(tier) ~= 'string' or tier == '' then return nil end

    if ttl > 0 then
        if heatTierCacheN >= heatTierCacheCap then
            heatTierCache, heatTierCacheN = {}, 0
        end
        if heatTierCache[cid] == nil then heatTierCacheN = heatTierCacheN + 1 end
        heatTierCache[cid] = { tier = tier, exp = t + ttl }
    end
    return tier
end

-- The citizen a 911 row is attributed to, or nil.
--
-- src_label is the only column that carries one. recordCall above builds it as
-- ('citizen %s'):format(cid) and may append ' (unverified)', so the citizenid
-- is the first whitespace-free token after the `citizen ` prefix. If that
-- recorder format ever changes, this pattern must change with it. Every other
-- label written to this table (palm6_tips' 'anonymous', palm6_brain's bus
-- label, the empty label a server-raised alert with no player gets) names no
-- citizen and correctly yields nil.
local function callCitizenId(label)
    if type(label) ~= 'string' then return nil end
    local cid = label:match('^citizen (%S+)')
    if cid == nil or cid == '' then return nil end
    return cid
end

-- Which of these 911 rows came from a citizen the heat layer rates as priority
-- RIGHT NOW. Returns a { [callId] = true } set, or nil when the feature is off,
-- palm6_heat is not started, or no row qualifies. nil is the "behave exactly as
-- before" answer and is the common case.
local function callPriorityFlags(rows)
    local cfg = Config.CallPriority
    if not (cfg and cfg.Enabled) then return nil end
    if type(cfg.Tiers) ~= 'table' then return nil end
    if not Bridge.ResourceStarted('palm6_heat') then return nil end

    local maxLookups = math.max(math.floor(tonumber(cfg.MaxLookups) or 0), 0)
    local seen, lookups, set = {}, 0, nil
    for _, c in ipairs(rows) do
        local cid = callCitizenId(c.src_label)
        if cid then
            -- false is a cached miss; nil means not looked up yet. One lookup
            -- per distinct citizen per invocation, whatever the TTL cache does.
            local tier = seen[cid]
            if tier == nil then
                if lookups >= maxLookups then break end
                lookups = lookups + 1
                tier = heatTier(cid) or false
                seen[cid] = tier
            end
            if tier and cfg.Tiers[tier] then
                set = set or {}
                set[c.id] = true
            end
        end
    end
    return set
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
            FROM palm6_mdt_calls ORDER BY id DESC LIMIT ?
        ]], { n }) or {}
    end)
    if #rows == 0 then
        Bridge.Reply(src, { 'no calls on the log' })
        return
    end

    -- nil whenever the feature is off or the heat layer is not answering, which
    -- makes every branch below collapse to the v0.4.0 code path.
    local priority = callPriorityFlags(rows)

    -- Priority rows float to the top of the same fetched set. Built by
    -- partitioning rather than table.sort: sort is not stable in Lua, and the
    -- newest-first order inside each group is the whole value of the listing.
    local ordered = rows
    if priority and Config.CallPriority.SortFirst then
        local hot, rest = {}, {}
        for _, c in ipairs(rows) do
            local dst = priority[c.id] and hot or rest
            dst[#dst + 1] = c
        end
        for _, c in ipairs(rest) do hot[#hot + 1] = c end
        ordered = hot
    end

    local lines = {}
    for _, c in ipairs(ordered) do
        -- Format string untouched from v0.4.0. The marker is prepended after
        -- the fact so that with no priority rows the emitted bytes are
        -- identical, not merely equivalent.
        local line = ('#%d [%dm ago] %s%s'):format(
            c.id, tonumber(c.age_m) or 0, c.text,
            c.src_label ~= '' and (' — ' .. c.src_label) or '')
        if priority and priority[c.id] then
            local mark = tostring(Config.CallPriority.Marker or '')
            if mark ~= '' then line = mark .. ' ' .. line end
        end
        lines[#lines + 1] = line
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
-- Boot DDL (self-creating tables). Same pattern as palm6_ems/server/main.lua
-- :67-105: Wait(3000) for oxmysql, per-statement pcall, CREATE TABLE IF NOT
-- EXISTS. sql/ files are applied BY HAND (deploy/README.md; CI never touches
-- the DB), so a fresh box that missed one left every query here pcall-swallowed
-- into silence - /mdt reporting zeros instead of "schema MISSING". Re-runs are
-- harmless no-ops on the live box, which already has these tables.
--
-- Every statement below is copied VERBATIM from the matching sql/ file so the
-- two can never diverge:
--   palm6_mdt_bolos, palm6_mdt_reports        <- sql/0022_mdt.sql
--   palm6_mdt_warrants, palm6_mdt_bookings    <- sql/0023_warrants.sql
--   palm6_mdt_calls                           <- sql/0025_calls.sql
-- and one BEST-EFFORT statement, run separately below:
--   ALTER bookings ADD sealed_at              <- sql/0026_legal.sql
-- The ALTER belongs to palm6_legal's migration but targets a table THIS
-- resource owns, and palm6_legal has no self-create of its own; without it a
-- fresh box would create bookings with no sealed_at and both GetBookingsFor
-- and SealBooking would fail forever.
--
-- It is deliberately kept OUT of the schemaOk signal. ADD COLUMN IF NOT EXISTS
-- is MariaDB syntax (exactly as 0026's own header argues); MySQL 8 has no such
-- form and THROWS on it, even on a box where all five tables exist and sealed_at
-- was already applied by hand from sql/0026_legal.sql. Folding that throw into
-- schemaOk made the boot banner report `schema MISSING` forever on MySQL, which
-- is the opposite of the signal the banner was added to give. The five CREATEs
-- are the tables this resource owns and are what schemaOk answers for; the ALTER
-- warns on its own line and is left to the operator.
-- ---------------------------------------------------------------------------
local schemaOk = true

local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_bolos` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    body VARCHAR(160) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    resolved_by VARCHAR(64) DEFAULT NULL,
    INDEX idx_palm6_mdt_bolos_active (resolved_at, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_reports` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    body TEXT NOT NULL,
    filed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_mdt_reports_cid (citizenid),
    INDEX idx_palm6_mdt_reports_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_warrants` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    citizen_name VARCHAR(100) NOT NULL DEFAULT '',
    issued_by VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    reason VARCHAR(200) NOT NULL,
    status ENUM('active','served','dropped') NOT NULL DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    resolved_by VARCHAR(64) DEFAULT NULL,
    INDEX idx_palm6_mdt_warrants_citizen (citizenid, status),
    INDEX idx_palm6_mdt_warrants_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_bookings` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    citizen_name VARCHAR(100) NOT NULL DEFAULT '',
    booked_by VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    warrant_id INT UNSIGNED DEFAULT NULL,
    charges TEXT NOT NULL,
    booked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_mdt_bookings_citizen (citizenid),
    INDEX idx_palm6_mdt_bookings_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_calls` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    text VARCHAR(160) NOT NULL,
    x DOUBLE DEFAULT NULL,
    y DOUBLE DEFAULT NULL,
    z DOUBLE DEFAULT NULL,
    src_label VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_mdt_calls_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_mdt_unit_positions` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    callsign VARCHAR(32) NOT NULL DEFAULT '',
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_palm6_mdt_unit_positions_updated (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            schemaOk = false
            print(('^1[palm6_mdt] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end

    -- Best effort, NOT part of schemaOk (see the header note): MariaDB-only
    -- syntax that throws on MySQL 8 whether or not the column is already there.
    local okAlter, errAlter = pcall(function()
        MySQL.query.await([[
ALTER TABLE `palm6_mdt_bookings`
    ADD COLUMN IF NOT EXISTS sealed_at TIMESTAMP NULL DEFAULT NULL;
        ]])
    end)
    if not okAlter then
        print(('^3[palm6_mdt] bookings.sealed_at self-heal skipped (MariaDB-only ADD COLUMN IF NOT EXISTS) -> %s. Apply sql/0026_legal.sql by hand if palm6_legal sealing misbehaves.^0')
            :format(tostring(errAlter)))
    end

    -- Custody status for web /ops booking board (W2 Cylex-parity). Best-effort.
    pcall(function()
        MySQL.query.await([[
ALTER TABLE `palm6_mdt_bookings`
    ADD COLUMN IF NOT EXISTS custody_status ENUM('intake','housed','released','transferred') NOT NULL DEFAULT 'housed';
        ]])
    end)
    pcall(function()
        MySQL.query.await([[
ALTER TABLE `palm6_mdt_bookings`
    ADD COLUMN IF NOT EXISTS released_at TIMESTAMP NULL DEFAULT NULL;
        ]])
    end)
end

-- Live map heartbeats from client/positions.lua (W5). Duty-gated; fail-soft.
RegisterNetEvent('palm6_mdt:unitHeartbeat', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local heading = tonumber(payload.heading) or 0
    if not x or not y or not z then return end
    if not Bridge.IsOnDutyPolice(src) then return end
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then return end
    local name = Bridge.GetPlayerName(src) or ''
    pcall(function()
        MySQL.insert.await([[
INSERT INTO palm6_mdt_unit_positions (citizenid, callsign, officer_name, x, y, z, heading)
VALUES (?, '', ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
  officer_name = VALUES(officer_name),
  x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading),
  updated_at = CURRENT_TIMESTAMP
        ]], { citizenid, name, x, y, z, heading })
    end)
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
-- onResourceStart can fire more than once for this resource's own name in
-- some boot sequences (same failure mode documented and fixed in
-- palm6_eventguard: guards/handlers silently double-registering). Command
-- and net-event registration are not safe to run twice in the same VM —
-- Bridge.OnPoliceAlert binds a fresh RegisterNetEvent handler every call, so
-- a double-fire would double-process every future 911 alert — so make the
-- whole boot block idempotent regardless of how many times the event fires.
local startupDone = false

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if startupDone then return end
    startupDone = true

    MDT = Bridge.GetMDTContract() or Config.MDTDefaults
    if MDT.enabled == false then
        print('[palm6_mdt] disabled by the qbx_police_overrides MDT contract (enabled=false) — no commands registered')
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
    -- Gated like /runplate below. See Config.Identify.Enabled for why a name
    -- as common as `id` needs an off switch on a 157-resource box.
    if Config.Identify.Enabled then
        Bridge.RegisterCommand(Config.Identify.Command, function(source) cmdId(source) end)
    end
    if Config.RunPlate.Enabled then
        Bridge.RegisterCommand('runplate', function(source, args) cmdRunPlate(source, args) end)
    end
    -- Charge catalogue reader. Registered only when the catalogue is switched
    -- on, so with the flag off the command name is not claimed at all.
    if Config.Charges.Enabled then
        Bridge.RegisterCommand(Config.Charges.Command, function(source, args) cmdCharges(source, args) end)
    end

    -- Net-event registration is a pure native and must NOT sit behind the
    -- oxmysql-connect wait, or a `restart palm6_mdt` would miss every alert
    -- raised in that ~3s window (the same reasoning palm6_ems documents at
    -- :422-427 for its command registration).
    if Config.Calls.Enabled then
        Bridge.OnPoliceAlert(recordCall)
    end

    -- Schema + the counts that read it move into a thread so the DDL lands
    -- before anything SELECTs. Everything above stays synchronous.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        if Config.Calls.Enabled then pruneCalls() end

        -- `call priority` is a BOOT-TIME snapshot of the heat soft-dep, not a
        -- promise about later: palm6_heat can stop or restart after this line
        -- prints, and /calls re-checks GetResourceState on every invocation.
        -- It is here so an operator who flips the flag can see at a glance
        -- whether the resource it reads was even up when the desk came online.
        print(('[palm6_mdt] desk online - %d active BOLO(s), %d active warrant(s), %d report(s), %d booking(s), %d call(s)/24h; contract %s, case system %s, call log %s, call priority %s, charge catalogue %s, schema %s')
            :format(activeBoloCount(), activeWarrantCount(), reportCount(), bookingCount(), calls24h(),
                Bridge.GetMDTContract() and 'qbx_police_overrides' or 'built-in defaults',
                Bridge.ResourceStarted('palm6_evidence') and 'ONLINE' or 'offline',
                Config.Calls.Enabled and 'ON' or 'off',
                Config.CallPriority.Enabled
                    and ('ON (palm6_heat %s at boot)'):format(
                        Bridge.ResourceStarted('palm6_heat') and 'started' or 'NOT started')
                    or 'off',
                Config.Charges.Enabled and ('ON (%d codes)'):format(#Config.Charges.Catalogue) or 'off',
                schemaOk and 'OK' or '^1MISSING^0'))

        -- Sentencing reads `sealed_at`, which is NOT in the inline CREATE above
        -- and arrives only via sql/0026_legal.sql's `ADD COLUMN IF NOT EXISTS`.
        -- That is MariaDB-only syntax, so on MySQL 8 the migration throws and,
        -- since sql/ is applied by hand, an operator can easily end up with the
        -- flag on and the column absent. Every sentencing query then fails and
        -- the command answers "no recommendation available" forever, with no
        -- clue why. One probe at boot, only when the flag is on, turns a silent
        -- dead feature into one line in the console.
        if Config.Charges.Enabled then
            local ok = pcall(function()
                MySQL.single.await('SELECT sealed_at FROM palm6_mdt_bookings LIMIT 1')
            end)
            if not ok then
                print('^1[palm6_mdt] charge catalogue is ON but palm6_mdt_bookings has no sealed_at column - apply sql/0026_legal.sql by hand (its ADD COLUMN IF NOT EXISTS is MariaDB-only). Sentencing recommendations will find nothing until you do.^0')
            end
        end
    end)
end)

-- ADDITIVE export — sibling systems (palm6_citations' overdue escalation)
-- put warrants in the ledger without touching its tables. Same
-- never-change-signature rule as palm6_evidence's exports.
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

-- ADDITIVE exports for palm6_legal (rap sheets + expungement). Sealed
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
            FROM palm6_mdt_bookings
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
            FROM palm6_mdt_bookings WHERE id = ?
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
-- palm6_legal's granted petitions call this; idempotent-safe (sealing a
-- sealed row returns false).
exports('SealBooking', function(bookingId)
    bookingId = tonumber(bookingId)
    if not bookingId then return false end
    local sealed = false
    pcall(function()
        sealed = MySQL.update.await(
            'UPDATE palm6_mdt_bookings SET sealed_at = NOW() WHERE id = ? AND sealed_at IS NULL',
            { bookingId }) == 1
    end)
    return sealed
end)

-- ADDITIVE export — sibling systems (palm6_tips) put entries on the 911
-- log without touching its table. Caller owns its own flood control;
-- text is bounded here. Same never-change-signature rule.
-- LogCall(text: string, coords: {x,y,z}|nil, label: string) -> boolean
exports('LogCall', function(text, coords, label)
    if not Config.Calls.Enabled then return false end
    if type(coords) ~= 'table' or type(coords.x) ~= 'number' then coords = nil end
    return insertCall(text, coords, label)
end)

-- ADDITIVE export — police commands that live in OTHER resources (/cite in
-- palm6_citations, /casesuspect in palm6_evidence) accept the same
-- "citizenid or online server id" argument /warrant and /book take, without
-- each one re-deriving the framework lookups and drifting from this one.
-- Same never-change-signature rule as the exports above.
--
-- ResolveTarget(arg: string|number)
--   -> { citizenid = string, name = string } | nil
-- nil when the argument is neither an online player's server id nor a
-- citizenid on record. A table rather than two return values so the result
-- survives the export boundary unambiguously.
--
-- Read-only, and it gates NOTHING: it answers "who is this" for anyone who
-- asks, so every caller must run its own police/duty gate first.
exports('ResolveTarget', function(arg)
    local citizenid, name = Bridge.ResolveTarget(arg)
    if not citizenid then return nil end
    return { citizenid = citizenid, name = name }
end)

-- ---------------------------------------------------------------------------
-- Sentencing exports (v0.4.0). ALL of these return nil while
-- Config.Charges.Enabled is false, so a consumer that ships before the flag is
-- flipped degrades to "sentencing is switched off" rather than half-working.
--
-- Read-only, every one of them: they SELECT, they compute, they return. None
-- writes a row, moves money, or jails anybody — this repo cannot jail anybody
-- (see the qbx_police handoff note in README.md). Same never-change-signature
-- rule as the exports above.
-- ---------------------------------------------------------------------------

-- Prior UNSEALED bookings for a citizen, counted STRICTLY BEFORE `beforeId`.
-- Two deliberate choices:
--   * `id < beforeId` — the arrest being sentenced is not its own prior.
--   * `sealed_at IS NULL` — an expunged booking stops counting, which is what
--     makes palm6_legal's expungement petitions mean something mechanically.
-- Ids are auto-increment so `id <` is a stable stand-in for "filed earlier"
-- and, unlike a timestamp compare, cannot tie.
--
-- Returns nil, NOT 0, when the query fails. The two are completely different
-- claims and only one of them is safe to print: 0 means "verified first
-- offence" and goes into a breakdown sold as reproducible on paper. The
-- `sealed_at` column arrives only via sql/0026_legal.sql's ADD COLUMN IF NOT
-- EXISTS, which is MariaDB-only syntax (the same hazard this file documents at
-- the schema notes below), so on a MySQL 8 box that nobody patched by hand this
-- query throws every single time. Swallowing that into 0 would tell every
-- citizen on the server, in writing, that they have a clean record. The caller
-- refuses to compute instead.
local function priorsFor(citizenid, beforeId)
    local n
    local ok = pcall(function()
        local r = MySQL.single.await([[
            SELECT COUNT(*) AS n FROM palm6_mdt_bookings
            WHERE citizenid = ? AND sealed_at IS NULL AND id < ?
        ]], { citizenid, beforeId })
        n = r and tonumber(r.n) or nil
    end)
    if not ok then return nil end
    return n
end

-- GetChargeCatalogue() -> { {code,label,class,sentence,fine}, ... } | nil
-- A COPY. Handing out the live Config table across an export boundary would
-- let any consumer mutate this resource's config in place.
exports('GetChargeCatalogue', function()
    if not Config.Charges.Enabled then return nil end
    local out = {}
    for _, e in ipairs(Config.Charges.Catalogue) do
        out[#out + 1] = {
            code = e.code, label = e.label, class = e.class,
            sentence = e.sentence, fine = e.fine,
        }
    end
    return out
end)

-- CalculateSentence(codes: string[], priors: number) -> result | nil
-- The raw calculator, for a caller that already knows the priors count.
-- See shared/sentencing.lua for the result shape and the arithmetic.
exports('CalculateSentence', function(codes, priors)
    if not Config.Charges.Enabled then return nil end
    return Sentencing.Calculate(codes, priors)
end)

-- RecommendForBooking(bookingId: number, codes: string[]|nil, opts: table|nil)
--   -> table | nil
-- The whole review in one call: resolve the booking, derive priors from this
-- resource's own bookings table, and calculate.
--
-- SEALED BOOKINGS ARE INVISIBLE HERE. A sealed row is an EXPUNGED row: the
-- player paid the court fee and won the petition, and every other read surface
-- in this stack already drops it (GetBookingsFor above filters `sealed_at IS
-- NULL`, palm6_rapsheet does the same, palm6_legal's /expunge refuses one).
-- Returning the citizenid, the name and the original charge text from here
-- would have handed the whole sealed record back to any on-duty officer who
-- typed the booking number, which makes expungement cosmetic. `opts.allowSealed`
-- exists ONLY for the console/ace audit path in palm6_legal; without it a sealed
-- booking is indistinguishable from a booking that never existed, which is the
-- point (an "it exists but you may not see it" answer is still a disclosure).
--
-- INFERENCE NO LONGER PRODUCES A NUMBER. When `codes` is empty the booking's
-- free text is still scanned (Sentencing.CodesInText, strictly literal), but the
-- hits come back as `suggested` and the result is a refusal. The scan cannot
-- see any compound code, and on the shipped catalogue the compound codes are
-- the severe ones, so a number derived from it is biased low by construction:
-- "assault on a peace officer during a bank robbery" scans to `assault` alone,
-- 8 months and $3000 instead of 55 months and $35,000. A confident, itemised,
-- systematically-too-lenient recommendation is worse than no recommendation.
-- Free-text charges are never rewritten or replaced.
--
-- nil when: sentencing is off, no such booking, or the booking is sealed and
-- the caller did not pass opts.allowSealed. `.ok` is false when no code was
-- given, when nothing resolved to a real charge code, or when the prior-record
-- lookup failed (see priorsFor: it refuses rather than guessing zero).
exports('RecommendForBooking', function(bookingId, codes, opts)
    if not Config.Charges.Enabled then return nil end
    bookingId = tonumber(bookingId)
    if not bookingId then return nil end
    local allowSealed = type(opts) == 'table' and opts.allowSealed == true

    local row
    pcall(function()
        row = MySQL.single.await([[
            SELECT id, citizenid, citizen_name, charges, case_id,
                   (sealed_at IS NOT NULL) AS sealed
            FROM palm6_mdt_bookings WHERE id = ?
        ]], { bookingId })
    end)
    if not row then return nil end

    local sealed = (tonumber(row.sealed) or 0) == 1
    if sealed and not allowSealed then return nil end

    local given = {}
    for _, c in ipairs(type(codes) == 'table' and codes or {}) do
        local k = tostring(c or ''):lower():gsub('%s+', '')
        if k ~= '' then given[#given + 1] = k end
    end

    -- Suggestions only, and only when the caller gave nothing to work with.
    -- `unmatchable` ships alongside them so the caller can name the codes the
    -- scan structurally cannot find. It is derived from the live catalogue
    -- rather than hardcoded, so renaming a charge cannot make the warning lie.
    local suggested, unmatchable = {}, {}
    if #given == 0 then
        suggested = Sentencing.CodesInText(row.charges)
        unmatchable = Sentencing.CompoundCodes()
    end

    local base = {
        bookingId    = tonumber(row.id),
        citizenid    = row.citizenid,
        citizenName  = row.citizen_name,
        charges      = row.charges,
        caseId       = row.case_id and tonumber(row.case_id) or nil,
        sealed       = sealed,
        codes        = given,
        suggested    = suggested,
        unmatchable  = unmatchable,
        priors       = nil,
    }

    if #given == 0 then
        base.result = Sentencing.Failure('no charge codes given')
        return base
    end

    local priors = priorsFor(row.citizenid, bookingId)
    if priors == nil then
        base.result = Sentencing.Failure('prior-record lookup failed - refusing to compute')
        return base
    end

    base.priors = priors
    base.result = Sentencing.Calculate(given, priors)
    return base
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
