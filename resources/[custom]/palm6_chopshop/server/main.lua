-- ============================================================================
-- palm6_chopshop/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The recipe's `qbx_vehiclekeys` already ships real vehicle theft (hotwiring,
-- carjacking — both alert police via SendPoliceAlertAttempt) but it's
-- entirely ephemeral: no economic payoff for the thief, no persistent
-- "this plate was reported stolen" registry, no paper trail. This resource
-- is that registry + the economy — it never touches the theft mechanic
-- itself. Same "recipe owns the verb, custom layer owns the consequence"
-- pattern as palm6_ransom (kidnap) and palm6_gunrunning (ballistics).
--
-- qbx_police's own `/flagplate` is a separate, purely in-memory, manual
-- staff-driven flag (a private local `Plates` table with no export, no
-- persistence, resets on resource restart) — this resource does not (and
-- cannot, no export exists) write into it. `palm6_chopshop_stolen` is its
-- own independent, persistent, queryable registry; palm6_mdt now surfaces it
-- via `/runplate`, reading the additive IsStolen export at the bottom of this
-- file. That is a READ-ONLY integration in the correct direction: this
-- resource publishes a frozen-signature export and knows nothing about the
-- MDT, exactly like GetSummary.
-- ============================================================================

local lastAction = {} -- [src] = { [key] = ts } — chat-command spam guard

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same shape as palm6_courier/palm6_ems:
-- per-statement pcall, everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with neither
-- chop-shop table. Every query in this file is pcall-guarded, so that is not an
-- error, it is SILENCE: /reportstolen answers "could not file the report",
-- /sellstolen refuses every car with "this one's clean", the MDT's /runplate
-- reports every plate as not stolen, and the boot banner reports 0/0 as though
-- the shop were simply quiet. On the live box these statements are pure no-ops.
--
-- Both statements are copied VERBATIM from sql/0032_chopshop.sql (trailing `;`
-- dropped so oxmysql sees a single statement each). Only these two tables are
-- created here: `player_vehicles` is qbx_core's, owned by the framework, and
-- this resource only ever reads/deletes rows in it.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_chopshop_stolen` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plate VARCHAR(15) NOT NULL,
    owner_citizenid VARCHAR(64) NOT NULL,
    status ENUM('active', 'resolved', 'expired') NOT NULL DEFAULT 'active',
    reported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_chopshop_stolen_plate_status (plate, status),
    INDEX idx_palm6_chopshop_stolen_owner (owner_citizenid)
)
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_chopshop_sales` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    seller_citizenid VARCHAR(64) NOT NULL,
    plate VARCHAR(15) NOT NULL,
    vehicle_class TINYINT UNSIGNED NOT NULL,
    payout INT UNSIGNED NOT NULL,
    was_stolen TINYINT(1) NOT NULL DEFAULT 0,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    sold_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_chopshop_sales_seller (seller_citizenid)
)
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_chopshop] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_chopshop] ' .. msg) end
end

local function rl(src, key, window)
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- ---------------------------------------------------------------------------
-- The fence's heat haircut. Returns (multiplier, tier): 1.0 and nil whenever
-- the flag is off, palm6_heat is not started, the export throws or returns a
-- non-string, or the tier carries no entry, so every failure mode lands on
-- exactly today's flat class payout.
--
-- Read through GetTier ONLY. palm6_heat stores heat alongside an updated_at and
-- settles the decay on READ, so a direct palm6_heat_state query would report a
-- citizen who has long since cooled off as still WANTED.
--
-- Clamped to [Floor, 1.0]. The upper clamp is the anti-farm guarantee in code
-- rather than in a comment: whatever Config.HeatPayout.Mult says, this function
-- cannot return a number that pays a hot chopper MORE than a clean one.
-- ---------------------------------------------------------------------------
local function heatPayoutMult(cid)
    -- Every key is read guarded (`or {}`, `tonumber(...) or default`) so
    -- deleting the whole Config.HeatPayout block degrades to "disabled" rather
    -- than throwing a nil-index inside a command that is not pcall-wrapped.
    local HP = Config.HeatPayout or {}
    if not HP.Enabled then return 1.0, nil end
    if type(cid) ~= 'string' or cid == '' then return 1.0, nil end
    if GetResourceState('palm6_heat') ~= 'started' then return 1.0, nil end
    local tier
    pcall(function() tier = exports.palm6_heat:GetTier(cid) end)
    if type(tier) ~= 'string' then return 1.0, nil end
    local m = tonumber((HP.Mult or {})[tier])
    if not m then return 1.0, tier end
    local floorMult = tonumber(HP.Floor) or 0.50
    if m > 1.0 then m = 1.0 end
    if m < floorMult then m = floorMult end
    return m, tier
end

local function atDropPoint(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.DropPoint.coords) <= Config.DropPoint.radius
end

-- ---------------------------------------------------------------------------
-- /reportstolen <plate> — owner-only. Server-verifies real ownership against
-- player_vehicles before writing anything; a citizen can never flag a plate
-- they don't own.
-- ---------------------------------------------------------------------------
local function cmdReportStolen(src, args)
    if src == 0 then return end
    if not rl(src, 'reportstolen', Config.ReportCooldownSec) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local plate = args[1] and args[1]:upper():gsub('%s+', '') or nil
    if not plate or #plate == 0 then
        Bridge.Notify(src, 'Chop Shop', 'Usage: /reportstolen [plate]', 'error')
        return
    end

    local owns
    pcall(function()
        owns = MySQL.single.await(
            'SELECT id FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, cid })
    end)
    if not owns then
        Bridge.Notify(src, 'Chop Shop', 'That plate is not registered to you.', 'error')
        return
    end

    local existing
    pcall(function()
        existing = MySQL.single.await(
            "SELECT id FROM palm6_chopshop_stolen WHERE plate = ? AND status = 'active'", { plate })
    end)
    if existing then
        Bridge.Notify(src, 'Chop Shop', 'That plate is already reported stolen.', 'error')
        return
    end

    local ok = pcall(function()
        MySQL.insert.await(
            [[INSERT INTO palm6_chopshop_stolen
                (plate, owner_citizenid, expires_at)
              VALUES (?, ?, NOW() + INTERVAL ? HOUR)]],
            { plate, cid, Config.StolenReportTTLHours })
    end)
    if not ok then
        Bridge.Notify(src, 'Chop Shop', 'Could not file the report — try again.', 'error')
        return
    end

    Bridge.Notify(src, 'Chop Shop', ('%s reported stolen.'):format(plate), 'success')
    dbg(('%s reported %s stolen'):format(cid, plate))
end

-- ---------------------------------------------------------------------------
-- /sellstolen — must be the DRIVER of a real vehicle at the drop point.
-- Plate, class, and ownership are all re-derived server-side; nothing here
-- trusts a client-supplied value. Selling your own registered vehicle is
-- refused (this is a chop shop, not a legitimate scrapyard — qbx_scrapyard
-- already covers legal scrapping).
-- ---------------------------------------------------------------------------
local function cmdSellStolen(src)
    if src == 0 then return end
    if not rl(src, 'sellstolen', Config.SellCooldownSec) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if not atDropPoint(src) then
        Bridge.Notify(src, 'Chop Shop', ('You need to be at %s.'):format(Config.DropPoint.label), 'error')
        return
    end

    local veh = Bridge.GetDrivenVehicle(src)
    if not veh then
        Bridge.Notify(src, 'Chop Shop', 'You need to be driving the vehicle.', 'error')
        return
    end

    local plate = Bridge.GetVehiclePlate(veh)
    if not plate or #plate == 0 then
        Bridge.Notify(src, 'Chop Shop', 'Could not read that plate.', 'error')
        return
    end

    local ownRow
    pcall(function()
        ownRow = MySQL.single.await(
            'SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate })
    end)
    if ownRow and ownRow.citizenid == cid then
        Bridge.Notify(src, 'Chop Shop', "That's your own registered vehicle — take it to a legal scrapyard instead.", 'error')
        return
    end

    local class = Bridge.GetVehicleClass(veh)
    local payout = Config.ClassPayout[class]
    if not payout then
        Bridge.Notify(src, 'Chop Shop', "We don't touch that kind of vehicle.", 'error')
        return
    end

    local stolenRow
    pcall(function()
        stolenRow = MySQL.single.await(
            "SELECT id, owner_citizenid FROM palm6_chopshop_stolen WHERE plate = ? AND status = 'active' AND expires_at > NOW()", { plate })
    end)

    if not stolenRow and not ownRow then
        Bridge.Notify(src, 'Chop Shop', "This one's clean — nothing to chop here.", 'error')
        return
    end

    -- Heat haircut. Read HERE: after the last refusal (so a car the shop was
    -- never going to buy costs no round-trip) and BEFORE the sale row is
    -- written, so the ledger, the bank credit and the number the seller reads
    -- are all the same figure. Doing it after the INSERT would leave a recorded
    -- sale disagreeing with what was actually paid.
    --
    -- This yield sits in the same stretch of the command as the three ownership
    -- and stolen-report reads above it, and the per-source rate limit was
    -- check-and-set before any of them, so it opens no new double-fire window.
    local cleanPayout = payout
    local hMult, hTier = heatPayoutMult(cid)
    if hMult < 1.0 then
        payout = math.max(1, math.floor(payout * hMult))
    end

    -- Record the sale FIRST (durable audit trail), THEN retire the asset, THEN
    -- pay. Ordering matters: if we destroyed the victim's registration before the
    -- sale row existed and the INSERT then failed, an innocent owner's car would be
    -- wiped with no sale/payout/trail. So: INSERT sale -> retire owned vehicle
    -- (void the sale if the retire fails) -> pay. Consume (retire) still precedes
    -- the payout, so the collusion faucet stays closed.
    local saleId
    local ok = pcall(function()
        saleId = MySQL.insert.await(
            [[INSERT INTO palm6_chopshop_sales
                (seller_citizenid, plate, vehicle_class, payout, was_stolen)
              VALUES (?, ?, ?, ?, ?)]],
            { cid, plate, class, payout, stolenRow and 1 or 0 })
    end)
    if not ok or not saleId then
        Bridge.Notify(src, 'Chop Shop', 'Could not process the sale — try again.', 'error')
        return
    end

    -- Retire a registered player vehicle so it can't be recovered from a garage/
    -- impound and chopped again (closes the owner-collusion faucet — a given owned
    -- plate can only ever be chopped once; the car is permanently gone). Stolen-but-
    -- unowned cars have no recoverable row, so they skip this. If the retire fails,
    -- VOID the just-recorded sale so a failed retire never leaves an orphan sale.
    if ownRow then
        local removed = 0
        pcall(function()
            removed = MySQL.update.await(
                'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?',
                { plate, ownRow.citizenid }) or 0
        end)
        if removed ~= 1 then
            pcall(function()
                MySQL.update.await('DELETE FROM palm6_chopshop_sales WHERE id = ?', { saleId })
            end)
            Bridge.Notify(src, 'Chop Shop', 'That vehicle is no longer choppable.', 'error')
            return
        end
    end

    Bridge.CreditBank(src, payout, 'chopshop-sale')
    Bridge.DeleteVehicle(veh)

    if stolenRow then
        -- Guarded UPDATE — a plate can only be resolved once even if two
        -- chop-shop sales somehow raced (the vehicle entity itself can only
        -- physically be driven to one drop point at a time, but the DB
        -- guard costs nothing and matches the discipline every other
        -- guarded-write feature this session uses).
        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_chopshop_stolen SET status = 'resolved', resolved_at = NOW() WHERE id = ? AND status = 'active'",
                { stolenRow.id })
        end)
    end

    -- Open a forensic case on EVERY chop that has a real victim — a reported-stolen
    -- car (stolenRow) OR an unreported owned car (ownRow, i.e. chop-before-report).
    -- Evidence creation used to be nested under `if stolenRow`, so the common
    -- chop-before-report path (owner hasn't run /reportstolen yet) destroyed the
    -- victim's registration and paid clean money with ZERO paper trail — bypassing
    -- the very consequence layer this resource exists to guarantee just by acting
    -- fast. was_stolen already records which path it was; the case is opened either
    -- way so the seller is always linked as a suspect.
    if stolenRow or ownRow then
        local victimCid = (stolenRow and stolenRow.owner_citizenid) or (ownRow and ownRow.citizenid)
        local evidenceCaseId
        if Bridge.ResourceStarted('palm6_evidence') then
            pcall(function()
                local incidentKey = ('chopshop-%s-%d'):format(plate, math.floor(now() / 300))
                local caseTitle = stolenRow and 'Stolen vehicle sold to chop shop'
                    or 'Vehicle sold to chop shop (unreported at time of chop)'
                evidenceCaseId = exports.palm6_evidence:EnsureCase(incidentKey, caseTitle, 'palm6_chopshop')
                if evidenceCaseId then
                    exports.palm6_evidence:AppendEntry(evidenceCaseId, 'chopshop_sale', {
                        plate = plate, vehicle_class = class, payout = payout,
                        owner_citizenid = victimCid, was_stolen = stolenRow and true or false,
                    }, 'palm6_chopshop')
                    exports.palm6_evidence:LinkSuspect(evidenceCaseId, cid, nil)
                end
            end)
        end
        if evidenceCaseId then
            pcall(function()
                MySQL.update.await('UPDATE palm6_chopshop_sales SET evidence_case_id = ? WHERE id = ?',
                    { evidenceCaseId, saleId })
            end)
        end
    end

    -- Say the cost out loud. A quietly smaller number is not a consequence the
    -- player can learn from; naming the shortfall and the tier lets them tie it
    -- back to /myheat and decide to lie low instead of filing a bug.
    if hMult < 1.0 then
        Bridge.Notify(src, 'Chop Shop',
            ('Sold for $%d. The fence held back $%d, you are too hot right now (%s).')
                :format(payout, cleanPayout - payout, tostring(hTier)), 'warning')
    else
        Bridge.Notify(src, 'Chop Shop', ('Sold for $%d.'):format(payout), 'success')
    end

    -- Persistent police attention: fencing a car is a crime, and fencing one
    -- that was reported STOLEN is hotter than dumping your own. Keyed to the
    -- seller (cid) so it follows them after they log. Fires only after the sale
    -- committed above. Soft-dep + pcall — a stopped palm6_heat never touches
    -- the sale path.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(cid,
                Config.HeatOnSale + (stolenRow and Config.HeatStolenBonus or 0),
                'chopshop')
        end)
    end

    dbg(('%s sold %s (class %d) for $%d (base $%d, heat tier %s), stolen=%s'):format(
        cid, plate, class, payout, cleanPayout, tostring(hTier), tostring(stolenRow ~= nil)))
end

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('reportstolen', function(source, args) cmdReportStolen(source, args) end)
Bridge.RegisterCommand('sellstolen', function(source) cmdSellStolen(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The banner now runs on its own thread because ensureSchema has to Wait for
    -- oxmysql's connection before it can issue any query, and the two counts
    -- below must not run before the tables are guaranteed to exist. Nothing here
    -- populates a cache or a cap, so the delay only moves the printing.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        local activeReports, totalSales = 0, 0
        pcall(function()
            local r = MySQL.single.await(
                "SELECT COUNT(*) AS n FROM palm6_chopshop_stolen WHERE status = 'active' AND expires_at > NOW()")
            activeReports = r and tonumber(r.n) or 0
        end)
        pcall(function()
            local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_chopshop_sales')
            totalSales = r and tonumber(r.n) or 0
        end)
        print(('[palm6_chopshop] shop open — %d active stolen report(s), %d sale(s) all-time'):format(activeReports, totalSales))
        -- Said out loud so a fresh box cannot be mistaken for a quiet shop: with
        -- the tables absent both counts above read 0 and every command no-ops.
        if not SchemaReady then
            print('^1[palm6_chopshop] schema MISSING - the stolen registry and the shop are INERT on this box.^0')
        end
    end)
end)

-- ADDITIVE export - the police side of the registry. Until now the stolen
-- table was WRITE-ONLY from a cop's point of view: a citizen could report a
-- plate stolen and the chop shop could consume the report, but no officer had
-- any way to ask "is this plate hot?". palm6_mdt's /runplate is the first
-- consumer. Same never-change-signature rule as GetSummary.
--
-- IsStolen(plate: string) -> { stolen: boolean, owner_citizenid: string|nil,
--   since: string|nil }
-- `stolen` is true only for a live report: status='active' AND not yet past
-- expires_at, which is exactly the WHERE clause /sellstolen uses, so the two
-- agree on what "still hot" means.
--
-- They do NOT agree on the lookup KEY, and that is pre-existing, not something
-- this export introduced. The plate normalisation here (:upper() plus strip of
-- ALL whitespace) matches the WRITER, /reportstolen. /sellstolen instead reads
-- its plate off the vehicle entity via Bridge.GetVehiclePlate
-- (bridge/sv_framework.lua), which only trims TRAILING pad and does not
-- uppercase. So a report filed with odd casing or an interior space can still
-- read hot here and clean at the shop. Do not read this export as a guarantee
-- that the two surfaces classify every plate identically; it is a guarantee
-- about the staleness rule only.
-- `since` is the report timestamp (reported_at), stringified for the caller.
exports('IsStolen', function(plate)
    local out = { stolen = false, owner_citizenid = nil, since = nil }
    plate = tostring(plate or ''):upper():gsub('%s+', '')
    if plate == '' then return out end
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT owner_citizenid, reported_at FROM palm6_chopshop_stolen WHERE plate = ? AND status = 'active' AND expires_at > NOW() ORDER BY id DESC LIMIT 1",
            { plate })
    end)
    if not row then return out end
    out.stolen = true
    out.owner_citizenid = row.owner_citizenid
    out.since = tostring(row.reported_at)
    return out
end)

---Report/sale counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { activeStolenReports = 0, totalSales = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_chopshop_stolen WHERE status = 'active' AND expires_at > NOW()")
        out.activeStolenReports = r and tonumber(r.n) or 0
    end)
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_chopshop_sales')
        out.totalSales = r and tonumber(r.n) or 0
    end)
    return out
end)
