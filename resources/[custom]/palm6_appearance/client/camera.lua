-- ============================================================================
-- palm6_appearance/client/camera.lua
--
-- Bone-indexed orbit camera. Calls Game.* only (bridge/cl_game.lua) — never a
-- raw GTA native directly. Pattern (bone-indexed focus regions, clamped
-- orbit, interp-based region swap with a DOF ramp) is a from-scratch PALM6
-- Lua design; the general "layering" idea is a pattern reference from the
-- open-source GPLv3 bl_appearance project (Byte-Labs-Studio) — no code from
-- that project is reused here.
-- ============================================================================

Camera = {}

local activeCam = nil
local orbit = { region = 'whole', yaw = 210.0, pitch = 0.0, distance = nil }
local previewPed = nil
local dofRampGeneration = 0   -- bumped on every FocusRegion so stale ramp threads self-cancel
local cameraAlive = false      -- gates the persistent per-frame DOF maintenance thread
local currentDofStrength = 0.0

-- ---- Math -------------------------------------------------------------------

local function wrapYaw(yaw)
    while yaw > 180.0 do yaw = yaw - 360.0 end
    while yaw < -180.0 do yaw = yaw + 360.0 end
    return yaw
end

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function orbitOffset(yaw, pitch, distance)
    local yawRad, pitchRad = math.rad(yaw), math.rad(pitch)
    local x = distance * math.cos(pitchRad) * math.sin(yawRad)
    local y = -distance * math.cos(pitchRad) * math.cos(yawRad)
    local z = distance * math.sin(pitchRad)
    return vector3(x, y, z)
end

local function currentFocusPoint()
    local cfg = Config.CameraRegions[orbit.region]
    local bonePos = Game.GetPedBoneCoords(previewPed, cfg.bone)
    return bonePos + cfg.offset, cfg
end

local function repositionActiveCam()
    if not activeCam then return end
    local focusPoint, cfg = currentFocusPoint()
    local camCoords = focusPoint + orbitOffset(orbit.yaw, orbit.pitch + cfg.pitch, orbit.distance)
    Game.SetCamCoord(activeCam, camCoords)
    Game.PointCamAtCoord(activeCam, focusPoint)
end

-- ---- Public API ---------------------------------------------------------

function Camera.Init(ped)
    previewPed = ped
    orbit.region = 'whole'
    orbit.yaw = 210.0
    orbit.pitch = 0.0

    local cfg = Config.CameraRegions.whole
    orbit.distance = cfg.distance

    local focusPoint = Game.GetPedBoneCoords(previewPed, cfg.bone) + cfg.offset
    local camCoords = focusPoint + orbitOffset(orbit.yaw, orbit.pitch + cfg.pitch, orbit.distance)

    activeCam = Game.CreateOrbitCam(camCoords, cfg.fov)
    Game.PointCamAtCoord(activeCam, focusPoint)
    Game.SetCamActive(activeCam, true)
    Game.RenderScriptCams(true, false, 0)

    currentDofStrength = cfg.dofStrength
    cameraAlive = true
    CreateThread(function()
        -- SET_USE_HI_DOF only holds for the frame it's called on, so this
        -- persistent thread re-asserts it every tick the active region wants
        -- DOF, for as long as the camera screen is open. Camera.RampDof
        -- handles the transient lerp during a region swap; this thread keeps
        -- the settled value alive afterward.
        while cameraAlive do
            if currentDofStrength > 0.0 and activeCam then
                Game.SetUseHiDof(true)
            end
            Wait(0)
        end
    end)
end

function Camera.FocusRegion(regionKey)
    local cfg = Config.CameraRegions[regionKey]
    if not cfg then return false end
    if not previewPed or not DoesEntityExist(previewPed) then return false end

    local oldCam = activeCam

    -- Reset zoom baseline for the new region; keep current yaw so the camera
    -- doesn't snap-spin between regions.
    orbit.distance = cfg.distance

    local bonePos = Game.GetPedBoneCoords(previewPed, cfg.bone)
    local focusPoint = bonePos + cfg.offset
    local camCoords = focusPoint + orbitOffset(orbit.yaw, orbit.pitch + cfg.pitch, orbit.distance)

    local toCam = Game.CreateOrbitCam(camCoords, cfg.fov)
    Game.PointCamAtCoord(toCam, focusPoint)

    Game.SetCamActiveWithInterp(toCam, oldCam, Config.CameraSwapDurationMs, true, true)

    activeCam = toCam
    orbit.region = regionKey

    dofRampGeneration = dofRampGeneration + 1
    local myGeneration = dofRampGeneration
    CreateThread(function()
        Camera.RampDof(toCam, cfg.dofStrength, Config.CameraDofRampMs, myGeneration)
    end)
    currentDofStrength = cfg.dofStrength

    CreateThread(function()
        Wait(Config.CameraSwapDurationMs)
        Game.DestroyCam(oldCam, true)
    end)

    return true
end

function Camera.RampDof(cam, targetStrength, durationMs, generation)
    local startStrength = 0.0
    local startTime = GetGameTimer()
    local useDof = targetStrength > 0.0

    while true do
        if generation ~= dofRampGeneration then break end   -- superseded by a newer region swap
        if not Game.DoesCamExist(cam) then break end

        local elapsed = GetGameTimer() - startTime
        local t = clamp(elapsed / durationMs, 0.0, 1.0)
        local strength = lerp(startStrength, targetStrength, t)

        Game.SetCamDofStrength(cam, strength)
        if useDof then
            Game.SetUseHiDof(true)
        end

        if t >= 1.0 then break end
        Wait(0)
    end

    if generation == dofRampGeneration and not useDof then
        Game.SetCamDofStrength(cam, 0.0)
    end
end

function Camera.Rotate(deltaYawDeg, deltaPitchDeg)
    if not activeCam then return end
    orbit.yaw = wrapYaw(orbit.yaw + deltaYawDeg)
    orbit.pitch = clamp(orbit.pitch + deltaPitchDeg, Config.OrbitClamps.pitchMin, Config.OrbitClamps.pitchMax)
    repositionActiveCam()
end

function Camera.Zoom(deltaDistance)
    if not activeCam then return end
    local cfg = Config.CameraRegions[orbit.region]
    local minDist = cfg.distance * Config.OrbitClamps.distanceMinMul
    local maxDist = cfg.distance * Config.OrbitClamps.distanceMaxMul
    orbit.distance = clamp(orbit.distance + deltaDistance, minDist, maxDist)
    repositionActiveCam()
end

function Camera.GetRegion()
    return orbit.region
end

function Camera.Destroy()
    dofRampGeneration = dofRampGeneration + 1
    cameraAlive = false
    currentDofStrength = 0.0
    Game.RenderScriptCams(false, false, 0)
    Game.DestroyCam(activeCam, true)
    Game.SetUseHiDof(false)
    activeCam = nil
    previewPed = nil
end
