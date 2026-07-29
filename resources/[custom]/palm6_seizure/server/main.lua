-- ============================================================================
-- palm6_seizure/server/main.lua
--
-- Pure logic. Calls Bridge.* for all framework / inventory / mdt / evidence /
-- native access. No direct framework / native calls here (§6 gate).
--
-- An on-duty officer runs /seizedirty over a nearby WANTED suspect: the
-- suspect's dirty money (black_money) is removed from circulation, written to a
-- persistent forfeiture ledger, and attached to a palm6_evidence case. The law's
-- counter to the dirty-money economy. Nothing trusts a client-supplied target,
-- position, amount, or item; the money is destroyed, never paid to the officer.
-- ============================================================================

local lastAction = {}   -- [src] = ts of last /seizedirty (spam guard)
AddEventHandler('playerDropped', function() lastAction[source] = nil end)  -- reclaim on disconnect
local seizeLock  = {}   -- [suspect citizenid] = true while a seizure is in flight

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_seizure] ' .. msg) end
end

-- Open/append the forfeiture evidence case. Returns caseId or nil.
local function fileEvidence(officerCid, suspectCid, amount)
    local incidentKey = ('%s%s-%d'):format(Config.Evidence.IncidentKeyPrefix, suspectCid, math.floor(now() / 300))
    local caseId = Bridge.EvidenceEnsureCase(incidentKey, Config.Evidence.CaseTitle, 'palm6_seizure')
    if caseId then
        Bridge.EvidenceAppend(caseId, 'forfeiture', {
            amount = amount, item = Config.DirtyItem, seized_by = officerCid,
        }, 'palm6_seizure')
        Bridge.EvidenceLinkSuspect(caseId, suspectCid, nil)
    end
    return caseId
end

-- ---------------------------------------------------------------------------
-- /seizedirty — forfeit a nearby wanted suspect's dirty money.
-- ---------------------------------------------------------------------------
local function cmdSeizeDirty(src)
    if src == 0 then return end
    local t = now()
    -- Atomic check-and-set before any yield (rl() idiom).
    if (lastAction[src] or 0) + Config.CooldownSec > t then
        Bridge.Notify(src, 'Forfeiture', 'Give it a second.', 'error'); return
    end
    lastAction[src] = t

    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Forfeiture', 'Only on-duty police can seize assets.', 'error'); return
    end
    local officerCid = Bridge.GetCitizenId(src)
    if not officerCid then return end

    local target = Bridge.NearestPlayer(src, Config.SeizeRadius)
    if not target or not target.citizenid then
        Bridge.Notify(src, 'Forfeiture', 'No suspect close enough.', 'error'); return
    end
    local suspectCid = target.citizenid

    if Config.RequireWarrant and not Bridge.HasActiveWarrant(suspectCid) then
        Bridge.Notify(src, 'Forfeiture', 'No active warrant on that suspect — no probable cause.', 'error'); return
    end

    if seizeLock[suspectCid] then
        Bridge.Notify(src, 'Forfeiture', 'Another officer is already processing that suspect.', 'error'); return
    end
    seizeLock[suspectCid] = true

    local held = Bridge.CountDirty(target.src, Config.DirtyItem)
    if held <= 0 then
        seizeLock[suspectCid] = nil
        Bridge.Notify(src, 'Forfeiture', 'The suspect is carrying no dirty money.', 'inform'); return
    end

    -- Remove exactly what they hold; log only what ox confirms was taken.
    if not Bridge.RemoveDirty(target.src, Config.DirtyItem, held) then
        seizeLock[suspectCid] = nil
        Bridge.Notify(src, 'Forfeiture', 'Seizure failed — try again.', 'error'); return
    end

    -- Forfeited money is destroyed (booked to the state), never paid to the
    -- officer. Record the ledger row + attach evidence.
    local caseId = fileEvidence(officerCid, suspectCid, held)
    pcall(function()
        MySQL.insert.await(
            "INSERT INTO palm6_seizure_forfeitures (officer_citizenid, suspect_citizenid, amount, evidence_case_id) VALUES (?, ?, ?, ?)",
            { officerCid, suspectCid, held, caseId })
    end)

    seizeLock[suspectCid] = nil
    -- Hype: a police win on the case desk. Suspect kept vague AND the exact
    -- amount is omitted — the raw forfeited figure is a private on-hand balance
    -- (a "take"), so it stays in the officer/suspect Notify + the DB ledger,
    -- never in the public Discord feed.
    Bridge.Announce('police', {
        title = 'Assets forfeited',
        description = 'LSPD forfeited dirty money from a wanted suspect and booked it into evidence.',
    })
    Bridge.Notify(src, 'Forfeiture', ('Seized $%d in dirty money — booked into evidence.'):format(held), 'success')
    Bridge.Notify(target.src, 'Forfeiture', ('Police forfeited $%d in dirty money from you.'):format(held), 'error')
    dbg(('%s forfeited $%d from %s (case %s)'):format(officerCid, held, suspectCid, tostring(caseId)))
end

-- ---------------------------------------------------------------------------
-- /seizures — read-only totals (on-duty police).
-- ---------------------------------------------------------------------------
local function cmdSeizures(src)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Forfeiture', 'On-duty police only.', 'error'); return
    end
    local count, total, day = 0, 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s, COALESCE(SUM(CASE WHEN created_at >= NOW() - INTERVAL 24 HOUR THEN amount ELSE 0 END),0) AS d FROM palm6_seizure_forfeitures")
        if r then count = tonumber(r.c) or 0; total = tonumber(r.s) or 0; day = tonumber(r.d) or 0 end
    end)
    Bridge.Notify(src, 'Forfeiture',
        ('%d seizure(s) all-time · $%d forfeited total · $%d in the last 24h'):format(count, total, day), 'inform')
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same pattern as palm6_mdt/server/main.lua:
-- Wait(3000) for oxmysql, per-statement pcall, CREATE TABLE IF NOT EXISTS.
-- sql/ files are applied BY HAND (deploy/README.md; CI never touches the DB),
-- so a fresh box that missed one left every query here pcall-swallowed into
-- silence - /seizures reporting zeros and every forfeiture row vanishing,
-- instead of "schema MISSING". Re-runs are harmless no-ops on the live box,
-- which already has this table.
--
-- The statement below is copied VERBATIM from the matching sql/ file so the
-- two can never diverge:
--   palm6_seizure_forfeitures   <- sql/0037_seizure.sql
-- ---------------------------------------------------------------------------
local schemaOk = true

local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_seizure_forfeitures` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    officer_citizenid VARCHAR(64) NOT NULL,
    suspect_citizenid VARCHAR(64) NOT NULL,
    amount INT UNSIGNED NOT NULL,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_seizure_suspect (suspect_citizenid),
    INDEX idx_palm6_seizure_officer (officer_citizenid)
);
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            schemaOk = false
            print(('^1[palm6_seizure] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('seizedirty', function(source) cmdSeizeDirty(source) end)
Bridge.RegisterCommand('seizures', function(source) cmdSeizures(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not Bridge.ItemExists(Config.DirtyItem) then
        print(('^1[palm6_seizure] FATAL: item "%s" is not registered in ox_inventory — forfeiture disabled.^0'):format(Config.DirtyItem))
        return
    end
    -- Schema + the counts that read it move into a thread so the DDL lands
    -- before anything SELECTs. Nothing above this point touches the DB.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()

        local count, total = 0, 0
        pcall(function()
            local r = MySQL.single.await("SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s FROM palm6_seizure_forfeitures")
            count = r and tonumber(r.c) or 0
            total = r and tonumber(r.s) or 0
        end)
        print(('[palm6_seizure] forfeiture online — %d seizure(s), $%d taken out of circulation; warrant gate %s, evidence %s, schema %s'):format(
            count, total,
            Bridge.ResourceStarted('palm6_mdt') and 'via palm6_mdt' or (Config.RequireWarrant and 'OFFLINE (mdt down → no seizures)' or 'disabled'),
            Bridge.ResourceStarted('palm6_evidence') and 'ONLINE' or 'offline',
            schemaOk and 'OK' or '^1MISSING^0'))
    end)
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { seizures = 0, totalForfeited = 0 }
    pcall(function()
        local r = MySQL.single.await("SELECT COUNT(*) AS c, COALESCE(SUM(amount),0) AS s FROM palm6_seizure_forfeitures")
        if r then out.seizures = tonumber(r.c) or 0; out.totalForfeited = tonumber(r.s) or 0 end
    end)
    return out
end)
