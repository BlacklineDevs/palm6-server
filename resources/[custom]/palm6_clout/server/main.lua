-- ============================================================================
-- palm6_clout/server/main.lua
--
-- IRL-streamer culture as a game mechanic. Any player with a streamer phone
-- goes live to a SIMULATED audience: a server-side tick loop scores what
-- actually happens around them (gunfire, explosions, police chases, crowds,
-- gang turf) into a viewer count, fires probability-scaled donations, and
-- unlocks one-time brand-deal payouts at viewer milestones. The RP twist:
-- everything witnessed while live lands on the VOD (palm6_clout_vod), and
-- police can subpoena a streamer's last 24h of clips — streamers are walking
-- evidence cameras gangs want to run off their block.
--
-- Pure logic — every framework/native/game-event access goes through
-- Bridge.* (§6 gate). Our own palm6_clout_* SQL is portable, so it stays
-- here (see docs/GTA6-READINESS.md, Section 3).
--
-- Server authority: viewer math, donation rolls + hourly caps, milestone
-- sustain counters, payout snapshots, claim proximity, subpoena job/distance
-- gates, and every rate limit live HERE. The client only ever receives
-- display state and sends two intents (claim deals, live-list sync) — it is
-- never trusted for viewers, money, positions, or identity.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local Streams = {}        -- citizenid -> live stream record
local SrcToCid = {}       -- server source -> citizenid (live streamers only)
local Cooldowns = {}      -- citizenid -> { key -> epoch of last accepted use }
local DonationLedger = {} -- citizenid -> { {ts, amt}, ... } rolling-hour cap
local TurfOwned = {}      -- turf zone_id -> owner gang (palm6_turf soft dep)
local GunshotBuf = {}     -- { ts, src, coords } from the engine damage event
local ExplosionBuf = {}   -- { ts, src?, coords } from the engine explosion event
local SyncLast = {}       -- per-source throttle for live-list sync requests

local HOUR = 3600
local tickSec = math.max(1, math.floor(Config.TickIntervalMs / 1000))

-- Forward-declared: the boot-reconcile payout recovery is defined down in the
-- brand-deal cashout section (next to settleDeal, which it shares), but is
-- CALLED from onResourceStart above it. Declaring the local here lets that
-- handler's closure capture it as an upvalue so the later assignment is seen.
local reconcileUnpaidDeals

local function now() return os.time() end

-- Soft dependency: going-live posts go out iff palm6_discord is running
-- with the 'live' feed configured. Never blocks or errors stream flows.
local function discordAnnounce(payload)
    if GetResourceState('palm6_discord') ~= 'started' then return end
    pcall(function() exports.palm6_discord:Announce('live', payload) end)
end

local function dbg(...)
    if Config.Debug then print('[palm6_clout]', ...) end
end

-- ---------------------------------------------------------------------------
-- Cooldowns (server-side rate limits, keyed by character not source)
-- ---------------------------------------------------------------------------

-- Check-and-consume: returns true (and rejects) if still cooling down,
-- otherwise stamps now and returns false.
local function onCooldown(cid, key, secs)
    local c = Cooldowns[cid]
    if not c then c = {} Cooldowns[cid] = c end
    local t = now()
    if c[key] and (t - c[key]) < secs then return true end
    c[key] = t
    return false
end

-- Un-stamp a consumed cooldown (used when the gated action later fails for
-- reasons that were not the player's spam).
local function refundCooldown(cid, key)
    local c = Cooldowns[cid]
    if c then c[key] = nil end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function randomStartViewers()
    return math.random(Config.StartViewersMin, Config.StartViewersMax)
end

-- Sum of donations credited to this character in the rolling hour.
local function donationHourSum(cid)
    local ledger = DonationLedger[cid]
    if not ledger then return 0 end
    local cutoff, sum, keep = now() - HOUR, 0, {}
    for _, e in ipairs(ledger) do
        if e.ts > cutoff then
            sum = sum + e.amt
            keep[#keep + 1] = e
        end
    end
    DonationLedger[cid] = keep
    return sum
end

-- Is this position inside a gang-OWNED danger zone? Returns the owner gang
-- name or nil. Ownership comes from the palm6_turf table cache (soft dep).
local function dangerZoneOwner(coords)
    if not Config.DangerZoneEnabled then return nil end
    for _, z in ipairs(Config.DangerZones) do
        local owner = TurfOwned[z.id]
        if owner and Bridge.Distance(coords, z.coords) <= Config.DangerZoneRadius then
            return owner
        end
    end
    return nil
end

-- Write one clip to the streamer's VOD, rate-limited per streamer
-- (per-minute row cap + suspect/type dedupe) so a sustained firefight is a
-- handful of rows, not a DB flood.
local function writeVod(s, eventType, suspectCid, suspectName, detail, coords)
    local t = now()
    local keep = {}
    for _, ts in ipairs(s.vodTimes) do
        if ts > t - 60 then keep[#keep + 1] = ts end
    end
    s.vodTimes = keep
    if #s.vodTimes >= Config.VodMaxRowsPerMin then return end

    local key = eventType .. '|' .. (suspectCid or '?')
    if s.vodDedupe[key] and (t - s.vodDedupe[key]) < Config.VodDedupeSec then return end
    s.vodDedupe[key] = t
    s.vodTimes[#s.vodTimes + 1] = t

    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_clout_vod
                (streamer_citizenid, streamer_name, event_type, suspect_citizenid, suspect_name, detail, coords)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]], { s.cid, s.name, eventType, suspectCid, suspectName, detail,
              coords and json.encode(coords) or nil })
    end)
end

-- ---------------------------------------------------------------------------
-- Engine event buffers (filled via bridge callbacks, consumed by the tick).
-- Both events are client-relayed and floodable, so ingest is bounded two
-- ways: a hard per-buffer ceiling (the tick scan can never become an
-- unbounded loop) and a per-sender quota per tick window (one spammer can
-- neither fill the buffer nor starve everyone else out of it).
-- ---------------------------------------------------------------------------
local BUF_HARD_CAP = 128          -- absolute entries per buffer per tick window
local SENDER_EVENT_CAP = 10       -- buffered events per sender per tick window
local SenderEventCount = {}       -- src -> events buffered since last tick

-- Consume one slot of the sender's per-tick ingest quota; false = drop.
local function senderQuotaOk(src)
    local n = (SenderEventCount[src] or 0) + 1
    if n > SENDER_EVENT_CAP then return false end
    SenderEventCount[src] = n
    return true
end

-- Cheap predicate the bridge checks FIRST (before any native entity resolution)
-- so a no-stream server pays a single table lookup per gunshot/explosion instead
-- of NetworkGetEntityFromNetworkId + GetEntityCoords on every combat event.
local function anyLive() return next(Streams) ~= nil end

Bridge.OnWeaponDamage(function(ev)
    -- Only buffer while someone is live — otherwise this is a no-op server.
    if not next(Streams) or not ev.coords or not ev.src then return end
    if #GunshotBuf >= BUF_HARD_CAP or not senderQuotaOk(ev.src) then return end
    GunshotBuf[#GunshotBuf + 1] = { ts = now(), src = ev.src, coords = ev.coords }
end, anyLive)

Bridge.OnExplosion(function(ev)
    if not next(Streams) or not ev.coords or not ev.src then return end
    if #ExplosionBuf >= BUF_HARD_CAP or not senderQuotaOk(ev.src) then return end
    ExplosionBuf[#ExplosionBuf + 1] = { ts = now(), src = ev.src, coords = ev.coords }
end, anyLive)

-- Drop buffer entries older than two ticks (already consumed or unwitnessed)
-- and reopen every sender's ingest quota for the next window.
local function pruneBuffers()
    local cutoff = now() - (tickSec * 2)
    local g, e = {}, {}
    for _, ev in ipairs(GunshotBuf) do
        if ev.ts > cutoff then g[#g + 1] = ev end
    end
    for _, ev in ipairs(ExplosionBuf) do
        if ev.ts > cutoff then e[#e + 1] = ev end
    end
    GunshotBuf, ExplosionBuf = g, e
    SenderEventCount = {}
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    local ok = pcall(function()
        MySQL.scalar.await('SELECT 1 FROM palm6_clout_streamers LIMIT 1')
    end)
    if not ok then
        print('[palm6_clout] ERROR: palm6_clout_* tables missing — is sql/0016_clout.sql applied?')
    end

    -- Config sanity guards (mirrors the palm6_pumpcoin boot-warning pattern).
    local prev = 0
    for _, m in ipairs(Config.Milestones) do
        if m.viewers <= prev then
            print('[palm6_clout] WARNING: Config.Milestones must be sorted ascending by viewers.')
            break
        end
        prev = m.viewers
    end
    if Config.MilestoneSustainTicks < 2 then
        print('[palm6_clout] WARNING: MilestoneSustainTicks < 2 lets a one-tick death spike '
            .. 'sustain a milestone — deal payouts become suicide-farmable. Use >= 2.')
    end
    if Config.DonationHourlyCap < Config.DonationMin then
        print('[palm6_clout] WARNING: DonationHourlyCap < DonationMin — donations can never fire.')
    end

    print(('[palm6_clout] on air — %d milestones, donations capped at $%d/hr')
        :format(#Config.Milestones, Config.DonationHourlyCap))

    -- Recover any brand-deal payout interrupted by the last restart (claimed at
    -- the broker but never credited). Delayed so oxmysql + palm6_dbmigrate's
    -- 0060 `paid` column are up before the paid = 0 predicate runs. Idempotent —
    -- re-crediting an already-paid deal is impossible (settleDeal claims first).
    CreateThread(function()
        Wait(8000)
        reconcileUnpaidDeals()
    end)
end)

-- ---------------------------------------------------------------------------
-- Go live / end stream
-- ---------------------------------------------------------------------------

local function broadcastLiveAdd(s)
    TriggerClientEvent('palm6_clout:liveAdd', -1, s.src, s.name)
end

local function broadcastLiveRemove(src)
    TriggerClientEvent('palm6_clout:liveRemove', -1, src)
end

-- End a stream and persist its stats. `silent` skips the chat notify
-- (disconnects, silent identity loss) but ALWAYS sends the overlay-closing
-- client event: a multicharacter switch ends the stream while the source is
-- still connected, and without the event the NUI HUD would stay LIVE forever
-- (sending to a truly dropped source is a harmless no-op). Safe to call
-- twice — second call is a no-op.
local function endStream(cid, reason, silent)
    local s = Streams[cid]
    if not s then return end
    Streams[cid] = nil
    if SrcToCid[s.src] == cid then SrcToCid[s.src] = nil end

    local duration = math.max(0, now() - s.startedAt)
    pcall(function()
        MySQL.update.await([[
            UPDATE palm6_clout_streamers
            SET total_streams = total_streams + 1,
                total_seconds = total_seconds + ?,
                peak_viewers = GREATEST(peak_viewers, ?),
                total_donations = total_donations + ?
            WHERE citizenid = ?
        ]], { duration, s.peak, s.donationTotal, cid })
    end)

    broadcastLiveRemove(s.src)
    TriggerClientEvent('palm6_clout:streamEnded', s.src, {
        peak = s.peak,
        seconds = duration,
        donations = s.donationTotal,
    })
    if not silent then
        Bridge.Notify(s.src, 'Clout',
            ('Stream ended (%s). Peak %d viewers, $%d in donations.')
            :format(reason, s.peak, s.donationTotal), 'inform')
    end
    dbg(('stream ended for %s (%s): peak %d, $%d'):format(cid, reason, s.peak, s.donationTotal))
end

RegisterCommand('golive', function(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    if Streams[cid] or SrcToCid[src] then
        Bridge.Notify(src, 'Clout', 'You are already live. /endstream first.', 'error')
        return
    end
    local health = Bridge.GetHealth(src)
    if health and health <= Config.DeadHealthThreshold then
        Bridge.Notify(src, 'Clout', 'You cannot go live while down.', 'error')
        return
    end
    if Config.PhoneItem and Bridge.CountItem(src, Config.PhoneItem) < 1 then
        Bridge.Notify(src, 'Clout', 'You need a streamer phone to go live.', 'error')
        return
    end
    if onCooldown(cid, 'golive', Config.GoLiveCooldownSec) then
        Bridge.Notify(src, 'Clout', 'Your last stream just ended — give the audience a minute.', 'error')
        return
    end

    local name = Bridge.GetPlayerName(src)

    -- Ensure the stats row exists, then load already-unlocked deals so this
    -- stream never re-unlocks (and never re-announces) an earned milestone.
    local unlocked = {}
    local ok = pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_clout_streamers (citizenid, streamer_name, last_live_at)
            VALUES (?, ?, NOW())
            ON DUPLICATE KEY UPDATE streamer_name = VALUES(streamer_name), last_live_at = NOW()
        ]], { cid, name })
        local rows = MySQL.query.await(
            'SELECT milestone FROM palm6_clout_deals WHERE citizenid = ?', { cid }) or {}
        for _, r in ipairs(rows) do unlocked[tonumber(r.milestone)] = true end
    end)
    if not ok then
        refundCooldown(cid, 'golive')
        Bridge.Notify(src, 'Clout', 'Stream platform is down (DB error). Try again.', 'error')
        return
    end

    local t = now()
    local s = {
        cid = cid, src = src, name = name,
        startedAt = t,
        endsAt = t + Config.MaxStreamSec,
        viewers = randomStartViewers(),
        peak = 0,
        prevShown = 0,
        donationTotal = 0,
        nextDonationAt = t + Config.DonationIntervalSec,
        unlocked = unlocked,   -- milestone viewers -> true (earned, ever)
        sustain = {},          -- milestone viewers -> consecutive ticks at/above
        deadNow = false,
        deathSpikeUsed = false,
        vodTimes = {},         -- per-minute VOD row cap
        vodDedupe = {},        -- eventType|suspect -> last write epoch
        lastEventTs = t,       -- buffers consumed up to here
    }
    s.peak = s.viewers
    Streams[cid] = s
    SrcToCid[src] = cid

    broadcastLiveAdd(s)
    TriggerClientEvent('palm6_clout:streamStarted', src, {
        viewers = s.viewers,
        maxSec = Config.MaxStreamSec,
    })
    Bridge.Notify(src, 'Clout', 'You are LIVE. Everything you film is on the record.', 'success')
    if Config.AnnounceGoLive then
        Bridge.NotifyAll('📡 LIVE', ('%s just went live. Smile — you might be content.'):format(name), 'inform')
        -- Mirrors the in-city NotifyAll gate: no city-wide announce, no
        -- Discord announce.
        discordAnnounce({
            title = ('📡 %s IS LIVE'):format(name),
            description = ('Started with %d viewers. Everything filmed is on the record — VODs are subpoenable.')
                :format(s.viewers),
        })
    end
    dbg(('stream started: %s (%s)'):format(name, cid))
end, false)

RegisterCommand('endstream', function(src)
    if src == 0 then return end
    local cid = SrcToCid[src]
    if not cid or not Streams[cid] then
        Bridge.Notify(src, 'Clout', 'You are not live.', 'error')
        return
    end
    endStream(cid, 'ended by you')
end, false)

AddEventHandler('playerDropped', function()
    local src = source
    SyncLast[src] = nil
    local cid = SrcToCid[src]
    if cid then endStream(cid, 'disconnect', true) end
end)

-- ---------------------------------------------------------------------------
-- The viewer simulation tick
-- ---------------------------------------------------------------------------

-- Score and advance one live stream. `ctx` carries the per-tick snapshots
-- (player coords, on-duty police) so 5 streamers don't mean 5 full scans.
local function tickStream(s, ctx)
    local t = ctx.t

    -- Identity / phone / lifetime gates — all re-checked server-side every
    -- tick, not just at go-live.
    if Bridge.GetCitizenId(s.src) ~= s.cid then
        endStream(s.cid, 'signal lost', true)
        return
    end
    if t >= s.endsAt then
        endStream(s.cid, 'max stream length')
        return
    end
    if Config.PhoneItem and Bridge.CountItem(s.src, Config.PhoneItem) < 1 then
        endStream(s.cid, 'streamer phone lost')
        return
    end

    local coords = Bridge.GetCoords(s.src)
    if not coords then return end -- ped not scoped this tick; try next

    local age = t - s.startedAt
    local mood = 'idle'
    local shown -- what the overlay displays this tick (differs on death spike)

    -- ---- death: spike once per stream, then reset ------------------------
    local health = Bridge.GetHealth(s.src)
    local dead = health ~= nil and health <= Config.DeadHealthThreshold
    if dead then
        if not s.deadNow then
            s.deadNow = true
            mood = 'death'
            shown = s.viewers
            if not s.deathSpikeUsed then
                s.deathSpikeUsed = true
                shown = math.min(Config.MaxViewers, math.floor(s.viewers * Config.DeathSpikeMult))
                s.peak = math.max(s.peak, shown)
            end
            writeVod(s, 'streamer_down', s.cid, s.name, 'Streamer went down live on stream', coords)
            s.viewers = randomStartViewers() -- the clip ends; a fresh room drifts in
        else
            shown = math.max(Config.MinViewers, math.floor(s.viewers * (1 - Config.IdleDecayPct)))
            s.viewers = shown
        end
        s.sustain = {} -- a reset audience sustains nothing
        s.prevShown = shown
        TriggerClientEvent('palm6_clout:tick', s.src, { viewers = shown, mood = mood, trend = 'down' })
        return
    end
    s.deadNow = false

    -- ---- score the tick ---------------------------------------------------
    local gain = 0

    -- Gunfire witnessed within WitnessRadius: one score per unique shooter
    -- per tick, capped. Blank-firing scores nothing — the engine event only
    -- fires on actual damage, so "content" requires actual violence.
    local shooters, shots = {}, 0
    for _, ev in ipairs(GunshotBuf) do
        if ev.ts > s.lastEventTs and shots < Config.Gain.MaxGunshotEventsPerTick
            and not shooters[ev.src]
            and Bridge.Distance(coords, ev.coords) <= Config.WitnessRadius then
            shooters[ev.src] = true
            shots = shots + 1
            gain = gain + Config.Gain.GunshotEvent
            local susCid = Bridge.GetCitizenId(ev.src)
            writeVod(s, 'gunfire', susCid, Bridge.GetPlayerName(ev.src),
                'Gunfire on stream', ev.coords)
        end
    end
    if shots > 0 then mood = 'gunfight' end

    -- Explosions witnessed: one score per unique bomber per tick, capped —
    -- same anti-farm shape as gunfire (a spammed detonator is one clip).
    local bombers, booms = {}, 0
    for _, ev in ipairs(ExplosionBuf) do
        if ev.ts > s.lastEventTs and booms < Config.Gain.MaxExplosionsPerTick
            and not bombers[ev.src]
            -- Economy audit 2026-07-19 fix: a streamer cannot score their OWN
            -- explosionEvent. FiveM explosions are client-emitted and cannot be
            -- server-authenticated, so a self-explosion is the spoof vector (emit
            -- at your own coords, pass WitnessRadius, farm viewers -> milestone
            -- payouts). Others' explosions near your stream still count, which is
            -- the intended "film the chaos" content. (Mirrors the crowd loop's
            -- pl.src ~= s.src guard.) Tune Config.Gain.Explosion to rebalance.
            and ev.src ~= s.src
            and Bridge.Distance(coords, ev.coords) <= Config.WitnessRadius then
            bombers[ev.src] = true
            booms = booms + 1
            gain = gain + Config.Gain.Explosion
            writeVod(s, 'explosion', Bridge.GetCitizenId(ev.src), Bridge.GetPlayerName(ev.src),
                'Explosion on stream', ev.coords)
            mood = 'gunfight'
        end
    end

    -- Police chase: streamer moving fast with an on-duty officer close.
    if Bridge.GetSpeed(s.src) >= Config.ChaseSpeedMs then
        for _, cop in ipairs(ctx.police) do
            if cop.coords and Bridge.Distance(coords, cop.coords) <= Config.PoliceChaseRadius then
                gain = gain + Config.Gain.PoliceChase
                mood = 'chase'
                writeVod(s, 'police_chase', s.cid, s.name,
                    'Streamer filmed themselves fleeing police', coords)
                break
            end
        end
    end

    -- Crowd: other players in frame.
    local crowd = 0
    for _, pl in ipairs(ctx.players) do
        if pl.src ~= s.src and pl.coords
            and Bridge.Distance(coords, pl.coords) <= Config.WitnessRadius then
            crowd = crowd + 1
        end
    end
    gain = gain + math.min(crowd * Config.Gain.CrowdPerPlayer, Config.Gain.CrowdCap)

    -- Danger zone (palm6_turf synergy): filming on an owned block multiplies
    -- everything — and the go-live head icon tells the block you're there.
    if gain > 0 and dangerZoneOwner(coords) then
        gain = math.floor(gain * Config.DangerZoneMult)
    end

    -- ---- apply gain or decay ----------------------------------------------
    if gain > 0 then
        s.viewers = math.min(Config.MaxViewers, s.viewers + gain)
        if mood == 'idle' then mood = 'hype' end
    else
        s.viewers = math.max(Config.MinViewers, math.floor(s.viewers * (1 - Config.IdleDecayPct)))
    end
    s.peak = math.max(s.peak, s.viewers)

    -- ---- milestones: sustained viewers unlock one-time brand deals --------
    if age >= Config.WarmupSec then
        for _, m in ipairs(Config.Milestones) do
            if not s.unlocked[m.viewers] then
                if s.viewers >= m.viewers then
                    s.sustain[m.viewers] = (s.sustain[m.viewers] or 0) + 1
                    if s.sustain[m.viewers] >= Config.MilestoneSustainTicks then
                        -- Payout snapshotted at unlock; INSERT IGNORE + the
                        -- unique (citizenid, milestone) key make this
                        -- once-per-character no matter what. Only announce
                        -- if the row actually persisted — on a DB hiccup the
                        -- sustain counter is still over threshold next tick,
                        -- so the unlock retries instead of evaporating.
                        -- `paid = 0` is EXPLICIT: the column defaults to 1 so
                        -- the 0060 migration marks legacy rows already-paid; a
                        -- fresh, uncredited deal must start at 0 or the broker
                        -- claim-before-credit (settleDeal) could never pay it.
                        local wrote = pcall(function()
                            MySQL.insert.await([[
                                INSERT IGNORE INTO palm6_clout_deals (citizenid, milestone, payout, paid)
                                VALUES (?, ?, ?, 0)
                            ]], { s.cid, m.viewers, m.payout })
                        end)
                        if wrote then
                            s.unlocked[m.viewers] = true
                            TriggerClientEvent('palm6_clout:milestone', s.src, {
                                viewers = m.viewers, label = m.label,
                            })
                            Bridge.Notify(s.src, 'Brand Deal',
                                ('%d viewers sustained — "%s" unlocked. Cash it at the pawnshop broker.')
                                :format(m.viewers, m.label), 'success')
                        end
                    end
                else
                    s.sustain[m.viewers] = 0
                end
            end
        end
    end

    -- ---- donations ---------------------------------------------------------
    if t >= s.nextDonationAt then
        s.nextDonationAt = t + Config.DonationIntervalSec
        if age >= Config.WarmupSec then
            local chance = math.max(Config.DonationMinChance,
                math.min(Config.DonationMaxChance, s.viewers / Config.DonationViewerDivisor))
            if math.random() < chance then
                local amount = math.random(Config.DonationMin, Config.DonationMax)
                    + math.floor(s.viewers * Config.DonationPerViewer)
                local room = Config.DonationHourlyCap - donationHourSum(s.cid)
                if amount > room then amount = room end
                if amount > 0 and Bridge.CreditCash(s.src, amount, 'clout-donation') then
                    DonationLedger[s.cid] = DonationLedger[s.cid] or {}
                    local ledger = DonationLedger[s.cid]
                    ledger[#ledger + 1] = { ts = t, amt = amount }
                    s.donationTotal = s.donationTotal + amount
                    local donor = Config.DonorNames[math.random(#Config.DonorNames)]
                    TriggerClientEvent('palm6_clout:donation', s.src, {
                        name = donor, amount = amount,
                    })
                end
            end
        end
    end

    -- ---- push display state -----------------------------------------------
    shown = s.viewers
    local trend = 'flat'
    if shown > s.prevShown then trend = 'up'
    elseif shown < s.prevShown then trend = 'down' end
    s.prevShown = shown
    TriggerClientEvent('palm6_clout:tick', s.src, { viewers = shown, mood = mood, trend = trend })
end

CreateThread(function()
    while true do
        Wait(Config.TickIntervalMs)
        if next(Streams) then
            local ctx = { t = now(), players = Bridge.GetPlayersWithCoords(), police = {} }
            for _, pl in ipairs(ctx.players) do
                if Bridge.IsOnDutyPolice(pl.src) then ctx.police[#ctx.police + 1] = pl end
            end

            -- Collect first — tickStream can end (and remove) streams.
            local live = {}
            for _, s in pairs(Streams) do live[#live + 1] = s end
            for _, s in ipairs(live) do
                tickStream(s, ctx)
                s.lastEventTs = ctx.t
            end
        end
        pruneBuffers()
    end
end)

-- ---------------------------------------------------------------------------
-- Brand-deal cashout (pawnshop broker) — recoverable, idempotent settlement.
--
-- Two flags gate a deal's money:
--   * claimed_at — the broker-claim slot. Set once when a deal is cashed;
--                  /clout and the broker read it as "claimed". The conditional
--                  UPDATE ... WHERE claimed_at IS NULL is the double-fire guard.
--   * paid       — the claim-before-credit idempotency flag for the ACTUAL
--                  bank credit (sql/0060). Claimed 0->1 BEFORE the money moves.
--
-- settleDeal() is the single claim-before-credit payout, called from BOTH the
-- live broker path (credit the online source) AND the boot reconcile (credit
-- by citizenid, possibly offline). It claims paid 0->1 first and credits ONLY
-- if it won that claim, so a replay can never double-pay an already-paid deal.
-- If the credit does NOT land (player offline mid-loop, or a lying framework),
-- it reverts BOTH paid and claimed_at so the deal returns to fully claimable —
-- palm6_season's revert idiom. Bias (same as palm6_fightclub): a crash in the
-- tiny window between claiming paid and the credit costs at most that one
-- payout — a rare shortfall, never a mint; the common crash (before the paid
-- claim) is fully recovered on the next boot by reconcileUnpaidDeals().
-- ---------------------------------------------------------------------------

-- Pay ONE deal exactly once. `creditFn(amount)` returns true iff the money
-- landed. Returns the amount actually credited (0 if skipped or reverted).
local function settleDeal(deal, creditFn)
    local payout = tonumber(deal.payout) or 0

    -- Claim the credit BEFORE moving money (never credit-then-mark). Exactly
    -- one settlement run — live or boot-recovery — can flip paid 0->1.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            'UPDATE palm6_clout_deals SET paid = 1 WHERE id = ? AND paid = 0', { deal.id }) == 1
    end)
    if not claimed then return 0 end -- another run already owns this credit

    if payout <= 0 then return 0 end -- claimed a $0 deal; nothing to credit

    if creditFn(payout) then return payout end

    -- Credit did not land — revert BOTH flags so the deal stays claimable and
    -- is re-driven at the broker or on the next boot (palm6_season's revert).
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_clout_deals SET paid = 0, claimed_at = NULL WHERE id = ? AND paid = 1',
            { deal.id })
    end)
    return 0
end

-- Boot reconcile — re-drive any deal left claimed_at IS NOT NULL but paid = 0
-- (server died between the broker claim and the credit, or an offline-mid-loop
-- CreditBank-false stranded it). Idempotent: settleDeal skips anything already
-- paid=1. Delayed in onResourceStart so palm6_dbmigrate's 0060 ALTER (the
-- `paid` column) has landed first — before that the paid = 0 predicate would
-- error (pcall-swallowed) and recover nothing.
reconcileUnpaidDeals = function()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            'SELECT id, citizenid, payout FROM palm6_clout_deals WHERE claimed_at IS NOT NULL AND paid = 0') or {}
    end)
    local recovered, total = 0, 0
    for _, deal in ipairs(pending) do
        local paid = settleDeal(deal, function(amount)
            return Bridge.CreditBankByCitizenId(deal.citizenid, amount, 'clout-brand-deal-recovered')
        end)
        if paid > 0 then
            recovered = recovered + 1
            total = total + paid
            local s = Bridge.GetSourceByCitizenId(deal.citizenid)
            if s then
                Bridge.Notify(s, 'Broker',
                    ('A brand deal that got stuck mid-payout just cleared — $%d to your bank.'):format(paid),
                    'success')
            end
        end
    end
    if recovered > 0 then
        print(('[palm6_clout] boot reconcile paid %d stranded brand deal(s) ($%d)')
            :format(recovered, total))
    end
end

RegisterNetEvent('palm6_clout:requestClaimDeals', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if onCooldown(cid, 'claim', Config.ClaimCooldownSec) then return end

    -- Server-side proximity gate (+3.0 slack over the client prompt radius,
    -- same convention as palm6_evidence/palm6_pumpcoin).
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, Config.PawnshopCoords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Broker', 'You need to be at the broker.', 'error')
        return
    end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT id, milestone, payout FROM palm6_clout_deals WHERE citizenid = ? AND claimed_at IS NULL',
            { cid })
    end)
    if not ok then
        Bridge.Notify(src, 'Broker', 'Ledger is down (DB error). Try again.', 'error')
        return
    end
    if not rows or #rows == 0 then
        Bridge.Notify(src, 'Broker', 'No unclaimed brand deals. Go get famous.', 'inform')
        return
    end

    -- Claim row-by-row: the conditional UPDATE on claimed_at is the double-fire
    -- authority (a re-fired event can't re-enter a deal), then settleDeal does
    -- the claim-before-credit payout. On a credit that doesn't land, settleDeal
    -- reverts claimed_at back to NULL so the deal stays claimable — no strand.
    local total, n = 0, 0
    for _, deal in ipairs(rows) do
        local claimed = 0
        pcall(function()
            claimed = MySQL.update.await(
                'UPDATE palm6_clout_deals SET claimed_at = NOW() WHERE id = ? AND claimed_at IS NULL',
                { deal.id }) or 0
        end)
        if claimed == 1 then
            local paid = settleDeal(deal, function(amount)
                return Bridge.CreditBank(src, amount, 'clout-brand-deal')
            end)
            if paid > 0 then
                total = total + paid
                n = n + 1
            end
        end
    end

    if n > 0 then
        Bridge.Notify(src, 'Broker',
            ('%d brand deal(s) cashed — $%d to your bank.'):format(n, total), 'success')
    else
        Bridge.Notify(src, 'Broker', 'Nothing to cash out.', 'inform')
    end
end)

-- ---------------------------------------------------------------------------
-- Police subpoena: the streamer IS the evidence camera
-- ---------------------------------------------------------------------------
RegisterCommand('subpoena', function(src, args)
    if src == 0 then return end
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Subpoena', 'You need to be on duty as police.', 'error')
        return
    end
    local officerCid = Bridge.GetCitizenId(src)
    if not officerCid then return end

    local targetSrc = math.floor(tonumber(args[1] or 0) or 0)
    local targetCid = targetSrc > 0 and Bridge.GetCitizenId(targetSrc) or nil
    if not targetCid then
        Bridge.Notify(src, 'Subpoena', 'Usage: /subpoena <player id> — target must be online.', 'error')
        return
    end

    -- Serve it in person: officer must be near the streamer.
    local a, b = Bridge.GetCoords(src), Bridge.GetCoords(targetSrc)
    if not a or not b or Bridge.Distance(a, b) > Config.SubpoenaRadius then
        Bridge.Notify(src, 'Subpoena', 'You need to serve the subpoena in person — get closer.', 'error')
        return
    end
    if onCooldown(officerCid, 'subpoena', Config.SubpoenaCooldownSec) then
        Bridge.Notify(src, 'Subpoena', 'The paperwork takes a minute. Cool down.', 'error')
        return
    end

    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT event_type, suspect_name, detail, created_at
            FROM palm6_clout_vod
            WHERE streamer_citizenid = ? AND created_at > NOW() - INTERVAL ? HOUR
            ORDER BY created_at DESC LIMIT ?
        ]], { targetCid, Config.VodRetentionHours, Config.SubpoenaRowLimit })
    end)
    if not ok then
        refundCooldown(officerCid, 'subpoena')
        Bridge.Notify(src, 'Subpoena', 'Records office is down (DB error).', 'error')
        return
    end

    local targetName = Bridge.GetPlayerName(targetSrc)
    if not rows or #rows == 0 then
        Bridge.Notify(src, 'Subpoena',
            ('%s has no clips on record in the last %dh.'):format(targetName, Config.VodRetentionHours), 'inform')
        return
    end

    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ('**%s** — %s%s\n_%s_'):format(
            r.event_type:upper():gsub('_', ' '),
            r.detail or 'clip',
            r.suspect_name and (' — suspect: ' .. r.suspect_name) or '',
            tostring(r.created_at))
    end
    TriggerClientEvent('palm6_clout:showVodLog', src,
        ('VOD — %s (last %dh)'):format(targetName, Config.VodRetentionHours),
        table.concat(lines, '\n\n'))

    Bridge.Notify(targetSrc, 'Subpoena',
        'Police just subpoenaed your last 24h of clips. Everything you filmed is in evidence.', 'error')

    -- palm6_evidence synergy: the served subpoena itself becomes a case-log
    -- entry (soft dependency — silently skipped if the table is absent).
    -- citizenid follows palm6_evidence's own /logevidence semantics: the
    -- OFFICER who filed it. The streamer's citizenid stays in the
    -- description so the full tape remains traceable.
    if Config.WriteEvidenceOnSubpoena then
        pcall(function()
            MySQL.insert.await(
                'INSERT INTO palm6_evidence (citizenid, officer_name, description, coords) VALUES (?, ?, ?, ?)',
                { officerCid, Bridge.GetPlayerName(src),
                  ('VOD SUBPOENA: pulled %d clip(s) from streamer %s covering the last %dh. Full tape: palm6_clout_vod streamer %s.')
                  :format(#rows, targetName, Config.VodRetentionHours, targetCid),
                  json.encode(b) })
        end)
    end
    dbg(('subpoena served on %s by %s — %d rows'):format(targetCid, officerCid, #rows))
end, false)

-- ---------------------------------------------------------------------------
-- /clout — your creator dashboard; /streamers — the leaderboard
-- ---------------------------------------------------------------------------
RegisterCommand('clout', function(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if onCooldown(cid, 'clout', 2) then return end

    local row, deals
    pcall(function()
        row = MySQL.single.await(
            'SELECT total_streams, total_seconds, peak_viewers, total_donations FROM palm6_clout_streamers WHERE citizenid = ?',
            { cid })
        deals = MySQL.query.await(
            'SELECT milestone, payout, claimed_at FROM palm6_clout_deals WHERE citizenid = ? ORDER BY milestone',
            { cid })
    end)

    local lines = {}
    if row then
        lines[#lines + 1] = ('Streams: **%d** — air time: **%dh %dm**')
            :format(row.total_streams, math.floor(row.total_seconds / 3600),
                math.floor((row.total_seconds % 3600) / 60))
        lines[#lines + 1] = ('All-time peak: **%d viewers** — donations: **$%d**')
            :format(row.peak_viewers, row.total_donations)
    else
        lines[#lines + 1] = 'No streams on record. Grab a streamer phone and /golive.'
    end
    local pending = 0
    for _, d in ipairs(deals or {}) do
        if d.claimed_at then
            lines[#lines + 1] = ('~~%d viewers — $%d~~ (claimed)'):format(d.milestone, d.payout or 0)
        else
            pending = pending + 1
            lines[#lines + 1] = ('**%d viewers — $%d** (UNCLAIMED — see the broker)'):format(d.milestone, d.payout or 0)
        end
    end
    if pending > 0 then
        lines[#lines + 1] = ('_%d deal(s) waiting at the pawnshop broker._'):format(pending)
    end
    TriggerClientEvent('palm6_clout:showVodLog', src, 'Creator Dashboard', table.concat(lines, '\n\n'))
end, false)

RegisterCommand('streamers', function(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if onCooldown(cid, 'board', 2) then return end

    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT streamer_name, peak_viewers, total_donations
            FROM palm6_clout_streamers
            WHERE total_streams > 0
            ORDER BY peak_viewers DESC LIMIT ?
        ]], { Config.TopStreamersLimit })
    end)
    if not ok or not rows or #rows == 0 then
        Bridge.Notify(src, 'Clout', 'Nobody has streamed yet. Be first.', 'inform')
        return
    end
    local lines = {}
    for i, r in ipairs(rows) do
        lines[#lines + 1] = ('%d. **%s** — peak %d viewers, $%d earned')
            :format(i, r.streamer_name or 'unknown', r.peak_viewers, r.total_donations)
    end
    TriggerClientEvent('palm6_clout:showVodLog', src, 'Top Streamers', table.concat(lines, '\n'))
end, false)

-- ---------------------------------------------------------------------------
-- Live-list sync for late joiners (throttled per-source — fires on client
-- load, which can be before a character is picked).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_clout:requestLiveSync', function()
    local src = source
    local t = now()
    if SyncLast[src] and (t - SyncLast[src]) < 5 then return end
    SyncLast[src] = t
    local out = {}
    for _, s in pairs(Streams) do
        out[#out + 1] = { src = s.src, name = s.name }
    end
    TriggerClientEvent('palm6_clout:liveSync', src, out)
end)

-- ---------------------------------------------------------------------------
-- Housekeeping: turf-ownership cache + VOD retention pruning
-- ---------------------------------------------------------------------------
CreateThread(function()
    local lastTurf, lastPrune = 0, 0
    while true do
        Wait(Config.SweepIntervalMs)
        local t = now()

        -- palm6_turf ownership cache (soft dependency — table may not exist).
        if Config.DangerZoneEnabled and (t - lastTurf) >= Config.TurfRefreshSec then
            lastTurf = t
            pcall(function()
                local rows = MySQL.query.await(
                    'SELECT zone_id, owner_gang FROM palm6_turf WHERE owner_gang IS NOT NULL') or {}
                local owned = {}
                for _, r in ipairs(rows) do owned[r.zone_id] = r.owner_gang end
                TurfOwned = owned
            end)
        end

        -- VOD pruning keeps the table bounded (once an hour is plenty).
        if (t - lastPrune) >= HOUR then
            lastPrune = t
            pcall(function()
                MySQL.update.await(
                    'DELETE FROM palm6_clout_vod WHERE created_at < NOW() - INTERVAL ? DAY',
                    { Config.VodPruneDays })
            end)
        end
    end
end)
