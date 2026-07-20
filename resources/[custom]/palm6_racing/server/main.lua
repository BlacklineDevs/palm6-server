-- ============================================================================
-- palm6_racing/server/main.lua
--
-- Street-racing lifecycle + the single authority. Owns the in-memory race state
-- (LOBBY -> COUNTDOWN -> LIVE -> RESOLVED), server-validated checkpoint progress
-- (anti-cheat: order + min-interval + server-coord proximity), rep award, and the
-- leaderboard ledger. Pure logic — all framework/native access goes through Bridge.*
--
-- Phase 0 is REP-ONLY: no bank money moves anywhere in this resource, so there is no
-- faucet to guard (unlike palm6_fightclub). Rep is display/ladder only. Money (entry
-- stakes + parimutuel betting) arrives in Phase 1 on palm6_fightclub's proven engine.
-- Ships behind Config.Enabled (prod-inert while false).
-- ============================================================================

local races        = {}   -- [raceId] = race table (see createRace)
local activeByCid  = {}    -- [cid] = raceId  (a driver is in at most one race)
local activeBySrc  = {}    -- [src] = raceId  (playerDropped routing)
local raceSeq      = 0
local lastAction   = {}    -- [src][key] = ts — command spam guard
local bootDone     = false

local RATE = { startrace = 5, joinrace = 2, racego = 2, raceleave = 2, races = 2, racetop = 3, racecp = 1 }

local function now() return os.time() end

local function dbg(msg) if Config and Config.Debug then print('[palm6_racing] ' .. msg) end end

local function enabled() return Config and Config.Enabled == true end

local function rl(src, key)
    local window = RATE[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- ---------------------------------------------------------------------------
-- Gates
-- ---------------------------------------------------------------------------
local function atMeet(src)
    local c = Bridge.GetCoords(src)
    if not c or not Config.Meet then return false end
    return Bridge.Distance(c, Config.Meet.coords) <= (Config.Meet.radius or 40.0)
end

local function routeById(routeId)
    for _, r in ipairs(Config.Routes or {}) do
        if r.id == routeId then return r end
    end
    return nil
end

-- Exactly one active (lobby/countdown/live) race at a time in Phase 0 (single meet).
local function currentActiveRace()
    for id, r in pairs(races) do
        if r.status ~= 'resolved' then return id, r end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function addRacer(r, src, cid)
    local name = Bridge.GetPlayerName(src)
    r.racers[cid] = {
        src = src, cid = cid, name = name,
        cpIndex = 1,            -- next checkpoint to hit (1 = start line; 2 = first real CP)
        lastCpAt = 0, finishAt = nil, place = nil, dnf = false,
    }
    r.racerOrder[#r.racerOrder + 1] = cid
    activeByCid[cid] = r.id
    activeBySrc[src] = r.id
end

local function racerCount(r)
    local n = 0
    for _ in pairs(r.racers) do n = n + 1 end
    return n
end

local function broadcastRacers(r)
    -- Push the current grid to every racer's client (HUD/lobby list).
    local grid = {}
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc then grid[#grid + 1] = { name = rc.name, cid = cid } end
    end
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc and rc.src then
            TriggerClientEvent('palm6_racing:lobby', rc.src,
                { raceId = r.id, routeName = r.route.name, grid = grid, joinSecLeft = math.max(0, (r.joinEndsAt or 0) - now()) })
        end
    end
end

-- Teardown: tell every racer's client to clear its race UI, free the maps.
local function teardownRace(raceId)
    local r = races[raceId]
    if not r then return end
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc then
            if rc.src then TriggerClientEvent('palm6_racing:teardown', rc.src, { raceId = raceId }) end
            if activeByCid[cid] == raceId then activeByCid[cid] = nil end
            if rc.src and activeBySrc[rc.src] == raceId then activeBySrc[rc.src] = nil end
        end
    end
    races[raceId] = nil
    dbg(('race #%d torn down'):format(raceId))
end

-- Forward declares (resolveRace references awardResults defined later).
local awardResults

-- Compute final places for everyone who finished (in finish order), mark the rest
-- DNF, award rep, log the leaderboard, then tear down.
local function resolveRace(raceId, reason)
    local r = races[raceId]
    if not r or r.status == 'resolved' then return end
    r.status = 'resolved'

    -- finishers already have .place set in finish order; collect them + the field size.
    local finishers = {}
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc and rc.finishAt then finishers[#finishers + 1] = rc end
    end
    table.sort(finishers, function(a, b) return (a.place or 99) < (b.place or 99) end)

    local fieldSize = #r.racerOrder
    local solo = fieldSize <= 1
    for _, rc in pairs(r.racers) do
        if rc.src then
            TriggerClientEvent('palm6_racing:result', rc.src, {
                raceId = raceId, place = rc.place, finished = rc.finishAt ~= nil,
                fieldSize = fieldSize, routeName = r.route.name,
            })
        end
    end

    -- Persist + rep (rep-only, no money) off the AUTHORITATIVE server places.
    awardResults(r, finishers, solo)

    dbg(('race #%d resolved (%s) — %d/%d finished'):format(raceId, reason or '?', #finishers, fieldSize))
    teardownRace(raceId)
end

-- A racer crossed the final checkpoint -> record finish order (server authoritative).
local function finishRacer(r, rc)
    if rc.finishAt then return end
    rc.finishAt = now()
    -- place = number already finished + 1
    local finishedSoFar = 0
    for _, cid in ipairs(r.racerOrder) do
        local o = r.racers[cid]
        if o and o.finishAt and o ~= rc then finishedSoFar = finishedSoFar + 1 end
    end
    rc.place = finishedSoFar + 1
    if rc.src then
        Bridge.Notify(rc.src, 'Racing', ('You finished P%d.'):format(rc.place), rc.place == 1 and 'success' or 'inform')
        -- advance the client past the last checkpoint (sentinel) so it stops polling.
        TriggerClientEvent('palm6_racing:cpAck', rc.src, { raceId = r.id, next = #r.route.checkpoints + 1, total = #r.route.checkpoints })
    end
    -- All racers accounted for (finished or DNF)? -> resolve now.
    local pending = 0
    for _, cid in ipairs(r.racerOrder) do
        local o = r.racers[cid]
        if o and not o.finishAt and not o.dnf then pending = pending + 1 end
    end
    if pending == 0 then resolveRace(r.id, 'all-finished') end
end

local function startCountdownThenLive(raceId)
    local r = races[raceId]
    if not r or r.status ~= 'lobby' then return end
    if racerCount(r) < (Config.Lobby.MinRacers or 1) then
        for _, cid in ipairs(r.racerOrder) do
            local rc = r.racers[cid]
            if rc and rc.src then Bridge.Notify(rc.src, 'Racing', 'Not enough drivers — race cancelled.', 'error') end
        end
        teardownRace(raceId)
        return
    end
    r.status = 'countdown'
    local cd = Config.Lobby.CountdownSec or 5
    local cps = r.route.checkpoints
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc and rc.src then
            TriggerClientEvent('palm6_racing:start', rc.src,
                { raceId = raceId, checkpoints = cps, radius = Config.Race.CheckpointRadius or 15.0,
                  countdown = cd, pollMs = Config.Race.PollMs or 250 })
        end
    end
    CreateThread(function()
        Wait(cd * 1000)
        local rr = races[raceId]
        if not rr or rr.status ~= 'countdown' then return end
        rr.status = 'live'
        rr.liveAt = now()
        for _, cid in ipairs(rr.racerOrder) do
            local rc = rr.racers[cid]
            if rc then rc.cpIndex = 2 end   -- next real checkpoint after the grid/start
        end
        dbg(('race #%d LIVE'):format(raceId))
        -- DNF timeout backstop.
        CreateThread(function()
            Wait((Config.Race.DnfTimeoutSec or 420) * 1000)
            local r3 = races[raceId]
            if r3 and r3.status == 'live' then resolveRace(raceId, 'timeout') end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
local function cmdStartRace(src, args)
    if src == 0 then return end
    if not enabled() or not bootDone then return end
    if not rl(src, 'startrace') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atMeet(src) then
        Bridge.Notify(src, 'Racing', ('You must be at %s.'):format(Config.Meet.label), 'error'); return
    end
    if not Bridge.DriverVehicle(src) then
        Bridge.Notify(src, 'Racing', 'Get in a car first.', 'error'); return
    end
    if activeByCid[cid] then
        Bridge.Notify(src, 'Racing', 'You are already in a race.', 'error'); return
    end
    if currentActiveRace() then
        Bridge.Notify(src, 'Racing', 'A race is already forming at the meet — /joinrace.', 'error'); return
    end
    local routeId = args[1]
    local route = routeId and routeById(routeId) or (Config.Routes or {})[1]
    if not route then
        Bridge.Notify(src, 'Racing', 'No routes configured.', 'error'); return
    end

    raceSeq = raceSeq + 1
    local raceId = raceSeq
    races[raceId] = {
        id = raceId, routeId = route.id, route = route, hostCid = cid,
        status = 'lobby', racers = {}, racerOrder = {}, createdAt = now(),
        joinEndsAt = now() + (Config.Lobby.JoinWindowSec or 45),
    }
    addRacer(races[raceId], src, cid)
    Bridge.Notify(src, 'Racing', ('Race created: %s. Others /joinrace (%ds), then /racego.'):format(route.name, Config.Lobby.JoinWindowSec or 45), 'success')
    broadcastRacers(races[raceId])

    -- Auto-start when the join window closes (host can /racego sooner).
    CreateThread(function()
        Wait((Config.Lobby.JoinWindowSec or 45) * 1000)
        local r = races[raceId]
        if r and r.status == 'lobby' then startCountdownThenLive(raceId) end
    end)
    dbg(('race #%d created by %s on %s'):format(raceId, cid, route.id))
end

local function cmdJoinRace(src)
    if src == 0 then return end
    if not enabled() or not bootDone then return end
    if not rl(src, 'joinrace') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if activeByCid[cid] then Bridge.Notify(src, 'Racing', 'You are already in a race.', 'error'); return end
    if not atMeet(src) then Bridge.Notify(src, 'Racing', ('You must be at %s.'):format(Config.Meet.label), 'error'); return end
    if not Bridge.DriverVehicle(src) then Bridge.Notify(src, 'Racing', 'Get in a car first.', 'error'); return end
    local raceId, r = currentActiveRace()
    if not r or r.status ~= 'lobby' then Bridge.Notify(src, 'Racing', 'No race is forming right now — /startrace.', 'error'); return end
    if racerCount(r) >= (Config.Lobby.MaxRacers or 8) then Bridge.Notify(src, 'Racing', 'The grid is full.', 'error'); return end
    addRacer(r, src, cid)
    Bridge.Notify(src, 'Racing', ('Joined: %s.'):format(r.route.name), 'success')
    broadcastRacers(r)
end

local function cmdRaceGo(src)
    if src == 0 then return end
    if not rl(src, 'racego') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local raceId, r = currentActiveRace()
    if not r or r.status ~= 'lobby' then return end
    if r.hostCid ~= cid then Bridge.Notify(src, 'Racing', 'Only the host can start the race.', 'error'); return end
    startCountdownThenLive(raceId)
end

local function cmdRaceLeave(src)
    if src == 0 then return end
    if not rl(src, 'raceleave') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local raceId = activeByCid[cid]
    if not raceId then return end
    local r = races[raceId]
    if not r then activeByCid[cid] = nil; return end
    local rc = r.racers[cid]
    if r.status == 'lobby' then
        -- leaving the lobby: drop out; if the host leaves, cancel the whole race.
        r.racers[cid] = nil
        activeByCid[cid] = nil
        if rc and rc.src and activeBySrc[rc.src] == raceId then activeBySrc[rc.src] = nil end
        for i, c in ipairs(r.racerOrder) do if c == cid then table.remove(r.racerOrder, i) break end end
        if cid == r.hostCid or racerCount(r) == 0 then
            for _, oc in ipairs(r.racerOrder) do
                local o = r.racers[oc]
                if o and o.src then Bridge.Notify(o.src, 'Racing', 'The host left — race cancelled.', 'inform') end
            end
            teardownRace(raceId)
        else
            Bridge.Notify(src, 'Racing', 'You left the race.', 'inform')
            broadcastRacers(r)
        end
    else
        -- live/countdown: mark DNF, resolve if that empties the field.
        if rc then rc.dnf = true end
        if rc and rc.src then TriggerClientEvent('palm6_racing:teardown', rc.src, { raceId = raceId }) end
        activeByCid[cid] = nil
        if rc and rc.src and activeBySrc[rc.src] == raceId then activeBySrc[rc.src] = nil end
        Bridge.Notify(src, 'Racing', 'You dropped out (DNF).', 'inform')
        local pending = 0
        for _, oc in ipairs(r.racerOrder) do
            local o = r.racers[oc]
            if o and not o.finishAt and not o.dnf then pending = pending + 1 end
        end
        if pending == 0 then resolveRace(raceId, 'field-empty') end
    end
end

local function cmdRaces(src)
    if src == 0 then return end
    if not rl(src, 'races') then return end
    local _, r = currentActiveRace()
    if not r then Bridge.Reply(src, { 'No race forming. Get in a car at the meet and /startrace.' }); return end
    Bridge.Reply(src, {
        ('%s — %s — %d driver(s) [%s]'):format(r.route.name, r.status, racerCount(r),
            r.status == 'lobby' and ('/joinrace, ' .. math.max(0, (r.joinEndsAt or 0) - now()) .. 's') or r.status),
    })
end

-- ---------------------------------------------------------------------------
-- Checkpoint net event — the anti-cheat gate. The client reports "I reached CP N";
-- the server validates it is THIS driver's live race, the CORRECT next checkpoint,
-- not too soon after the last (teleport/skip), AND the driver's SERVER ped coords
-- are actually within range of that checkpoint (client can't claim a CP it is not
-- at). Only then does progress advance; the last checkpoint = a finish.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_racing:checkpoint', function(payload)
    local src = source
    if not enabled() or type(payload) ~= 'table' then return end
    local raceId = tonumber(payload.raceId)
    local cpIndex = tonumber(payload.cpIndex)
    if not raceId or not cpIndex then return end
    local r = races[raceId]
    if not r or r.status ~= 'live' then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local rc = r.racers[cid]
    if not rc or rc.src ~= src or rc.finishAt or rc.dnf then return end
    if cpIndex ~= rc.cpIndex then return end                       -- must be the NEXT checkpoint, in order

    local cp = r.route.checkpoints[cpIndex]
    if not cp then return end

    local nowMs = now()
    if (nowMs - (rc.lastCpAt or 0)) < (Config.Race.MinCheckpointSec or 1) then return end  -- teleport/skip guard

    -- server-coord proximity: the driver must ACTUALLY be near the checkpoint. Radius
    -- is padded generously over the client radius so honest lag never false-rejects.
    local coords = Bridge.GetCoords(src)
    local tol = (Config.Race.CheckpointRadius or 15.0) * 2.0 + 10.0
    if coords and Bridge.Distance(coords, cp) > tol then
        dbg(('race #%d: %s CP%d rejected — %.0fm from checkpoint'):format(raceId, cid, cpIndex, Bridge.Distance(coords, cp)))
        return
    end

    rc.lastCpAt = nowMs
    rc.cpIndex = cpIndex + 1
    if cpIndex >= #r.route.checkpoints then
        finishRacer(r, rc)                                          -- crossed the final checkpoint
    else
        if rc.src then TriggerClientEvent('palm6_racing:cpAck', rc.src, { raceId = raceId, next = rc.cpIndex, total = #r.route.checkpoints }) end
    end
end)

-- ---------------------------------------------------------------------------
-- DC handling — a drop is a leave (lobby: remove/cancel; live: DNF).
-- ---------------------------------------------------------------------------
AddEventHandler('playerDropped', function()
    local src = source
    local raceId = activeBySrc[src]
    if not raceId then return end
    local r = races[raceId]
    if not r then activeBySrc[src] = nil; return end
    -- find this src's cid within the race
    local dropCid
    for _, cid in ipairs(r.racerOrder) do
        local rc = r.racers[cid]
        if rc and rc.src == src then dropCid = cid break end
    end
    activeBySrc[src] = nil
    if not dropCid then return end
    local rc = r.racers[dropCid]
    if r.status == 'lobby' then
        r.racers[dropCid] = nil
        activeByCid[dropCid] = nil
        for i, c in ipairs(r.racerOrder) do if c == dropCid then table.remove(r.racerOrder, i) break end end
        if dropCid == r.hostCid or racerCount(r) == 0 then teardownRace(raceId)
        else broadcastRacers(r) end
    else
        if rc then rc.dnf = true; rc.src = nil end
        activeByCid[dropCid] = nil
        local pending = 0
        for _, oc in ipairs(r.racerOrder) do
            local o = r.racers[oc]
            if o and not o.finishAt and not o.dnf then pending = pending + 1 end
        end
        if pending == 0 then resolveRace(raceId, 'field-empty') end
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(6000)   -- let palm6_dbmigrate land the racing tables first
        bootDone = true
        print('[palm6_racing] ready — Enabled=' .. tostring(enabled()))
    end)
end)

-- ---------------------------------------------------------------------------
-- Rep + leaderboard (rep-only, no money — nothing here can create bank cash).
-- Anti-farm: rolling-24h DailyRepCap on rep-granting finishes; solo pays a fraction.
-- ---------------------------------------------------------------------------
local RANK = (Config.Rep and Config.Rep.RankThresholds) or { 250, 700, 1500, 3000, 5500 }
local function rankForRep(rep)
    rep = tonumber(rep) or 0
    local tier = 0
    for i = 1, #RANK do if rep >= RANK[i] then tier = i else break end end
    return tier
end

local function repDailyCount(cid)
    local n = 0
    pcall(function()
        local row = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_racing_results WHERE citizenid = ? AND rep > 0 AND created_at >= (NOW() - INTERVAL 24 HOUR)",
            { cid })
        if row then n = tonumber(row.n) or 0 end
    end)
    return n
end

local function bumpProgression(cid, name, repGain, won)
    pcall(function()
        MySQL.insert.await([[
            INSERT INTO palm6_racing_progression (citizenid, name, rep, wins, races, rank_tier)
            VALUES (?, ?, ?, ?, 1, 0)
            ON DUPLICATE KEY UPDATE
                name = VALUES(name), rep = rep + VALUES(rep), wins = wins + VALUES(wins), races = races + 1
        ]], { cid, name or cid, repGain, won and 1 or 0 })
    end)
    local newRep = repGain
    pcall(function()
        local row = MySQL.single.await("SELECT rep FROM palm6_racing_progression WHERE citizenid = ?", { cid })
        if row then newRep = tonumber(row.rep) or repGain end
    end)
    pcall(function()
        MySQL.update.await("UPDATE palm6_racing_progression SET rank_tier = ? WHERE citizenid = ?", { rankForRep(newRep), cid })
    end)
end

-- assign the forward-declared local (resolveRace calls this by name at runtime).
awardResults = function(r, finishers, solo)
    local cfg = Config.Rep or {}
    for _, rc in ipairs(finishers) do
        local base
        if rc.place == 1 then base = cfg.RepPerWin or 50
        elseif rc.place == 2 or rc.place == 3 then base = cfg.RepPerPodium or 20
        else base = cfg.RepPerFinish or 5 end
        if solo then base = math.floor(base * (cfg.SoloRepFactor or 0.25)) end

        local capped  = repDailyCount(rc.cid) >= (cfg.DailyRepCap or 12)
        local repGain = capped and 0 or base

        pcall(function()
            MySQL.insert.await(
                "INSERT INTO palm6_racing_results (citizenid, route_id, place, rep) VALUES (?, ?, ?, ?)",
                { rc.cid, r.routeId, rc.place, repGain })
        end)
        bumpProgression(rc.cid, rc.name, repGain, rc.place == 1)

        if rc.src and repGain > 0 then
            Bridge.Notify(rc.src, 'Racing', ('P%d — +%d rep.'):format(rc.place, repGain), rc.place == 1 and 'success' or 'inform')
        elseif rc.src and capped then
            Bridge.Notify(rc.src, 'Racing', ('P%d — no rep (daily cap).'):format(rc.place), 'inform')
        end
    end
end

local function cmdRaceTop(src)
    if src == 0 then return end
    if not rl(src, 'racetop') then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await(
            "SELECT name, citizenid, rep, wins, races FROM palm6_racing_progression ORDER BY rep DESC LIMIT 10") or {}
    end)
    if #rows == 0 then Bridge.Reply(src, { 'No race results yet — be the first: /startrace at the meet.' }); return end
    local lines = { 'Top racers:' }
    for i, row in ipairs(rows) do
        lines[#lines + 1] = ('%d. %s — %d rep (%d wins / %d races)')
            :format(i, row.name or row.citizenid, tonumber(row.rep) or 0, tonumber(row.wins) or 0, tonumber(row.races) or 0)
    end
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- Admin route builder — drive the route, /racecp at each point, /racecpdump to
-- print a ready-to-paste `checkpoints = { ... }` block for shared/config.lua.
-- Ace-gated (palm6_racing.admin). Solves the "placeholder coords" problem in-game.
-- ---------------------------------------------------------------------------
local cpBuffers = {}   -- [key] = { {x,y,z}, ... }
local function cpKey(src) return Bridge.GetCitizenId(src) or ('src' .. tostring(src)) end

local function cmdRaceCp(src)
    if not Bridge.IsAdmin(src) then return end
    if not rl(src, 'racecp') then return end
    local c = Bridge.GetCoords(src)
    if not c then return end
    local k = cpKey(src)
    cpBuffers[k] = cpBuffers[k] or {}
    table.insert(cpBuffers[k], c)
    Bridge.Reply(src, { ('CP %d: { x = %.1f, y = %.1f, z = %.1f },'):format(#cpBuffers[k], c.x, c.y, c.z) })
end

local function cmdRaceCpDump(src)
    if not Bridge.IsAdmin(src) then return end
    local buf = cpBuffers[cpKey(src)]
    if not buf or #buf == 0 then
        Bridge.Reply(src, { 'No checkpoints captured. Drive the route and /racecp at the start, each turn, and the finish.' }); return
    end
    local lines = { 'checkpoints = {' }
    for _, c in ipairs(buf) do lines[#lines + 1] = ('    { x = %.1f, y = %.1f, z = %.1f },'):format(c.x, c.y, c.z) end
    lines[#lines + 1] = '},'
    Bridge.Reply(src, lines)
end

local function cmdRaceCpClear(src)
    if not Bridge.IsAdmin(src) then return end
    cpBuffers[cpKey(src)] = nil
    Bridge.Reply(src, { 'Checkpoint buffer cleared.' })
end

Bridge.RegisterCommand('startrace', function(source, args) cmdStartRace(source, args) end)
Bridge.RegisterCommand('joinrace', function(source) cmdJoinRace(source) end)
Bridge.RegisterCommand('racego', function(source) cmdRaceGo(source) end)
Bridge.RegisterCommand('raceleave', function(source) cmdRaceLeave(source) end)
Bridge.RegisterCommand('races', function(source) cmdRaces(source) end)
Bridge.RegisterCommand('racetop', function(source) cmdRaceTop(source) end)
Bridge.RegisterCommand('racecp', function(source) cmdRaceCp(source) end)
Bridge.RegisterCommand('racecpdump', function(source) cmdRaceCpDump(source) end)
Bridge.RegisterCommand('racecpclear', function(source) cmdRaceCpClear(source) end)
