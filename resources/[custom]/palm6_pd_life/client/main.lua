-- ============================================================================
-- palm6_pd_life/client/main.lua
--
-- Builds the PBPD station crowd from Config.Zones on boot: each zone scatters
-- `count` scenario NPCs across its radius so the station reads busy. Kept alive
-- across respawns, torn down on stop. All natives go through Game.*.
--
-- /pdnpc <type>  — drop one NPC where you stand (+ log its coord)
-- /pdnpcclear    — wipe the scene
-- /pdnpccount    — report how many NPCs are live
-- ============================================================================

local spawned = {}

local function pick(list)
    return list[math.random(#list)]
end

-- Expand a zone mix {type=weight,...} into a flat pool, then assign one type per
-- ped up to count (cycling the pool so weights are honoured).
local function buildTypeList(mix, count)
    local pool = {}
    for ty, w in pairs(mix) do
        for _ = 1, w do pool[#pool + 1] = ty end
    end
    if #pool == 0 then return {} end
    -- shuffle for spatial variety
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local out = {}
    for i = 1, count do
        out[i] = pool[((i - 1) % #pool) + 1]
    end
    return out
end

local function spawnOne(ty, x, y, z, h)
    local t = Config.Types[ty]
    if not t then return end
    local ped = Game.SpawnScenarioPed(pick(t.models), x, y, z, h, t.scenario, t.freeze)
    if ped then spawned[#spawned + 1] = ped end
end

local function fillZone(zone)
    local types = buildTypeList(zone.mix, zone.count)
    for i = 1, zone.count do
        local ang = math.random() * 2.0 * math.pi
        local dist = math.sqrt(math.random()) * zone.radius   -- uniform over the disc
        local x = zone.center.x + math.cos(ang) * dist
        local y = zone.center.y + math.sin(ang) * dist
        local z = zone.center.z + (Config.SpawnZOffset or 0.0)
        spawnOne(types[i] or 'waiting', x, y, z, math.random(0, 359) + 0.0)
        Wait(0)   -- yield between model loads to avoid a spawn hitch
    end
end

local function buildScene()
    if #spawned > 0 then return end
    for _, zone in ipairs(Config.Zones) do
        fillZone(zone)
    end
    -- explicit fixed placements (seated NPCs on real chairs)
    for _, e in ipairs(Config.Fixed or {}) do
        spawnOne(e.type, e.coords.x, e.coords.y, e.coords.z, e.coords.w)
    end
end

local function clearScene()
    for _, ped in ipairs(spawned) do
        Game.DeletePed(ped)
    end
    spawned = {}
end

CreateThread(function()
    Wait(1500)          -- let the interior/collision settle after join
    buildScene()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearScene()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    buildScene()
end)

-- ---------------------------------------------------------------------------
-- Dev tools
-- ---------------------------------------------------------------------------
if Config.DevPlacement then
    RegisterCommand('pdnpc', function(_, args)
        local ty = args[1]
        if not ty or not Config.Types[ty] then
            Game.Chat('[pd_life]', 'usage: /pdnpc <clerk|cop|copidle|meeting|bencher|waiting|phone>')
            return
        end
        local x, y, z, h = Game.PlayerPose()
        spawnOne(ty, x, y, z, h)
        local line = ("{ type='%s', coords=vector4(%.2f, %.2f, %.2f, %.1f) },"):format(ty, x, y, z, h)
        print('[pd_life] ' .. line)
        Game.Chat('[pd_life]', line)
    end, false)

    RegisterCommand('pdnpcclear', function()
        clearScene()
        Game.Chat('[pd_life]', 'scene cleared')
    end, false)

    RegisterCommand('pdnpccount', function()
        Game.Chat('[pd_life]', ('%d NPCs live'):format(#spawned))
    end, false)
end
