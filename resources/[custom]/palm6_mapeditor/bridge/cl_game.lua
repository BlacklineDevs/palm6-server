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

-- Read an object's current transform back (after the visual gizmo moved it).
function Game.GetObjectTransform(obj)
    if not (obj and DoesEntityExist(obj)) then return 0, 0, 0, 0, 0, 0 end
    local c = GetEntityCoords(obj)
    local r = GetEntityRotation(obj, 2)
    return c.x, c.y, c.z, r.x, r.y, r.z
end

-- Hand an entity to object_gizmo's visual handles (translate/rotate/scale,
-- world/local, snap-to-ground). Blocks until the user presses Enter.
function Game.UseGizmo(obj)
    if GetResourceState('object_gizmo') ~= 'started' then return false end
    if not (obj and DoesEntityExist(obj)) then return false end
    pcall(function() exports.object_gizmo:useGizmo(obj) end)
    return true
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

-- What world entity the crosshair is pointing at (for select / world-erase).
-- Returns entity, model, hitX, hitY, hitZ  (entity 0 if none).
function Game.RaycastEntity(maxDist)
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rz, rx = math.rad(rot.z), math.rad(rot.x)
    local cosx = math.abs(math.cos(rx))
    local dx, dy, dz = -math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx)
    local d = maxDist or 30.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z,
        cam.x + dx * d, cam.y + dy * d, cam.z + dz * d, 1 + 16, PlayerPedId(), 0)
    local _, hit, coords, _, ent = GetShapeTestResult(ray)
    if hit == 1 then return ent or 0, ent and ent ~= 0 and GetEntityModel(ent) or 0, coords.x, coords.y, coords.z end
    return 0, 0, 0.0, 0.0, 0.0
end

-- World eraser: hide all instances of a model in a tight sphere (vanilla map
-- prop suppression). Excludes our own script objects; survives map reload.
function Game.HideModelAt(x, y, z, radius, modelHash)
    CreateModelHideExcludingScriptObjects(x + 0.0, y + 0.0, z + 0.0, radius + 0.0, modelHash, true)
end
function Game.RestoreModelAt(x, y, z, radius, modelHash)
    RemoveModelHide(x + 0.0, y + 0.0, z + 0.0, radius + 0.0, modelHash, false)
end

function Game.SetOutline(obj, on)
    if obj and DoesEntityExist(obj) then
        SetEntityDrawOutline(obj, on and true or false)
        if on then SetEntityDrawOutlineColor(30, 180, 255, 255) end
    end
end
function Game.SetCollision(obj, on) if obj and DoesEntityExist(obj) then SetEntityCollision(obj, on and true or false, on and true or false) end end
function Game.SetFreeze(obj, on) if obj and DoesEntityExist(obj) then FreezeEntityPosition(obj, on and true or false) end end
function Game.ModelName(hash) return hash end   -- placeholder; NUI resolves names

function Game.SetClipboard(text)
    if lib and lib.setClipboard then lib.setClipboard(text) end
end

function Game.Notify(msg, kind)
    if lib and lib.notify then lib.notify({ title = 'Map Editor', description = msg, type = kind or 'inform' }) end
end

function Game.Chat(tag, line)
    TriggerEvent('chat:addMessage', { args = { tag, line } })
end

-- Lights are drawn per-frame (not entities). These are called every frame from
-- the light render loop over the synced light defs.
function Game.DrawPointLight(x, y, z, r, g, b, range, intensity)
    DrawLightWithRange(x + 0.0, y + 0.0, z + 0.0, math.floor(r), math.floor(g), math.floor(b), range + 0.0, intensity + 0.0)
end

function Game.DrawSpot(x, y, z, dx, dy, dz, r, g, b, dist, brightness, radius, falloff)
    DrawSpotLight(x + 0.0, y + 0.0, z + 0.0, dx + 0.0, dy + 0.0, dz + 0.0,
        math.floor(r), math.floor(g), math.floor(b), dist + 0.0, brightness + 0.0, 3.0, radius + 0.0, falloff + 0.0)
end
