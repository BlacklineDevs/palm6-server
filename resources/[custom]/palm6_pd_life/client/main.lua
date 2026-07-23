-- ============================================================================
-- palm6_pd_life/client/main.lua
--
-- Pure logic: build the PBPD station scene from Config.Scene on boot, keep it
-- alive across respawns, tear it down on stop. All natives go through Game.*.
--
-- /pdnpc <type> — live placement: spawns a preview NPC of <type> at the player
-- and prints its bake-ready vector4 to console + chat. Walk the lobby dropping
-- NPCs, then paste the logged lines into Config.Scene.
-- ============================================================================

local spawned = {}

local function pick(list)
    return list[math.random(#list)]
end

local function spawnEntry(e)
    local t = Config.Types[e.type]
    if not t then return end
    local ped = Game.SpawnScenarioPed(pick(t.models), e.coords.x, e.coords.y, e.coords.z, e.coords.w, t.scenario, t.freeze)
    if ped then spawned[#spawned + 1] = ped end
end

local function buildScene()
    if #spawned > 0 then return end
    for _, e in ipairs(Config.Scene) do
        spawnEntry(e)
    end
end

local function clearScene()
    for _, ped in ipairs(spawned) do
        Game.DeletePed(ped)
    end
    spawned = {}
end

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    buildScene()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearScene()
end)

-- Rebuild after a character (re)loads — scene peds are lost on session changes.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    buildScene()
end)

-- ---------------------------------------------------------------------------
-- /pdnpc <type> — live placement tool (dev). Drops a preview NPC where you stand
-- and logs its coord for baking into Config.Scene.
-- ---------------------------------------------------------------------------
if Config.DevPlacement then
    RegisterCommand('pdnpc', function(_, args)
        local ty = args[1]
        if not ty or not Config.Types[ty] then
            Game.Chat('[pd_life]', 'usage: /pdnpc <clerk|cop|meeting|bencher|waiting>')
            return
        end
        local x, y, z, h = Game.PlayerPose()
        spawnEntry({ type = ty, coords = vector4(x, y, z, h) })
        local line = ("{ type='%s', coords=vector4(%.2f, %.2f, %.2f, %.1f) },"):format(ty, x, y, z, h)
        print('[pd_life] ' .. line)
        Game.Chat('[pd_life]', line)
        Game.Notify(('%s placed — coord logged'):format(ty))
    end, false)

    -- /pdnpcclear — wipe the current scene (to re-place from scratch).
    RegisterCommand('pdnpcclear', function()
        clearScene()
        Game.Chat('[pd_life]', 'scene cleared')
    end, false)
end
