-- ============================================================================
-- palm6_brain/client/talk.lua — INTEL+ FLAGSHIP (client): talk to ANY ped.
--
-- Aim at / stand near ANY pedestrian, hit the talk key (or /talk), type a line —
-- the server voices that ped with GLM in character (server/talk.lua). This is the
-- generalisation of the named-NPC flow in client/main.lua to EVERY ped on the
-- street, so the whole city can hold a conversation, not just three anchors.
--
-- We derive a STABLE pedKey so the same ped maps to the same persona server-side:
-- a networked ped uses its network id; a client-local ambient ped uses a hash of
-- model + rounded coords (ambient peds sit on scenarios, so this is stable enough).
--
-- Dark by default: the whole file no-ops unless Config.Social.Enabled. Reuses a
-- local copy of main.lua's drawText3D speech bubble (kept local so the two files
-- stay independent — same seam discipline as the rest of the resource).
-- ============================================================================

if not (Config.Social and Config.Social.Enabled) then return end   -- dark-ship: inert while off

local TALK_RANGE = (Config.Social.TalkRange or 2.5)
local BUBBLE_MS  = math.floor((Config.BubbleSeconds or 7.0) * 1000)

-- pedKey -> ped handle for the LAST ped we spoke to, so an incoming reply can find
-- the right ped to float the bubble over. Small + self-cleaning (stale/dead entries
-- are dropped on reply).
local talked = {}

-- ── STABLE pedKey ────────────────────────────────────────────────────────────
local function pedKeyFor(ped)
    if NetworkGetEntityIsNetworked(ped) then
        local nid = NetworkGetNetworkIdFromEntity(ped)
        if nid and nid ~= 0 then return 'net:' .. nid end
    end
    -- Client-local ambient ped: hash model + rounded coords (stable per ~stationary ped).
    local model = GetEntityModel(ped)
    local c = GetEntityCoords(ped)
    return ('loc:%d:%d:%d:%d'):format(model,
        math.floor(c.x + 0.5), math.floor(c.y + 0.5), math.floor(c.z + 0.5))
end

-- ── PED PICK: nearest living non-player ped within TalkRange ──────────────────
-- Prefer the ped the player is looking at (raycast down the aim), else fall back
-- to the nearest ped in range. Either way we only ever return a real, alive,
-- non-player ped close enough to talk to.
local function raycastPed(from, dir, dist)
    local to = from + dir * dist
    local ray = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 12, PlayerPedId(), 0)
    local _, hit, _, _, ent = GetShapeTestResult(ray)
    if hit == 1 and ent and ent ~= 0 and IsEntityAPed(ent)
        and not IsPedAPlayer(ent) and not IsPedDeadOrDying(ent, true) then
        return ent
    end
    return nil
end

local function nearestPed(me, mc)
    local best, bestD = nil, TALK_RANGE + 0.01
    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= me and DoesEntityExist(ped) and not IsPedAPlayer(ped)
            and not IsPedDeadOrDying(ped, true) then
            local d = #(GetEntityCoords(ped) - mc)
            if d < bestD then best, bestD = ped, d end
        end
    end
    return best
end

local function pickPed()
    local me = PlayerPedId()
    if me == 0 then return nil end
    local mc = GetEntityCoords(me)
    -- aim raycast first (camera direction), then nearest-in-range fallback
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local pitch, yaw = math.rad(rot.x), math.rad(rot.z)
    local dir = vector3(-math.sin(yaw) * math.cos(pitch),
                         math.cos(yaw) * math.cos(pitch),
                         math.sin(pitch))
    local ped = raycastPed(cam, dir, TALK_RANGE + 1.5)
    if ped and #(GetEntityCoords(ped) - mc) <= TALK_RANGE + 1.5 then return ped end
    return nearestPed(me, mc)
end

-- ── DIALOGUE ─────────────────────────────────────────────────────────────────
local function startTalk()
    if not (Config.Social and Config.Social.Enabled) then return end
    local ped = pickPed()
    if not ped then
        if lib and lib.notify then lib.notify({ description = 'Nobody close enough to talk to.', type = 'inform' }) end
        return
    end
    local pedKey = pedKeyFor(ped)
    local input = lib.inputDialog('Talk', {
        { type = 'input', label = 'Say something', required = true, max = 200 },
    })
    if not input or not input[1] then return end
    -- still close enough after typing?
    if #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(ped)) > TALK_RANGE + 1.5 then return end
    talked[pedKey] = ped
    TriggerServerEvent('palm6_brain:talk:say', pedKey, input[1])
end

RegisterCommand('talk', startTalk, false)
-- Default keybind (rebindable in the pause menu). Unbound if the player clears it.
RegisterKeyMapping('talk', 'Talk to nearest pedestrian', 'keyboard', 'U')

-- ── SPEECH BUBBLE (local copy of client/main.lua drawText3D) ──────────────────
local speech = {}          -- ped -> { text, expire }
local speechThread = false

local function drawText3D(x, y, z, text)
    SetDrawOrigin(x + 0.0, y + 0.0, z + 0.0, 0)
    SetTextScale(0.34, 0.34)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

local function startSpeechThread()
    if speechThread then return end
    speechThread = true
    CreateThread(function()
        while speechThread do
            local now = GetGameTimer()
            local any = false
            for ped, b in pairs(speech) do
                if not DoesEntityExist(ped) or now > b.expire then
                    speech[ped] = nil
                else
                    any = true
                    local c = GetEntityCoords(ped)
                    drawText3D(c.x, c.y, c.z + 1.1, b.text)
                end
            end
            if not any then speechThread = false break end
            Wait(0)
        end
    end)
end

-- Server pushed a ped's GLM reply. Float it over that ped if we can still find it.
RegisterNetEvent('palm6_brain:talk:reply', function(pedKey, text)
    local ped = talked[tostring(pedKey or '')]
    if not (ped and DoesEntityExist(ped)) then
        talked[tostring(pedKey or '')] = nil
        return   -- ped not local anymore -> just skip
    end
    speech[ped] = { text = text, expire = GetGameTimer() + BUBBLE_MS }
    startSpeechThread()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    speechThread = false
end)
