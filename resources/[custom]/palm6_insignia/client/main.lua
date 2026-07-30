-- ============================================================================
-- palm6_insignia/client/main.lua
--
-- Renders every nearby officer's name tape from the SERVER-supplied roster.
--
-- This file composes nothing. It receives { id, l1, l2, badge } rows and draws
-- l1 and l2. It cannot invent an identity, and it cannot render one the server
-- did not publish, which is what makes "each client draws every officer it can
-- see" safe rather than a self-labelling exploit.
--
-- Every GTA native this file needs goes through Game.* (bridge/cl_game.lua).
-- That is now literally true: the last direct call left here, DoesEntityExist
-- in the draw loop, is Game.EntityExists. Note what the test suite actually
-- pins, though: it asserts GetActivePlayers is absent from THE BRIDGE, so the
-- bridge discipline is a convention this file keeps, not something the suite
-- can enforce on this file.
--
-- ---------------------------------------------------------------------------
-- THE COST BUDGET, AND HOW IT IS ENFORCED
--
--   SCAN loop    every Config.Render.ScanIntervalMs (250ms default)
--                iterates the ROSTER only - on-duty officers, hard-capped at
--                Config.Roster.MaxEntries by the server. Never
--                GetActivePlayers(), never a ped scan. Produces a candidate
--                list already truncated to Config.Render.MaxTapes.
--
--   DRAW loop    every frame, but ONLY over that pre-built candidate list, so
--                its length is bounded by Config.Render.MaxTapes (5) no matter
--                how many officers or players exist.
--
--   IDLE         with an empty roster the scan sleeps Config.Render.
--                IdleIntervalMs and never touches a ped; with no candidate the
--                draw loop does the same. A server with no police on duty pays
--                one cheap timer tick per second and nothing else.
--
-- Text width, line height and the bone index are all resolved in the SCAN loop
-- and cached on the candidate. The draw loop measures and resolves nothing.
-- ============================================================================

local roster     = {}      -- serverId -> { id, l1, l2, badge }
local rosterSize = 0
local candidates = {}      -- rebuilt by the scan, read by the draw
local running    = true
local style                -- Config.Render flattened once, see below

-- Live, client-local tuning for the anchor. Nil means "use the config list".
-- These exist so David can correct a wrong anchor IN GAME and report the value
-- that worked, instead of anyone guessing a replacement.
local boneOverride    = nil
local offsetOverride  = nil   -- { forward, up }

-- One-time diagnostics, so a broken anchor says so once instead of every frame.
local warnedNoBone   = false
local lastBoneName   = nil

local function boneNameList()
    if boneOverride then return { boneOverride } end
    return Config.Render.BoneNames
end

local function offsets()
    if offsetOverride then return offsetOverride[1], offsetOverride[2] end
    return Config.Render.OffsetForward, Config.Render.OffsetUp
end

local function countRoster()
    local n = 0
    for _ in pairs(roster) do n = n + 1 end
    rosterSize = n
end

-- ---------------------------------------------------------------------------
-- Roster intake. Every payload here came from the server; there is no path by
-- which another client can write into this table.
-- ---------------------------------------------------------------------------

local function validEntry(e)
    return type(e) == 'table'
        and type(e.id) == 'number'
        and type(e.l1) == 'string'
        and type(e.l2) == 'string'
end

RegisterNetEvent('palm6_insignia:sync', function(list)
    if type(list) ~= 'table' then return end
    local fresh = {}
    for _, e in ipairs(list) do
        if validEntry(e) then fresh[e.id] = e end
    end
    roster = fresh
    countRoster()
end)

RegisterNetEvent('palm6_insignia:upsert', function(e)
    if not validEntry(e) then return end
    roster[e.id] = e
    countRoster()
end)

RegisterNetEvent('palm6_insignia:remove', function(id)
    if type(id) ~= 'number' then return end
    roster[id] = nil
    countRoster()
end)

-- Someone showed you their badge (/badge). A notification rather than a draw,
-- because the point of presenting a badge is that it is a deliberate act with
-- a record on screen, not another thing floating in the world.
RegisterNetEvent('palm6_insignia:card', function(card)
    if type(card) ~= 'table' or type(card.l1) ~= 'string' then return end
    Game.Notify('Badge shown', ('%s\n%s'):format(card.l1, tostring(card.l2 or '')), 'inform')
end)

-- ---------------------------------------------------------------------------
-- SCAN: which officers get a tape this quarter-second.
-- ---------------------------------------------------------------------------

local function buildCandidates()
    local out = {}
    if rosterSize == 0 then return out end

    local mine = Game.MyServerId()
    local hideOwn = Config.Render.HideOwnInFirstPerson and Game.IsFirstPerson()
    local maxDist = Config.Render.MaxDistance
    local names = boneNameList()

    for id, e in pairs(roster) do
        local skip = false
        if id == mine then
            skip = (not Config.Render.ShowOwn) or hideOwn
        end

        if not skip then
            local ped = Game.PedForServerId(id)
            if ped then
                local d = Game.DistanceToPed(ped)
                if d and d <= maxDist then
                    if (not Config.Render.RequireOnScreen) or Game.IsPedOnScreen(ped) then
                        out[#out + 1] = { ped = ped, dist = d, l1 = e.l1, l2 = e.l2 }
                    end
                end
            end
        end
    end

    -- Nearest first, then truncate. The truncation is the hard per-frame cap:
    -- everything downstream reads this list and nothing else.
    table.sort(out, function(a, b) return a.dist < b.dist end)
    for i = #out, Config.Render.MaxTapes + 1, -1 do out[i] = nil end

    -- Measure and resolve ONCE here, not per frame. The bone index is per PED
    -- MODEL, so it is resolved against the actual ped each scan rather than
    -- assumed: a player who changes ped model gets a fresh index inside 250ms.
    for i = 1, #out do
        out[i].w1 = Game.MeasureText(out[i].l1, style.scale, style.font)
        out[i].w2 = Game.MeasureText(out[i].l2, style.scale, style.font)
        local idx, name = Game.ResolveTapeBone(out[i].ped, names)
        out[i].bone = idx
        if idx then
            lastBoneName = name
        elseif not warnedNoBone then
            warnedNoBone = true
            Game.Print(('none of these bone names resolved on that ped: %s. '):format(table.concat(names, ', '))
                .. 'The tape will draw at the ped ORIGIN (their feet). '
                .. 'Use /insigniabone <NAME> to try another and report what works.')
        end
    end

    -- Line height depends only on scale and font, but it is read here so the
    -- plate is sized from a value the game produced, not a guess. nil means the
    -- native was unavailable; keep the previous value rather than clearing it.
    style.charH = Game.CharHeight(style.scale, style.font) or style.charH

    return out
end

-- ---------------------------------------------------------------------------
-- Threads
-- ---------------------------------------------------------------------------

local function startThreads()
    -- SCAN
    CreateThread(function()
        while running do
            if not Config.Render.Enabled or rosterSize == 0 then
                candidates = {}
                Wait(Config.Render.IdleIntervalMs)
            else
                candidates = buildCandidates()
                Wait(Config.Render.ScanIntervalMs)
            end
        end
    end)

    -- DRAW
    CreateThread(function()
        while running do
            local list = candidates
            local n = #list
            if n == 0 then
                -- With officers on the roster but none in range, poll at the
                -- SCAN rate rather than the idle rate: otherwise walking up to
                -- an officer costs up to a second of blank before the first
                -- tape appears, which reads as "broken".
                Wait(rosterSize > 0 and Config.Render.ScanIntervalMs or Config.Render.IdleIntervalMs)
            else
                local fwd, up = offsets()
                for i = 1, n do
                    local c = list[i]
                    -- The ped handle was captured up to ScanIntervalMs ago, so
                    -- re-resolve nothing but do confirm it is still a live
                    -- entity before reading a bone off it.
                    if Game.EntityExists(c.ped) then
                        local x, y, z = Game.TapeAnchor(c.ped, c.bone, fwd, up)
                        Game.DrawTape(x, y, z, c.l1, c.l2, c.w1, c.w2, style, style.charH)
                    end
                end
                Wait(0)
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

CreateThread(function()
    local r = Config.Render
    style = {
        scale      = r.Scale,
        font       = r.Font,
        lineGap    = r.LineGap,
        text       = r.TextColour,
        plate      = r.PlateColour,
        plateAlpha = r.PlateAlpha,
        padX       = r.PlatePadX,
        padY       = r.PlatePadY,
        charH      = r.LineGap,   -- replaced by a measured value on first scan
    }
    startThreads()

    -- Ask for the roster promptly. Covers a resource restart mid-session as
    -- well as a fresh join, which is why it is not tied to spawn alone.
    --
    -- 500ms rather than the 2000ms this used to wait: after `restart
    -- palm6_insignia` David was staring at nothing for two seconds plus a
    -- second of draw idle, which is indistinguishable from a dead feature.
    Wait(500)
    TriggerServerEvent('palm6_insignia:requestRoster')

    -- One retry, for the case where the server side of this resource, or
    -- qbx_core, was not ready to answer the first ask. Config.RateLimits
    -- .requestRoster is 3s server-side, so this is spaced past it and cannot
    -- be swallowed by the floor.
    Wait(3500)
    if rosterSize == 0 then
        TriggerServerEvent('palm6_insignia:requestRoster')
    end
end)

-- A fresh character load means a new server-side identity; ask again.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('palm6_insignia:requestRoster')
end)

-- Manual resync, for when David wants to prove the roster rather than wait for
-- the 60s reconcile. Server-side rate limited.
Game.RegisterCommand('insigniasync', function()
    TriggerServerEvent('palm6_insignia:requestRoster')
    Game.Notify('Insignia', 'Roster resync requested.', 'inform')
end)

-- ---------------------------------------------------------------------------
-- LIVE ANCHOR TUNING (client-local, this client only)
--
-- These change nothing on the server and nothing for anyone else. They exist so
-- the anchor stops being a number somebody asserted and becomes a value that
-- was seen to work in game and then written into shared/config.lua.
-- ---------------------------------------------------------------------------

-- /insigniabone           -> report what is in use
-- /insigniabone SKEL_Head -> try that name on your own ped, then use it
-- /insigniabone reset     -> back to the Config list
Game.RegisterCommand('insigniabone', function(_, args)
    args = args or {}
    local want = args[1]

    if not want then
        Game.Notify('Insignia', ('Anchor: %s. Last resolved: %s. Try /insigniabone SKEL_Spine3'):format(
            boneOverride or ('config list (' .. table.concat(Config.Render.BoneNames, ', ') .. ')'),
            lastBoneName or 'none yet'), 'inform')
        return
    end

    if want == 'reset' then
        boneOverride = nil
        warnedNoBone = false
        Game.Notify('Insignia', 'Anchor back to the config list.', 'success')
        return
    end

    -- Resolve it against YOUR OWN ped right now, so the answer is immediate and
    -- comes from the engine rather than from a table of names in a comment.
    local idx = Game.ResolveTapeBone(Game.MyPed(), { want })
    if not idx then
        Game.Notify('Insignia', ('"%s" is not a bone on your ped model. Nothing changed.'):format(want), 'error')
        return
    end

    boneOverride = want
    warnedNoBone = false
    candidates = {}
    Game.Notify('Insignia', ('Anchor -> %s (bone index %d on your model). '):format(want, idx)
        .. 'Takes effect within a quarter second.', 'success')
    Game.Print(('anchor override -> %s (index %d on your current ped model)'):format(want, idx))
end)

-- /insigniaoffset <forward> <up>  -> nudge the tape live, metres
-- /insigniaoffset reset
Game.RegisterCommand('insigniaoffset', function(_, args)
    args = args or {}

    if args[1] == 'reset' then
        offsetOverride = nil
        Game.Notify('Insignia', 'Offsets back to the config values.', 'success')
        return
    end

    local f = tonumber(args[1])
    local u = tonumber(args[2])
    if not f or not u then
        local cf, cu = offsets()
        Game.Notify('Insignia', ('Offsets: forward %.3f, up %.3f. Usage: /insigniaoffset <forward> <up>'):format(cf, cu), 'inform')
        return
    end

    -- Clamped so a typo cannot fling the tape somewhere it takes a relog to
    -- find. Two metres is far more than a chest anchor ever needs.
    if f < -2.0 then f = -2.0 elseif f > 2.0 then f = 2.0 end
    if u < -2.0 then u = -2.0 elseif u > 2.0 then u = 2.0 end

    offsetOverride = { f, u }
    Game.Notify('Insignia', ('Offsets -> forward %.3f, up %.3f.'):format(f, u), 'success')
    Game.Print(('offset override -> OffsetForward = %.3f, OffsetUp = %.3f'):format(f, u))
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    running = false
    candidates = {}
    roster = {}
    rosterSize = 0
end)
