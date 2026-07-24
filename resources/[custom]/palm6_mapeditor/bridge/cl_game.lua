-- ============================================================================
-- palm6_mapeditor/bridge/cl_game.lua
--
-- The ONLY file that calls GTA natives. client/main.lua calls Game.* only.
-- Object spawn/transform + raycast/snap/clipboard (the last three are the same
-- proven helpers from palm6_pd_life's placement tool).
-- ============================================================================

Game = {}

local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 200 do RequestModel(hash) Wait(10) tries = tries + 1 end
    return HasModelLoaded(hash) and hash or nil
end

-- Spawn a map object (client-local, non-networked, frozen — an editor prop).
function Game.SpawnObject(model, x, y, z)
    local hash = loadModel(model)
    if not hash then return nil end
    local obj = CreateObjectNoOffset(hash, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(obj) then return nil end
    SetEntityDynamic(obj, false)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, true, true)
    return obj
end

function Game.DeleteObject(obj)
    if obj and DoesEntityExist(obj) then
        SetEntityAsMissionEntity(obj, true, true)
        DeleteObject(obj)
    end
end

-- Absolute transform (position + full euler rotation, ZXY like CodeWalker/GTA).
function Game.SetObjectTransform(obj, x, y, z, rx, ry, rz)
    if not (obj and DoesEntityExist(obj)) then return end
    SetEntityCoordsNoOffset(obj, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetEntityRotation(obj, rx + 0.0, ry + 0.0, rz + 0.0, 2, true)
end

function Game.SetObjectAlpha(obj, a)
    if obj and DoesEntityExist(obj) then
        if a then SetEntityAlpha(obj, a, false) else ResetEntityAlpha(obj) end
    end
end

-- Where the camera crosshair hits world+objects (aim-to-place). x,y,z or nil.
function Game.CameraAimPoint(maxDist)
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rz, rx = math.rad(rot.z), math.rad(rot.x)
    local cosx = math.abs(math.cos(rx))
    local dx, dy, dz = -math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx)
    local d = maxDist or 30.0
    local ex, ey, ez = cam.x + dx * d, cam.y + dy * d, cam.z + dz * d
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, ex, ey, ez, 1 + 16, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    if hit == 1 then return coords.x, coords.y, coords.z end
    return nil
end

-- Z of the first solid surface below a point (snap-to-ground/surface).
function Game.SurfaceZBelow(x, y, z)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x, y, z + 1.0, x, y, z - 6.0, 1 + 16, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    if hit == 1 then return coords.z end
    return nil
end

function Game.PlayerPos()
    local c = GetEntityCoords(PlayerPedId())
    return c.x, c.y, c.z
end

-- The object's exact world quaternion (x,y,z,w) — used for the ymap CEntityDef
-- rotation (stored inverted). Reading the game's own quaternion avoids any
-- euler->quat convention mismatch.
function Game.GetObjectQuat(obj)
    if not (obj and DoesEntityExist(obj)) then return 0.0, 0.0, 0.0, 1.0 end
    return GetEntityQuaternion(obj)
end

function Game.SetClipboard(text)
    if lib and lib.setClipboard then lib.setClipboard(text) end
end

function Game.Notify(msg, kind)
    if lib and lib.notify then lib.notify({ title = 'Map Editor', description = msg, type = kind or 'inform' }) end
end

function Game.Chat(tag, line)
    TriggerEvent('chat:addMessage', { args = { tag, line } })
end
