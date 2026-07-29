-- ============================================================================
-- palm6_fc_arena/client/main.lua
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all natives / ox_lib.
-- Presentation only: ring blip + gallery zone, crowd peds (LIVE-only, culled),
-- spectator cam, soft-repel, fight-mark square-up. No authority.
-- ============================================================================

local ringBlip, ringZone
local promoterPed, promoterZone
local crowd = {}
local currentMatchId
local spectating = false
local lastRepelNotify = 0

local function core() return exports.palm6_fc_core:Config() end

local function coreSafe()
    local ok, c = pcall(core)
    return ok and c or nil
end

local function enabled()
    local c = coreSafe(); return c and c.Enabled and true or false
end

local function ring()
    local c = coreSafe(); return c and c.Ring or nil
end

local function stateKey(id)
    local ok, k = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    if ok and k and k.matchKey then return k.matchKey(id) end
    return ('fc:match:%d'):format(id)
end

local function isLive()
    if not currentMatchId then return false end
    local st = GlobalState[stateKey(currentMatchId)]
    return type(st) == 'table' and st.status == 'live'
end

-- BETTING open → discoverability notify for spectators.
RegisterNetEvent('palm6_fc_arena:bettingOpen', function(d)
    if type(d) ~= 'table' then return end
    currentMatchId = d.matchId
    Game.Notify({
        title = 'Fight Club',
        description = ('Match #%d open: %s vs %s\nBet: %s'):format(
            d.matchId or 0, d.f1name or '?', d.f2name or '?', d.betCmd or '/fcbet'),
        type = 'inform',
    })
end)

-- Square the local fighter up on their own mark (own ped only).
RegisterNetEvent('palm6_fc_arena:squareUp', function(d)
    if type(d) ~= 'table' or not d.coords then return end
    Game.SquareUp(d.coords, d.heading or 0.0)
end)

-- Canonical teardown (also the boot "abort any fight" broadcast) → tear down
-- all local presentation regardless of matchId (single ring in MVP).
RegisterNetEvent('palm6_fc_combat:teardown', function(d)
    if type(d) ~= 'table' then return end
    currentMatchId = nil
    if #crowd > 0 then Game.DeleteCrowd(crowd); crowd = {} end
    if spectating then Game.SpectateOff(); spectating = false end
end)

-- Presentation manager: crowd (LIVE + near) and soft-repel (LIVE + not a fighter).
CreateThread(function()
    while true do
        local sleep = 1000
        local r = ring()
        local live = enabled() and isLive()

        if live and r then
            local pc = Game.LocalCoords()
            local near = pc and Game.Dist(pc, r.coords) <= (Config.CullDistance or 60.0)
            if near and #crowd == 0 then
                local c = coreSafe()
                crowd = Game.SpawnCrowd(r.coords, (c and c.MaxCrowd) or 12, Config.GalleryRadius or 7.0)
            elseif (not near) and #crowd > 0 then
                Game.DeleteCrowd(crowd); crowd = {}
            end

            if near and not Game.IsFighter() then
                if Game.RepelFromRing(r.coords, Config.RepelRadius or 3.5) then
                    local t = GetGameTimer()
                    if t - lastRepelNotify > (Config.RepelNotifySec or 5) * 1000 then
                        lastRepelNotify = t
                        Game.Notify({ title = 'Fight Club', description = 'Stay clear of the ring during the fight.', type = 'error' })
                    end
                end
                sleep = 50    -- responsive repel while a non-fighter is at the ring
            else
                sleep = near and 250 or 1000
            end
        else
            if #crowd > 0 then Game.DeleteCrowd(crowd); crowd = {} end
            if spectating then Game.SpectateOff(); spectating = false end
            sleep = 1000
        end

        Wait(sleep)
    end
end)

-- Optional spectator cam toggle (non-participants, live fight only).
RegisterCommand('fcspectate', function()
    local r = ring()
    if not enabled() or not r then return end
    if Game.IsFighter() then return end
    if not isLive() then
        Game.Notify({ title = 'Fight Club', description = 'No live fight to spectate.', type = 'error' })
        return
    end
    spectating = not spectating
    if spectating then Game.SpectateOn(r.coords) else Game.SpectateOff() end
end, false)

-- Fight-promoter NPC menu — pure discoverability / UX. Explains the loop and
-- opens NO match (challenges stay player-to-player via ox_target at the ring);
-- fires no server events. Ante is pulled from the fightclub money authority when
-- that export is reachable (pcall-guarded), else the number is omitted.
local function openPromoterInfo()
    local stake
    -- palm6_fightclub is NOT a declared dependency of this resource
    -- (fxmanifest.lua lists ox_lib, qbx_core and palm6_fc_core only), so this is
    -- a true soft dep: check the state before indexing the export, not just pcall.
    if GetResourceState('palm6_fightclub') == 'started' then
        local ok, v = pcall(function() return exports.palm6_fightclub:GetEntryStake() end)
        if ok and type(v) == 'number' and v > 0 then stake = v end
    end
    local anteDesc = stake
        and ('Both fighters ante $%d — winner takes the purse.'):format(stake)
        or  'Both fighters ante the entry stake — winner takes the purse.'

    Game.OpenMenu('palm6_fc_promoter', 'Fight Club — how it works', {
        {
            title = '1. Challenge a citizen at the ring',
            description = 'Head to the ring, aim at another fighter, and pick "Challenge to a fight".',
            icon = 'fa-solid fa-hand-fist', disabled = true,
        },
        {
            title = '2. Both fighters ante up',
            description = anteDesc,
            icon = 'fa-solid fa-sack-dollar', disabled = true,
        },
        {
            title = '3. Spectators bet with /fcbet',
            description = 'During the betting window, back a fighter to win a share of the pool.',
            icon = 'fa-solid fa-money-bill-trend-up', disabled = true,
        },
        {
            title = '4. Best striker wins',
            description = 'Land clean strikes, fill your meter, and take the purse plus street rep.',
            icon = 'fa-solid fa-trophy', disabled = true,
        },
    })
end

-- Ring blip + gallery zone + fight-promoter NPC (only when enabled — prod-inert
-- otherwise). The single Enabled gate below wraps the blip, the ped, AND the
-- promoter interaction, so nothing appears on prod while Config.Enabled == false.
CreateThread(function()
    Wait(1500)  -- let fc_core exports come up
    if not enabled() then return end
    local r = ring()
    if not r then return end
    ringBlip = Game.AddBlip(r.coords, Config.Blip)
    ringZone = Game.AddRingZone(r.coords, r.radius or 15.0, function()
        Game.Notify({ title = 'Fight Club', description = 'You are at the fight ring. /fcspectate to watch, /fcbet during betting.', type = 'inform' })
    end, nil)
    -- Discoverability NPC: same Enabled gate as the ring blip above.
    if Config.Promoter then
        promoterPed = Game.SpawnPed(Config.Promoter.model, Config.Promoter.coords, Config.Promoter.heading)
        promoterZone = Game.AddPedInteraction(promoterPed, Config.Promoter.coords, Config.Promoter.label, Config.Promoter.icon, openPromoterInfo)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if #crowd > 0 then Game.DeleteCrowd(crowd) end
    if spectating then Game.SpectateOff() end
    Game.RemoveInteraction(promoterZone)
    Game.DeletePed(promoterPed)
    Game.RemoveBlip(ringBlip)
    Game.RemoveZone(ringZone)
end)
