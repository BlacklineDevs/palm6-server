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
        lines[#lines + 1] = s.citizenid
            and ('suspect: citizen %s'):format(s.citizenid)
            or ('suspect (unidentified): %s'):format(tostring(s.descriptor))
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

    print(('[gtarp_mdt] desk online — %d active BOLO(s), %d report(s) on file; contract %s, case system %s')
        :format(activeBoloCount(), reportCount(),
            Bridge.GetMDTContract() and 'qbx_police_overrides' or 'built-in defaults',
            Bridge.ResourceStarted('gtarp_evidence') and 'ONLINE' or 'offline'))
end)

---BOLO/report counts for devtest and future consumers.
exports('GetSummary', function()
    return { activeBolos = activeBoloCount(), reports = reportCount() }
end)
