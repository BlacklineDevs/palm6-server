-- ============================================================================
-- palm6_evidence/server/main.lua
--
-- Police evidence log + locker (v1) + case files, suspect linkage, and the
-- frozen export API for sibling resources (v2).
--
-- Pure logic — all framework/native access via Bridge.* (§6 gate). Our own
-- `palm6_evidence*` SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
--
-- Backward compatibility contract (do not break):
--   * `/logevidence` and the bare `/evidence` behave exactly as v1.
--   * The v1 `palm6_evidence` insert shape (citizenid, officer_name,
--     description[, coords]) still works — palm6_pumpcoin's rug-reveal
--     fraud entry writes that raw INSERT and must keep working. All v2
--     columns (case_id / kind / source) are nullable or defaulted
--     (sql/0018_evidence_v2.sql).
--   * Uncased entries (case_id NULL) are legal forever.
--
-- Frozen export API (server): EnsureCase / AppendEntry / LinkSuspect /
-- GetCase. Signatures are FROZEN — sibling resources (NPC-witness facts,
-- counterfeit-cash serial leads) build against them. Extend by adding new
-- exports, never by changing these.
-- ============================================================================

local STASH_ID = 'evidence_locker'

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql, per-statement pcall, every statement
-- IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this resource in particular: sql/ is applied BY HAND (deploy/README.md)
-- and CI never touches the DB, so a restored backup or a new box boots with no
-- evidence tables. This resource owns a FROZEN export API that five sibling
-- resources (protection, counterfeit, witnesses, seizure, replay) call inside
-- pcall - so a missing table means EnsureCase silently returns nil forever and
-- the entire case-file layer disappears with no console line. On the live box
-- these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0012_evidence.sql (the v1 log table) and
-- sql/0018_evidence_v2.sql (cases, suspects, and the additive v1 columns).
-- The v2 ALTERs are included because the v1 CREATE alone leaves case_id/kind/
-- source absent, which breaks every v2 insert path. `ADD COLUMN IF NOT EXISTS`
-- / `ADD INDEX IF NOT EXISTS` are MariaDB syntax, which is what this stack
-- runs (qbx_core is MariaDB-only) - same assumption sql/0018 states.
--
-- One deliberate deviation from byte-verbatim: the five-line SQL comment that
-- sits above uq_palm6_evidence_suspects_case_cid in sql/0018 is NOT reproduced
-- here. The DDL itself is identical; only the comment is dropped. Read sql/0018
-- for the reasoning behind that key (race-safe INSERT IGNORE dedupe, NULL
-- citizenid exempt because MariaDB unique keys permit multiple NULLs).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_evidence` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL,
    description TEXT NOT NULL,
    coords TEXT DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_evidence_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_evidence_cases` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    incident_key VARCHAR(80) DEFAULT NULL,
    title VARCHAR(150) NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'open',
    created_by VARCHAR(64) NOT NULL DEFAULT 'system',
    created_by_name VARCHAR(100) NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_palm6_evidence_cases_incident (incident_key),
    INDEX idx_palm6_evidence_cases_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_evidence_suspects` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    case_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) DEFAULT NULL,
    descriptor TEXT DEFAULT NULL,
    added_by VARCHAR(100) NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_palm6_evidence_suspects_case_cid (case_id, citizenid),
    INDEX idx_palm6_evidence_suspects_case (case_id),
    INDEX idx_palm6_evidence_suspects_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN/INDEX IF
    -- NOT EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- or index already exists. Folding these into SchemaReady made a perfectly
    -- healthy MySQL box print `schema MISSING` on every boot, which is the
    -- permanent-false-alarm failure that trains an operator to ignore the
    -- banner (see palm6_perf/server/tables.lua's header). The CREATE TABLEs
    -- above are what this resource owns and what SchemaReady answers for.
    -- Same pattern as palm6_mdt/server/main.lua's schemaOk.
    local alters = {
        [[
ALTER TABLE `palm6_evidence`
    ADD COLUMN IF NOT EXISTS case_id INT UNSIGNED DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS kind VARCHAR(32) NOT NULL DEFAULT 'note',
    ADD COLUMN IF NOT EXISTS source VARCHAR(64) NOT NULL DEFAULT 'police'
        ]],
        [[
ALTER TABLE `palm6_evidence`
    ADD INDEX IF NOT EXISTS idx_palm6_evidence_case (case_id)
        ]],
        [[
ALTER TABLE `palm6_evidence_suspects`
    ADD UNIQUE INDEX IF NOT EXISTS uq_palm6_evidence_suspects_case_cid (case_id, citizenid)
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_evidence] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_evidence] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column or index already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Restrict to the police group and to the locker coords so ox_inventory
    -- enforces access itself; the server on-duty/proximity gate below is then
    -- a second layer, not the only one.
    Bridge.RegisterStash(STASH_ID, 'Evidence Locker', Config.LockerSlots, Config.LockerMaxWeight,
        { police = 0 }, Config.LockerCoords)
    print('[palm6_evidence] evidence locker registered')
    -- Schema on its own thread: the stash registration above must not wait on
    -- oxmysql, and nothing in this resource queries before a player acts.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        if not SchemaReady then
            print('^1[palm6_evidence] schema MISSING - case files and the frozen export API are INERT on this box.^0')
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Rate limiting (server-side; commands are player-spammable)
-- ---------------------------------------------------------------------------

local lastAction = {} -- src -> { read = ms, write = ms }

AddEventHandler('playerDropped', function()
    lastAction[source] = nil
end)

-- true = allowed (and stamps the clock); false = still cooling down.
local function allow(src, bucket, cooldownMs)
    local now = Bridge.NowMs()
    local t = lastAction[src]
    if not t then
        t = {}
        lastAction[src] = t
    end
    if t[bucket] and (now - t[bucket]) < cooldownMs then return false end
    t[bucket] = now
    return true
end

-- Rejections notify the player: a silently-eaten `/caseadd` right after a
-- `/casenew` looks like a successful write with a missing toast, and the
-- officer only finds out later that the entry never landed.
-- Commands validate args BEFORE calling these, so a typo'd command never
-- burns the cooldown window.
local function allowWrite(src)
    if allow(src, 'write', Config.WriteCooldownMs) then return true end
    Bridge.Notify(src, 'Evidence', 'Slow down — try that again in a moment.', 'error')
    return false
end

local function allowRead(src)
    if allow(src, 'read', Config.ReadCooldownMs) then return true end
    Bridge.Notify(src, 'Evidence', 'Slow down — try that again in a moment.', 'error')
    return false
end

-- ---------------------------------------------------------------------------
-- Small helpers (pure)
-- ---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function clamp(s, maxLen)
    if type(s) ~= 'string' then return nil end
    s = trim(s)
    if #s == 0 then return nil end
    if #s > maxLen then
        s = s:sub(1, maxLen)
        -- Byte-level cut can split a multibyte UTF-8 sequence; MariaDB
        -- strict mode (STRICT_TRANS_TABLES) then rejects the INSERT with
        -- 'Incorrect string value'. Back off any trailing partial sequence.
        local n = #s
        local i = n
        while i > 0 and i > n - 4 do
            local b = s:byte(i)
            if b < 0x80 then break end -- ASCII: cut is clean
            if b >= 0xC0 then
                -- Lead byte at i; drop it if its sequence got truncated.
                local expect = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
                if i + expect - 1 > n then s = s:sub(1, i - 1) end
                break
            end
            i = i - 1 -- continuation byte: keep scanning back for the lead
        end
        s = trim(s)
        if #s == 0 then return nil end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Case core (DB access; used by both commands and the export API)
-- ---------------------------------------------------------------------------

local function getCaseRow(caseId)
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM palm6_evidence_cases WHERE id = ?', { caseId })
    end)
    if not ok or not rows then return nil end
    return rows[1]
end

-- Create a case, or return the existing one for `incidentKey`. Race-safe:
-- the UNIQUE key on incident_key plus INSERT IGNORE means two systems
-- reporting the same incident concurrently converge on one case.
-- Soft dependency: new-case posts go to the police Discord feed iff
-- palm6_discord is running with it configured. Never blocks case creation.
local function discordAnnounce(payload)
    if GetResourceState('palm6_discord') ~= 'started' then return end
    pcall(function() exports.palm6_discord:Announce('police', payload) end)
end

local function ensureCase(incidentKey, title, createdBy, createdByName)
    title = clamp(title, Config.CaseTitleMax)
    if not title then return nil, 'title required' end
    incidentKey = incidentKey and clamp(tostring(incidentKey), 80) or nil
    createdBy = clamp(tostring(createdBy or 'system'), 64) or 'system'
    createdByName = clamp(tostring(createdByName or createdBy), 100) or createdBy

    if incidentKey then
        local ok, rows = pcall(function()
            return MySQL.query.await(
                'SELECT id FROM palm6_evidence_cases WHERE incident_key = ?', { incidentKey })
        end)
        if ok and rows and rows[1] then return rows[1].id end
    end

    local ok, insertId = pcall(function()
        return MySQL.insert.await(
            'INSERT IGNORE INTO palm6_evidence_cases (incident_key, title, status, created_by, created_by_name) VALUES (?, ?, ?, ?, ?)',
            { incidentKey, title, 'open', createdBy, createdByName })
    end)
    if ok and insertId and insertId > 0 then
        -- Only genuinely NEW cases announce (idempotent re-ensures return
        -- above). devtest's probe cases stay out of the feed.
        if createdBy ~= 'palm6_devtest' then
            discordAnnounce({
                title = ('CASE #%d OPENED'):format(insertId),
                description = title,
                fields = { { name = 'Source', value = createdByName, inline = true } },
            })
        end
        return insertId
    end

    -- INSERT IGNORE returned no id: someone else won the incident_key race.
    if incidentKey then
        local ok2, rows = pcall(function()
            return MySQL.query.await(
                'SELECT id FROM palm6_evidence_cases WHERE incident_key = ?', { incidentKey })
        end)
        if ok2 and rows and rows[1] then return rows[1].id end
    end
    return nil, 'insert failed'
end

local function appendEntry(caseId, kind, payload, source, citizenid, officerName, coords)
    caseId = tonumber(caseId)
    if not caseId or not getCaseRow(caseId) then return nil, 'no such case' end

    kind = clamp(tostring(kind or 'note'), 32) or 'note'
    if type(payload) == 'table' then
        local okEnc, enc = pcall(json.encode, payload)
        if not okEnc or type(enc) ~= 'string' then return nil, 'payload encode failed' end
        -- Structured payloads must never be truncated: a byte-clamped JSON
        -- blob is silently unparseable for the consumer that wrote it.
        -- Reject oversized instead of storing corrupt data with a success id.
        if #enc > Config.EntryMax then return nil, 'payload too large' end
        payload = enc
    end
    payload = clamp(tostring(payload or ''), Config.EntryMax)
    if not payload then return nil, 'payload required' end
    source = clamp(tostring(source or 'unknown'), 64) or 'unknown'
    citizenid = clamp(tostring(citizenid or source), 64) or source
    officerName = clamp(tostring(officerName or source), 100) or source

    local ok, insertId = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO palm6_evidence (citizenid, officer_name, description, coords, case_id, kind, source) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { citizenid, officerName, payload, coords and json.encode(coords) or nil, caseId, kind, source })
    end)
    if not ok or not insertId then return nil, 'insert failed' end
    return insertId
end

local function linkSuspect(caseId, citizenid, descriptor, addedBy)
    caseId = tonumber(caseId)
    if not caseId or not getCaseRow(caseId) then return false, 'no such case' end

    citizenid = citizenid and clamp(tostring(citizenid), 64) or nil
    descriptor = descriptor and clamp(tostring(descriptor), Config.EntryMax) or nil
    if not citizenid and not descriptor then return false, 'citizenid or descriptor required' end
    addedBy = clamp(tostring(addedBy or 'system'), 100) or 'system'

    -- Dedupe: same known citizenid (or identical descriptor) on the same
    -- case is a no-op success, so repeat reports don't pile up rows.
    -- Known-citizenid dedupe is race-safe: UNIQUE (case_id, citizenid)
    -- (0018_evidence_v2.sql) + INSERT IGNORE below — same pattern as
    -- EnsureCase's incident_key. The descriptor path stays check-then-insert
    -- (TEXT can't carry a full unique index; a prefix-unique would falsely
    -- merge distinct descriptors), so it is best-effort only.
    local ok, rows = pcall(function()
        if citizenid then
            return MySQL.query.await(
                'SELECT id FROM palm6_evidence_suspects WHERE case_id = ? AND citizenid = ?',
                { caseId, citizenid })
        end
        return MySQL.query.await(
            'SELECT id FROM palm6_evidence_suspects WHERE case_id = ? AND citizenid IS NULL AND descriptor = ?',
            { caseId, descriptor })
    end)
    if ok and rows and rows[1] then return true end

    local ok2 = pcall(function()
        if citizenid then
            -- INSERT IGNORE: if a concurrent link won the unique-key race,
            -- the row already exists, which is the outcome we wanted.
            MySQL.insert.await(
                'INSERT IGNORE INTO palm6_evidence_suspects (case_id, citizenid, descriptor, added_by) VALUES (?, ?, ?, ?)',
                { caseId, citizenid, descriptor, addedBy })
        else
            MySQL.insert.await(
                'INSERT INTO palm6_evidence_suspects (case_id, citizenid, descriptor, added_by) VALUES (?, ?, ?, ?)',
                { caseId, citizenid, descriptor, addedBy })
        end
    end)
    if not ok2 then return false, 'insert failed' end
    return true
end

local function getCaseFull(caseId)
    caseId = tonumber(caseId)
    if not caseId then return nil end
    local c = getCaseRow(caseId)
    if not c then return nil end

    local suspects, entries = {}, {}
    pcall(function()
        suspects = MySQL.query.await(
            'SELECT id, citizenid, descriptor, added_by, created_at FROM palm6_evidence_suspects WHERE case_id = ? ORDER BY created_at ASC',
            { caseId }) or {}
    end)
    pcall(function()
        entries = MySQL.query.await(
            'SELECT id, kind, source, officer_name, citizenid, description, created_at FROM palm6_evidence WHERE case_id = ? ORDER BY created_at DESC LIMIT ?',
            { caseId, Config.CaseEntryLimit }) or {}
    end)

    return {
        id = c.id,
        incident_key = c.incident_key,
        title = c.title,
        status = c.status,
        created_by = c.created_by,
        created_by_name = c.created_by_name,
        created_at = tostring(c.created_at),
        updated_at = tostring(c.updated_at),
        suspects = suspects,
        entries = entries,
    }
end

local function setCaseStatus(caseId, status)
    caseId = tonumber(caseId)
    if not caseId or not getCaseRow(caseId) then return false, 'no such case' end
    local ok = pcall(function()
        MySQL.update.await('UPDATE palm6_evidence_cases SET status = ? WHERE id = ?', { status, caseId })
    end)
    return ok
end

-- ---------------------------------------------------------------------------
-- FROZEN EXPORT API — sibling resources (server-side) build against these.
-- Add new exports for new needs; never change these signatures.
-- ---------------------------------------------------------------------------

-- EnsureCase(incidentKey: string|nil, title: string, createdBy: string|nil) -> caseId: number|nil
-- Idempotent per incidentKey (nil incidentKey always creates a new case).
exports('EnsureCase', function(incidentKey, title, createdBy)
    local id = ensureCase(incidentKey, title, createdBy, createdBy)
    return id
end)

-- AppendEntry(caseId: number, kind: string, payload: string|table, source: string) -> entryId: number|nil
-- Tables are json-encoded. kind: freeform taxonomy ('note'|'fact'|'lead'|...).
exports('AppendEntry', function(caseId, kind, payload, source)
    local id = appendEntry(caseId, kind, payload, source, nil, nil, nil)
    return id
end)

-- LinkSuspect(caseId: number, citizenid: string|nil, descriptor: string|nil) -> boolean
-- Known suspect: pass citizenid. Unknown suspect: citizenid nil + descriptor.
exports('LinkSuspect', function(caseId, citizenid, descriptor)
    local ok = linkSuspect(caseId, citizenid, descriptor, 'system')
    return ok == true
end)

-- GetCase(caseId: number) -> table|nil
-- { id, incident_key, title, status, created_by, created_by_name,
--   created_at, updated_at, suspects = {...}, entries = {...} }
exports('GetCase', function(caseId)
    return getCaseFull(caseId)
end)

-- ADDITIVE export (added for palm6_mdt) — not one of the frozen four, but
-- the same rule applies now that it exists: never change the signature.
-- Read-only; no schema impact.
--
-- ListCases(status: string|nil, limit: number|nil) -> { { id, title,
--   status, created_at, suspects }, ... }  (newest activity first;
--   status defaults 'open', limit clamps to [1, 25])
exports('ListCases', function(status, limit)
    status = tostring(status or 'open')
    limit = math.min(math.max(math.floor(tonumber(limit) or 10), 1), 25)
    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT c.id, c.title, c.status, c.created_at,
                   (SELECT COUNT(*) FROM palm6_evidence_suspects s WHERE s.case_id = c.id) AS suspects
            FROM palm6_evidence_cases c
            WHERE c.status = ?
            ORDER BY c.updated_at DESC
            LIMIT ?
        ]], { status, limit }) or {}
    end)
    for _, r in ipairs(rows) do r.created_at = tostring(r.created_at) end
    return rows
end)

-- ---------------------------------------------------------------------------
-- v1 commands (unchanged behavior)
-- ---------------------------------------------------------------------------

RegisterCommand('logevidence', function(src, args)
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end
    -- Clamped like every v2 write path: command args arrive over the net and
    -- are NOT limited to the 255-char chat box, so an unbounded concat lets a
    -- modded client insert TEXT-size rows. Legit chat usage is unaffected.
    local description = clamp(table.concat(args, ' '), Config.EntryMax)
    if not description then
        Bridge.Notify(src, 'Evidence', 'Usage: /logevidence <description>', 'error')
        return
    end
    if not allowWrite(src) then return end

    local cid = Bridge.GetCitizenId(src)
    local coords = Bridge.GetCoords(src)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_evidence (citizenid, officer_name, description, coords) VALUES (?, ?, ?, ?)',
            { cid, Bridge.GetPlayerName(src), description, coords and json.encode(coords) or nil })
    end)

    if ok then
        Bridge.Notify(src, 'Evidence', 'Logged.', 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed to log evidence.', 'error')
    end
end, false)

-- ---------------------------------------------------------------------------
-- /evidence — v1 flat review (no args) + v2 case browsing (subcommands).
-- All views render through the same v1 client path:
-- palm6_evidence:showLog -> Game.ShowLogDialog.
-- ---------------------------------------------------------------------------

local function showDialog(src, text)
    TriggerClientEvent('palm6_evidence:showLog', src, text)
end

local function suspectLabel(s)
    if s.citizenid then return ('CID `%s`'):format(s.citizenid) end
    return ('unknown — %s'):format(s.descriptor or '?')
end

local function renderCaseDetail(case)
    local lines = {
        ('**Case #%d — %s**  [%s]'):format(case.id, case.title, case.status:upper()),
        ('_Opened by %s — %s_'):format(case.created_by_name ~= '' and case.created_by_name or case.created_by, case.created_at),
        '',
        '**Suspects**',
    }
    if #case.suspects == 0 then
        lines[#lines + 1] = '- none linked'
    else
        for _, s in ipairs(case.suspects) do
            lines[#lines + 1] = ('- %s _(added by %s)_'):format(suspectLabel(s), s.added_by)
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('**Entries** (newest %d)'):format(Config.CaseEntryLimit)
    if #case.entries == 0 then
        lines[#lines + 1] = '- no entries yet'
    else
        for _, e in ipairs(case.entries) do
            lines[#lines + 1] = ('- [%s] **%s** — %s\n  _%s_'):format(e.kind, e.officer_name, e.description, tostring(e.created_at))
        end
    end
    return table.concat(lines, '\n')
end

local function evidenceCasesView(src)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT id, title, status, created_by_name, created_at FROM palm6_evidence_cases ORDER BY created_at DESC LIMIT ?',
            { Config.CaseListLimit })
    end)
    if not ok or not rows or #rows == 0 then
        Bridge.Notify(src, 'Evidence', 'No cases yet. /casenew <title> opens one.', 'inform')
        return
    end
    local lines = { '**Case Files** — `/evidence case <id>` for detail', '' }
    for _, c in ipairs(rows) do
        lines[#lines + 1] = ('**#%d** [%s] %s — %s\n_%s_'):format(c.id, c.status, c.title, c.created_by_name, tostring(c.created_at))
    end
    showDialog(src, table.concat(lines, '\n\n'))
end

local function evidenceCaseView(src, caseId)
    local case = getCaseFull(caseId)
    if not case then
        Bridge.Notify(src, 'Evidence', 'No such case.', 'error')
        return
    end
    showDialog(src, renderCaseDetail(case))
end

local function evidenceSuspectView(src, citizenid)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            [[SELECT c.id, c.title, c.status, c.created_at
              FROM palm6_evidence_cases c
              JOIN palm6_evidence_suspects s ON s.case_id = c.id
              WHERE s.citizenid = ?
              GROUP BY c.id
              ORDER BY c.created_at DESC LIMIT ?]],
            { citizenid, Config.CaseListLimit })
    end)
    if not ok or not rows or #rows == 0 then
        Bridge.Notify(src, 'Evidence', 'No cases linked to that citizen.', 'inform')
        return
    end
    local lines = { ('**Cases linked to CID `%s`**'):format(citizenid), '' }
    for _, c in ipairs(rows) do
        lines[#lines + 1] = ('**#%d** [%s] %s\n_%s_'):format(c.id, c.status, c.title, tostring(c.created_at))
    end
    showDialog(src, table.concat(lines, '\n\n'))
end

RegisterCommand('evidence', function(src, args)
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end
    local sub = args[1] and args[1]:lower() or nil

    if sub == 'cases' then
        if not allowRead(src) then return end
        evidenceCasesView(src)
        return
    elseif sub == 'case' then
        local caseId = tonumber(args[2])
        if not caseId then
            Bridge.Notify(src, 'Evidence', 'Usage: /evidence case <id>', 'error')
            return
        end
        if not allowRead(src) then return end
        evidenceCaseView(src, caseId)
        return
    elseif sub == 'suspect' then
        local cid = args[2] and clamp(args[2], 64) or nil
        if not cid then
            Bridge.Notify(src, 'Evidence', 'Usage: /evidence suspect <citizenid>', 'error')
            return
        end
        if not allowRead(src) then return end
        evidenceSuspectView(src, cid)
        return
    end

    -- No subcommand: v1 flat log, unchanged.
    if not allowRead(src) then return end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT officer_name, description, created_at FROM palm6_evidence ORDER BY created_at DESC LIMIT ?',
            { Config.LogEntryLimit })
    end)

    if not ok or not rows or #rows == 0 then
        Bridge.Notify(src, 'Evidence', 'No evidence logged yet.', 'inform')
        return
    end

    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ('**%s** — %s\n_%s_'):format(r.officer_name, r.description, tostring(r.created_at))
    end
    showDialog(src, table.concat(lines, '\n\n'))
end, false)

-- ---------------------------------------------------------------------------
-- v2 case commands (on-duty police, server-gated, rate-limited)
-- ---------------------------------------------------------------------------

local function requireOfficer(src)
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return false
    end
    return true
end

RegisterCommand('casenew', function(src, args)
    if not requireOfficer(src) then return end
    local title = clamp(table.concat(args, ' '), Config.CaseTitleMax)
    if not title then
        Bridge.Notify(src, 'Evidence', 'Usage: /casenew <title>', 'error')
        return
    end
    if not allowWrite(src) then return end
    -- Officer-opened cases carry no incident_key: never auto-merged.
    local caseId = ensureCase(nil, title, Bridge.GetCitizenId(src) or 'unknown', Bridge.GetPlayerName(src))
    if caseId then
        Bridge.Notify(src, 'Evidence', ('Case #%d opened: %s'):format(caseId, title), 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed to open case.', 'error')
    end
end, false)

RegisterCommand('caseadd', function(src, args)
    if not requireOfficer(src) then return end
    local caseId = tonumber(args[1])
    local description = clamp(table.concat(args, ' ', 2), Config.EntryMax)
    if not caseId or not description then
        Bridge.Notify(src, 'Evidence', 'Usage: /caseadd <case id> <description>', 'error')
        return
    end
    if not allowWrite(src) then return end
    local entryId = appendEntry(caseId, 'note', description, 'police',
        Bridge.GetCitizenId(src), Bridge.GetPlayerName(src), Bridge.GetCoords(src))
    if entryId then
        Bridge.Notify(src, 'Evidence', ('Entry logged to case #%d.'):format(caseId), 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed — check the case id.', 'error')
    end
end, false)

-- Turn /casesuspect's known-suspect argument into a citizenid. Accepts EITHER
-- a raw citizenid (unchanged - the only form this command ever took) or the
-- online server id that palm6_mdt's /id prints, so one number works across
-- /id, /cite, /warrant, /book and here.
--
-- Soft cross-resource read, deliberately NOT a second copy of the logic: the
-- single implementation is Bridge.ResolveTarget in
-- palm6_mdt/bridge/sv_framework.lua, exposed as exports.palm6_mdt:ResolveTarget.
--
-- Returns citizenid, verified. Non-numeric input that does not resolve falls
-- through UNCHANGED (verified = false), because this command never verified the
-- citizenid it stored and an officer working a case may legitimately link an id
-- this server has no player row for. An ALL-DIGIT token is different: when
-- palm6_mdt answered and still could not resolve it, it is unambiguously a dead
-- server id, because ResolveTarget already retries an all-digit argument as a
-- citizenid against the `players` table (palm6_mdt/bridge/sv_framework.lua:162-173).
-- Storing that verbatim writes a server id into the citizenid column, and server
-- ids are reused across sessions, so UNIQUE (case_id, citizenid) would later
-- collapse two different people into one suspect row. Return nil so the caller
-- rejects it, matching /cite (palm6_citations/server/main.lua:107-110).
local function suspectCitizenId(raw)
    if GetResourceState('palm6_mdt') == 'started' then
        local hit
        pcall(function() hit = exports.palm6_mdt:ResolveTarget(raw) end)
        if type(hit) == 'table' and hit.citizenid then return hit.citizenid, true end
        if tostring(raw):match('^%d+$') then return nil, false end
    end
    return raw, false
end

RegisterCommand('casesuspect', function(src, args)
    if not requireOfficer(src) then return end
    local caseId = tonumber(args[1])
    local second = args[2]
    if not caseId or not second then
        Bridge.Notify(src, 'Evidence',
            'Usage: /casesuspect <case id> <citizenid or server id> — or — /casesuspect <case id> unknown <descriptors>', 'error')
        return
    end

    local ok
    if second:lower() == 'unknown' then
        local descriptor = clamp(table.concat(args, ' ', 3), Config.EntryMax)
        if not descriptor then
            Bridge.Notify(src, 'Evidence', 'Give some descriptors: /casesuspect <id> unknown red hoodie, white mask', 'error')
            return
        end
        if not allowWrite(src) then return end
        ok = linkSuspect(caseId, nil, descriptor, Bridge.GetPlayerName(src))
    else
        -- Resolve BEFORE allowWrite, so a dead server id never burns the
        -- write cooldown (same rule as the arg validation above).
        local suspect, verified = suspectCitizenId(second)
        if not suspect then
            Bridge.Notify(src, 'Evidence',
                'No citizen with that id on record. Re-check the server id with /id, or pass the citizenid.', 'error')
            return
        end
        if not allowWrite(src) then return end
        ok = linkSuspect(caseId, clamp(suspect, 64), nil, Bridge.GetPlayerName(src))
        -- Only reachable with palm6_mdt stopped: nothing could check the
        -- number, so say so rather than implying the suspect was identified.
        if ok and not verified and suspect:match('^%d+$') then
            Bridge.Notify(src, 'Evidence',
                ('Stored "%s" verbatim: the MDT is offline, so it could not be checked against a citizen.')
                :format(suspect), 'inform')
        end
    end

    if ok then
        Bridge.Notify(src, 'Evidence', ('Suspect linked to case #%d.'):format(caseId), 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed — check the case id.', 'error')
    end
end, false)

RegisterCommand('caseclose', function(src, args)
    if not requireOfficer(src) then return end
    local caseId = tonumber(args[1])
    if not caseId then
        Bridge.Notify(src, 'Evidence', 'Usage: /caseclose <case id>', 'error')
        return
    end
    if not allowWrite(src) then return end
    if setCaseStatus(caseId, 'closed') then
        Bridge.Notify(src, 'Evidence', ('Case #%d closed.'):format(caseId), 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed — check the case id.', 'error')
    end
end, false)

RegisterCommand('casereopen', function(src, args)
    if not requireOfficer(src) then return end
    local caseId = tonumber(args[1])
    if not caseId then
        Bridge.Notify(src, 'Evidence', 'Usage: /casereopen <case id>', 'error')
        return
    end
    if not allowWrite(src) then return end
    if setCaseStatus(caseId, 'open') then
        Bridge.Notify(src, 'Evidence', ('Case #%d reopened.'):format(caseId), 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed — check the case id.', 'error')
    end
end, false)

-- ---------------------------------------------------------------------------
-- Locker (v1, unchanged)
-- ---------------------------------------------------------------------------

RegisterNetEvent('palm6_evidence:requestOpenLocker', function()
    local src = source
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, Config.LockerCoords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Evidence', 'You are too far from the locker.', 'error')
        return
    end
    TriggerClientEvent('palm6_evidence:openLocker', src, STASH_ID)
end)
