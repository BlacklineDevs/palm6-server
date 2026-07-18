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
