-- ============================================================================
-- palm6_smuggling/server/main.lua
--
-- Pure logic. Calls Bridge.* for all framework / inventory / police / evidence
-- / native access. No direct framework / native calls here (§6 gate).
--
-- Standalone contraband smuggling runs: /smuggle at the hidden pickup starts a
-- server-tracked run to a randomly assigned drop (land/sea/air) under a
-- deadline, and pings police to intercept; /deliver at that drop within the
-- time pays DIRTY (black_money) and leaves a palm6_evidence trail. The run is
-- STATE, not a carried item — nothing to register, nothing a client can forge.
-- ============================================================================

local lastStart = {}   -- [src] = ts of last /smuggle (spam guard)
AddEventHandler('playerDropped', function() lastStart[source] = nil end)  -- reclaim on disconnect
local runLock   = {}   -- [citizenid] = true while a start/deliver is in flight
local enabled   = false

-- Fixed drop lookup by id.
local DropById = {}
for _, d in ipairs(Config.Dropoffs) do DropById[d.id] = d end

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_smuggling] ' .. msg) end
end

local function atPickup(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Pickup.coords) <= Config.Pickup.radius
end

-- ---------------------------------------------------------------------------
-- /smuggle — start a run at the pickup.
-- ---------------------------------------------------------------------------
local function cmdSmuggle(src)
    if src == 0 then return end
    if not enabled then Bridge.Notify(src, 'Smuggling', 'No shipments right now.', 'error'); return end
    local t = now()
    if (lastStart[src] or 0) + Config.CooldownSec > t then
        Bridge.Notify(src, 'Smuggling', ('Lay low — nothing new for %ds.'):format((lastStart[src] or 0) + Config.CooldownSec - t), 'error')
        return
    end
    lastStart[src] = t

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atPickup(src) then
        Bridge.Notify(src, 'Smuggling', ('Find %s.'):format(Config.Pickup.label), 'error'); return
    end
    if runLock[cid] then Bridge.Notify(src, 'Smuggling', 'One thing at a time.', 'error'); return end
    runLock[cid] = true

    local existing
    pcall(function()
        existing = MySQL.single.await(
            "SELECT id FROM palm6_smuggling_runs WHERE citizenid = ? AND status = 'active' AND expires_at > NOW() LIMIT 1", { cid })
    end)
    if existing then
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'You already have a shipment in transit — drop it first.', 'error'); return
    end

    local d = Config.Dropoffs[math.random(1, #Config.Dropoffs)]
    local payout = math.random(d.payoutMin, d.payoutMax)
    local ok = pcall(function()
        MySQL.insert.await(
            "INSERT INTO palm6_smuggling_runs (citizenid, dropoff_id, mode, payout, expires_at) VALUES (?, ?, ?, ?, NOW() + INTERVAL ? SECOND)",
            { cid, d.id, d.mode, payout, Config.RunTimeLimitSec })
    end)
    if not ok then
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'The contact waved you off — try again.', 'error'); return
    end

    Bridge.PoliceAlert(src, 'Contraband movement reported near the docks')
    runLock[cid] = nil
    Bridge.Notify(src, 'Smuggling',
        ('Shipment loaded. Run it to %s (%s) within %d min — $%d on delivery.'):format(
            d.label, d.mode:upper(), math.floor(Config.RunTimeLimitSec / 60), payout), 'success')
    dbg(('%s started run to %s (%s, $%d)'):format(cid, d.id, d.mode, payout))
end

-- ---------------------------------------------------------------------------
-- /deliver — make the drop.
-- ---------------------------------------------------------------------------
local function cmdDeliver(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if runLock[cid] then Bridge.Notify(src, 'Smuggling', 'One thing at a time.', 'error'); return end
    runLock[cid] = true

    local run
    pcall(function()
        run = MySQL.single.await(
            "SELECT id, dropoff_id, payout, (expires_at > NOW()) AS live FROM palm6_smuggling_runs WHERE citizenid = ? AND status = 'active' ORDER BY id DESC LIMIT 1",
            { cid })
    end)
    if not run then
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'You have no shipment to drop.', 'inform'); return
    end
    if tonumber(run.live) ~= 1 then
        pcall(function()
            MySQL.update.await("UPDATE palm6_smuggling_runs SET status = 'expired', closed_at = NOW() WHERE id = ? AND status = 'active'", { run.id })
        end)
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'That shipment went cold — you missed the window.', 'error'); return
    end

    local d = DropById[run.dropoff_id]
    if not d then runLock[cid] = nil; Bridge.Notify(src, 'Smuggling', 'Bad drop — void run.', 'error'); return end

    local c = Bridge.GetCoords(src)
    if not c or Bridge.Distance(c, d.coords) > Config.DeliverRadius then
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', ('Not at the drop — get to %s.'):format(d.label), 'error'); return
    end

    -- Claim the delivery atomically before paying (guarded on the live active
    -- state), so a second /deliver or the expiry sweep can't double-pay it.
    local claimed = false
    pcall(function()
        local aff = MySQL.update.await(
            "UPDATE palm6_smuggling_runs SET status = 'delivered', closed_at = NOW() WHERE id = ? AND status = 'active' AND expires_at > NOW()",
            { run.id })
        claimed = (tonumber(aff) or 0) > 0
    end)
    if not claimed then
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'That shipment just went cold.', 'error'); return
    end

    local payout = tonumber(run.payout)
    if not Bridge.GiveDirty(src, Config.DirtyItem, payout) then
        -- Restore the run so the payout isn't lost on a rare give failure.
        pcall(function()
            MySQL.update.await("UPDATE palm6_smuggling_runs SET status = 'active', closed_at = NULL WHERE id = ?", { run.id })
        end)
        runLock[cid] = nil
        Bridge.Notify(src, 'Smuggling', 'Couldn\'t take the cash — try the drop again.', 'error'); return
    end

    -- Leave the trail.
    local caseId = Bridge.EvidenceEnsureCase(
        ('%s%s-%d'):format(Config.Evidence.IncidentKeyPrefix, cid, math.floor(now() / 300)),
        Config.Evidence.CaseTitle, 'palm6_smuggling')
    if caseId then
        Bridge.EvidenceAppend(caseId, 'smuggling_run', { dropoff = d.label, mode = d.mode, payout = payout }, 'palm6_smuggling')
        Bridge.EvidenceLinkSuspect(caseId, cid, nil)
        pcall(function() MySQL.update.await("UPDATE palm6_smuggling_runs SET evidence_case_id = ? WHERE id = ?", { caseId, run.id }) end)
    end

    runLock[cid] = nil
    -- Hype: bigger sea/air runs make the news (small land drops stay quiet).
    if payout >= Config.AnnounceMinPayout then
        Bridge.Announce('heat', {
            title = 'Contraband on the move',
            description = ('Word is a %s shipment slipped through to %s tonight.'):format(
                tostring(d.mode):upper(), d.label),
        })
    end
    Bridge.Notify(src, 'Smuggling', ('Dropped. $%d dirty — get it laundered.'):format(payout), 'success')

    -- Persistent police attention: a cross-map contraband run is a serious
    -- crime. Keyed to the runner (cid) so it follows them after they log. Fires
    -- only after the atomic delivery claim + payout above. Soft-dep + pcall — a
    -- stopped palm6_heat never touches the delivery path.
    if GetResourceState('palm6_heat') == 'started' then
        pcall(function()
            exports.palm6_heat:AddHeat(cid, Config.HeatOnDeliver, 'smuggle_run')
        end)
    end

    dbg(('%s delivered run %d for $%d'):format(cid, run.id, payout))
end

-- ---------------------------------------------------------------------------
-- /smugglerun — read-only: your active run.
-- ---------------------------------------------------------------------------
local function cmdRun(src)
    if src == 0 then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local run
    pcall(function()
        run = MySQL.single.await(
            "SELECT dropoff_id, mode, payout, TIMESTAMPDIFF(SECOND, NOW(), expires_at) AS secs FROM palm6_smuggling_runs WHERE citizenid = ? AND status = 'active' AND expires_at > NOW() ORDER BY id DESC LIMIT 1",
            { cid })
    end)
    if not run then
        Bridge.Notify(src, 'Smuggling', 'No active shipment. Start one at the docks.', 'inform'); return
    end
    local d = DropById[run.dropoff_id]
    local secs = tonumber(run.secs) or 0
    Bridge.Notify(src, 'Smuggling',
        ('Deliver to %s (%s) · $%d · %dm%02ds left'):format(
            d and d.label or run.dropoff_id, tostring(run.mode):upper(), tonumber(run.payout), math.floor(secs / 60), secs % 60), 'inform')
end

-- ---------------------------------------------------------------------------
-- Commands, expiry sweep, boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('smuggle', function(source) cmdSmuggle(source) end)
Bridge.RegisterCommand('deliver', function(source) cmdDeliver(source) end)
Bridge.RegisterCommand('smugglerun', function(source) cmdRun(source) end)

CreateThread(function()
    while true do
        Wait(120000)  -- expire abandoned runs so state stays tidy
        if enabled then
            pcall(function()
                MySQL.update.await("UPDATE palm6_smuggling_runs SET status = 'expired', closed_at = NOW() WHERE status = 'active' AND expires_at <= NOW()")
            end)
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not Bridge.ItemExists(Config.DirtyItem) then
        print(('^1[palm6_smuggling] FATAL: payout item "%s" is not registered in ox_inventory — smuggling disabled.^0'):format(Config.DirtyItem))
        return
    end
    enabled = true
    local delivered, dirty = 0, 0
    pcall(function()
        local r = MySQL.single.await("SELECT COUNT(*) AS c, COALESCE(SUM(payout),0) AS s FROM palm6_smuggling_runs WHERE status = 'delivered'")
        delivered = r and tonumber(r.c) or 0
        dirty = r and tonumber(r.s) or 0
    end)
    print(('[palm6_smuggling] routes open — %d drop site(s) (land/sea/air), %d run(s) delivered ($%d dirty all-time); evidence %s'):format(
        #Config.Dropoffs, delivered, dirty, Bridge.ResourceStarted('palm6_evidence') and 'ONLINE' or 'offline'))
end)

--- Totals for devtest and future consumers.
exports('GetSummary', function()
    local out = { dropSites = #Config.Dropoffs, delivered = 0, active = 0, dirtyPaid = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT SUM(status='delivered') AS d, SUM(status='active' AND expires_at > NOW()) AS a, COALESCE(SUM(CASE WHEN status='delivered' THEN payout ELSE 0 END),0) AS p FROM palm6_smuggling_runs")
        if r then out.delivered = tonumber(r.d) or 0; out.active = tonumber(r.a) or 0; out.dirtyPaid = tonumber(r.p) or 0 end
    end)
    return out
end)
