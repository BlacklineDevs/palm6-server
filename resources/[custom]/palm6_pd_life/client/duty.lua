-- ============================================================================
-- palm6_pd_life/client/duty.lua
--
-- Interactive layer (Phase B): man a post, leave it, toggle duty, and sit in a
-- chair. Posts are the Config.Rooms entries that carry a `post` id. Taking one
-- asks the server (authoritative) to assign it; the server relieves the ambient
-- NPC (broadcast handled in client/main.lua) and puts the officer on duty. All
-- natives go through Game.* (bridge/cl_game.lua).
-- ============================================================================

local interactions = {}   -- post id -> interaction handle
local myPost = nil        -- the post this client is currently manning
local sitOn = false       -- whether the /sit ox_target models are registered

-- Every post-tagged room entry, once.
local function eachPost(fn)
    for _, e in ipairs(Config.Rooms or {}) do
        if e.post then fn(e) end
    end
end

local function label(e)
    if e.post == 'front_desk' then return 'Man the front desk' end
    if e.post:find('captain') then return 'Take the captain\'s desk' end
    return 'Man this post'
end

local function buildPostTargets()
    eachPost(function(e)
        if interactions[e.post] then return end
        interactions[e.post] = Game.CreateInteraction(
            e.post, e.coords, 1.6, label(e), 'fas fa-user-shield',
            function()
                local job = Game.PlayerJob()
                if job ~= Config.PoliceJob then
                    Game.Notify('Only police can man a post.')
                    return
                end
                TriggerServerEvent('palm6_pd_life:takePost', e.post)
            end
        )
    end)
end

local function clearPostTargets()
    for id, h in pairs(interactions) do Game.RemoveInteraction(h) end
    interactions = {}
end

-- Server confirmed we took a post -> drop into the manning pose.
RegisterNetEvent('palm6_pd_life:tookPost', function(postId, coords, scen)
    myPost = postId
    Game.EnterPostPose(coords.x, coords.y, coords.z, coords.w, scen)
end)

RegisterNetEvent('palm6_pd_life:leftPost', function()
    myPost = nil
    Game.ExitPostPose()
end)

-- Commands: leave post + toggle duty (police get these anywhere in station).
RegisterCommand('leavepost', function()
    if not myPost then Game.Notify('You are not manning a post.') return end
    TriggerServerEvent('palm6_pd_life:leavePost')
end, false)

-- Namespaced so it never clobbers qbx_core's own /duty toggle.
RegisterCommand('pdduty', function()
    TriggerServerEvent('palm6_pd_life:toggleDuty')
end, false)

-- Generic sit: ox_target on the station's chair models.
local function buildSitTargets()
    if sitOn then return end
    sitOn = Game.AddSitModels(Config.SitModels, function(data)
        Game.SitOnEntity(data and data.entity, 'PROP_HUMAN_SEAT_CHAIR_MP')
    end)
end

RegisterCommand('getup', function()
    Game.ExitPostPose()
end, false)

-- Wire targets on start / player load; tear down on stop.
CreateThread(function()
    Wait(1500)
    buildPostTargets()
    buildSitTargets()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    buildPostTargets()
    buildSitTargets()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearPostTargets()
    if sitOn then Game.RemoveSitModels(Config.SitModels) end
    if myPost then Game.ExitPostPose() end
end)
