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
-- own independent, persistent, queryable registry; a future palm6_mdt
-- extension could surface it via a `/runplate` command, but that is
-- explicitly out of scope here (no forced integration without a real hook).
-- ============================================================================

local lastAction = {} -- [src] = { [key] = ts } — chat-command spam guard

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

    Bridge.Notify(src, 'Chop Shop', ('Sold for $%d.'):format(payout), 'success')

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

    dbg(('%s sold %s (class %d) for $%d, stolen=%s'):format(cid, plate, class, payout, tostring(stolenRow ~= nil)))
end

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('reportstolen', function(source, args) cmdReportStolen(source, args) end)
Bridge.RegisterCommand('sellstolen', function(source) cmdSellStolen(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
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
