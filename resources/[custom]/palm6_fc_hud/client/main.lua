-- ============================================================================
-- palm6_fc_hud/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for NUI / statebags / exports.
-- DISPLAY-ONLY: reads the server-owned fight statebags (T1/T7) and the T3
-- betting-pool broadcast, renders the HUD, and has ZERO authority. It never
-- writes fight state, never sends a combat/bet event, and mints nothing.
-- Prod-inert until exports.palm6_fc_core:Config().Enabled is true.
-- ============================================================================

local CFG                       -- cached fc_core Config
local SK                        -- cached fc_core StateKeys
local takeout = 0.25            -- RakePct + WinnerPursePct (from CFG)
local minBet  = 50              -- CFG.Betting.MinBet
local maxHp, maxStam, maxBlazin = 100, 100, 100

local hudOpen = false
local lastSig = nil             -- coalesce: only push vitals on change

-- Wait for fc_core (shared_scripts export) to be ready, cache constants.
CreateThread(function()
    while not (CFG and SK) do
        CFG = Game.CoreConfig()
        SK  = Game.StateKeys()
        Wait(500)
    end
    takeout   = (CFG.Betting and CFG.Betting.RakePct or 0.10) + (CFG.WinnerPursePct or 0.15)
    minBet    = (CFG.Betting and CFG.Betting.MinBet) or 50
    maxHp     = (CFG.Vitals and CFG.Vitals.StartHP) or 100
    maxStam   = (CFG.Vitals and CFG.Vitals.MaxStamina) or 100
    maxBlazin = (CFG.Blazin and CFG.Blazin.FullThreshold) or 100
end)

local function snap(s)
    if type(s) ~= 'table' then return { hp = 0, stam = 0, blazin = 0, name = '' } end
    return {
        hp     = math.max(0, math.floor(tonumber(s.hp) or 0)),
        stam   = math.max(0, math.floor(tonumber(s.stam) or 0)),
        blazin = math.max(0, math.floor(tonumber(s.blazin) or 0)),
        name   = s.name or '',
    }
end

local function sig(mySlot, s1, s2)
    return table.concat({ mySlot,
        s1.hp, s1.stam, s1.blazin, s1.name,
        s2.hp, s2.stam, s2.blazin, s2.name }, '|')
end

local function closeHud()
    if hudOpen then
        Game.SendUIMessage({ action = 'hud:close' })
        hudOpen = false
        lastSig = nil
    end
end

-- Vitals poll: tight (100ms) only while I am a fighter with a live statebag;
-- otherwise idle (750ms) with zero NUI traffic. Mirrors palm6_clout's
-- idle-until-active loop — no per-frame work on a 48-slot server.
CreateThread(function()
    while true do
        local wait = 750
        if CFG and SK and CFG.Enabled then
            local matchId = Game.GetLocalActive(SK.PLAYER_ACTIVE)
            if type(matchId) == 'number' then
                local st = Game.GetMatchState(SK.MATCH_PREFIX .. matchId)
                if type(st) == 'table' and type(st.slot) == 'table' then
                    local mySlot = Game.GetLocalSlot(SK.PLAYER_SLOT) or 1
                    local s1, s2 = snap(st.slot[1]), snap(st.slot[2])
                    if not hudOpen then
                        Game.SendUIMessage({ action = 'hud:open', mySlot = mySlot,
                            maxHp = maxHp, maxStam = maxStam, maxBlazin = maxBlazin })
                        hudOpen = true
                        lastSig = nil
                    end
                    local s = sig(mySlot, s1, s2)
                    if s ~= lastSig then
                        Game.SendUIMessage({ action = 'hud:vitals', mySlot = mySlot, s1 = s1, s2 = s2 })
                        lastSig = s
                    end
                    wait = 100
                else
                    closeHud()
                end
            else
                closeHud()
            end
        else
            closeHud()
        end
        Wait(wait)
    end
end)

-- T3 tote-board broadcast (to all/arena). Display only; the server computes
-- nothing authoritative from this render.
RegisterNetEvent('palm6_fightclub:oddsUpdate', function(d)
    if not CFG or not CFG.Enabled then return end
    d = d or {}
    local secsLeft = tonumber(d.secsLeft) or 0
    Game.SendUIMessage({
        action   = 'odds:update',
        matchId  = tonumber(d.matchId) or 0,
        sideA    = tonumber(d.sideA) or 0,
        sideB    = tonumber(d.sideB) or 0,
        betCount = tonumber(d.betCount) or 0,
        secsLeft = secsLeft,
        takeout  = takeout,
        minBet   = minBet,
        closed   = secsLeft <= 0,   -- GoLive leaves secsLeft<=0 → CLOSED closing line
    })
end)

-- Read-only career panel. /fccareer pops rep/rank for a few seconds. No
-- authority, no rate-limit needed (a read-only callback), inert when disabled.
RegisterCommand('fccareer', function()
    if not CFG or not CFG.Enabled then return end
    local res = Game.FetchCareer()
    if res then
        Game.SendUIMessage({ action = 'career:show', rep = res.rep or 0, rank = res.rank or 0 })
    end
end, false)

-- On resource stop (dev restart), make sure the overlay is fully cleared so no
-- stale HUD lingers on the client.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        Game.SendUIMessage({ action = 'hud:close' })
        Game.SendUIMessage({ action = 'odds:hide' })
        Game.SendUIMessage({ action = 'career:hide' })
    end
end)
