-- ============================================================================
-- palm6_fc_combat/client/main.lua
--
-- Pure presentation: fires the CHALLENGE, answers the prompt, picks a fighter,
-- runs the client 3-2-1 + model swap, squares up, and unwinds on teardown.
-- Every action is server-validated; a modified client only picks what to REQUEST.
-- Combat input (strike/block) is added by Task 7.
-- ============================================================================

local myPick = nil  -- { fighterId, styleId } — remembered so the model swap matches the pick

local function enabledClient()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and cfg and cfg.Enabled == true
end

-- CHALLENGE: ox_target eye on a nearby player.
CreateThread(function()
    Game.AddChallengeTarget(function(serverId)
        TriggerServerEvent('palm6_fc_combat:challenge', { targetServerId = serverId })
    end)
end)

-- CHALLENGE fallback: /fcchallenge <serverid>
RegisterCommand('fcchallenge', function(_, args)
    local sid = tonumber(args[1])
    if not sid then
        Game.Notify({ title = 'Fight Club', description = 'Usage: /fcchallenge [server id]', type = 'error' })
        return
    end
    TriggerServerEvent('palm6_fc_combat:challenge', { targetServerId = sid })
end, false)

RegisterNetEvent('palm6_fc_combat:challengePrompt', function(d)
    if type(d) ~= 'table' then return end
    local ok = Game.ConfirmDialog('Fight Challenge',
        ('**%s** wants to fight you at the ring. Accept?'):format(d.fromName or 'Someone'), d.ttl or 20)
    TriggerServerEvent(ok and 'palm6_fc_combat:accept' or 'palm6_fc_combat:decline')
end)

RegisterNetEvent('palm6_fc_combat:openSelect', function(d)
    if type(d) ~= 'table' then return end
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    if not ok or not cfg then return end
    local opts = {}
    for _, f in ipairs(cfg.Fighters or {}) do
        opts[#opts + 1] = {
            title = f.name,
            description = ('Style: %s'):format(f.styleId or '?'),
            icon = 'fa-solid fa-user-ninja',
            onSelect = function()
                myPick = { fighterId = f.id, styleId = f.styleId }
                TriggerServerEvent('palm6_fc_combat:select', { fighterId = f.id, styleId = f.styleId })
            end,
        }
    end
    Game.OpenMenu('palm6_fc_select', 'Choose your fighter', opts)
end)

RegisterNetEvent('palm6_fc_combat:countdown', function(d)
    if type(d) ~= 'table' then return end
    local sec = tonumber(d.seconds) or 0
    if sec > 0 then
        -- COUNTDOWN: preload + model swap (uses the remembered pick, else the default the server also used)
        local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
        local pick = myPick or (ok and cfg and { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle }) or nil
        if pick then
            local f = exports.palm6_fc_core:GetFighter(pick.fighterId)
            if f and f.model then Game.SwapToFighter(f.model, pick.styleId) end
        end
        Game.RunCountdown(sec)
    else
        Game.Notify({ title = 'Fight Club', description = 'FIGHT!', type = 'inform', duration = 1500 })
    end
end)

-- Emitted by T10's palm6_fc_arena (T6 no longer emits squareUp — C7); this is a
-- pure consumer that places the local ped on its fight-mark.
RegisterNetEvent('palm6_fc_arena:squareUp', function(d)
    if type(d) ~= 'table' or type(d.coords) ~= 'table' then return end
    Game.SquareUp(d.coords, d.heading)
end)

RegisterNetEvent('palm6_fc_combat:teardown', function(d)
    -- matchId==0 is the boot "abort any fight" broadcast — always unwind.
    Game.RestoreAppearance()
    myPick = nil
    pcall(function() lib.hideContext(false) end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Game.RestoreAppearance()
end)

-- ============================================================================
-- T7: LIVE fighter hardening loop + strike/KO/teardown reactions. Presentation
-- only; the server owns every number and validates every event.
-- ============================================================================

local Fighter = { matchId = false, hardening = false }

-- Clip name WITHIN the style's strike dict (server picks the dict; the clip is
-- pure feel — tune/replace in David's feel-test, zero logic impact).
local STRIKE_CLIP = {
    jab      = 'plyr_takedown_front_lefthook',
    cross    = 'plyr_takedown_front_lefthook',
    hook     = 'plyr_takedown_front_lefthook',
    uppercut = 'plyr_takedown_front_lefthook',
    body     = 'plyr_takedown_front_lefthook',
}

local function startHardening(matchId)
    if Fighter.hardening then return end
    Fighter.matchId = matchId
    Fighter.hardening = true
    CreateThread(function()
        while Fighter.hardening do
            Game.HardenFighterPed()
            Wait(0)                       -- re-assert every frame (§6)
        end
    end)
end

local function stopHardening()
    Fighter.hardening = false
    Fighter.matchId = false
    Game.RestoreFighterPed()
end

-- Drive hardening off our own player statebag. bagFilter nil + explicit own-bag
-- check because GetPlayerServerId is unreliable at script-load.
AddStateBagChangeHandler('fc:active', nil, function(bagName, _, value)
    if bagName ~= ('player:%d'):format(GetPlayerServerId(PlayerId())) then return end
    if value and value ~= false then
        startHardening(tonumber(value))
    else
        stopHardening()
    end
end)

-- Attacker's own swing (targeted to us; replication shows it to everyone else).
RegisterNetEvent('palm6_fc_combat:playClip', function(data)
    if type(data) ~= 'table' then return end
    local clip = STRIKE_CLIP[data.moveId] or 'plyr_takedown_front_lefthook'
    Game.PlayStrikeClip(data.animDict, clip)
end)

-- KO: stop re-asserting CanRagdoll(false) BEFORE ragdolling (§6 ordering) or the
-- next hardening frame no-ops SetPedToRagdoll.
RegisterNetEvent('palm6_fc_combat:koRagdoll', function(data)
    if type(data) ~= 'table' then return end
    Fighter.hardening = false
    Wait(0)
    Game.RagdollSelf()
    Fighter.matchId = false
end)

-- Canonical teardown (net-registered by T6). A second AddEventHandler runs
-- alongside T6's HUD/cam teardown to guarantee hardening is dropped + ped restored
-- (ring-out drops invincibility the instant this arrives).
AddEventHandler('palm6_fc_combat:teardown', function()
    stopHardening()
end)
