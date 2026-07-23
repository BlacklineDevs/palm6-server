-- ============================================================================
-- palm6_pd_life/client/main.lua
--
-- Spawns NTeam's creator-designed station scene (Config.Scene) on boot: a ped at
-- each exact point + heading running its intended scenario. Kept alive across
-- respawns, torn down on stop. All natives via Game.*.
-- ============================================================================

local spawned = {}

local function pick(list)
    return list[math.random(#list)]
end

local function buildScene()
    if #spawned > 0 then return end
    for _, e in ipairs(Config.Scene) do
        local models = Config.Peds[e.ped] or Config.Peds.civ
        local ped = Game.SpawnScenarioPed(pick(models), e.coords.x, e.coords.y, e.coords.z, e.coords.w, e.scen, true)
        if ped then spawned[#spawned + 1] = ped end
        Wait(0)   -- yield between model loads
    end
end

local function clearScene()
    for _, ped in ipairs(spawned) do
        Game.DeletePed(ped)
    end
    spawned = {}
end

CreateThread(function()
    Wait(1500)
    buildScene()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearScene()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    buildScene()
end)

-- Dev: wipe / recount (placement now comes from the MLO, so /pdnpc is retired).
if Config.DevPlacement then
    RegisterCommand('pdnpcclear', function()
        clearScene()
        Game.Chat('[pd_life]', 'scene cleared')
    end, false)
    RegisterCommand('pdnpccount', function()
        Game.Chat('[pd_life]', ('%d NPCs live'):format(#spawned))
    end, false)
end
