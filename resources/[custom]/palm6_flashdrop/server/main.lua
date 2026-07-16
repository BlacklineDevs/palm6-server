-- ============================================================================
-- palm6_flashdrop/server/main.lua
--
-- Hype-drop scarcity economics: limited-serial drops at surprise locations,
-- a per-player checkout line, a consignment aftermarket with provenance,
-- a no-questions fence, and counterfeits that only a registry check catches.
--
-- Pure logic — all framework/native access via Bridge.* (§6 gate). Our own
-- palm6_flashdrop_* SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
--
-- SERVER AUTHORITY: every serial is minted here; every price, distance, job
-- of work, and supply cap is validated here. Clients only ever say "I want
-- to start X" / "I finished X" — and both ends of every two-phase action
-- carry min- AND max-elapsed checks plus fresh proximity checks.
-- ============================================================================

local FENCE_OWNER = '__FENCE__'   -- registry owner for pairs out of circulation
local LEGIT_MAX_SEC = 60          -- max wall-clock for the legit minigame

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
local activeDrop   = nil    -- current drop event (see arm())
local nextAutoAt   = nil    -- unix ts the scheduler may arm the next drop
local pendingCraft = {}     -- [src] = { dropRow, startedAt, cid }
local pendingLegit = {}     -- [src] = { uid, startedAt, cid }
local lastAction   = {}     -- [src] = { [key] = ts } rate-limit ledger
local cooldowns    = {}     -- [cid] = { craft = ts, legit = ts, fence = ts }
local itemRegistered = false -- set at start: ox_inventory knows our base item

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_flashdrop] ' .. msg) end
end

-- Soft dependency: hype posts go out iff palm6_discord is running with the
-- 'drops' feed configured. Never blocks or errors the drop lifecycle.
local function discordAnnounce(payload)
    if GetResourceState('palm6_discord') ~= 'started' then return end
    pcall(function() exports.palm6_discord:Announce('drops', payload) end)
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
-- Catalog / location helpers
-- ---------------------------------------------------------------------------
local function getCatalog(code)
    for _, c in ipairs(Config.Catalog) do
        if c.code == code then return c end
    end
    return nil
end

local function getLocation(id)
    for _, l in ipairs(Config.Locations) do
        if l.id == id then return l end
    end
    return nil
end

-- Weighted-random catalog pick (rarity = tickets).
local function pickCatalog()
    local total = 0
    for _, c in ipairs(Config.Catalog) do total = total + (c.rarity or 1) end
    local roll = math.random(total)
    for _, c in ipairs(Config.Catalog) do
        roll = roll - (c.rarity or 1)
        if roll <= 0 then return c end
    end
    return Config.Catalog[1]
end

local function pickLocation()
    return Config.Locations[math.random(#Config.Locations)]
end

-- ---------------------------------------------------------------------------
-- Serial registry helpers
-- ---------------------------------------------------------------------------
local UID_CHARS = '0123456789abcdef'

local function makeUid()
    local out = {}
    for i = 1, 16 do
        local n = math.random(#UID_CHARS)
        out[i] = UID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

local function makeSerial(code, n, cap)
    return ('%s-%03d/%d'):format(code, n, cap)
end

-- Item metadata for a pair. IDENTICAL builder for real and fake pairs — the
-- registry, not the metadata, is what tells them apart.
local function pairMetadata(catalog, serial, uid)
    return {
        uid = uid,
        serial = serial,
        label = ('%s [%s]'):format(catalog.label, serial),
        description = ('%s Serial %s — %d made.'):format(catalog.blurb or '', serial, catalog.cap),
    }
end

-- Append-only audit tape.
local function provenance(uid, event, actorCid, actorName, counterCid, price, detail)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_flashdrop_provenance (uid, event, actor_citizenid, actor_name, counterparty_citizenid, price, detail) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { uid, event, actorCid, actorName or '', counterCid, price, detail })
    end)
end

local function serialByUid(uid)
    local ok, row = pcall(function()
        return MySQL.single.await('SELECT * FROM palm6_flashdrop_serials WHERE uid = ?', { uid })
    end)
    return ok and row or nil
end

-- ---------------------------------------------------------------------------
-- Proximity gates (server-side; +3.0 slack over the client prompt radius,
-- like palm6_evidence)
-- ---------------------------------------------------------------------------
local function nearCoords(src, coords, radius)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, coords) <= radius
end

local function nearConsignment(src)
    return nearCoords(src, Config.Consignment.Coords, Config.InteractRadius + 3.0)
end

local function nearFence(src)
    return nearCoords(src, Config.Fence.Coords, Config.InteractRadius + 3.0)
end

local function nearBench(src, radius)
    return nearCoords(src, Config.Counterfeit.Coords, radius or (Config.InteractRadius + 3.0))
end

-- ===========================================================================
-- DROP LIFECYCLE
-- ===========================================================================

-- Payload the client needs for the current public stage (also used for
-- late-join sync).
local function stagePayload(stage)
    local d = activeDrop
    if not d then return nil end
    local base = {
        stage = stage,
        catalogLabel = d.catalog.label,
        retail = d.catalog.retail,
        cap = d.cap,
        remaining = d.cap - d.claimed,
    }
    if stage == 'hint' then
        base.riddle = d.location.riddle
        base.minutes = math.max(1, math.floor((d.liveAt - now()) / 60))
    elseif stage == 'reveal' or stage == 'live' then
        base.locationLabel = d.location.label
        base.coords = { x = d.location.coords.x, y = d.location.coords.y, z = d.location.coords.z }
        base.seconds = math.max(0, d.liveAt - now())
        base.turfCallout = d.turfCallout
    end
    return base
end

local function broadcastStage(stage)
    local payload = stagePayload(stage)
    if payload then TriggerClientEvent('palm6_flashdrop:stage', -1, payload) end
end

-- palm6_turf soft synergy: who owns the block this drop lands on?
local function lookupTurfCallout(location)
    if not Config.TurfCallouts or not location.turfZone then return nil end
    local ok, gang = pcall(function()
        return MySQL.scalar.await(
            'SELECT owner_gang FROM palm6_turf WHERE zone_id = ?', { location.turfZone })
    end)
    if ok and gang and gang ~= '' then
        return ('Word is that block belongs to %s.'):format(gang)
    end
    return nil
end

local function scheduleNextAuto()
    local s = Config.Scheduler
    nextAutoAt = now() + math.random(s.MinIntervalMin * 60, s.MaxIntervalMin * 60)
    dbg(('next auto drop eligible in %ds'):format(nextAutoAt - now()))
end

-- Arm a drop. Returns true, or false + reason.
local function arm(catalogCode, locationId, hintLeadSec, revealLeadSec, liveDurationSec)
    if activeDrop then return false, 'a drop is already armed' end
    if not itemRegistered then
        return false, ('item %s is not registered with ox_inventory — see server console'):format(Config.Item.name)
    end

    local catalog = catalogCode and getCatalog(catalogCode) or pickCatalog()
    if not catalog then return false, ('unknown catalog code %s'):format(tostring(catalogCode)) end
    local location = locationId and getLocation(locationId) or pickLocation()
    if not location then return false, ('unknown location id %s'):format(tostring(locationId)) end

    local hintLead   = math.max(10, tonumber(hintLeadSec) or Config.Timing.HintLeadSec)
    local revealLead = math.min(hintLead, math.max(5, tonumber(revealLeadSec) or Config.Timing.RevealLeadSec))
    local liveFor    = math.max(60, tonumber(liveDurationSec) or Config.Timing.LiveDurationSec)

    local t = now()
    local liveAt = t + hintLead

    local ok, id = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO palm6_flashdrop_drops (catalog_code, label, location_id, retail, supply_cap, status, hint_at, reveal_at, live_at, closes_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { catalog.code, catalog.label, location.id, catalog.retail, catalog.cap,
              'announced', t, liveAt - revealLead, liveAt, liveAt + liveFor })
    end)
    if not ok or not id then return false, 'db insert failed' end

    activeDrop = {
        id = id,
        catalog = catalog,
        location = location,
        cap = catalog.cap,
        claimed = 0,
        status = 'announced',
        hintAt = t,
        revealAt = liveAt - revealLead,
        liveAt = liveAt,
        closesAt = liveAt + liveFor,
        hintSent = false,
        reservations = {},       -- [src] = { cid, startedAt }
        reservedCount = 0,
        claimedCids = {},        -- [citizenid] = true (one-per-citizen cache)
        turfCallout = lookupTurfCallout(location),
    }

    dbg(('armed drop #%d %s @ %s (live in %ds)'):format(id, catalog.code, location.id, hintLead))
    -- Location and turf callout stay OUT of the post — the in-game hint
    -- system owns reveals; Discord only builds the line.
    discordAnnounce({
        title = ('DROP INCOMING — %s'):format(catalog.label),
        description = ('%d units at $%d retail. Serialized, provenance-taped. Location hits in-city in ~%d min — be there or pay resale.')
            :format(catalog.cap, catalog.retail, math.max(1, math.floor(hintLead / 60))),
    })
    return true
end

local function setDropStatus(status)
    if not activeDrop then return end
    activeDrop.status = status
    local id = activeDrop.id
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_flashdrop_drops SET status = ?, claimed = ? WHERE id = ?',
            { status, activeDrop.claimed, id })
    end)
end

-- End the active drop (sold_out / expired / cancelled).
local function closeDrop(status, publicMsg)
    if not activeDrop then return end
    setDropStatus(status)
    for src in pairs(activeDrop.reservations) do
        Bridge.Notify(src, 'Flash Drop', 'The table just closed.', 'error')
    end
    TriggerClientEvent('palm6_flashdrop:stage', -1, { stage = 'closed', reason = status })
    if publicMsg then Bridge.NotifyAll('👟 Flash Drop', publicMsg, status == 'sold_out' and 'success' or 'inform') end
    dbg(('drop #%d closed: %s'):format(activeDrop.id, status))
    activeDrop = nil
    scheduleNextAuto()
end

local function voidReservation(src, msg)
    local d = activeDrop
    if not d or not d.reservations[src] then return end
    d.reservations[src] = nil
    d.reservedCount = math.max(0, d.reservedCount - 1)
    if msg then Bridge.Notify(src, 'Flash Drop', msg, 'error') end
end

-- Lifecycle sweep: stage transitions, reservation timeouts, the scheduler.
CreateThread(function()
    while true do
        Wait(5000)
        local t = now()

        -- Two-phase janitor: void craft/legit sessions whose client never
        -- sent finish/cancel (client script error, crash). Without this the
        -- stale entry blocks the bench/counter for the rest of the session.
        -- No refund — same as finishing outside the window.
        local craftMax = Config.Counterfeit.CraftSec + Config.Counterfeit.CraftGraceSec + 5
        for src, pend in pairs(pendingCraft) do
            if t - pend.startedAt > craftMax then
                pendingCraft[src] = nil
                Bridge.Notify(src, 'Workbench', 'You walked off mid-job — materials wasted.', 'error')
            end
        end
        for src, pend in pairs(pendingLegit) do
            if t - pend.startedAt > LEGIT_MAX_SEC + 5 then
                pendingLegit[src] = nil
                Bridge.Notify(src, 'SoleWorth', 'You wandered off — inconclusive. Fee is non-refundable.', 'error')
            end
        end

        if activeDrop then
            local d = activeDrop

            -- Each transition broadcasts ONE stage event; the client side
            -- renders the announcement (and the blip/prop/zone at reveal).
            if not d.hintSent and t >= d.hintAt then
                d.hintSent = true
                broadcastStage('hint')
            end

            if d.status == 'announced' and t >= d.revealAt then
                setDropStatus('revealed')
                broadcastStage('reveal')
            elseif d.status == 'revealed' and t >= d.liveAt then
                setDropStatus('live')
                broadcastStage('live')
            elseif d.status == 'live' and t >= d.closesAt then
                closeDrop('expired',
                    ('%s is done — %d of %d pairs claimed. See you on the resale market.')
                    :format(d.catalog.label, d.claimed, d.cap))
            end

            -- Reservation janitor: void checkouts that blew the grace window.
            if activeDrop then
                local maxAge = Config.Timing.CheckoutSec + Config.Timing.CheckoutGraceSec
                for src, res in pairs(d.reservations) do
                    if t - res.startedAt > maxAge then
                        voidReservation(src, 'Checkout timed out — back of the line.')
                    end
                end
            end
        else
            -- Scheduler
            local s = Config.Scheduler
            if s.Enabled and nextAutoAt and t >= nextAutoAt then
                if Bridge.PlayerCount() >= s.MinPlayers then
                    local ok, err = arm()
                    if not ok then
                        dbg('auto-arm failed: ' .. tostring(err))
                        nextAutoAt = t + 600
                    end
                else
                    nextAutoAt = t + 600  -- server too quiet; check again in 10 min
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The line: two-phase checkout (start -> 8s -> finish)
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_flashdrop:startCheckout', function()
    local src = source
    if not rl(src, 'checkout') then return end
    local d = activeDrop
    if not d then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if d.status ~= 'live' then
        local wait = math.max(0, d.liveAt - now())
        Bridge.Notify(src, 'Flash Drop',
            wait > 0 and ('Doors open in %ds — hold the line.'):format(wait) or 'The table is closed.', 'inform')
        return
    end

    -- One reservation at a time, per source AND per citizen.
    if d.reservations[src] then return end
    for _, res in pairs(d.reservations) do
        if res.cid == cid then return end
    end

    -- One pair per citizen per drop (memory cache + registry truth).
    if Config.OnePerCitizen then
        if d.claimedCids[cid] then
            Bridge.Notify(src, 'Flash Drop', 'One per person. You already got yours.', 'error')
            return
        end
        local ok, n = pcall(function()
            return MySQL.scalar.await(
                'SELECT COUNT(*) FROM palm6_flashdrop_serials WHERE drop_id = ? AND claimed_by = ? AND is_fake = 0',
                { d.id, cid })
        end)
        if ok and (tonumber(n) or 0) > 0 then
            d.claimedCids[cid] = true
            Bridge.Notify(src, 'Flash Drop', 'One per person. You already got yours.', 'error')
            return
        end
    end

    -- Stock, counting in-flight reservations.
    if d.claimed + d.reservedCount >= d.cap then
        Bridge.Notify(src, 'Flash Drop', 'Everything on the table is spoken for — pray someone fumbles.', 'error')
        return
    end

    -- Physically at the table (server-side). Keep the coords: they anchor
    -- the finish check (the checkout bar locks movement client-side, and the
    -- server holds the claimant to that spot — see finishCheckout).
    local startCoords = Bridge.GetCoords(src)
    if not startCoords or Bridge.Distance(startCoords, d.location.coords) > Config.Timing.ClaimRadius then
        Bridge.Notify(src, 'Flash Drop', 'You need to be AT the table.', 'error')
        return
    end

    -- Don't burn a reservation on someone who can't pay.
    if Bridge.GetCashBalance(src) < d.catalog.retail then
        Bridge.Notify(src, 'Flash Drop', ('Cash only — $%d.'):format(d.catalog.retail), 'error')
        return
    end

    d.reservations[src] = { cid = cid, startedAt = now(), startCoords = startCoords }
    d.reservedCount = d.reservedCount + 1
    TriggerClientEvent('palm6_flashdrop:beginCheckout', src, Config.Timing.CheckoutSec)
    dbg(('src %d reserved a pair on drop #%d'):format(src, d.id))
end)

RegisterNetEvent('palm6_flashdrop:finishCheckout', function()
    local src = source
    local d = activeDrop
    if not d then return end
    local res = d.reservations[src]
    if not res then return end

    -- Two-phase window: full checkout time must have elapsed, and not more
    -- than the grace allows. (min AND max, server clock.)
    local elapsed = now() - res.startedAt
    if elapsed < Config.Timing.CheckoutSec - 1 then
        voidReservation(src, 'Nice try — the checkout timer is not optional.')
        return
    end
    if elapsed > Config.Timing.CheckoutSec + Config.Timing.CheckoutGraceSec then
        voidReservation(src, 'Checkout timed out — back of the line.')
        return
    end

    if d.status ~= 'live' then
        voidReservation(src, 'The table just closed.')
        return
    end

    -- Still at the table — AND still where checkout started. The checkout
    -- progress bar disables movement/vehicles/combat client-side, so a legit
    -- claimant cannot have drifted; a client that skipped the bar to move or
    -- fight through the window fails the anchor and loses the claim. This is
    -- the server-side proxy for "you were actually locked in the bar".
    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, d.location.coords) > Config.Timing.ClaimRadius then
        voidReservation(src, 'You walked away from the table.')
        return
    end
    if res.startCoords and Bridge.Distance(here, res.startCoords) > Config.Timing.AnchorRadius then
        voidReservation(src, 'You stepped off the register mid-checkout.')
        return
    end

    if d.claimed >= d.cap then
        voidReservation(src, 'Sold out under your nose.')
        return
    end

    -- Charge (framework-checked affordability).
    if not Bridge.ChargeCash(src, d.catalog.retail, 'flashdrop-purchase') then
        voidReservation(src, ('Cash only — $%d.'):format(d.catalog.retail))
        return
    end

    -- Mint the serial. This is the ONLY place a genuine serial is born.
    d.claimed = d.claimed + 1
    local serialNo = d.claimed
    local serial = makeSerial(d.catalog.code, serialNo, d.cap)
    local uid = makeUid()
    local name = Bridge.GetPlayerName(src)

    local okIns = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_flashdrop_serials (uid, serial, drop_id, catalog_code, is_fake, is_dirty, owner_citizenid, claimed_by) VALUES (?, ?, ?, ?, 0, 0, ?, ?)',
            { uid, serial, d.id, d.catalog.code, res.cid, res.cid })
    end)
    if not okIns then
        d.claimed = d.claimed - 1
        Bridge.AddCash(src, d.catalog.retail, 'flashdrop-refund')
        voidReservation(src, 'Register jammed — you were not charged.')
        return
    end

    local meta = pairMetadata(d.catalog, serial, uid)
    if not Bridge.GivePair(src, Config.Item.name, meta) then
        -- Inventory full: refund, unmint.
        d.claimed = d.claimed - 1
        pcall(function()
            MySQL.update.await('DELETE FROM palm6_flashdrop_serials WHERE uid = ?', { uid })
        end)
        Bridge.AddCash(src, d.catalog.retail, 'flashdrop-refund')
        voidReservation(src, 'Your hands are full — refunded.')
        return
    end

    voidReservation(src)  -- consumed, no message
    d.claimedCids[res.cid] = true
    provenance(uid, 'drop_claim', res.cid, name, nil, d.catalog.retail,
        ('drop #%d at %s'):format(d.id, d.location.id))
    setDropStatus('live')  -- persists the claimed counter

    Bridge.Notify(src, 'Flash Drop',
        ('%s — serial %s. Now get it home.'):format(d.catalog.label, serial), 'success')

    if d.claimed >= d.cap then
        closeDrop('sold_out',
            ('%s SOLD OUT — %d serials in the wild. Aftermarket opens now.')
            :format(d.catalog.label, d.cap))
    elseif Config.AnnounceClaims then
        Bridge.NotifyAll('👟 Flash Drop',
            ('%d of %d pairs left at %s.'):format(d.cap - d.claimed, d.cap, d.location.label))
    end
end)

RegisterNetEvent('palm6_flashdrop:cancelCheckout', function()
    voidReservation(source)
end)

-- ===========================================================================
-- CONSIGNMENT (SoleWorth)
-- ===========================================================================

local function activeListingCount(cid)
    local ok, n = pcall(function()
        return MySQL.scalar.await(
            "SELECT COUNT(*) FROM palm6_flashdrop_listings WHERE seller_citizenid = ? AND status = 'active'",
            { cid })
    end)
    return ok and (tonumber(n) or 0) or 0
end

-- Pairs in the requester's inventory, joined against the registry, for the
-- sell / legit-check pickers. Reveals NOTHING about fake/dirty status.
RegisterNetEvent('palm6_flashdrop:consign:pairs', function(purpose)
    local src = source
    if not rl(src, 'menu') then return end
    if purpose ~= 'sell' and purpose ~= 'legit' then return end
    if not nearConsignment(src) then return end
    if not Bridge.GetCitizenId(src) then return end

    local out = {}
    for _, p in ipairs(Bridge.ListPairs(src, Config.Item.name)) do
        local row = serialByUid(p.uid)
        if row then
            local cat = getCatalog(row.catalog_code)
            out[#out + 1] = {
                uid = row.uid,
                serial = row.serial,
                label = cat and cat.label or row.catalog_code,
            }
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, purpose .. 'Pairs', out)
end)

RegisterNetEvent('palm6_flashdrop:consign:list', function(uid, price)
    local src = source
    if not rl(src, 'action') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if type(uid) ~= 'string' then return end

    price = tonumber(price) or 0
    if price ~= price then return end  -- NaN over msgpack survives BOTH range checks below
    price = math.floor(price)
    local row = serialByUid(uid)
    if not row then
        Bridge.Notify(src, 'SoleWorth', 'I have no record of that pair. Not touching it.', 'error')
        return
    end

    -- The consignor legit-checks everything on intake.
    if row.is_fake == 1 then
        provenance(uid, 'legit_check', cid, Bridge.GetPlayerName(src), nil, nil, 'consignor refused: counterfeit')
        Bridge.Notify(src, 'SoleWorth', 'These are FAKE. Get them off my counter.', 'error')
        return
    end
    if row.is_dirty == 1 then
        Bridge.Notify(src, 'SoleWorth', 'That serial is reported stolen. I can\'t sell hot pairs.', 'error')
        return
    end

    local cat = getCatalog(row.catalog_code)
    local maxPrice = (cat and cat.retail or 1000) * Config.Consignment.MaxPriceMult
    if price < Config.Consignment.MinPrice or price > maxPrice then
        Bridge.Notify(src, 'SoleWorth',
            ('Price it between $%d and $%d.'):format(Config.Consignment.MinPrice, maxPrice), 'error')
        return
    end

    if activeListingCount(cid) >= Config.Consignment.MaxListingsPerPlayer then
        Bridge.Notify(src, 'SoleWorth', 'Your shelf space is full — cancel a listing first.', 'error')
        return
    end

    -- No double-listing the same uid.
    local okDup, dup = pcall(function()
        return MySQL.scalar.await(
            "SELECT COUNT(*) FROM palm6_flashdrop_listings WHERE uid = ? AND status = 'active'", { uid })
    end)
    if okDup and (tonumber(dup) or 0) > 0 then return end

    -- Take physical custody LAST, after every check passed.
    local slot = Bridge.FindPairSlot(src, Config.Item.name, uid)
    if not slot then
        Bridge.Notify(src, 'SoleWorth', 'You are not holding that pair.', 'error')
        return
    end
    if not Bridge.RemovePairBySlot(src, Config.Item.name, slot) then return end

    local name = Bridge.GetPlayerName(src)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_flashdrop_listings (uid, seller_citizenid, seller_name, price) VALUES (?, ?, ?, ?)',
            { uid, cid, name, price })
    end)
    if not ok then
        -- Listing failed: hand the pair straight back.
        Bridge.GivePair(src, Config.Item.name, pairMetadata(cat or { label = row.catalog_code, cap = 0 }, row.serial, uid))
        Bridge.Notify(src, 'SoleWorth', 'Ledger trouble — try again.', 'error')
        return
    end

    provenance(uid, 'consign_list', cid, name, nil, price, nil)
    Bridge.Notify(src, 'SoleWorth',
        ('%s [%s] on the shelf at $%d. House keeps %d%%.'):format(
            cat and cat.label or row.catalog_code, row.serial, price,
            math.floor(Config.Consignment.FeePct * 100)), 'success')
end)

RegisterNetEvent('palm6_flashdrop:consign:browse', function()
    local src = source
    if not rl(src, 'menu') then return end
    if not nearConsignment(src) then return end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            [[SELECT l.id, l.price, l.seller_name, s.serial, s.catalog_code
              FROM palm6_flashdrop_listings l
              JOIN palm6_flashdrop_serials s ON s.uid = l.uid
              WHERE l.status = 'active' ORDER BY l.listed_at DESC LIMIT ?]],
            { Config.Consignment.BrowseLimit })
    end)
    local out = {}
    if ok and rows then
        for _, r in ipairs(rows) do
            local cat = getCatalog(r.catalog_code)
            out[#out + 1] = {
                id = r.id, price = r.price, seller = r.seller_name,
                serial = r.serial, label = cat and cat.label or r.catalog_code,
            }
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, 'browse', out)
end)

-- Settle the SELLER side of a consignment sale idempotently. Called from the
-- live buy path (once the buyer has both paid and received the pair) and from
-- the boot reconcile. Claim-before-credit: the seller is credited only if we
-- win the settled=0 -> 1 claim, so a replay after a crash can never double-pay.
-- It matches ONLY listings with buyer_paid=1, so it can never mint against a
-- sale whose buyer was never charged. The buyer's item delivery is handled
-- live and is deliberately NOT reconciled here (see sql/0062).
local function settleConsignSale(listingId, buyerName)
    local l
    pcall(function()
        l = MySQL.single.await(
            "SELECT id, uid, seller_citizenid, buyer_citizenid, price FROM palm6_flashdrop_listings WHERE id = ? AND status = 'sold' AND buyer_paid = 1 AND settled = 0",
            { listingId })
    end)
    if not l then return end

    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_flashdrop_listings SET settled = 1 WHERE id = ? AND settled = 0", { listingId }) == 1
    end)
    if not claimed then return end

    -- Seller payout (bank; survives them being offline). Fee is the sink.
    local fee = math.floor(l.price * Config.Consignment.FeePct)
    Bridge.CreditBankByCitizenId(l.seller_citizenid, l.price - fee, 'flashdrop-consign-sale')
    pcall(function()
        MySQL.update.await('UPDATE palm6_flashdrop_serials SET owner_citizenid = ? WHERE uid = ?', { l.buyer_citizenid, l.uid })
    end)
    provenance(l.uid, 'consign_sale', l.buyer_citizenid, buyerName, l.seller_citizenid, l.price, nil)
end

-- Boot reconcile — re-drive consignment sales interrupted by the last restart.
-- buyer_paid=1 + settled=0: buyer was charged, seller never credited -> settle
-- (credit seller idempotently). buyer_paid=0 while 'sold': the listing was
-- reserved but the buyer was never charged (crash between the claim and the
-- charge) -> release it back to 'active' so the pair can be sold again.
local function reconcileConsignSales()
    local paidUnsettled, reserved = {}, {}
    pcall(function()
        paidUnsettled = MySQL.query.await(
            "SELECT id FROM palm6_flashdrop_listings WHERE status = 'sold' AND buyer_paid = 1 AND settled = 0") or {}
    end)
    for _, r in ipairs(paidUnsettled) do settleConsignSale(r.id, nil) end
    pcall(function()
        reserved = MySQL.query.await(
            "SELECT id FROM palm6_flashdrop_listings WHERE status = 'sold' AND buyer_paid = 0") or {}
    end)
    for _, r in ipairs(reserved) do
        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_flashdrop_listings SET status = 'active', buyer_citizenid = NULL, resolved_at = NULL WHERE id = ? AND status = 'sold' AND buyer_paid = 0",
                { r.id })
        end)
    end
    if #paidUnsettled > 0 or #reserved > 0 then
        print(('[palm6_flashdrop] boot reconcile: settled %d sale(s), released %d unpaid reservation(s)')
            :format(#paidUnsettled, #reserved))
    end
end

RegisterNetEvent('palm6_flashdrop:consign:buy', function(listingId)
    local src = source
    if not rl(src, 'action') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    listingId = math.floor(tonumber(listingId) or 0)
    if listingId <= 0 then return end

    local okQ, l = pcall(function()
        return MySQL.single.await(
            "SELECT * FROM palm6_flashdrop_listings WHERE id = ? AND status = 'active'", { listingId })
    end)
    if not okQ or not l then
        Bridge.Notify(src, 'SoleWorth', 'That pair just moved.', 'error')
        return
    end
    if l.seller_citizenid == cid then
        Bridge.Notify(src, 'SoleWorth', 'Buying your own listing back? Just cancel it.', 'error')
        return
    end

    local row = serialByUid(l.uid)
    if not row then return end
    local cat = getCatalog(row.catalog_code)

    -- Atomically claim the listing FIRST so two buyers can never both win.
    -- buyer_paid=0 + settled=0 mark THIS new sale as needing settlement (the
    -- columns default to 1 to protect pre-deploy history); buyer_paid flips to 1
    -- only once the buyer's cash is actually taken, below.
    local okClaim, affected = pcall(function()
        return MySQL.update.await(
            "UPDATE palm6_flashdrop_listings SET status = 'sold', buyer_citizenid = ?, resolved_at = NOW(), buyer_paid = 0, settled = 0 WHERE id = ? AND status = 'active'",
            { cid, listingId })
    end)
    if not okClaim or (tonumber(affected) or 0) == 0 then
        Bridge.Notify(src, 'SoleWorth', 'That pair just moved.', 'error')
        return
    end

    local function revert()
        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_flashdrop_listings SET status = 'active', buyer_citizenid = NULL, resolved_at = NULL WHERE id = ?",
                { listingId })
        end)
    end

    if not Bridge.ChargeCash(src, l.price, 'flashdrop-consign-buy') then
        revert()
        Bridge.Notify(src, 'SoleWorth', ('Cash only — $%d.'):format(l.price), 'error')
        return
    end

    -- Buyer's cash is now taken — mark the sale financially committed BEFORE the
    -- pair hand-off / seller credit. This is the flag the boot reconcile keys on
    -- to decide a crash is a recoverable seller-strand (buyer_paid=1) rather than
    -- an un-charged reservation to release (buyer_paid=0), so the seller credit
    -- can never mint against a buyer who was never charged.
    pcall(function()
        MySQL.update.await(
            "UPDATE palm6_flashdrop_listings SET buyer_paid = 1 WHERE id = ? AND status = 'sold'", { listingId })
    end)

    local meta = pairMetadata(cat or { label = row.catalog_code, cap = 0 }, row.serial, row.uid)
    if not Bridge.GivePair(src, Config.Item.name, meta) then
        Bridge.AddCash(src, l.price, 'flashdrop-consign-refund')
        revert()
        pcall(function()
            MySQL.update.await("UPDATE palm6_flashdrop_listings SET buyer_paid = 0 WHERE id = ?", { listingId })
        end)
        Bridge.Notify(src, 'SoleWorth', 'Your hands are full — refunded.', 'error')
        return
    end

    -- Seller payout + serial owner-flip, via the shared idempotent settler so a
    -- crash here is re-driven identically on the next boot (claim-before-credit).
    settleConsignSale(listingId, Bridge.GetPlayerName(src))

    Bridge.Notify(src, 'SoleWorth',
        ('%s [%s] — yours for $%d.'):format(cat and cat.label or row.catalog_code, row.serial, l.price), 'success')
end)

RegisterNetEvent('palm6_flashdrop:consign:myListings', function()
    local src = source
    if not rl(src, 'menu') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            [[SELECT l.id, l.price, s.serial, s.catalog_code
              FROM palm6_flashdrop_listings l
              JOIN palm6_flashdrop_serials s ON s.uid = l.uid
              WHERE l.seller_citizenid = ? AND l.status = 'active' ORDER BY l.listed_at DESC]],
            { cid })
    end)
    local out = {}
    if ok and rows then
        for _, r in ipairs(rows) do
            local cat = getCatalog(r.catalog_code)
            out[#out + 1] = { id = r.id, price = r.price, serial = r.serial,
                              label = cat and cat.label or r.catalog_code }
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, 'myListings', out)
end)

RegisterNetEvent('palm6_flashdrop:consign:cancel', function(listingId)
    local src = source
    if not rl(src, 'action') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    listingId = math.floor(tonumber(listingId) or 0)

    -- Atomic: only the seller can pull an ACTIVE listing, exactly once.
    local okU, affected = pcall(function()
        return MySQL.update.await(
            "UPDATE palm6_flashdrop_listings SET status = 'cancelled', resolved_at = NOW() WHERE id = ? AND seller_citizenid = ? AND status = 'active'",
            { listingId, cid })
    end)
    if not okU or (tonumber(affected) or 0) == 0 then return end

    -- From here on the listing sits at 'cancelled' — EVERY bail-out below
    -- must flip it back to 'active', or the pair is destroyed with no way
    -- to ever hand it back.
    local function backOnShelf()
        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_flashdrop_listings SET status = 'active', resolved_at = NULL WHERE id = ?", { listingId })
        end)
    end

    local okQ, l = pcall(function()
        return MySQL.single.await('SELECT uid FROM palm6_flashdrop_listings WHERE id = ?', { listingId })
    end)
    if not okQ or not l then
        backOnShelf()
        Bridge.Notify(src, 'SoleWorth', 'Ledger trouble — try again.', 'error')
        return
    end
    local row = serialByUid(l.uid)
    if not row then
        backOnShelf()
        Bridge.Notify(src, 'SoleWorth', 'Ledger trouble — try again.', 'error')
        return
    end
    local cat = getCatalog(row.catalog_code)

    if not Bridge.GivePair(src, Config.Item.name, pairMetadata(cat or { label = row.catalog_code, cap = 0 }, row.serial, row.uid)) then
        -- No room: put it back on the shelf rather than eat the pair.
        backOnShelf()
        Bridge.Notify(src, 'SoleWorth', 'Your hands are full — it stays on the shelf.', 'error')
        return
    end
    provenance(row.uid, 'consign_cancel', cid, Bridge.GetPlayerName(src), nil, nil, nil)
    Bridge.Notify(src, 'SoleWorth', ('[%s] back in your hands.'):format(row.serial), 'success')
end)

-- ---------------------------------------------------------------------------
-- Legit check: fee up front, a steady-hands minigame, then the registry
-- verdict + provenance tape. Two-phase with min/max window.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_flashdrop:legit:start', function(uid)
    local src = source
    if not rl(src, 'action') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or type(uid) ~= 'string' then return end
    if pendingLegit[src] then return end

    local left = cdRemaining(cid, 'legit', Config.LegitCheck.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, 'SoleWorth', ('Give me a minute — %ds.'):format(left), 'error')
        return
    end

    if not Bridge.FindPairSlot(src, Config.Item.name, uid) then return end

    if not Bridge.ChargeCash(src, Config.LegitCheck.Fee, 'flashdrop-legit-check') then
        Bridge.Notify(src, 'SoleWorth', ('Legit check is $%d, cash.'):format(Config.LegitCheck.Fee), 'error')
        return
    end

    setCooldown(cid, 'legit')
    pendingLegit[src] = { uid = uid, startedAt = now(), cid = cid }
    TriggerClientEvent('palm6_flashdrop:beginLegit', src, uid)
end)

RegisterNetEvent('palm6_flashdrop:legit:finish', function(uid, passed)
    local src = source
    local pend = pendingLegit[src]
    if not pend or pend.uid ~= uid then return end
    pendingLegit[src] = nil

    -- Two-phase window: the minigame takes real seconds; instant or ancient
    -- finishes are both rejected.
    local elapsed = now() - pend.startedAt
    if elapsed < 1 or elapsed > LEGIT_MAX_SEC then return end
    if not nearConsignment(src) then return end

    -- TRUST BOUNDARY: `passed` is the client-side skill-check outcome and a
    -- modified client can always send true. That is deliberate flavor, not a
    -- security gate: the fee was charged up front, the window/proximity/
    -- possession checks above are server-side, and the verdict only reveals
    -- registry truth about a pair the caller already holds. Skipping the
    -- minigame gains nothing that cannot be had legitimately.
    if not passed then
        Bridge.Notify(src, 'SoleWorth', 'Hands shook — inconclusive. Fee is non-refundable.', 'error')
        return
    end

    -- Verdict comes from the REGISTRY, never from metadata.
    if not Bridge.FindPairSlot(src, Config.Item.name, uid) then return end
    local row = serialByUid(uid)

    local verdict, body
    if not row or row.is_fake == 1 then
        verdict = 'COUNTERFEIT'
        body = 'Stitching is off, the serial font is wrong, and the registry has no matching pair. These are fake.'
    elseif row.is_dirty == 1 then
        verdict = 'REPORTED STOLEN'
        body = ('Serial %s is genuine — and flagged stolen in the registry. A fence might still take them.'):format(row.serial)
    else
        verdict = 'AUTHENTIC'
        local cat = getCatalog(row.catalog_code)
        body = ('Serial %s of %d. Clean title.'):format(row.serial, cat and cat.cap or 0)
        local okP, tape = pcall(function()
            return MySQL.query.await(
                'SELECT event, actor_name, price, created_at FROM palm6_flashdrop_provenance WHERE uid = ? ORDER BY id DESC LIMIT 6',
                { uid })
        end)
        if okP and tape and #tape > 0 then
            local lines = { body, '', '**Provenance:**' }
            for _, e in ipairs(tape) do
                local pricePart = e.price and (' ($%d)'):format(e.price) or ''
                lines[#lines + 1] = ('- %s — %s%s — _%s_'):format(e.event, e.actor_name, pricePart, tostring(e.created_at))
            end
            body = table.concat(lines, '\n')
        end
    end

    provenance(uid, 'legit_check', pend.cid, Bridge.GetPlayerName(src), nil, nil, verdict)
    TriggerClientEvent('palm6_flashdrop:report', src, ('Legit Check: %s'):format(verdict), body)
end)

-- ---------------------------------------------------------------------------
-- Stolen reports. Only the registered owner can flag a serial, and only when
-- the pair is NOT in their own pockets (you cannot dirty what you still hold).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_flashdrop:reportMenu', function()
    local src = source
    if not rl(src, 'menu') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local held = {}
    for _, p in ipairs(Bridge.ListPairs(src, Config.Item.name)) do held[p.uid] = true end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT uid, serial, catalog_code FROM palm6_flashdrop_serials WHERE owner_citizenid = ? AND is_fake = 0 AND is_dirty = 0 ORDER BY id DESC LIMIT 20',
            { cid })
    end)
    local out = {}
    if ok and rows then
        for _, r in ipairs(rows) do
            if not held[r.uid] then
                local cat = getCatalog(r.catalog_code)
                out[#out + 1] = { uid = r.uid, serial = r.serial,
                                  label = cat and cat.label or r.catalog_code }
            end
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, 'report', out)
end)

RegisterNetEvent('palm6_flashdrop:reportStolen', function(uid)
    local src = source
    if not rl(src, 'action') then return end
    if not nearConsignment(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or type(uid) ~= 'string' then return end

    local row = serialByUid(uid)
    if not row or row.owner_citizenid ~= cid or row.is_fake == 1 or row.is_dirty == 1 then return end
    if Bridge.FindPairSlot(src, Config.Item.name, uid) then
        Bridge.Notify(src, 'SoleWorth', 'They are in your pocket. That is not "stolen".', 'error')
        return
    end

    pcall(function()
        MySQL.update.await('UPDATE palm6_flashdrop_serials SET is_dirty = 1 WHERE uid = ?', { uid })
    end)
    local name = Bridge.GetPlayerName(src)
    provenance(uid, 'reported_stolen', cid, name, nil, nil, nil)

    -- palm6_evidence soft synergy: theft reports become detective RP (same
    -- silent-skip pattern as palm6_pumpcoin's rug reveals).
    if Config.WriteEvidenceOnStolenReport then
        pcall(function()
            local cat = getCatalog(row.catalog_code)
            MySQL.insert.await(
                'INSERT INTO palm6_evidence (citizenid, officer_name, description) VALUES (?, ?, ?)',
                { cid, 'SoleWorth Registry (automated)',
                  ('THEFT REPORT: %s serial %s reported stolen by %s. Serial is now flagged dirty — it will surface when fenced or legit-checked.')
                  :format(cat and cat.label or row.catalog_code, row.serial, name) })
        end)
    end

    Bridge.Notify(src, 'SoleWorth',
        ('Serial %s flagged. It can never be consigned again — only fenced at a loss.'):format(row.serial), 'success')
end)

-- ===========================================================================
-- THE FENCE
-- ===========================================================================

local function fenceOffer(row)
    local cat = getCatalog(row.catalog_code)
    local retail = cat and cat.retail or 100
    if row.is_fake == 1 then
        return math.max(1, math.floor(retail * Config.Fence.FakePayoutRate)), true
    end
    return math.floor(retail * Config.Fence.PayoutRate), false
end

RegisterNetEvent('palm6_flashdrop:fence:menu', function()
    local src = source
    if not rl(src, 'menu') then return end
    if not nearFence(src) then return end
    if not Bridge.GetCitizenId(src) then return end

    local out = {}
    for _, p in ipairs(Bridge.ListPairs(src, Config.Item.name)) do
        local row = serialByUid(p.uid)
        if row and row.owner_citizenid ~= FENCE_OWNER then
            local offer, isFake = fenceOffer(row)
            local cat = getCatalog(row.catalog_code)
            out[#out + 1] = {
                uid = row.uid, serial = row.serial,
                label = cat and cat.label or row.catalog_code,
                offer = offer,
                -- The fence is an expert: his lowball IS the tell.
                remark = isFake and 'These are plastic. Insult money only.'
                    or (row.is_dirty == 1 and 'Hot pairs. No questions.' or 'Clean. Easy flip.'),
            }
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, 'fence', out)
end)

RegisterNetEvent('palm6_flashdrop:fence:sell', function(uid)
    local src = source
    if not rl(src, 'action') then return end
    if not nearFence(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid or type(uid) ~= 'string' then return end

    local left = cdRemaining(cid, 'fence', Config.Fence.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, 'Fence', ('Slow down. %ds.'):format(left), 'error')
        return
    end

    -- Registry lookup FIRST (it yields); the slot lookup + removal below are
    -- back-to-back synchronous calls, so there is no window to swap items
    -- between "which slot is uid in" and "remove that slot".
    local row = serialByUid(uid)
    if not row or row.owner_citizenid == FENCE_OWNER then return end

    local offer, isFake = fenceOffer(row)
    local slot = Bridge.FindPairSlot(src, Config.Item.name, uid)
    if not slot then return end
    if not Bridge.RemovePairBySlot(src, Config.Item.name, slot) then return end

    setCooldown(cid, 'fence')
    Bridge.AddCash(src, offer, 'flashdrop-fence')
    pcall(function()
        MySQL.update.await('UPDATE palm6_flashdrop_serials SET owner_citizenid = ? WHERE uid = ?', { FENCE_OWNER, uid })
    end)
    provenance(uid, 'fenced', cid, Bridge.GetPlayerName(src), nil, offer,
        isFake and 'fake' or (row.is_dirty == 1 and 'dirty' or 'clean'))

    Bridge.Notify(src, 'Fence',
        isFake and ('$%d for the plastic. Don\'t bring me toys again.'):format(offer)
        or ('$%d, gone. [%s] never existed.'):format(offer, row.serial), 'success')
end)

-- ===========================================================================
-- COUNTERFEIT BENCH
-- ===========================================================================

RegisterNetEvent('palm6_flashdrop:craft:menu', function()
    local src = source
    if not rl(src, 'menu') then return end
    if not nearBench(src) then return end
    if not Bridge.GetCitizenId(src) then return end

    -- You can only fake what the street has already seen.
    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT id, catalog_code, label, retail FROM palm6_flashdrop_drops WHERE status IN ('live','sold_out','expired') ORDER BY id DESC LIMIT 10")
    end)
    local out = {}
    if ok and rows then
        for _, r in ipairs(rows) do
            out[#out + 1] = { dropId = r.id, label = r.label, retail = r.retail }
        end
    end
    TriggerClientEvent('palm6_flashdrop:menuData', src, 'craft', out)
end)

RegisterNetEvent('palm6_flashdrop:craft:start', function(dropId)
    local src = source
    if not rl(src, 'action') then return end
    -- At the bench (server-side). Keep the coords: they anchor the finish
    -- check the same way checkout is anchored to the table.
    local startCoords = Bridge.GetCoords(src)
    if not startCoords or Bridge.Distance(startCoords, Config.Counterfeit.Coords) > Config.Counterfeit.Radius then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if pendingCraft[src] then return end
    if not itemRegistered then
        Bridge.Notify(src, 'Workbench', 'The bench is out of commission — tell an admin.', 'error')
        return
    end
    dropId = math.floor(tonumber(dropId) or 0)

    local left = cdRemaining(cid, 'craft', Config.Counterfeit.CooldownSec)
    if left > 0 then
        Bridge.Notify(src, 'Workbench', ('Glue is still drying — %ds.'):format(left), 'error')
        return
    end

    local ok, drop = pcall(function()
        return MySQL.single.await(
            "SELECT id, catalog_code, supply_cap FROM palm6_flashdrop_drops WHERE id = ? AND status IN ('live','sold_out','expired')",
            { dropId })
    end)
    if not ok or not drop then return end
    local cat = getCatalog(drop.catalog_code)
    if not cat then return end

    if not Bridge.ChargeCash(src, Config.Counterfeit.CraftCost, 'flashdrop-craft') then
        Bridge.Notify(src, 'Workbench', ('Materials run $%d, cash.'):format(Config.Counterfeit.CraftCost), 'error')
        return
    end

    pendingCraft[src] = { dropId = drop.id, catalog = cat, cap = drop.supply_cap, startedAt = now(), cid = cid, startCoords = startCoords }
    TriggerClientEvent('palm6_flashdrop:beginCraft', src, Config.Counterfeit.CraftSec, cat.label)
end)

RegisterNetEvent('palm6_flashdrop:craft:finish', function()
    local src = source
    local pend = pendingCraft[src]
    if not pend then return end
    pendingCraft[src] = nil

    -- Two-phase window (min AND max), plus fresh proximity.
    local elapsed = now() - pend.startedAt
    if elapsed < Config.Counterfeit.CraftSec - 1
        or elapsed > Config.Counterfeit.CraftSec + Config.Counterfeit.CraftGraceSec then
        Bridge.Notify(src, 'Workbench', 'You rushed it — ruined.', 'error')
        return
    end
    -- Still at the bench — AND still where the job started. The craft
    -- progress bar disables movement client-side; the anchor is the
    -- server-side proxy for having actually been locked in it.
    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, Config.Counterfeit.Coords) > Config.Counterfeit.Radius then return end
    if pend.startCoords and Bridge.Distance(here, pend.startCoords) > Config.Timing.AnchorRadius then
        Bridge.Notify(src, 'Workbench', 'You wandered off the bench mid-job — ruined.', 'error')
        return
    end

    -- A convincing fake CLONES a plausible real serial. Same metadata shape
    -- as a genuine pair; only the registry knows.
    local serial = makeSerial(pend.catalog.code, math.random(1, pend.cap), pend.cap)
    local uid = makeUid()
    local name = Bridge.GetPlayerName(src)

    local okIns = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_flashdrop_serials (uid, serial, drop_id, catalog_code, is_fake, is_dirty, owner_citizenid, claimed_by) VALUES (?, ?, ?, ?, 1, 0, ?, ?)',
            { uid, serial, pend.dropId, pend.catalog.code, pend.cid, pend.cid })
    end)
    if not okIns then
        Bridge.AddCash(src, Config.Counterfeit.CraftCost, 'flashdrop-craft-refund')
        return
    end

    local meta = pairMetadata(pend.catalog, serial, uid)
    if not Bridge.GivePair(src, Config.Item.name, meta) then
        pcall(function()
            MySQL.update.await('DELETE FROM palm6_flashdrop_serials WHERE uid = ?', { uid })
        end)
        Bridge.AddCash(src, Config.Counterfeit.CraftCost, 'flashdrop-craft-refund')
        Bridge.Notify(src, 'Workbench', 'Your hands are full — refunded.', 'error')
        return
    end

    setCooldown(pend.cid, 'craft')
    provenance(uid, 'counterfeit_mint', pend.cid, name, nil, Config.Counterfeit.CraftCost,
        ('clones %s'):format(serial))
    Bridge.Notify(src, 'Workbench',
        ('One "authentic" %s [%s]. Passes a glance. Fails a legit check.'):format(pend.catalog.label, serial), 'success')
end)

RegisterNetEvent('palm6_flashdrop:craft:cancel', function()
    local src = source
    local pend = pendingCraft[src]
    if not pend then return end
    pendingCraft[src] = nil
    -- Player-cancelled: give the materials money back.
    Bridge.AddCash(src, Config.Counterfeit.CraftCost, 'flashdrop-craft-refund')
end)

-- ===========================================================================
-- SYNC + ADMIN + HOUSEKEEPING
-- ===========================================================================

-- Late joiners ask for the current public stage.
RegisterNetEvent('palm6_flashdrop:requestSync', function()
    local src = source
    if not rl(src, 'sync') then return end
    local d = activeDrop
    if not d or not d.hintSent then return end
    local stage = 'hint'
    if d.status == 'revealed' then stage = 'reveal'
    elseif d.status == 'live' then stage = 'live' end
    TriggerClientEvent('palm6_flashdrop:stage', src, stagePayload(stage))
end)

-- /flashdrop arm [code] [locationId] [hintLeadSec] [revealLeadSec] [liveSec]
-- /flashdrop cancel | status
-- Restricted (ace: command.flashdrop) — grant with:
--   add_ace group.admin command.flashdrop allow
RegisterCommand('flashdrop', function(src, args)
    local sub = args[1] and args[1]:lower() or 'status'

    if sub == 'arm' then
        local ok, err = arm(args[2] and args[2]:upper() or nil, args[3], args[4], args[5], args[6])
        if ok then
            local d = activeDrop
            Bridge.Notify(src, 'Flash Drop',
                ('Armed drop #%d: %s @ %s — live in %ds.'):format(d.id, d.catalog.label, d.location.label, d.liveAt - now()), 'success')
        else
            Bridge.Notify(src, 'Flash Drop', 'Arm failed: ' .. tostring(err), 'error')
        end
    elseif sub == 'cancel' then
        if not activeDrop then
            Bridge.Notify(src, 'Flash Drop', 'Nothing armed.', 'error')
            return
        end
        closeDrop('cancelled', 'Today\'s drop was pulled. Stay mad.')
        Bridge.Notify(src, 'Flash Drop', 'Cancelled.', 'success')
    elseif sub == 'status' then
        if activeDrop then
            local d = activeDrop
            Bridge.Notify(src, 'Flash Drop',
                ('#%d %s @ %s — %s, %d/%d claimed, live %+ds, closes %+ds.')
                :format(d.id, d.catalog.code, d.location.id, d.status, d.claimed, d.cap,
                    d.liveAt - now(), d.closesAt - now()), 'inform')
        else
            local eta = (Config.Scheduler.Enabled and nextAutoAt) and (nextAutoAt - now()) or nil
            Bridge.Notify(src, 'Flash Drop',
                eta and ('No active drop. Scheduler eligible in %ds.'):format(math.max(0, eta))
                or 'No active drop. Scheduler off.', 'inform')
        end
    else
        Bridge.Notify(src, 'Flash Drop', 'Usage: /flashdrop arm|cancel|status', 'error')
    end
end, true)

AddEventHandler('playerDropped', function()
    local src = source
    voidReservation(src)
    lastAction[src] = nil
    pendingLegit[src] = nil
    local craft = pendingCraft[src]
    if craft then
        pendingCraft[src] = nil
        -- They paid and never finished; the bench keeps the materials.
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Verify the base item is registered with the inventory. Registration is
    -- declarative (ox_inventory_overrides/data/items.lua ExtraItems);
    -- Bridge.RegisterItem is a presence check that screams to console when
    -- the item is missing. Drops and crafting stay disabled until it exists,
    -- so every claim can actually deliver a pair.
    itemRegistered = Bridge.RegisterItem(Config.Item.name, Config.Item)

    -- Any drop that was mid-flight when the server went down is dead.
    pcall(function()
        MySQL.update.await(
            "UPDATE palm6_flashdrop_drops SET status = 'cancelled' WHERE status IN ('announced','revealed','live')")
    end)

    if Config.Scheduler.Enabled then scheduleNextAuto() end
    print(('[palm6_flashdrop] ready — %d catalog entries, %d locations, scheduler %s')
        :format(#Config.Catalog, #Config.Locations, Config.Scheduler.Enabled and 'ON' or 'OFF'))

    -- Recover consignment sales interrupted by the last restart, once oxmysql +
    -- palm6_dbmigrate (0062 buyer_paid/settled columns) are up.
    CreateThread(function()
        Wait(8000)
        reconcileConsignSales()
    end)
end)
