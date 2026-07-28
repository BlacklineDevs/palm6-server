-- ============================================================================
-- palm6_counterfeit/server/main.lua
--
-- Counterfeit cash with a MEMORY. A deployable printer mints serialized
-- wads; every transfer appends a provenance hop (capped at the newest
-- Config.HopCap); printing raises district heat police feel as a vague zone
-- ping; sinks and fences move the paper at rising risk as a batch
-- circulates; and one seized serial at the evidence terminal cascades —
-- through palm6_evidence v2 case leads and interrogations — into a network
-- takedown.
--
-- Pure logic — all framework/native access via Bridge.* (§6 gate). Our own
-- palm6_counterfeit_* SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3). The palm6_evidence v2 exports called
-- below are our own frozen sibling API (Tier 1, engine-agnostic) — not a
-- framework binding, so they are consumed here directly.
--
-- SERVER AUTHORITY: every serial is minted here; every placement coord is
-- the player's SERVER-side position; both phases of every two-phase action
-- carry min- AND max-elapsed windows plus a position anchor and fresh
-- proximity; every payout, detection roll, quota, and item mutation is
-- server-side; every client-triggerable event is rate-limited.
-- ============================================================================

local ITEMS = Config.Items

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
local itemsReady   = false  -- every REQUIRED item resolves in ox_inventory
local bagsReady    = false  -- qbx_police evidence-bag items resolve (soft)
local bootReady    = false  -- printers/heat/fenceQuota rehydrated from the DB.
                            -- Every net event whose CAP is enforced against one
                            -- of those tables must refuse until this is true,
                            -- or the ~3s boot window is a free pass.
local printers     = {}     -- [id] = { id, owner, ownerName, district, coords,
                            --          paper, ink, prop } (status='placed' only)
local heat         = {}     -- [districtId] = { heat, lastPing }
local pendingPrint = {}     -- [src] = { printerId, startedAt, startCoords, cid }
local placingPrinter = {}   -- [citizenid] = true while a place INSERT is in flight
local pendingPen   = {}     -- [src] = { serial, startedAt, cid }
local lastAction   = {}     -- [src] = { [key] = ts } rate-limit ledger
local cooldowns    = {}     -- [cid] = { [key] = ts }
local fenceQuota   = {}     -- [cid .. '|' .. fenceId .. '|' .. yyyymmdd] = n

-- Persistent police attention (palm6_heat) for a completed print cycle. NOT the
-- same thing as `heat` above: that is this resource's own per-DISTRICT zone-ping
-- model, this is the durable per-CHARACTER score other resources read. Mirrors
-- palm6_heat Config.Suggested.counterfeit; a named local next to nothing else so
-- the number is never a bare literal in the print path. Bounded by
-- Config.Print.CooldownSec (180s per character) plus the paper/ink consumables.
local HEAT_ON_PRINT = 8

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_counterfeit] ' .. msg) end
end

-- Soft dependency: news bulletins go out iff palm6_discord is running with
-- the 'heat' feed configured. Never blocks or errors the heat sweep.
local function discordAnnounce(payload)
    if not Bridge.ResourceStarted('palm6_discord') then return end
    pcall(function() exports.palm6_discord:Announce('heat', payload) end)
end

-- Per-source rate limit. Returns true when the call is allowed.
local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function cdRemaining(cid, key, windowSec)
    local c = cooldowns[cid]
    if not c or not c[key] then return 0 end
    local left = (c[key] + windowSec) - now()
    return left > 0 and left or 0
end

local function setCooldown(cid, key)
    cooldowns[cid] = cooldowns[cid] or {}
    cooldowns[cid][key] = now()
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local SERIAL_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

local function makeBatchCode()
    local out = {}
    for i = 1, 6 do
        local n = math.random(#SERIAL_CHARS)
        out[i] = SERIAL_CHARS:sub(n, n)
    end
    return table.concat(out)
end

local function makeSerial(batchCode, n)
    return ('CF-%s-%02d'):format(batchCode, n)
end

local function districtById(id)
    for _, d in ipairs(Config.Districts) do
        if d.id == id then return d end
    end
    return nil
end

local function districtAt(coords)
    for _, d in ipairs(Config.Districts) do
        if Bridge.Distance(coords, d.center) <= d.radius then return d end
    end
    return nil
end

local function sinkById(id)
    for _, s in ipairs(Config.Sinks) do
        if s.id == id then return s end
    end
    return nil
end

local function fenceById(id)
    for _, f in ipairs(Config.Fences) do
        if f.id == id then return f end
    end
    return nil
end

local function nearCoords(src, coords, radius)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, coords) <= radius
end

-- Wear band the street can feel (fence remarks, pen verdicts). Circulation
-- is a batch-level count of hands the paper has passed through.
local function wearBand(circulation)
    if circulation <= 2 then return 'crisp' end
    if circulation <= 6 then return 'worn' end
    return 'rag paper'
end

-- Wad metadata: batch_id + serial (the spec'd identity pair) + a flat
-- description. Identical shape on every wad — nothing in the inventory UI
-- betrays counterfeit; the registry, not the metadata, is the truth.
local function wadMetadata(serial, batchCode)
    return {
        serial = serial,
        batch = batchCode,
        description = ('A rubber-banded bundle of hundreds. $%d, at a glance.')
            :format(Config.Print.FaceValue),
    }
end

-- Find the slot holding the wad with this serial, or nil.
local function findWadSlot(src, serial)
    for _, it in ipairs(Bridge.ListItemSlots(src, ITEMS.Cash.name)) do
        if it.metadata.serial == serial then return it.slot end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- DB access (our own portable palm6_counterfeit_* schema)
-- ---------------------------------------------------------------------------
local function wadWithBatch(serial)
    local ok, row = pcall(function()
        return MySQL.single.await(
            [[SELECT w.serial, w.batch_code, w.status,
                     b.circulation, b.wads_printed, b.district_id, b.face_value,
                     b.printed_by, b.printed_by_name, b.printer_id
              FROM palm6_counterfeit_wads w
              JOIN palm6_counterfeit_batches b ON b.code = w.batch_code
              WHERE w.serial = ?]], { serial })
    end)
    return ok and row or nil
end

local function setWadStatus(serial, status, seizedBy)
    pcall(function()
        if seizedBy then
            MySQL.update.await(
                'UPDATE palm6_counterfeit_wads SET status = ?, seized_by = ?, seized_at = NOW() WHERE serial = ?',
                { status, seizedBy, serial })
        else
            MySQL.update.await(
                'UPDATE palm6_counterfeit_wads SET status = ? WHERE serial = ?', { status, serial })
        end
    end)
end

local function bumpCirculation(batchCode)
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_batches SET circulation = circulation + 1 WHERE code = ?',
            { batchCode })
    end)
end

-- Append a provenance hop, then trim the chain to the newest Config.HopCap
-- rows. Old history genuinely falls off the end — moving paper fast erodes
-- the trail, including (eventually) the print hop itself.
local function appendHop(serial, kind, fromCid, fromName, toCid, toName, detail)
    pcall(function()
        MySQL.insert.await(
            [[INSERT INTO palm6_counterfeit_hops
                (serial, kind, from_citizenid, from_name, to_citizenid, to_name, detail)
              VALUES (?, ?, ?, ?, ?, ?, ?)]],
            { serial, kind, fromCid, fromName or '', toCid, toName or '', detail })
        local cutoff = MySQL.scalar.await(
            'SELECT id FROM palm6_counterfeit_hops WHERE serial = ? ORDER BY id DESC LIMIT 1 OFFSET ?',
            { serial, Config.HopCap - 1 })
        if cutoff then
            MySQL.query.await(
                'DELETE FROM palm6_counterfeit_hops WHERE serial = ? AND id < ?',
                { serial, cutoff })
        end
    end)
end

-- Newest-first hop chain for a serial (max Config.HopCap rows by design).
local function hopChain(serial)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            [[SELECT id, kind, from_citizenid, from_name, to_citizenid, to_name,
                     detail, created_at
              FROM palm6_counterfeit_hops WHERE serial = ? ORDER BY id DESC]],
            { serial })
    end)
    return ok and rows or {}
end

-- ---------------------------------------------------------------------------
-- District heat
-- ---------------------------------------------------------------------------
local function heatFor(districtId)
    local h = heat[districtId]
    if not h then
        h = { heat = 0.0, lastPing = 0 }
        heat[districtId] = h
    end
    return h
end

local function addHeat(districtId, amount)
    local h = heatFor(districtId)
    h.heat = h.heat + amount
    h.dirty = true
end

-- `inline` is the TEARDOWN path (onResourceStop) and it must not yield even
-- once: MySQL.query.await IS Citizen.Await, and a stopping resource is never
-- ticked again, so a yield here abandons every district after the first. The
-- inline path uses the non-await call form, which only hands the query to
-- oxmysql (a separate, still-running resource) and returns. The live sweep and
-- the seize path keep the awaiting form so they surface DB errors in-line.
local function persistHeat(districtId, inline)
    local h = heat[districtId]
    if not h then return end
    local sql = [[INSERT INTO palm6_counterfeit_heat (district_id, heat, last_ping)
              VALUES (?, ?, ?)
              ON DUPLICATE KEY UPDATE heat = VALUES(heat), last_ping = VALUES(last_ping)]]
    local params = { districtId, h.heat, h.lastPing }
    pcall(function()
        if inline then
            MySQL.query(sql, params)
        else
            MySQL.query.await(sql, params)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- palm6_evidence v2 consumers (frozen sibling API — pcall-guarded so a
-- missing/stopped palm6_evidence degrades to "terminal offline")
-- ---------------------------------------------------------------------------
local function evidenceOnline()
    return Bridge.ResourceStarted('palm6_evidence')
end

local function evEnsureCase(incidentKey, title, createdBy)
    local ok, id = pcall(function()
        return exports.palm6_evidence:EnsureCase(incidentKey, title, createdBy)
    end)
    return ok and id or nil
end

local function evAppendEntry(caseId, kind, payload, source)
    local ok, id = pcall(function()
        return exports.palm6_evidence:AppendEntry(caseId, kind, payload, source)
    end)
    return ok and id or nil
end

local function evLinkSuspect(caseId, citizenid, descriptor)
    local ok, res = pcall(function()
        return exports.palm6_evidence:LinkSuspect(caseId, citizenid, descriptor)
    end)
    return ok and res == true
end

local function evGetCase(caseId)
    local ok, case = pcall(function()
        return exports.palm6_evidence:GetCase(caseId)
    end)
    return ok and case or nil
end

-- ---------------------------------------------------------------------------
-- Printer cache + owner sync
-- ---------------------------------------------------------------------------
local function ownedPrinters(cid)
    local out = {}
    for _, p in pairs(printers) do
        if p.owner == cid then out[#out + 1] = p end
    end
    return out
end

local function syncOwner(src, cid)
    local list = {}
    for _, p in ipairs(ownedPrinters(cid)) do
        list[#list + 1] = { id = p.id, coords = p.coords }
    end
    TriggerClientEvent('palm6_counterfeit:printerSync', src, list)
end

local function removePrinter(p, status)
    Bridge.DeleteWorldProp(p.prop)
    printers[p.id] = nil
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_printers SET status = ?, paper = ?, ink = ?, seized_at = NOW() WHERE id = ?',
            { status, p.paper, p.ink, p.id })
    end)
    -- If the owner is online, drop their interaction zone.
    local ownerSrc = Bridge.GetSourceByCitizenId(p.owner)
    if ownerSrc then syncOwner(ownerSrc, p.owner) end
end

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same pattern as palm6_mdt/server/main.lua:
-- Wait(3000) for oxmysql, per-statement pcall, CREATE TABLE IF NOT EXISTS.
-- sql/ files are applied BY HAND (deploy/README.md; CI never touches the DB),
-- so a fresh box that missed one left every query here pcall-swallowed into
-- silence - printers that vanish on restart, serials with no registry row, a
-- provenance chain that never records, and a "ready" banner reporting nothing
-- wrong. Re-runs are harmless no-ops on the live box, which already has these
-- tables.
--
-- Every statement below is copied VERBATIM from the matching sql/ file so the
-- two can never diverge:
--   palm6_counterfeit_printers, _batches, _wads, _hops, _leads, _heat
--                                       <- sql/0020_counterfeit.sql
--   palm6_counterfeit_fence_quota       <- sql/0052_counterfeit_fence_quota.sql
-- There are no ALTERs on this resource's tables, so schemaOk answers for all
-- seven with no best-effort list.
-- ---------------------------------------------------------------------------
local schemaOk = true

local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_printers` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_citizenid VARCHAR(64) NOT NULL,
    owner_name VARCHAR(100) NOT NULL DEFAULT '',
    district_id VARCHAR(32) NOT NULL,
    coords TEXT NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0.0,
    paper SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    ink SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    status ENUM('placed','removed','seized') NOT NULL DEFAULT 'placed',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    seized_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_counterfeit_printers_owner (owner_citizenid, status),
    INDEX idx_palm6_counterfeit_printers_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_batches` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    code CHAR(6) NOT NULL UNIQUE,
    printer_id INT UNSIGNED NOT NULL,
    printed_by VARCHAR(64) NOT NULL,
    printed_by_name VARCHAR(100) NOT NULL DEFAULT '',
    district_id VARCHAR(32) NOT NULL,
    face_value INT UNSIGNED NOT NULL,
    wads_printed SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    circulation INT UNSIGNED NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_counterfeit_batches_printer (printer_id),
    INDEX idx_palm6_counterfeit_batches_printed_by (printed_by)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_wads` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    serial VARCHAR(20) NOT NULL UNIQUE,
    batch_code CHAR(6) NOT NULL,
    status ENUM('circulating','spent','fenced','burned','seized')
        NOT NULL DEFAULT 'circulating',
    seized_by VARCHAR(64) DEFAULT NULL,
    seized_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_counterfeit_wads_batch (batch_code),
    INDEX idx_palm6_counterfeit_wads_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_hops` (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    serial VARCHAR(20) NOT NULL,
    kind ENUM('print','trade','drop','pickup','sink','fence') NOT NULL,
    from_citizenid VARCHAR(64) DEFAULT NULL,
    from_name VARCHAR(100) NOT NULL DEFAULT '',
    to_citizenid VARCHAR(64) DEFAULT NULL,
    to_name VARCHAR(100) NOT NULL DEFAULT '',
    detail VARCHAR(190) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_counterfeit_hops_serial (serial, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_leads` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    case_id INT UNSIGNED NOT NULL,
    serial VARCHAR(20) NOT NULL,
    batch_code CHAR(6) NOT NULL,
    depth SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_palm6_counterfeit_leads_case_serial (case_id, serial),
    INDEX idx_palm6_counterfeit_leads_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_heat` (
    district_id VARCHAR(32) NOT NULL PRIMARY KEY,
    heat FLOAT NOT NULL DEFAULT 0,
    last_ping INT UNSIGNED NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_counterfeit_fence_quota` (
    `cid`      VARCHAR(64) NOT NULL,
    `fence_id` VARCHAR(64) NOT NULL,
    `day_key`  VARCHAR(8)  NOT NULL,
    `cnt`      INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (`cid`, `fence_id`, `day_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            schemaOk = false
            print(('^1[palm6_counterfeit] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Presence-check every item we hand out or consume. Registration is
    -- declarative (ox_inventory_overrides/data/items.lua ExtraItems);
    -- runtime merges cannot reach ox_inventory (export returns are msgpack
    -- copies) — so a missing item is a deploy error, and the whole resource
    -- self-disables loudly rather than minting items that vanish.
    local missing = {}
    for _, def in pairs(ITEMS) do
        if not Bridge.ItemExists(def.name) then missing[#missing + 1] = def.name end
    end
    for _, sink in ipairs(Config.Sinks) do
        for _, g in ipairs(sink.goods) do
            if not Bridge.ItemExists(g.name) then missing[#missing + 1] = g.name end
        end
    end
    itemsReady = #missing == 0
    if not itemsReady then
        print(('^1[palm6_counterfeit] FATAL: item(s) not registered with ox_inventory: %s. '
            .. 'Add them to ox_inventory_overrides/data/items.lua (ExtraItems) and restart. '
            .. 'The entire resource is disabled until then.^0'):format(table.concat(missing, ', ')))
    end

    -- qbx_police evidence-bag pattern (soft): without the bag items,
    -- /seizefake still seizes — it just cannot produce a physical bag.
    bagsReady = Bridge.ItemExists(Config.EvidenceBag.Empty)
        and Bridge.ItemExists(Config.EvidenceBag.Filled)
    if not bagsReady then
        print('^3[palm6_counterfeit] WARN: qbx_police evidence-bag items '
            .. '(empty_evidence_bag/filled_evidence_bag) not registered — '
            .. '/seizefake will destroy wads without producing a bag.^0')
    end

    if not evidenceOnline() then
        print('^3[palm6_counterfeit] WARN: palm6_evidence is not running — '
            .. 'the serial terminal (/runserial, /interrogate) is offline.^0')
    end

    -- Usable items.
    Bridge.OnUseItem(ITEMS.Printer.name, function(src)
        if not itemsReady then return end
        if not Bridge.GetCitizenId(src) then return end
        -- The client scans for a whitelisted anchor prop (map props are not
        -- visible to the server) and answers with palm6_counterfeit:place.
        TriggerClientEvent('palm6_counterfeit:beginPlacement', src)
    end)

    Bridge.OnUseItem(ITEMS.Pen.name, function(src)
        if not itemsReady then return end
        local cid = Bridge.GetCitizenId(src)
        if not cid then return end
        local left = cdRemaining(cid, 'pen', Config.Pen.CooldownSec)
        if left > 0 then
            Bridge.Notify(src, 'Detector Pen', ('The tip is still wet — %ds.'):format(left), 'error')
            return
        end
        local wads = {}
        for _, it in ipairs(Bridge.ListItemSlots(src, ITEMS.Cash.name)) do
            if it.metadata.serial then wads[#wads + 1] = { serial = it.metadata.serial } end
        end
        if #wads == 0 then
            Bridge.Notify(src, 'Detector Pen', 'No bundled cash on you to test.', 'inform')
            return
        end
        TriggerClientEvent('palm6_counterfeit:pen:pick', src, wads)
    end)

    -- Provenance tap: every approved ox_inventory move of a wad becomes a
    -- hop. The write is deferred to a fresh thread so the DB round-trip
    -- never delays the player's inventory action.
    Bridge.OnItemMoved(ITEMS.Cash.name, function(info)
        if not info.serial then return end
        local kind, fromCid, fromName, toCid, toName
        if info.fromType == 'player' and info.toType == 'player' then
            kind = 'trade'
            fromCid, fromName = info.fromCitizenId, info.fromName
            toCid, toName = info.toCitizenId, info.toName
        elseif info.fromType == 'player' then
            kind = 'drop'
            fromCid, fromName = info.fromCitizenId, info.fromName
            toName = info.toType == 'drop' and 'GROUND' or ('STASH:' .. tostring(info.toId))
        elseif info.toType == 'player' then
            kind = 'pickup'
            toCid, toName = info.toCitizenId, info.toName
            fromName = info.fromType == 'drop' and 'GROUND' or ('STASH:' .. tostring(info.fromId))
        else
            return -- stash-to-stash internals: no player involved, no hop
        end
        local serial = info.serial
        CreateThread(function()
            appendHop(serial, kind, fromCid, fromName, toCid, toName, nil)
            if kind == 'trade' then
                local row = wadWithBatch(serial)
                if row then bumpCirculation(row.batch_code) end
            end
        end)
    end)

    -- Schema + every read that depends on it move into a thread so the DDL
    -- lands before anything SELECTs. Item presence checks and the item/move
    -- handler registration above stay synchronous: those are pure natives, and
    -- a `restart palm6_counterfeit` must not miss a wad move in the ~3s window
    -- (the same reasoning palm6_mdt documents for its alert handler). That
    -- precedent only covers WRITE-ONLY recorders though: palm6_mdt's alert
    -- handler has no in-memory precondition, while palm6_counterfeit:place and
    -- :fence:pass enforce their caps against `printers` / `fenceQuota`, which
    -- are empty until this thread finishes. Those two gate on `bootReady`
    -- below, the same shape palm6_numbers uses for `drawEnabled`.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()

        -- Reload placed printers + district heat.
        pcall(function()
            local rows = MySQL.query.await(
                "SELECT * FROM palm6_counterfeit_printers WHERE status = 'placed'") or {}
            for _, r in ipairs(rows) do
                local coords = json.decode(r.coords)
                local p = {
                    id = r.id, owner = r.owner_citizenid, ownerName = r.owner_name,
                    district = r.district_id, coords = coords,
                    paper = r.paper, ink = r.ink,
                }
                if Config.Printer.SpawnProp then
                    p.prop = Bridge.SpawnWorldProp(Config.Printer.PropModel, coords, r.heading or 0.0)
                end
                printers[p.id] = p
            end
            print(('[palm6_counterfeit] restored %d placed printer(s)'):format(#rows))
        end)
        pcall(function()
            local rows = MySQL.query.await('SELECT * FROM palm6_counterfeit_heat') or {}
            for _, r in ipairs(rows) do
                local dbHeat = tonumber(r.heat) or 0.0
                local dbPing = tonumber(r.last_ping) or 0
                local h = heat[r.district_id]
                if h then
                    -- A sink spend (addHeat via :spend) inside the boot window
                    -- already built this entry up from a zero baseline. A plain
                    -- assignment would throw that accumulation away, so add and
                    -- keep the newer ping.
                    h.heat = h.heat + dbHeat
                    if dbPing > (h.lastPing or 0) then h.lastPing = dbPing end
                    h.dirty = true
                else
                    heat[r.district_id] = { heat = dbHeat, lastPing = dbPing }
                end
            end
        end)

        -- Rehydrate today's fence quota so the per-day cash-out cap survives restart.
        pcall(function()
            local today = os.date('%Y%m%d')
            local rows = MySQL.query.await(
                'SELECT cid, fence_id, cnt FROM palm6_counterfeit_fence_quota WHERE day_key = ?', { today }) or {}
            for _, r in ipairs(rows) do
                fenceQuota[('%s|%s|%s'):format(r.cid, r.fence_id, today)] = tonumber(r.cnt) or 0
            end
        end)

        -- LAST: the cap-bearing net events refuse everything until this flips.
        bootReady = true

        print(('[palm6_counterfeit] ready — items %s, evidence bags %s, %d districts, %d sinks, %d fences, schema %s')
            :format(itemsReady and 'OK' or 'MISSING', bagsReady and 'OK' or 'absent',
                #Config.Districts, #Config.Sinks, #Config.Fences,
                schemaOk and 'OK' or '^1MISSING^0'))
    end)
end)

-- TEARDOWN, and it must not yield even once. MySQL.update.await IS
-- Citizen.Await: that yield propagates out through pcall and out of this
-- handler, and teardown never ticks this resource again, so the old .await form
-- suspended on the FIRST printer and every printer after it - plus the whole
-- heat flush below, which never ran at all - silently lost its unsaved
-- paper/ink and heat. Same fix as palm6_mapeditor/server/live.lua restorePending's
-- inline path: the non-await call form only hands the query to oxmysql (a
-- separate, still-running resource) and returns, so every row leaves this VM
-- before the handler does.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, p in pairs(printers) do
        Bridge.DeleteWorldProp(p.prop)
        pcall(function()
            MySQL.update(
                'UPDATE palm6_counterfeit_printers SET paper = ?, ink = ? WHERE id = ?',
                { p.paper, p.ink, p.id })
        end)
    end
    for districtId in pairs(heat) do persistHeat(districtId, true) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastAction[src] = nil
    pendingPen[src] = nil
    pendingPrint[src] = nil  -- materials already in the machine stay burned
end)

-- ---------------------------------------------------------------------------
-- Heat sweep: decay, persistence, and the vague police ping
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(Config.Heat.SweepSec * 1000)
        local t = now()
        local decay = Config.Heat.DecayPerMin * (Config.Heat.SweepSec / 60)

        for districtId, h in pairs(heat) do
            if h.heat > 0 then
                h.heat = math.max(0, h.heat - decay)
                h.dirty = true
            end

            if h.heat >= Config.Heat.PingThreshold
                and (t - (h.lastPing or 0)) >= Config.Heat.PingCooldownSec then
                h.lastPing = t
                h.dirty = true
                local d = districtById(districtId)
                if d then
                    -- Centre on a live printer in the district when there is
                    -- one, else the district centre — then jitter hard. The
                    -- ping is a WEATHER REPORT, never a waypoint.
                    local cx, cy, cz = d.center.x, d.center.y, d.center.z
                    for _, p in pairs(printers) do
                        if p.district == districtId then
                            cx, cy, cz = p.coords.x, p.coords.y, p.coords.z
                            break
                        end
                    end
                    local j = math.floor(Config.Heat.PingJitter)
                    local coords = {
                        x = cx + math.random(-j, j),
                        y = cy + math.random(-j, j),
                        z = cz,
                    }
                    Bridge.PingPoliceArea(coords, Config.Heat.PingRadius,
                        ('Counterfeit activity suspected — %s area'):format(d.label),
                        Config.HeatBlip.durationSec)
                    -- Public bulletin rides the same threshold+cooldown gate
                    -- as the police ping, and is vaguer: district label
                    -- only, no coordinates, no heat number.
                    discordAnnounce({
                        title = 'COUNTERFEIT BILLS IN CIRCULATION',
                        description = ('Weazel News: merchants around %s report suspicious cash. LSPD has increased patrols in the area.')
                            :format(d.label),
                    })
                    dbg(('heat ping: %s (%.1f)'):format(districtId, h.heat))
                end
            end

            if h.dirty then
                h.dirty = nil
                persistHeat(districtId)
            end
        end

        -- Two-phase janitor: void print/pen sessions whose client never
        -- reported back (crash, script error) so the printer isn't wedged.
        local printMax = Config.Print.CycleSec + Config.Print.GraceSec + 5
        for src, pend in pairs(pendingPrint) do
            if t - pend.startedAt > printMax then
                pendingPrint[src] = nil
                Bridge.Notify(src, 'Printer', 'The cycle jammed — materials wasted.', 'error')
            end
        end
        for src, pend in pairs(pendingPen) do
            if t - pend.startedAt > Config.Pen.MaxCheckSec + 5 then
                pendingPen[src] = nil
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- PLACEMENT (use item -> client anchor scan -> server placement)
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_counterfeit:place', function(anchorModel)
    local src = source
    if not rl(src, 'action') then return end
    if not itemsReady then return end
    -- MaxPerCitizen and MinSpacing below are both enforced against the
    -- in-memory `printers` table, which is empty until the boot thread has
    -- reloaded status='placed' rows. Placing inside that window would pass both
    -- checks against nothing and persist a second press.
    if not bootReady then
        Bridge.Notify(src, 'Printer', 'The block is still waking up. Try again in a moment.', 'error')
        return
    end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    -- Anchor whitelist (the model the client says it found — flavor gate;
    -- see shared/config.lua for why this is not a security boundary).
    if type(anchorModel) ~= 'string' then return end
    local anchored = false
    for _, m in ipairs(Config.Printer.AnchorProps) do
        if m == anchorModel then anchored = true break end
    end
    if not anchored then return end

    -- Placement coords are the player's SERVER-side position. The client
    -- never supplies coordinates.
    local coords = Bridge.GetCoords(src)
    if not coords then return end

    local district = districtAt(coords)
    if not district then
        Bridge.Notify(src, 'Printer', 'Not here — too far off the grid to move paper.', 'error')
        return
    end

    if #ownedPrinters(cid) >= Config.Printer.MaxPerCitizen then
        Bridge.Notify(src, 'Printer', 'You already have a press running. Pick it up first.', 'error')
        return
    end

    for _, p in pairs(printers) do
        if Bridge.Distance(coords, p.coords) < Config.Printer.MinSpacing then
            Bridge.Notify(src, 'Printer', 'Too close to another operation. Find your own corner.', 'error')
            return
        end
    end

    -- In-flight guard (TOCTOU): the INSERT below yields, and the new printer
    -- only lands in `printers` afterwards — without this flag a second place
    -- fired during a slow insert would re-read stale MaxPerCitizen/MinSpacing
    -- state and could double-place. Every exit past this point clears it.
    if placingPrinter[cid] then return end
    placingPrinter[cid] = true

    -- Take the item LAST, after every check passed.
    if not Bridge.RemoveItem(src, ITEMS.Printer.name, 1) then
        placingPrinter[cid] = nil
        Bridge.Notify(src, 'Printer', 'You are not carrying a printer.', 'error')
        return
    end

    local ownerName = Bridge.GetPlayerName(src)
    local ok, id = pcall(function()
        return MySQL.insert.await(
            [[INSERT INTO palm6_counterfeit_printers
                (owner_citizenid, owner_name, district_id, coords, heading, paper, ink, status)
              VALUES (?, ?, ?, ?, 0.0, 0, 0, 'placed')]],
            { cid, ownerName, district.id, json.encode(coords) })
    end)
    if not ok or not id then
        placingPrinter[cid] = nil
        Bridge.GiveItem(src, ITEMS.Printer.name, 1)
        Bridge.Notify(src, 'Printer', 'The floor is uneven — try again.', 'error')
        return
    end

    local p = {
        id = id, owner = cid, ownerName = ownerName,
        district = district.id, coords = coords, paper = 0, ink = 0,
    }
    if Config.Printer.SpawnProp then
        p.prop = Bridge.SpawnWorldProp(Config.Printer.PropModel, coords, 0.0)
    end
    printers[id] = p
    placingPrinter[cid] = nil
    syncOwner(src, cid)
    dbg(('printer #%d placed in %s by %s'):format(id, district.id, cid))
    Bridge.Notify(src, 'Printer',
        ('Press set. Feed it paper and ink. This is %s — the block will feel the heat.'):format(district.label),
        'success')
end)

-- Owner asks for their printer zones (once after spawn; harmless to repeat).
RegisterNetEvent('palm6_counterfeit:requestPrinters', function()
    local src = source
    if not rl(src, 'menu') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    syncOwner(src, cid)
end)

-- Resolve the printer the source may operate: must exist, be theirs, and be
-- within reach (server-side).
local function operablePrinter(src, printerId)
    local p = printers[tonumber(printerId) or -1]
    if not p then return nil end
    local cid = Bridge.GetCitizenId(src)
    if not cid or p.owner ~= cid then return nil end
    if not nearCoords(src, p.coords, Config.InteractRadius + 3.0) then return nil end
    return p, cid
end

RegisterNetEvent('palm6_counterfeit:printer:menu', function(printerId)
    local src = source
    if not rl(src, 'menu') then return end
    local p = operablePrinter(src, printerId)
    if not p then return end
    TriggerClientEvent('palm6_counterfeit:printer:menuData', src, {
        id = p.id,
        paper = p.paper, ink = p.ink,
        maxPaper = Config.Printer.MaxPaper, maxInk = Config.Printer.MaxInk,
        heldPaper = Bridge.CountItem(src, ITEMS.Paper.name),
        heldInk = Bridge.CountItem(src, ITEMS.Ink.name),
        paperPerCycle = Config.Print.PaperPerCycle,
        inkPerCycle = Config.Print.InkPerCycle,
        wadsPerCycle = Config.Print.WadsPerCycle,
    })
end)

RegisterNetEvent('palm6_counterfeit:printer:feed', function(printerId, kind)
    local src = source
    if not rl(src, 'action') then return end
    local p = operablePrinter(src, printerId)
    if not p then return end
    if kind ~= 'paper' and kind ~= 'ink' then return end

    local itemName = kind == 'paper' and ITEMS.Paper.name or ITEMS.Ink.name
    local cap = kind == 'paper' and Config.Printer.MaxPaper or Config.Printer.MaxInk
    local current = kind == 'paper' and p.paper or p.ink
    local held = Bridge.CountItem(src, itemName)
    local space = cap - current
    local feed = math.min(held, space)
    if feed <= 0 then
        Bridge.Notify(src, 'Printer',
            held == 0 and 'You are not carrying any.' or 'The hopper is full.', 'error')
        return
    end
    if not Bridge.RemoveItem(src, itemName, feed) then return end

    if kind == 'paper' then p.paper = p.paper + feed else p.ink = p.ink + feed end
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_printers SET paper = ?, ink = ? WHERE id = ?',
            { p.paper, p.ink, p.id })
    end)
    Bridge.Notify(src, 'Printer',
        ('Fed %d %s. Hopper: %d paper / %d ink.'):format(feed, kind, p.paper, p.ink), 'success')
end)

-- ---------------------------------------------------------------------------
-- PRINT CYCLE (two-phase: start -> progress bar -> finish)
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_counterfeit:printer:start', function(printerId)
    local src = source
    if not rl(src, 'print') then return end
    if not itemsReady then return end
    if pendingPrint[src] then return end
    local p, cid = operablePrinter(src, printerId)
    if not p then return end

    local left = cdRemaining(cid, 'print', Config.Print.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, 'Printer', ('The plates need to cool — %ds.'):format(left), 'error')
        return
    end
    if p.paper < Config.Print.PaperPerCycle or p.ink < Config.Print.InkPerCycle then
        Bridge.Notify(src, 'Printer',
            ('A cycle takes %d paper + %d ink. Hopper: %d / %d.')
            :format(Config.Print.PaperPerCycle, Config.Print.InkPerCycle, p.paper, p.ink), 'error')
        return
    end

    -- Materials leave the hopper at START; a blown window wastes them.
    -- pendingPrint is set BEFORE the DB await below: the guard at the top of
    -- this handler reads it, and the await yields — setting it afterwards
    -- would let a second start slip past the guard and double-deduct.
    p.paper = p.paper - Config.Print.PaperPerCycle
    p.ink = p.ink - Config.Print.InkPerCycle
    pendingPrint[src] = {
        printerId = p.id, cid = cid,
        startedAt = now(), startCoords = Bridge.GetCoords(src),
    }
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_printers SET paper = ?, ink = ? WHERE id = ?',
            { p.paper, p.ink, p.id })
    end)

    -- Re-stamp AFTER the await: the client's progress bar starts when
    -- beginPrint arrives, so DB latency must not eat into the finish window.
    -- (playerDropped may have cleared the entry while we were yielded.)
    local pend = pendingPrint[src]
    if not pend then return end
    pend.startedAt = now()
    TriggerClientEvent('palm6_counterfeit:beginPrint', src, Config.Print.CycleSec)
end)

RegisterNetEvent('palm6_counterfeit:printer:finish', function()
    local src = source
    local pend = pendingPrint[src]
    if not pend then return end
    pendingPrint[src] = nil

    -- Two-phase window: min AND max elapsed, server clock.
    local elapsed = now() - pend.startedAt
    if elapsed < Config.Print.CycleSec - 1
        or elapsed > Config.Print.CycleSec + Config.Print.GraceSec then
        Bridge.Notify(src, 'Printer', 'You rushed the run — pulp.', 'error')
        return
    end

    local p = printers[pend.printerId]
    if not p or p.owner ~= pend.cid then return end

    -- Fresh proximity + position anchor: the progress bar locks movement
    -- client-side; a client that skipped it to move through the window
    -- fails the anchor and eats the materials.
    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, p.coords) > Config.InteractRadius + 3.0 then return end
    if pend.startCoords and Bridge.Distance(here, pend.startCoords) > Config.Print.AnchorRadius then
        Bridge.Notify(src, 'Printer', 'You stepped off the press mid-run — pulp.', 'error')
        return
    end

    -- Mint the batch. This is the ONLY place a serial is born.
    local code = makeBatchCode()
    local name = Bridge.GetPlayerName(src)
    local district = districtById(p.district)
    local okB = pcall(function()
        MySQL.insert.await(
            [[INSERT INTO palm6_counterfeit_batches
                (code, printer_id, printed_by, printed_by_name, district_id, face_value, wads_printed, circulation)
              VALUES (?, ?, ?, ?, ?, ?, 0, 0)]],
            { code, p.id, pend.cid, name, p.district, Config.Print.FaceValue })
    end)
    if not okB then
        Bridge.Notify(src, 'Printer', 'The run smeared — nothing usable.', 'error')
        return
    end

    local delivered = 0
    for i = 1, Config.Print.WadsPerCycle do
        local serial = makeSerial(code, i)
        if not Bridge.GiveItem(src, ITEMS.Cash.name, 1, wadMetadata(serial, code)) then break end
        delivered = delivered + 1
        pcall(function()
            MySQL.insert.await(
                "INSERT INTO palm6_counterfeit_wads (serial, batch_code, status) VALUES (?, ?, 'circulating')",
                { serial, code })
        end)
        appendHop(serial, 'print', nil, 'THE PRESS', pend.cid, name,
            ('batch %s — %s'):format(code, district and district.label or p.district))
    end
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_batches SET wads_printed = ? WHERE code = ?', { delivered, code })
    end)

    setCooldown(pend.cid, 'print')
    addHeat(p.district, Config.Heat.PerCycle)

    if delivered == 0 then
        Bridge.Notify(src, 'Printer', 'Your pockets are stuffed — the tray jammed and the run is ruined.', 'error')
        return
    end
    Bridge.Notify(src, 'Printer',
        ('%d wads off the press — batch %s. Small batches stay crisp; every hand they touch wears them down.')
        :format(delivered, code), 'success')

    -- Persistent police attention: running a press is a federal-flavoured crime.
    -- Distinct from the DISTRICT heat added above, which is this resource's own
    -- transient zone-ping model. This is the durable per-character score that
    -- follows the printer after they log. Keyed to the printer's own cid, and
    -- placed AFTER the delivered == 0 bail so a jammed run (pockets full, no
    -- wads handed over) scores nothing. Soft-dep + pcall: a stopped palm6_heat
    -- never touches the print path.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(pend.cid, HEAT_ON_PRINT, 'counterfeit', name)
        end)
    end

    dbg(('batch %s: %d wads by %s in %s'):format(code, delivered, pend.cid, p.district))
end)

RegisterNetEvent('palm6_counterfeit:printer:cancel', function()
    local src = source
    local pend = pendingPrint[src]
    if not pend then return end
    pendingPrint[src] = nil
    -- Player-cancelled: the sheets go back in the hopper.
    local p = printers[pend.printerId]
    if not p then return end
    p.paper = math.min(Config.Printer.MaxPaper, p.paper + Config.Print.PaperPerCycle)
    p.ink = math.min(Config.Printer.MaxInk, p.ink + Config.Print.InkPerCycle)
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_counterfeit_printers SET paper = ?, ink = ? WHERE id = ?',
            { p.paper, p.ink, p.id })
    end)
end)

RegisterNetEvent('palm6_counterfeit:printer:pickup', function(printerId)
    local src = source
    if not rl(src, 'action') then return end
    local p = operablePrinter(src, printerId)
    if not p then return end
    if pendingPrint[src] then return end

    if not Bridge.GiveItem(src, ITEMS.Printer.name, 1) then
        Bridge.Notify(src, 'Printer', 'Your hands are full — it stays put.', 'error')
        return
    end
    removePrinter(p, 'removed')
    Bridge.Notify(src, 'Printer', 'Packed up. Whatever was in the hopper is gone.', 'success')
end)

-- ---------------------------------------------------------------------------
-- SINKS — spend a wad on goods (never money)
-- ---------------------------------------------------------------------------
local function listHeldWads(src)
    local out = {}
    for _, it in ipairs(Bridge.ListItemSlots(src, ITEMS.Cash.name)) do
        if it.metadata.serial then out[#out + 1] = { serial = it.metadata.serial } end
    end
    return out
end

RegisterNetEvent('palm6_counterfeit:sink:menu', function(sinkId)
    local src = source
    if not rl(src, 'menu') then return end
    local sink = sinkById(sinkId)
    if not sink then return end
    if not nearCoords(src, sink.coords, Config.InteractRadius + 3.0) then return end
    if not Bridge.GetCitizenId(src) then return end
    TriggerClientEvent('palm6_counterfeit:sink:menuData', src, sinkId, listHeldWads(src))
end)

RegisterNetEvent('palm6_counterfeit:sink:spend', function(sinkId, serial)
    local src = source
    if not rl(src, 'action') then return end
    if not itemsReady then return end
    if type(serial) ~= 'string' then return end
    local sink = sinkById(sinkId)
    if not sink then return end
    if not nearCoords(src, sink.coords, Config.InteractRadius + 3.0) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local left = cdRemaining(cid, 'sink', Config.Sink.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, sink.label, ('"Not so fast. Come back in %ds."'):format(left), 'error')
        return
    end

    local row = wadWithBatch(serial)
    if not row or row.status ~= 'circulating' then return end
    local slot = findWadSlot(src, serial)
    if not slot then return end

    -- Pre-check the basket fits before anything is consumed.
    for _, g in ipairs(sink.goods) do
        if not Bridge.CanCarry(src, g.name, g.count) then
            Bridge.Notify(src, sink.label, '"Your arms are full. Come back lighter."', 'error')
            return
        end
    end

    setCooldown(cid, 'sink')
    local name = Bridge.GetPlayerName(src)

    -- The vendor's eye sharpens as the batch wears: quality decays with
    -- greed (circulation), server-rolled.
    local detectP = math.min(Config.Sink.DetectCap,
        Config.Sink.DetectBase + row.circulation * Config.Sink.DetectPerHop)
    if math.random() < detectP then
        local kept = math.random() < Config.Sink.KeepOnDetect
        if kept then
            if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
            setWadStatus(serial, 'burned')
            appendHop(serial, 'sink', cid, name, nil, sink.label, 'caught and kept by vendor')
        else
            appendHop(serial, 'sink', cid, name, nil, sink.label, 'caught and handed back')
        end
        bumpCirculation(row.batch_code)
        if math.random() < Config.Sink.PoliceCallChance then
            Bridge.PoliceAlert(src, ('Counterfeit currency passed at %s'):format(sink.label))
        end
        Bridge.Notify(src, sink.label,
            kept and '"This ink SMEARS. I\'m keeping it. Get out."'
                or '"Nice try. Take your funny money and go."', 'error')
        return
    end

    -- Clean pass: wad for goods.
    if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
    for _, g in ipairs(sink.goods) do
        Bridge.GiveItem(src, g.name, g.count)
    end
    setWadStatus(serial, 'spent')
    appendHop(serial, 'sink', cid, name, nil, sink.label, 'spent on goods')
    bumpCirculation(row.batch_code)
    addHeat(sink.district, Config.Heat.PerSpend)
    Bridge.Notify(src, sink.label, '"Pleasure doing business." The bundle disappears under the counter.', 'success')
end)

-- ---------------------------------------------------------------------------
-- FENCES — the only cash-out, per-wad, quota'd, and batch-history priced
-- ---------------------------------------------------------------------------
local function quotaKey(cid, fenceId)
    return ('%s|%s|%s'):format(cid, fenceId, os.date('%Y%m%d'))
end

local function rejectChance(row)
    local sizeOver = math.max(0, (row.wads_printed or 0) - Config.Fence.SmallBatch)
    return math.min(Config.Fence.RejectCap,
        Config.Fence.RejectBase
        + row.circulation * Config.Fence.RejectPerHop
        + sizeOver * Config.Fence.RejectPerWadOver)
end

RegisterNetEvent('palm6_counterfeit:fence:menu', function(fenceId)
    local src = source
    if not rl(src, 'menu') then return end
    local fence = fenceById(fenceId)
    if not fence then return end
    if not nearCoords(src, fence.coords, Config.InteractRadius + 3.0) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local offer = math.floor(Config.Print.FaceValue * Config.Fence.Rate)
    local used = fenceQuota[quotaKey(cid, fenceId)] or 0
    local out = {}
    -- ONE batched lookup for every held serial — a per-wad wadWithBatch()
    -- loop here would let a wad-stuffed inventory turn each menu open into
    -- N JOIN queries (cheap DB DoS pressure through the 1s menu limit).
    local held = listHeldWads(src)
    if #held > 0 then
        local serials, marks = {}, {}
        for i, w in ipairs(held) do
            serials[i] = w.serial
            marks[i] = '?'
        end
        local okq, rows = pcall(function()
            return MySQL.query.await(
                ([[SELECT w.serial, w.status, b.circulation
                   FROM palm6_counterfeit_wads w
                   JOIN palm6_counterfeit_batches b ON b.code = w.batch_code
                   WHERE w.serial IN (%s)]]):format(table.concat(marks, ',')),
                serials)
        end)
        if okq and type(rows) == 'table' then
            for _, row in ipairs(rows) do
                if row.status == 'circulating' then
                    out[#out + 1] = {
                        serial = row.serial,
                        offer = offer,
                        remark = ('Feels %s.'):format(wearBand(row.circulation)),
                    }
                end
            end
        end
    end
    TriggerClientEvent('palm6_counterfeit:fence:menuData', src, fenceId, out, {
        quotaLeft = math.max(0, Config.Fence.DailyQuota - used),
    })
end)

RegisterNetEvent('palm6_counterfeit:fence:pass', function(fenceId, serial)
    local src = source
    if not rl(src, 'action') then return end
    if type(serial) ~= 'string' then return end
    local fence = fenceById(fenceId)
    if not fence then return end
    if not nearCoords(src, fence.coords, Config.InteractRadius + 3.0) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local left = cdRemaining(cid, 'fence', Config.Fence.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, fence.label, ('"Slow down. %ds."'):format(left), 'error')
        return
    end
    -- The daily cap below reads `fenceQuota`, which sql/0052 exists to rehydrate
    -- precisely because an in-memory counter reset to 0 on every reboot is a
    -- money faucet. Refusing until the boot thread has read it back keeps that
    -- faucet closed for the ~3s window too.
    if not bootReady then
        Bridge.Notify(src, fence.label, '"Not right now. Come back in a minute."', 'error')
        return
    end
    local qk = quotaKey(cid, fenceId)
    if (fenceQuota[qk] or 0) >= Config.Fence.DailyQuota then
        Bridge.Notify(src, fence.label, '"I\'ve moved enough of your paper today. Tomorrow."', 'error')
        return
    end

    local row = wadWithBatch(serial)
    if not row or row.status ~= 'circulating' then return end
    local slot = findWadSlot(src, serial)
    if not slot then return end

    setCooldown(cid, 'fence')
    fenceQuota[qk] = (fenceQuota[qk] or 0) + 1  -- attempts count against quota
    -- Persist the attempt so the daily quota survives a restart (an in-memory
    -- counter reset to 0 on every reboot would defeat the per-day cap).
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_counterfeit_fence_quota (cid, fence_id, day_key, cnt) VALUES (?, ?, ?, 1) '
            .. 'ON DUPLICATE KEY UPDATE cnt = cnt + 1',
            { cid, fenceId, os.date('%Y%m%d') })
    end)
    local name = Bridge.GetPlayerName(src)

    -- Quality decays with greed: rejection rises with the batch's
    -- circulation AND its print size. Server-rolled.
    if math.random() < rejectChance(row) then
        local kept = math.random() < Config.Fence.KeepOnReject
        if kept then
            if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
            setWadStatus(serial, 'burned')
            appendHop(serial, 'fence', cid, name, nil, fence.label, 'rejected and kept')
        else
            appendHop(serial, 'fence', cid, name, nil, fence.label, 'rejected')
        end
        bumpCirculation(row.batch_code)
        -- Same alert plumbing as qbx_drugs cornerselling's policeCallChance.
        if math.random() < Config.Fence.PoliceCallChance then
            Bridge.PoliceAlert(src, 'Counterfeit currency offered to a local business')
        end
        Bridge.Notify(src, fence.label,
            kept and ('"This is %s. I\'m keeping it so nobody dumber takes it."'):format(wearBand(row.circulation))
                or '"I know wallpaper when I feel it. Walk."', 'error')
        return
    end

    if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
    local payout = math.floor((row.face_value or Config.Print.FaceValue) * Config.Fence.Rate)
    Bridge.AddCash(src, payout, 'counterfeit-fence')
    setWadStatus(serial, 'fenced')
    appendHop(serial, 'fence', cid, name, nil, fence.label, ('passed for $%d'):format(payout))
    bumpCirculation(row.batch_code)
    Bridge.Notify(src, fence.label, ('"$%d. It never touched your hands."'):format(payout), 'success')
end)

-- ---------------------------------------------------------------------------
-- DETECTOR PEN (two-phase: pick -> skill check -> registry verdict)
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_counterfeit:pen:start', function(serial)
    local src = source
    if not rl(src, 'action') then return end
    if type(serial) ~= 'string' then return end
    if pendingPen[src] then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not findWadSlot(src, serial) then return end
    if Bridge.CountItem(src, ITEMS.Pen.name) < 1 then return end

    setCooldown(cid, 'pen')
    pendingPen[src] = { serial = serial, startedAt = now(), cid = cid }
    TriggerClientEvent('palm6_counterfeit:pen:begin', src, serial)
end)

RegisterNetEvent('palm6_counterfeit:pen:finish', function(serial, passed)
    local src = source
    local pend = pendingPen[src]
    if not pend or pend.serial ~= serial then return end
    pendingPen[src] = nil

    local elapsed = now() - pend.startedAt
    if elapsed < 1 or elapsed > Config.Pen.MaxCheckSec then return end

    -- TRUST BOUNDARY: `passed` is the client-side skill-check outcome and a
    -- modified client can always send true. Deliberate flavor, not a
    -- security gate — the verdict only reveals registry truth about a wad
    -- the caller already physically holds (possession re-checked below).
    if not passed then
        Bridge.Notify(src, 'Detector Pen', 'The stroke smudged — inconclusive.', 'error')
        return
    end
    if not findWadSlot(src, serial) then return end

    local row = wadWithBatch(serial)
    local title, body
    if not row then
        title = 'Detector Pen: CRUDE FAKE'
        body = 'The mark blooms black instantly. This is not even good counterfeit — no registry record, no pedigree. Toilet paper.'
    else
        title = 'Detector Pen: COUNTERFEIT'
        body = ('The mark turns dark amber. Serial **%s** — the paper feels **%s** (%d hands so far). Every hand it passes through is one more name it remembers.')
            :format(row.serial, wearBand(row.circulation), row.circulation)
    end
    TriggerClientEvent('palm6_counterfeit:report', src, title, body)
end)

-- ---------------------------------------------------------------------------
-- POLICE — seizure (qbx_police evidence-bag pattern)
-- ---------------------------------------------------------------------------
RegisterCommand('seizefake', function(src, _)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Counterfeit', 'You need to be on duty as police.', 'error')
        return
    end
    if not rl(src, 'police') then return end
    local wads = listHeldWads(src)
    if #wads == 0 then
        Bridge.Notify(src, 'Counterfeit', 'No bundled cash on you. Search the suspect and take it first.', 'inform')
        return
    end
    TriggerClientEvent('palm6_counterfeit:police:pickSeize', src, wads)
end, false)

RegisterNetEvent('palm6_counterfeit:police:bag', function(serial)
    local src = source
    if not rl(src, 'police') then return end
    if type(serial) ~= 'string' then return end
    if not Bridge.IsOnDutyPolice(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local slot = findWadSlot(src, serial)
    if not slot then return end
    local row = wadWithBatch(serial)

    -- The evidence-bag flow mirrors qbx_police: consume an empty bag,
    -- produce a filled bag whose metadata describes the exhibit. Soft:
    -- without the bag items the wad is still seized and registered.
    local bagged = false
    if bagsReady and Bridge.CountItem(src, Config.EvidenceBag.Empty) >= 1 then
        if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
        Bridge.RemoveItem(src, Config.EvidenceBag.Empty, 1)
        bagged = Bridge.GiveItem(src, Config.EvidenceBag.Filled, 1, {
            type = 'Counterfeit Currency',
            serial = serial,
            batch = row and row.batch_code or 'unregistered',
            description = ('Counterfeit bundle, serial %s. Run at the evidence terminal: /runserial %s')
                :format(serial, serial),
        })
    else
        if not Bridge.RemoveItemBySlot(src, ITEMS.Cash.name, slot) then return end
    end

    if row then setWadStatus(serial, 'seized', cid) end
    Bridge.Notify(src, 'Counterfeit',
        bagged and ('Bagged. Run the serial at the evidence locker: /runserial %s'):format(serial)
        or ('Seized (no evidence bag on you). Run the serial at the evidence locker: /runserial %s'):format(serial),
        'success')
end)

-- ---------------------------------------------------------------------------
-- POLICE — the serial terminal + the cascade (palm6_evidence v2 consumer)
-- ---------------------------------------------------------------------------
local function atTerminal(src)
    return nearCoords(src, Config.Police.TerminalCoords, Config.Police.TerminalRadius + 3.0)
end

-- Reveal hops (fromIdx..toIdx, newest-first indexing) into the case as
-- named leads, linking every citizen that appears. Returns names revealed.
local function revealHops(caseId, serial, hops, fromIdx, toIdx)
    local names = {}
    for i = fromIdx, math.min(toIdx, #hops) do
        local h = hops[i]
        evAppendEntry(caseId, 'lead', {
            serial = serial, hop = i, kind = h.kind,
            from = h.from_name, from_citizenid = h.from_citizenid,
            to = h.to_name, to_citizenid = h.to_citizenid,
            detail = h.detail, at = tostring(h.created_at),
        }, 'palm6_counterfeit')
        if h.from_citizenid then
            evLinkSuspect(caseId, h.from_citizenid, nil)
            names[#names + 1] = h.from_name
        end
        if h.to_citizenid then
            evLinkSuspect(caseId, h.to_citizenid, nil)
            names[#names + 1] = h.to_name
        end
    end
    return names
end

local function leadRow(caseId, serial)
    local ok, row = pcall(function()
        return MySQL.single.await(
            'SELECT * FROM palm6_counterfeit_leads WHERE case_id = ? AND serial = ?',
            { caseId, serial })
    end)
    return ok and row or nil
end

RegisterCommand('runserial', function(src, args)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Serial Terminal', 'You need to be on duty as police.', 'error')
        return
    end
    local serial = args[1] and args[1]:upper() or nil
    if not serial or not serial:match('^CF%-[A-Z0-9]+%-%d+$') then
        Bridge.Notify(src, 'Serial Terminal', 'Usage: /runserial CF-XXXXXX-NN', 'error')
        return
    end
    if not atTerminal(src) then
        Bridge.Notify(src, 'Serial Terminal', 'The terminal is at the evidence locker.', 'error')
        return
    end
    if not rl(src, 'police') then return end
    if not evidenceOnline() then
        Bridge.Notify(src, 'Serial Terminal', 'Records system offline (palm6_evidence not running).', 'error')
        return
    end

    local row = wadWithBatch(serial)
    if not row then
        Bridge.Notify(src, 'Serial Terminal', 'No registry record. This one is not ours to trace.', 'inform')
        return
    end
    if row.status ~= 'seized' then
        Bridge.Notify(src, 'Serial Terminal', 'That serial has not been seized into evidence. /seizefake first.', 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src) or 'unknown'
    local district = districtById(row.district_id)
    local caseId = evEnsureCase(
        Config.Police.IncidentKeyPrefix .. row.batch_code,
        Config.Police.CaseTitle:format(row.batch_code), cid)
    if not caseId then
        Bridge.Notify(src, 'Serial Terminal', 'Case system rejected the write — try again.', 'error')
        return
    end

    local hops = hopChain(serial)
    if #hops == 0 then
        evAppendEntry(caseId, 'note',
            ('Serial %s seized — provenance chain empty (the paper moved too many hands; the trail wore off).'):format(serial),
            'palm6_counterfeit')
        Bridge.Notify(src, 'Serial Terminal',
            ('Case #%d. The chain on %s has worn blank — no leads.'):format(caseId, serial), 'inform')
        return
    end

    local existing = leadRow(caseId, serial)
    if existing then
        Bridge.Notify(src, 'Serial Terminal',
            ('Serial already traced on case #%d (%d of %d hops unlocked). Interrogate a linked suspect to go deeper: /interrogate %d <citizenid>')
            :format(caseId, existing.depth, #hops, caseId), 'inform')
        return
    end

    local depth = math.min(Config.Police.LeadsPerRun, #hops)
    evAppendEntry(caseId, 'fact', {
        serial = serial, batch = row.batch_code,
        batch_size = row.wads_printed, circulation = row.circulation,
        district = district and district.label or row.district_id,
        note = 'Serial trace initiated at the evidence terminal.',
    }, 'palm6_counterfeit')
    local names = revealHops(caseId, serial, hops, 1, depth)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_counterfeit_leads (case_id, serial, batch_code, depth) VALUES (?, ?, ?, ?)',
            { caseId, serial, row.batch_code, depth })
    end)

    local who = #names > 0 and table.concat(names, ', ') or 'no named subjects'
    Bridge.Notify(src, 'Serial Terminal',
        ('Case #%d — batch %s. Last %d hop(s) unlocked: %s. Deeper hops need an interrogation. /evidence case %d')
        :format(caseId, row.batch_code, depth, who, caseId), 'success')
end, false)

RegisterCommand('interrogate', function(src, args)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Counterfeit', 'You need to be on duty as police.', 'error')
        return
    end
    local caseId = tonumber(args[1])
    local targetCid = args[2]
    if not caseId or not targetCid then
        Bridge.Notify(src, 'Counterfeit', 'Usage: /interrogate <case id> <citizenid>', 'error')
        return
    end
    if not rl(src, 'police') then return end
    if not evidenceOnline() then
        Bridge.Notify(src, 'Counterfeit', 'Records system offline (palm6_evidence not running).', 'error')
        return
    end

    -- The pressed suspect must be a real person, in the room, and already a
    -- named lead on this case. Distance is server-side.
    local targetSrc = Bridge.GetSourceByCitizenId(targetCid)
    if not targetSrc then
        Bridge.Notify(src, 'Counterfeit', 'That citizen is not around to press.', 'error')
        return
    end
    local myCoords, theirCoords = Bridge.GetCoords(src), Bridge.GetCoords(targetSrc)
    if not myCoords or not theirCoords
        or Bridge.Distance(myCoords, theirCoords) > Config.Police.InterrogateRadius then
        Bridge.Notify(src, 'Counterfeit', 'Get them in front of you first.', 'error')
        return
    end

    local case = evGetCase(caseId)
    if not case then
        Bridge.Notify(src, 'Counterfeit', 'No such case.', 'error')
        return
    end
    local isSuspect = false
    for _, s in ipairs(case.suspects or {}) do
        if s.citizenid == targetCid then isSuspect = true break end
    end
    if not isSuspect then
        Bridge.Notify(src, 'Counterfeit', 'They are not a named lead on that case. Trace a serial first.', 'error')
        return
    end

    -- Cascade: for every serial traced on this case where the pressed
    -- citizen appears in the ALREADY-unlocked hops, unlock the next hop(s).
    local okQ, rows = pcall(function()
        return MySQL.query.await(
            'SELECT * FROM palm6_counterfeit_leads WHERE case_id = ?', { caseId })
    end)
    if not okQ or not rows then return end

    local revealed = {}
    for _, lr in ipairs(rows) do
        local hops = hopChain(lr.serial)
        if lr.depth < #hops then
            local appears = false
            for i = 1, math.min(lr.depth, #hops) do
                local h = hops[i]
                if h.from_citizenid == targetCid or h.to_citizenid == targetCid then
                    appears = true
                    break
                end
            end
            if appears then
                local newDepth = math.min(lr.depth + Config.Police.LeadsPerPress, #hops)
                local names = revealHops(caseId, lr.serial, hops, lr.depth + 1, newDepth)
                pcall(function()
                    MySQL.update.await(
                        'UPDATE palm6_counterfeit_leads SET depth = ? WHERE id = ?',
                        { newDepth, lr.id })
                end)
                for _, n in ipairs(names) do revealed[#revealed + 1] = n end
                -- The deepest hop is the print itself — closing the loop
                -- names the batch's press district in the case file.
                if newDepth >= #hops and hops[#hops].kind == 'print' then
                    local wrow = wadWithBatch(lr.serial)
                    local district = wrow and districtById(wrow.district_id)
                    evAppendEntry(caseId, 'fact', {
                        serial = lr.serial,
                        note = ('Chain closed: printed in %s. Sweep the district and /counterfeitraid the press.')
                            :format(district and district.label or 'an unknown district'),
                    }, 'palm6_counterfeit')
                end
            end
        end
    end

    if #revealed == 0 then
        evAppendEntry(caseId, 'note',
            ('Interrogated %s — gave up nothing new.'):format(targetCid), 'palm6_counterfeit')
        Bridge.Notify(src, 'Counterfeit', 'They gave up nothing new. Find another serial or another mouth.', 'inform')
    else
        Bridge.Notify(src, 'Counterfeit',
            ('They talked. New names on case #%d: %s. /evidence case %d')
            :format(caseId, table.concat(revealed, ', '), caseId), 'success')
    end
    Bridge.Notify(targetSrc, 'Interrogation',
        'Police pressed you about paper money. Somebody upstream should hear about this.', 'inform')
end, false)

RegisterCommand('counterfeitraid', function(src, _)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Counterfeit', 'You need to be on duty as police.', 'error')
        return
    end
    if not rl(src, 'police') then return end
    local coords = Bridge.GetCoords(src)
    if not coords then return end

    local found = nil
    for _, p in pairs(printers) do
        if Bridge.Distance(coords, p.coords) <= Config.Police.RaidRadius then
            found = p
            break
        end
    end
    if not found then
        Bridge.Notify(src, 'Counterfeit', 'No press within reach. Keep looking.', 'error')
        return
    end

    removePrinter(found, 'seized')
    if Config.Police.RaidHeatClear then
        local h = heatFor(found.district)
        h.heat = 0
        persistHeat(found.district)
    end

    -- Fold the raid into the batch case(s) this press produced.
    if evidenceOnline() then
        local okB, latest = pcall(function()
            return MySQL.single.await(
                'SELECT code FROM palm6_counterfeit_batches WHERE printer_id = ? ORDER BY id DESC LIMIT 1',
                { found.id })
        end)
        local district = districtById(found.district)
        local caseId = evEnsureCase(
            Config.Police.IncidentKeyPrefix .. ((okB and latest and latest.code) or ('printer-' .. found.id)),
            Config.Police.CaseTitle:format((okB and latest and latest.code) or ('press #' .. found.id)),
            Bridge.GetCitizenId(src) or 'unknown')
        if caseId then
            evAppendEntry(caseId, 'fact', {
                note = ('Printing press seized in %s.'):format(district and district.label or found.district),
                owner = found.ownerName,
                owner_citizenid = found.owner,
            }, 'palm6_counterfeit')
            evLinkSuspect(caseId, found.owner, nil)
            Bridge.Notify(src, 'Counterfeit',
                ('Press seized — logged to case #%d (owner: %s).'):format(caseId, found.ownerName), 'success')
            return
        end
    end
    Bridge.Notify(src, 'Counterfeit', ('Press seized (owner: %s).'):format(found.ownerName), 'success')
end, false)

-- ---------------------------------------------------------------------------
-- Admin status (ace: command.counterfeit)
--   add_ace group.admin command.counterfeit allow
-- ---------------------------------------------------------------------------
RegisterCommand('counterfeit', function(src, _)
    local nPrinters, lines = 0, {}
    for _, p in pairs(printers) do
        nPrinters = nPrinters + 1
        lines[#lines + 1] = ('#%d %s (%s) paper %d ink %d'):format(p.id, p.district, p.ownerName, p.paper, p.ink)
    end
    local heatLines = {}
    for id, h in pairs(heat) do
        if h.heat > 0.5 then heatLines[#heatLines + 1] = ('%s %.1f'):format(id, h.heat) end
    end
    Bridge.Notify(src, 'Counterfeit',
        ('%d press(es): %s | heat: %s'):format(nPrinters,
            #lines > 0 and table.concat(lines, '; ') or 'none',
            #heatLines > 0 and table.concat(heatLines, ', ') or 'cold'),
        'inform')
end, true)
