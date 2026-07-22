-- ============================================================================
-- palm6_gunrunning/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The recipe's `qbx_police` already ships real ballistics forensics: firing
-- a weapon drops a shell-casing prop carrying the weapon's ox_inventory
-- metadata.serial (`evidence:server:CreateCasing`, qbx_police/server/main.lua
-- ~line 491), which police can collect and "dust" for a readable serial
-- number. It's real, but entirely ephemeral — no database, no registry of
-- who a serial belongs to, no case/suspect linkage. This resource sells
-- serialized black-market weapons (the registry) and hooks that SAME event
-- (a second handler — FiveM fires every registered handler independently,
-- the recipe's own handler is untouched) so a serial the recipe already
-- surfaces can actually be traced back to a buyer.
-- ============================================================================

local lastAction = {} -- [src] = { [key] = ts } — chat-command spam guard
local SERIAL_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' -- no 0/O/1/I ambiguity

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_gunrunning] ' .. msg) end
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

local function randomSerial()
    local body = {}
    for i = 1, 6 do
        local n = math.random(1, #SERIAL_ALPHABET)
        body[i] = SERIAL_ALPHABET:sub(n, n)
    end
    return ('%s-%s'):format(Config.SerialPrefix, table.concat(body))
end

-- ---------------------------------------------------------------------------
-- /buyweapon <catalog index> — server-validated proximity + price. The
-- catalog INDEX and Config.Catalog are the only inputs from the client;
-- price and weapon name are always resolved server-side, never trusted.
-- Sale row is written BEFORE the item is granted (the DB row is the source
-- of truth for whether a sale happened); a failed grant refunds and deletes
-- the row rather than leaving an orphaned charge.
-- ---------------------------------------------------------------------------
local function cmdBuyWeapon(src, args)
    if src == 0 then return end
    if not rl(src, 'buyweapon', Config.BuyCooldownSec) then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local idx = tonumber(args[1])
    local entry = idx and Config.Catalog[math.floor(idx)]
    if not entry then
        local lines = {}
        for i, e in ipairs(Config.Catalog) do
            lines[#lines + 1] = ('%d) %s — $%d'):format(i, e.label, e.price)
        end
        Bridge.Notify(src, 'Dealer', 'Usage: /buyweapon [#]. Catalog:\n' .. table.concat(lines, '\n'), 'inform')
        return
    end

    if not atDropPoint(src) then
        Bridge.Notify(src, 'Dealer', ('You need to be at %s.'):format(Config.DropPoint.label), 'error')
        return
    end

    if not Bridge.ChargeBank(src, entry.price, 'gunrunning-purchase') then
        Bridge.Notify(src, 'Dealer', ('You need $%d in the bank.'):format(entry.price), 'error')
        return
    end

    local serial, inserted
    for _ = 1, 5 do
        serial = randomSerial()
        local ok = pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_gunrunning_sales (serial, buyer_citizenid, weapon, price) VALUES (?, ?, ?, ?)',
                { serial, cid, entry.weapon, entry.price })
        end)
        if ok then inserted = true break end
    end
    if not inserted then
        Bridge.CreditBankByCitizenId(cid, entry.price, 'gunrunning-refund')
        Bridge.Notify(src, 'Dealer', 'Could not complete the sale — try again.', 'error')
        return
    end

    local given = Bridge.GiveItem(src, entry.weapon, 1, {
        serial = serial,
        description = ('%s\n\nSerial #: %s'):format(entry.label, serial),
    })
    if not given then
        Bridge.CreditBankByCitizenId(cid, entry.price, 'gunrunning-refund')
        pcall(function()
            MySQL.update.await('DELETE FROM palm6_gunrunning_sales WHERE serial = ?', { serial })
        end)
        Bridge.Notify(src, 'Dealer', 'No room to carry that — refunded.', 'error')
        return
    end

    Bridge.Notify(src, 'Dealer', ('Bought a %s for $%d.'):format(entry.label, entry.price), 'success')

    -- Persistent police attention: acquiring an untraceable black-market weapon
    -- is a crime. Keyed to the buyer (cid) so it follows them after they log.
    -- Fires only after the sale row + item grant committed above. Soft-dep +
    -- pcall — a stopped palm6_heat never touches the purchase path.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(cid, Config.HeatOnBuy, 'gun_deal')
        end)
    end

    dbg(('%s bought %s for $%d, serial %s'):format(cid, entry.weapon, entry.price, serial))
end

-- ---------------------------------------------------------------------------
-- Ballistics hook — SECOND handler on the recipe's own net event. Re-derives
-- the true serial server-side (Bridge.GetCurrentWeaponSerial) rather than
-- trusting the event's `serial` parameter, which a modified client could
-- spoof to frame an innocent citizen — same discipline palm6_mdt's
-- spoofable-source fix and palm6_ransom's kidnap re-validation used. The
-- event's `coords` parameter is untrusted for the same reason: it's the
-- shooter's own client asserting where the casing landed, and this evidence
-- entry is treated as real forensics — re-derived server-side via
-- Bridge.GetCoords rather than recorded as given (found during the
-- independent harden pass; the module previously trusted this one field
-- while explicitly distrusting the adjacent serial field for the same
-- reason).
-- ---------------------------------------------------------------------------
RegisterNetEvent('evidence:server:CreateCasing', function(_weapon, _clientSerial, _clientCoords)
    local src = source
    local realSerial = Bridge.GetCurrentWeaponSerial(src)
    if not realSerial then return end -- non-serialized weapon, nothing to trace

    local sale
    pcall(function()
        sale = MySQL.single.await(
            'SELECT buyer_citizenid, weapon FROM palm6_gunrunning_sales WHERE serial = ?', { realSerial })
    end)
    if not sale then return end -- not a black-market weapon, nothing to link

    if not Bridge.ResourceStarted('palm6_evidence') then return end
    local coords = Bridge.GetCoords(src) or _clientCoords
    -- incidentKey buckets by serial + 5-minute window so one gunfight (many
    -- shots, many CreateCasing events) collapses into ONE case with
    -- multiple ballistics_match entries, instead of a new case per shot.
    local incidentKey = ('gunrunning-%s-%d'):format(realSerial, math.floor(now() / 300))
    pcall(function()
        local caseId = exports.palm6_evidence:EnsureCase(incidentKey, 'Ballistics match — black-market weapon fired', 'palm6_gunrunning')
        if not caseId then return end
        exports.palm6_evidence:AppendEntry(caseId, 'ballistics_match', {
            serial = realSerial, weapon = sale.weapon, coords = coords,
        }, 'palm6_gunrunning')
        exports.palm6_evidence:LinkSuspect(caseId, sale.buyer_citizenid, nil)
    end)
    dbg(('ballistics match: serial %s -> %s'):format(realSerial, sale.buyer_citizenid))
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('buyweapon', function(source, args) cmdBuyWeapon(source, args) end)

-- Dealer NPC buy — the client menu fires this with a catalog INDEX. Routes into
-- the exact same authority as /buyweapon: cmdBuyWeapon re-runs the spam guard,
-- resolves price/weapon from Config server-side (never trusts the client), re-
-- checks proximity to the drop point, charges the bank, and grants a serialized
-- weapon. A forged index is safely rejected (Config.Catalog[idx] is nil → usage,
-- no charge; a NaN/huge index indexes to nil the same way). Budgeted in
-- palm6_eventguard so a flood is throttled + logged like every other money event.
RegisterNetEvent('palm6_gunrunning:dealer:buy', function(idx)
    cmdBuyWeapon(source, { idx })
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local n, total = 0, 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n, COALESCE(SUM(price), 0) AS total FROM palm6_gunrunning_sales')
        n = r and tonumber(r.n) or 0
        total = r and tonumber(r.total) or 0
    end)
    print(('[palm6_gunrunning] dealer open — %d sale(s) all-time ($%d), ballistics tracing %s')
        :format(n, total, Bridge.ResourceStarted('palm6_evidence') and 'ONLINE' or 'offline'))
end)

---Sale counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalSales = 0, totalRevenue = 0 }
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS n, COALESCE(SUM(price), 0) AS total FROM palm6_gunrunning_sales')
        out.totalSales = r and tonumber(r.n) or 0
        out.totalRevenue = r and tonumber(r.total) or 0
    end)
    return out
end)
