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

-- Request a set of models and wait (bounded) until they're all resident. A batch
-- spawn that runs immediately after then finds every model already loaded, so
-- Game.SpawnObject never yields mid-loop — which keeps a prefab stamp a single
-- atomic undo group (no interleaved command can slip into the batch range).
function Game.PreloadModels(models)
    local want = {}
    for _, m in ipairs(models or {}) do
        local hash = type(m) == 'number' and m or joaat(m)
        if IsModelValid(hash) then want[hash] = true end
    end
    for hash in pairs(want) do RequestModel(hash) end
    local tries = 0
    while tries < 500 do
        local pending = false
        for hash in pairs(want) do
            if not HasModelLoaded(hash) then pending = true; RequestModel(hash) end
        end
        if not pending then break end
        Wait(10); tries = tries + 1
    end
end

function Game.DeleteObject(obj)
    if obj and DoesEntityExist(obj) then
        SetEntityAsMissionEntity(obj, true, true)
        DeleteObject(obj)
    end
end

-- Spawn a static scene ped (client-local, non-reactive). Optional ambient
-- scenario (e.g. WORLD_HUMAN_GUARD_STAND, WORLD_HUMAN_CLIPBOARD).
-- Frozen by default; a scenario ped is left unfrozen ONLY when
-- Config.ScenePedScenarioUnfreeze is on (ships off). See the note on that
-- branch below before flipping it, and note that any caller which hard-writes
-- a ped's transform every frame must pass '' rather than a scenario.
function Game.SpawnPed(model, x, y, z, heading, scenario)
    local hash = loadModel(model)
    if not hash then return nil end
    local ped = CreatePed(4, hash, x + 0.0, y + 0.0, z + 0.0, (heading or 0.0) + 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)   -- don't flee / react to the world
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    -- Frozen by default, which is what every scene ped has always shipped as: the
    -- ped holds the exact placed coords. The native below is TaskStartScenarioInPlace,
    -- which never walks the ped, so GUARD_PATROL/JOG_STANDING/PICNIC play on the
    -- spot and are fine frozen. Only the settle-onto-a-surface scenarios
    -- (WORLD_HUMAN_SEAT_LEDGE, WORLD_HUMAN_SUNBATHE; see data/scene_models.lua)
    -- want the small engine reposition a freeze blocks, and unfreezing costs the
    -- ped gravity + player/vehicle collision, so it is opt-in per
    -- Config.ScenePedScenarioUnfreeze (OFF = today's behaviour) and needs an
    -- in-game look before anyone flips it. Callers that hard-write the ped's
    -- transform every frame (the carry preview) must NOT pass a scenario.
    if not (Config.ScenePedScenarioUnfreeze and scenario and scenario ~= '') then
        FreezeEntityPosition(ped, true)
    end
    if scenario and scenario ~= '' then
        pcall(function() TaskStartScenarioInPlace(ped, scenario, 0, true) end)
    end
    return ped
end

-- Is this model a real vehicle model? (Callable without streaming it in.)
function Game.ModelIsVehicle(model)
    local hash = type(model) == 'number' and model or joaat(model)
    return IsModelValid(hash) and IsModelAVehicle(hash)
end

-- Spawn a static scene vehicle (client-local, frozen, locked). Refuses a
-- non-vehicle model so a wrong /matveh can't CreateVehicle a ped/object.
function Game.SpawnVehicle(model, x, y, z, heading)
    local hash = loadModel(model)
    if not hash then return nil end
    if not IsModelAVehicle(hash) then SetModelAsNoLongerNeeded(hash); return nil end
    local veh = CreateVehicle(hash, x + 0.0, y + 0.0, z + 0.0, (heading or 0.0) + 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(veh) then return nil end
    SetVehicleOnGroundProperly(veh)
    SetVehicleDoorsLocked(veh, 2)
    SetEntityInvincible(veh, true)
    FreezeEntityPosition(veh, true)
    return veh
end

-- Delete any entity kind (ped / vehicle / object).
function Game.DeleteAnyEntity(ent)
    if ent and DoesEntityExist(ent) then
        SetEntityAsMissionEntity(ent, true, true)
        DeleteEntity(ent)
    end
end

function Game.PlayerHeading() return GetEntityHeading(PlayerPedId()) end

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
    local ok, err = pcall(function() exports.object_gizmo:useGizmo(obj) end)
    if not ok then print('[palm6_mapeditor] gizmo error: ' .. tostring(err)) end
    return ok
end

function Game.SetObjectAlpha(obj, a)
    if obj and DoesEntityExist(obj) then
        if a then SetEntityAlpha(obj, a, false) else ResetEntityAlpha(obj) end
    end
end

-- The camera the aim raycasts shoot from: the scripted freecam (client/freecam.lua)
-- when /mapcam is active, otherwise the gameplay cam. EditorCam is a global set by
-- freecam.lua; when it's absent/inactive this is byte-for-byte the old behaviour, so
-- the default (freecam-off) editing path is unchanged. Returns cx,cy,cz, pitchRad, yawRad.
local function camView()
    if EditorCam and EditorCam.active and EditorCam.pos then
        local p, r = EditorCam.pos, EditorCam.rot
        return p.x, p.y, p.z, math.rad(r.x), math.rad(r.z)
    end
    local c = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    return c.x, c.y, c.z, math.rad(rot.x), math.rad(rot.z)
end

-- Heading (yaw) of the active view in radians — for the editor's camera-relative
-- arrow nudge, so it stays correct while the freecam is driving.
function Game.CamHeadingRad()
    if EditorCam and EditorCam.active and EditorCam.rot then return math.rad(EditorCam.rot.z) end
    return math.rad(GetGameplayCamRot(2).z)
end

-- Where the camera crosshair hits world+objects (aim-to-place). x,y,z or nil.
function Game.CameraAimPoint(maxDist)
    local cx, cy, cz, rx, rz = camView()
    local cosx = math.abs(math.cos(rx))
    local dx, dy, dz = -math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx)
    local d = maxDist or 30.0
    local ex, ey, ez = cx + dx * d, cy + dy * d, cz + dz * d
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cx, cy, cz, ex, ey, ez, 1 + 16, PlayerPedId(), 0)
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

function Game.TeleportPlayer(x, y, z)
    SetEntityCoords(PlayerPedId(), x + 0.0, y + 0.0, z + 1.0, false, false, false, false)
end

-- The object's exact world quaternion (x,y,z,w) — used for the ymap CEntityDef
-- rotation (stored inverted). Reading the game's own quaternion avoids any
-- euler->quat convention mismatch.
function Game.GetObjectQuat(obj)
    if not (obj and DoesEntityExist(obj)) then return 0.0, 0.0, 0.0, 1.0 end
    return GetEntityQuaternion(obj)
end

-- ---- rotation probe (exporting props with no entity) -----------------------
-- The .ymap / Blender writers need each prop's world QUATERNION, and the only
-- exact source is GetEntityQuaternion on a real entity. A distance-culled prop
-- (or one whose model never streamed) has no entity — but it has never lost its
-- rotation either: the DB row carries the euler and client/live.lua keeps it on
-- the record. The only missing step is euler -> quaternion.
--
-- Rather than reimplement that conversion (which means picking GTA's rotation
-- order by hand — precisely the mismatch Game.GetObjectQuat exists to avoid),
-- these three functions borrow the game's own conversion: spawn ONE hidden
-- scratch object, apply an euler to it with the SAME SetEntityRotation(...,2,true)
-- call Game.SetObjectTransform uses on real props, and read the quaternion back.
-- Same operation, same order, same engine — just on a stand-in entity.
--
-- The probe's model does not matter (an entity's rotation quaternion does not
-- depend on its geometry); it only has to be a model that streams in, so the
-- caller passes model names taken from the map being exported. Spawned AT THE
-- PLAYER (no authored coordinate anywhere), invisible, collisionless, and
-- deleted the moment the export is built.
function Game.CreateRotationProbe(models)
    local px, py, pz = Game.PlayerPos()
    for i = 1, #(models or {}) do
        local obj = Game.SpawnObject(models[i], px, py, pz)   -- yields on model load
        if obj then
            SetEntityVisible(obj, false, false)
            SetEntityAlpha(obj, 0, false)
            SetEntityCollision(obj, false, false)
            return obj
        end
    end
    return nil
end

-- Euler (degrees, the record's rx/ry/rz) -> world quaternion, via the probe.
-- Returns the identity quaternion if the probe is gone, matching what
-- Game.GetObjectQuat does for a dead entity, so a caller can never get nil back
-- and format a nil into an export.
function Game.ProbeQuat(probe, rx, ry, rz)
    if not (probe and DoesEntityExist(probe)) then return 0.0, 0.0, 0.0, 1.0 end
    SetEntityRotation(probe, (rx or 0.0) + 0.0, (ry or 0.0) + 0.0, (rz or 0.0) + 0.0, 2, true)
    return GetEntityQuaternion(probe)
end

function Game.DestroyRotationProbe(probe) Game.DeleteObject(probe) end

-- What world entity the crosshair is pointing at (for select / world-erase).
-- Returns entity, model, hitX, hitY, hitZ  (entity 0 if none).
function Game.RaycastEntity(maxDist)
    local cx, cy, cz, rx, rz = camView()
    local cosx = math.abs(math.cos(rx))
    local dx, dy, dz = -math.sin(rz) * cosx, math.cos(rz) * cosx, math.sin(rx)
    local d = maxDist or 30.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cx, cy, cz,
        cx + dx * d, cy + dy * d, cz + dz * d, 1 + 16, PlayerPedId(), 0)
    local _, hit, coords, _, ent = GetShapeTestResult(ray)
    if hit == 1 then return ent or 0, ent and ent ~= 0 and GetEntityModel(ent) or 0, coords.x, coords.y, coords.z end
    return 0, 0, 0.0, 0.0, 0.0
end

-- ---- freecam (client/freecam.lua) -----------------------------------------
-- Scripted camera used by /mapcam. Isolated here so the natives stay in the bridge.
function Game.GameplayCamState()
    local c = GetGameplayCamCoord()
    local r = GetGameplayCamRot(2)
    return c.x, c.y, c.z, r.x, r.z, GetGameplayCamFov()
end
function Game.CamCreate(x, y, z, pitch, yaw, fov)
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        x + 0.0, y + 0.0, z + 0.0, pitch + 0.0, 0.0, yaw + 0.0, fov + 0.0, true, 2)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, false)
    return cam
end
function Game.CamApply(cam, x, y, z, pitch, yaw, fov)
    if not cam then return end
    SetCamCoord(cam, x + 0.0, y + 0.0, z + 0.0)
    SetCamRot(cam, pitch + 0.0, 0.0, yaw + 0.0, 2)
    SetCamFov(cam, fov + 0.0)
end
function Game.CamDestroy(cam)
    RenderScriptCams(false, false, 0, true, false)
    if cam then DestroyCam(cam, false) end
end

-- World eraser: hide all instances of a model in a tight sphere (vanilla map
-- prop suppression). Excludes our own script objects; survives map reload.
-- NOTE: this native family takes POSITION AS A SINGLE vector3, not 3 floats.
function Game.HideModelAt(x, y, z, radius, modelHash)
    CreateModelHideExcludingScriptObjects(vector3(x + 0.0, y + 0.0, z + 0.0), radius + 0.0, modelHash, true)
end
function Game.RestoreModelAt(x, y, z, radius, modelHash)
    RemoveModelHide(vector3(x + 0.0, y + 0.0, z + 0.0), radius + 0.0, modelHash, false)
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

-- Activity log: a rolling in-memory feed of everything the editor reports. Every
-- Game.Notify is teed into it (one central tap → no per-command wiring), so the
-- /maplog NUI viewer shows a real, searchable history of the session's actions.
local activity = {}     -- { { ts, msg, kind }, ... } oldest-first
local ACTIVITY_MAX = 200
function Game.LogActivity(msg, kind)
    activity[#activity + 1] = { ts = os.time(), msg = tostring(msg), kind = kind or 'inform' }
    if #activity > ACTIVITY_MAX then table.remove(activity, 1) end
end
function Game.GetActivityLog() return activity end

function Game.Notify(msg, kind)
    Game.LogActivity(msg, kind)
    if lib and lib.notify then lib.notify({ title = 'Map Editor', description = msg, type = kind or 'inform' }) end
end

function Game.Chat(tag, line)
    TriggerEvent('chat:addMessage', { args = { tag, line } })
end

-- 2D HUD primitives (used by the mass-fill preview prompt in client/tools.lua).
function Game.DrawRect2D(x, y, w, h, r, g, b, a)
    DrawRect(x + 0.0, y + 0.0, w + 0.0, h + 0.0, math.floor(r), math.floor(g), math.floor(b), math.floor(a))
end
function Game.DrawText2D(s, x, y, scale, r, g, b, center)
    SetTextFont(4); SetTextScale(scale + 0.0, scale + 0.0)
    SetTextColour(math.floor(r or 235), math.floor(g or 235), math.floor(b or 235), 235)
    SetTextOutline()
    if center then SetTextCentre(true) end
    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(s); EndTextCommandDisplayText(x + 0.0, y + 0.0)
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
