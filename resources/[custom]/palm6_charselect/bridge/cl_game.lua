-- ============================================================================
-- palm6_charselect/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA
-- natives, camera/ped/streaming functions, or ox_lib UI. client/main.lua
-- calls Game.* only, so this logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3) and the same convention in
-- palm6_onboarding/bridge/cl_game.lua.
-- ============================================================================

Game = {}

local sceneCam, transitionCam = nil, nil

-- Called once when charselect should take over the screen. Freezes/hides
-- the local ped, disables HUD, fades in on the configured scene camera.
function Game.SetupScene(cameraCfg)
    sceneTornDown = false   -- a scene exists again; stage spawns are wanted
    DoScreenFadeOut(0)
    DisplayRadar(false)
    DisplayHud(false)
    FreezeEntityPosition(PlayerPedId(), true)
    SetEntityVisible(PlayerPedId(), false, false)

    sceneCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        cameraCfg.pos.x, cameraCfg.pos.y, cameraCfg.pos.z,
        0.0, 0.0, 0.0, cameraCfg.fov, false, 0)
    PointCamAtCoord(sceneCam, cameraCfg.lookAt.x, cameraCfg.lookAt.y, cameraCfg.lookAt.z)
    SetCamActive(sceneCam, true)
    RenderScriptCams(true, false, 0, true, true)

    -- Deterministic time/weather for the stage ped. Set before the fade so the
    -- player never sees the transition from live weather to the locked look.
    Game.LockStageEnvironment()

    Wait(60)
    DoScreenFadeIn(400)
end

-- Cinematic swap on character select: a push-in on the SAME point the scene
-- camera is already looking at (closes SelectZoomDistance of the pos->lookAt
-- gap, narrows to SelectZoomFov), interp'd over durationMs. Deliberately NOT
-- a cut to a different world location - this resource has no per-character
-- world position to frame (that's the actual spawn point, handled by
-- Game.SpawnAtPosition, not this camera), and an earlier version faked a
-- "cinematic" by building a transitionCam at the IDENTICAL coords as
-- sceneCam, which interpolated between two identical cameras and moved
-- nothing. This at least visibly moves.
function Game.PlaySelectCinematic(fromCam, durationMs)
    local sourceCam = fromCam or sceneCam
    if not sourceCam then return nil end

    local cfg = Config.SceneCamera
    local dist = Config.SelectZoomDistance or 0.5
    local zoomPos = vector3(
        cfg.pos.x + (cfg.lookAt.x - cfg.pos.x) * dist,
        cfg.pos.y + (cfg.lookAt.y - cfg.pos.y) * dist,
        cfg.pos.z + (cfg.lookAt.z - cfg.pos.z) * dist
    )

    transitionCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        zoomPos.x, zoomPos.y, zoomPos.z, 0.0, 0.0, 0.0, Config.SelectZoomFov or 32.0, false, 0)
    PointCamAtCoord(transitionCam, cfg.lookAt.x, cfg.lookAt.y, cfg.lookAt.z)
    SetCamActiveWithInterp(transitionCam, sourceCam, durationMs, 1, 1)
    Wait(durationMs)
    return transitionCam
end

-- NOTE: a per-citizenid Game.SpawnPreviewPed/DestroyPreviewPed pair used to
-- live here, keyed off a `previewPeds` table. It was never called by anything
-- (flagged as dead in this resource's own README) and it only ever applied the
-- `components` half of an appearance, so a preview built with it would have
-- had the right clothes on a default face. It has been replaced by the single
-- Game.SetStageCharacter below, which reuses palm6_appearance's real apply
-- path - including the model guard - instead of a second, weaker copy of it.
-- Two ped-preview systems in one file is how one of them silently rots.

-- ---------------------------------------------------------------------------
-- Character preview stage — ONE ped, standing where the scene camera is
-- already looking, wearing the selected character's real saved appearance.
--
-- Deliberately one ped and not one-per-card: a card is a 260px DOM element
-- with no world position, so "a ped behind each card" would mean inventing
-- three world coordinates and hoping they line up with a CSS grid at every
-- resolution. Swapping the single framed ped as the selection moves is what
-- the premium scripts on the market actually do, and it needs no coordinate
-- this repo cannot cite.
-- ---------------------------------------------------------------------------

local stagePed = nil
local stageCitizenId = nil
local stageGroundZ = nil   -- probed once; the floor under a fixed point does not move

--- True from the moment any teardown path runs until the next SetupScene.
---
--- Game.SetStageCharacter is not instant - it yields on a ground probe (up to
--- 2s on the first call, while collision streams in around a freshly connected
--- client) and on a model load (up to 5s). Hit PLAY inside that window and
--- teardown runs DestroyStagePed while `stagePed` is still nil, then the
--- suspended spawn resumes and creates its ped into a scene that no longer
--- exists. Nothing destroys it afterwards: onResourceStop's cleanup is gated
--- on `isOpen`, which is false by then. The result is a frozen invincible
--- clone standing near the spawn point the moment the player loads in, plus a
--- Wait(0) turntable thread that can never exit - the last generation bump
--- belongs to that thread itself, so its own guard can never go false.
---
--- The caller's token (`isCancelled`) covers "a newer stage request
--- superseded me"; this flag covers "the whole scene is gone", which the
--- caller's token does not express.
local sceneTornDown = false

--- GTA heading (degrees) that makes an entity at `from` face `to`.
--- Forward for heading h is (-sin h, cos h), so h = atan2(-dx, dy).
local function headingTowards(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    if dx == 0.0 and dy == 0.0 then return 0.0 end
    return math.deg(math.atan(-dx, dy))
end

--- Ground height at (x, y), probed from above. Returns nil when the world
--- underneath genuinely isn't there yet - the caller must treat that as "no
--- preview", never as "use z anyway".
local function probeGroundZ(x, y, startZ)
    local cfg = Config.PreviewStage
    RequestCollisionAtCoord(x, y, startZ)
    for _ = 1, cfg.probeAttempts do
        local found, groundZ = GetGroundZFor_3DCoord(x, y, startZ, false)
        if found then return groundZ end
        RequestCollisionAtCoord(x, y, startZ)
        Wait(cfg.probeIntervalMs)
    end
    return nil
end

--- Slow turntable on the stage ped. A character standing dead still reads as a
--- mannequin; rotating it is what lets a player actually see the outfit they
--- are choosing.
---
--- Generation-guarded rather than flag-guarded: every spawn bumps
--- `turntableGeneration`, so a previous ped's thread exits on its next frame
--- instead of continuing to rotate a deleted entity (SetEntityHeading on a
--- dead handle is a silent no-op, but the thread would otherwise run forever).
--- Frame-rate independent - the step is scaled by real elapsed time, so it
--- turns at the same speed on a 30fps and a 144fps client.
local turntableGeneration = 0

local function startTurntable(ped, startHeading)
    if not Config.PreviewStage.turntable then return end

    turntableGeneration = turntableGeneration + 1
    local myGeneration = turntableGeneration
    local heading = startHeading
    local degreesPerSecond = Config.PreviewStage.turntableDegreesPerSecond or 7.0

    CreateThread(function()
        local last = GetGameTimer()
        while myGeneration == turntableGeneration and not sceneTornDown and ped and DoesEntityExist(ped) do
            local now = GetGameTimer()
            heading = (heading + degreesPerSecond * ((now - last) / 1000.0)) % 360.0
            last = now
            SetEntityHeading(ped, heading)
            Wait(0)
        end
    end)
end

--- Freezes time and weather for the select screen so a character looks the
--- same on every join. Client-local; Game.ClearStageEnvironment undoes it and
--- every teardown path calls that.
function Game.LockStageEnvironment()
    local cfg = Config.PreviewStage
    if not cfg.lockEnvironment then return end
    NetworkOverrideClockTime(cfg.clockHour, cfg.clockMinute, 0)
    SetWeatherTypeNowPersist(cfg.weather)
end

function Game.ClearStageEnvironment()
    if not Config.PreviewStage.lockEnvironment then return end
    NetworkClearClockTimeOverride()
    ClearWeatherTypePersist()
    ClearOverrideWeatherType()
end

--- Spawns (or re-spawns) the stage ped wearing `appearance`.
--- @param modelName string 'mp_m_freemode_01'|'mp_f_freemode_01' - taken from
---        the saved payload's own model stamp, never inferred here.
--- @param isCancelled function|nil returns true once this request has been
---        superseded by a newer one (client/main.lua passes its stage token
---        closure). Re-checked after EVERY yield below - see `sceneTornDown`.
--- @return boolean spawned
function Game.SetStageCharacter(citizenid, modelName, appearance, isCancelled)
    if not Config.PreviewStage.enabled then return false end
    if type(modelName) ~= 'string' or modelName == '' then return false end

    -- One predicate for "stop, this spawn is no longer wanted", covering both
    -- reasons: the scene is gone, or a newer request replaced this one.
    local function cancelled()
        return sceneTornDown or (isCancelled ~= nil and isCancelled())
    end

    if cancelled() then return false end
    if stageCitizenId == citizenid and stagePed and DoesEntityExist(stagePed) then
        return true   -- already showing this character
    end

    local lookAt = Config.SceneCamera.lookAt
    -- Probed once and reused. The probe retries for up to two seconds while
    -- collision streams in around a freshly-connected client, and re-running
    -- that on every hover would make swapping between cards feel broken.
    if not stageGroundZ then
        stageGroundZ = probeGroundZ(lookAt.x, lookAt.y, lookAt.z + Config.PreviewStage.probeHeightAbove)
    end
    if not stageGroundZ then
        -- No surface under the framed point (or the world hasn't streamed in).
        -- Refuse rather than float a ped in mid-air at a guessed height.
        return false
    end
    if cancelled() then return false end   -- probeGroundZ yields for up to 2s

    local hash = joaat(modelName)
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(50); waited = waited + 50
        if cancelled() then SetModelAsNoLongerNeeded(hash); return false end
    end
    if not HasModelLoaded(hash) then return false end

    Game.DestroyStagePed()

    local heading = headingTowards(lookAt, Config.SceneCamera.pos)
    local ped = CreatePed(4, hash, lookAt.x, lookAt.y, stageGroundZ, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return false end

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetPedCanRagdoll(ped, false)
    -- A fresh freemode ped has no component variation at all and renders
    -- naked; this is the floor the saved appearance is then applied over, so a
    -- payload that doesn't cover every slot still looks dressed.
    SetPedDefaultComponentVariation(ped)

    stagePed = ped
    stageCitizenId = citizenid

    -- Registered first, THEN re-checked: if the scene went away during the
    -- loads above, DestroyStagePed can now actually find this ped and delete
    -- it. Doing the check before assigning would leave the handle unreachable
    -- and the ped permanently orphaned - which is precisely the old bug.
    if cancelled() then
        Game.DestroyStagePed()
        return false
    end

    startTurntable(ped, heading)

    -- The appearance itself is applied by palm6_appearance, which owns the
    -- model guard (docs/CUSTOM-CLOTHING.md §5 - a capture must never be
    -- applied to a ped of the other model). Failing that call leaves a
    -- correctly-modelled ped in default clothes, which is still a real
    -- character standing there, so it is not treated as a spawn failure.
    if appearance then
        pcall(function()
            exports.palm6_appearance:applyAppearanceToPed(ped, appearance)
        end)
    end

    return true
end

function Game.DestroyStagePed()
    -- Stop the turntable BEFORE deleting, so its thread cannot run one more
    -- frame against a handle that is about to become invalid.
    turntableGeneration = turntableGeneration + 1
    if stagePed and DoesEntityExist(stagePed) then DeleteEntity(stagePed) end
    stagePed = nil
    stageCitizenId = nil
end

function Game.TeardownScene()
    sceneTornDown = true   -- abandons any stage spawn still suspended on a load
    Game.DestroyStagePed()
    Game.ClearStageEnvironment()
    RenderScriptCams(false, true, 400, true, true)
    if sceneCam then DestroyCam(sceneCam, false); sceneCam = nil end
    if transitionCam then DestroyCam(transitionCam, false); transitionCam = nil end
    DisplayHud(true)
    DisplayRadar(true)
    FreezeEntityPosition(PlayerPedId(), false)
    SetEntityVisible(PlayerPedId(), true, false)
    DoScreenFadeOut(0)
end

-- Same as Game.TeardownScene, EXCEPT it leaves the real player ped frozen
-- and hidden. Used only for the create-character hand-off to
-- palm6_appearance (client/main.lua): that resource spawns its OWN preview
-- ped at the real ped's coords and does not hide/freeze the real one itself
-- (its normal use case is a barbershop-style re-edit where there's no
-- competing "charselect scene" to hand off from) - if we un-hide/un-freeze
-- the real ped here first, the player briefly sees two overlapping models.
-- Restoring HUD/radar and killing charselect's own camera is still correct;
-- only the ped visibility/freeze step is skipped.
-- Un-hides/un-freezes the real player ped without touching camera/HUD/radar
-- state - the other half of Game.TeardownSceneKeepPedHidden's split, for the
-- path where the palm6_appearance hand-off failed and there's no preview ped
-- coming to take over ped visibility instead.
function Game.RevealRealPed()
    FreezeEntityPosition(PlayerPedId(), false)
    SetEntityVisible(PlayerPedId(), true, false)
end

function Game.TeardownSceneKeepPedHidden()
    -- Same abandonment as the full teardown. This is the path that bites
    -- hardest: it hands off to the appearance editor, where the player then
    -- sits for minutes with no further teardown coming to clean up after a
    -- late spawn.
    sceneTornDown = true
    Game.DestroyStagePed()
    Game.ClearStageEnvironment()
    RenderScriptCams(false, true, 400, true, true)
    if sceneCam then DestroyCam(sceneCam, false); sceneCam = nil end
    if transitionCam then DestroyCam(transitionCam, false); transitionCam = nil end
    DisplayHud(true)
    DisplayRadar(true)
    DoScreenFadeOut(0)
end

--- Human-readable district for a saved character position, e.g. "Vinewood
--- Hills". Every premium select screen shows where a character was left; the
--- data was already here (qbx_core returns `position` per character, and this
--- resource already reads it for the actual spawn) and was only ever used to
--- teleport with. Returns nil rather than a code when the game has no label
--- for the zone, so the NUI can just omit the line.
function Game.GetZoneLabel(pos)
    if not pos then return nil end
    local zoneCode = GetNameOfZone(pos.x, pos.y, pos.z)
    if not zoneCode or zoneCode == '' then return nil end
    local label = GetLabelText(zoneCode)
    if not label or label == '' or label == 'NULL' then return nil end
    return label
end

function Game.FadeOut(ms) DoScreenFadeOut(ms or 400) end
function Game.FadeIn(ms) DoScreenFadeIn(ms or 400) end

function Game.Notify(opts) lib.notify(opts) end

--- Stock frontend UI sound - the standard GTA HUD sound bank, already
--- resident on every client, streams nothing new. Discrete-event only.
---@param soundName string e.g. 'SELECT'
function Game.PlaySound(soundName)
    PlaySoundFrontend(-1, soundName, 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

function Game.ShowMandatoryDialog(header, content)
    lib.alertDialog({ header = header, content = content, centered = true, cancel = false })
end

-- Hides qbx_core's loaded-event naming behind Game.*, same convention as
-- palm6_onboarding/bridge/cl_game.lua Game.OnPlayerLoaded.
function Game.OnPlayerLoaded(handler)
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', handler)
end

-- ---------------------------------------------------------------------------
-- qbx_core character RPC — CONFIRMED against the live qbx_core source
-- (github.com/Qbox-project/qbx_core, server/character.lua): these are
-- lib.callback.register'd on qbx_core's SERVER, which ox_lib only lets a
-- CLIENT invoke (lib.callback has no server-to-server path - see
-- ox_lib/imports/callback/server.lua, lib.callback.register wires a
-- RegisterNetEvent that only a client-side lib.callback.await can trigger).
-- That's why these live here in Game.*, called directly from
-- client/main.lua, instead of round-tripping through our own server - a
-- prior version of this file guessed at server-side qbx_core exports for
-- this (GetCharacters/CreateCharacter did not exist under those names) and
-- has been corrected to match the verified real integration surface.
-- ---------------------------------------------------------------------------

-- Every lib.callback.await below is pcall-wrapped: ox_lib's own client
-- import (imports/callback/client.lua) REJECTS the awaited promise (which
-- raises through Citizen.Await) on a timeout (ox:callbackTimeout, default
-- 300s) or a 'cb_invalid' response (the target callback was never
-- registered - e.g. qbx_core isn't running, or useExternalCharacters is
-- misconfigured so qbx_core's own character.lua never loaded). Unprotected,
-- that raises INSIDE the RegisterNUICallback handler that called it, which
-- would otherwise die mid-flow with NUI focus/scene state stuck. Every
-- caller in client/main.lua must treat a false first return as "the qbx_core
-- call itself failed", distinct from "qbx_core ran it and said no".

-- Returns (ok, characters, maxSlots) - characters/maxSlots exactly as
-- qbx_core's own client/character.lua receives them (maxSlots is qbx_core's
-- REAL config.characters value, not a guessed convar - qbx_core's config is
-- plain Lua, not convar-driven; see README.md "qbx_core integration").
function Game.GetCharacters()
    local ok, characters, maxSlots = pcall(lib.callback.await, 'qbx_core:server:getCharacters', false)
    if not ok then return false, nil, nil end
    return true, characters, maxSlots
end

-- form: { firstname, lastname, nationality, gender, birthdate } - gender is
-- 0 (male) or 1 (female), a NUMBER, matching qbx_core's own characterDialog()
-- payload shape exactly (client/character.lua line ~319). Returns
-- (ok, newData) - newData is the new character's data table on success,
-- nil/false if qbx_core rejected the submission (qbx_core's own server-side
-- sanitizeNewCharInfo + cid assignment + starter items all run as part of
-- this call - do not attempt to replicate that logic here).
function Game.CreateCharacterViaQbx(form)
    local ok, newData = pcall(lib.callback.await, 'qbx_core:server:createCharacter', false, form)
    if not ok then return false, nil end
    return true, newData
end

-- Logs into an existing character. qbx_core's own Login() re-validates
-- ownership server-side and drops the client on a mismatch (server/player.lua)
-- - this call does not need a separate ownership pre-check to be safe, though
-- server/main.lua still does one for defense in depth / a cleaner error
-- message instead of a hard drop. Returns ok only - qbx_core's own callback
-- doesn't communicate success/failure back to the caller either way (its own
-- UI doesn't check); server/main.lua's confirmSelect handler is the real
-- signal, via Bridge.IsPlayerLoaded.
function Game.LoginCharacterViaQbx(citizenid)
    local ok = pcall(lib.callback.await, 'qbx_core:server:loadCharacter', false, citizenid)
    return ok
end

-- ---------------------------------------------------------------------------
-- Spawn pipeline - the part of qbx_core's client/character.lua that DOES
-- NOT get skipped by useExternalCharacters and has to be reimplemented here
-- instead: shutting down the FiveM loading screen, disabling spawnmanager's
-- default autospawn, actually moving the ped to a spawn point, and firing
-- the OnPlayerLoaded events every other palm6_* resource's cl_game.lua
-- listens for (palm6_insignia, palm6_pd_life, palm6_onboarding,
-- server_identity, server_base, palm6_turf, palm6_uniform - confirmed via
-- repo-wide grep for QBCore:Client:OnPlayerLoaded). None of this happens on
-- its own just because useExternalCharacters=true routes qbx_core's own
-- character.lua out - that file was the ONLY place that did any of it.
-- ---------------------------------------------------------------------------

-- Call ONCE, early (client/main.lua's onResourceStart), before any spawn
-- attempt - matches qbx_core's own client/character.lua:499 timing
-- (`pcall(function() exports.spawnmanager:setAutoSpawn(false) end)` inside
-- its session-start wait loop). Without this, spawnmanager's own default
-- behavior can auto-spawn the ped into the world while charselect's NUI is
-- still up.
function Game.DisableAutoSpawn()
    pcall(function() exports.spawnmanager:setAutoSpawn(false) end)
end

-- Closes the real FiveM loading screen. Call once charselect's own NUI is
-- actually ready to take over (right before the first SetupScene) - NOT
-- something to leave to "FiveM auto-closes it", which is only true when
-- qbx_core's own character.lua (which calls this) is the thing running.
function Game.ShutdownLoadingScreen()
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
end

-- Moves the real ped to `pos` (a vector4, x/y/z/heading) and fires the
-- QBCore loaded events every dependent palm6_* resource listens for. Uses
-- spawnmanager if present (matches qbx_core's own call shape exactly -
-- `exports.spawnmanager:spawnPlayer({x,y,z,heading})`), falls back to a
-- direct SetEntityCoords/SetEntityHeading if spawnmanager isn't running for
-- some reason - degrade safely rather than strand the player with no spawn
-- at all.
function Game.SpawnAtPosition(pos)
    local ok = pcall(function()
        exports.spawnmanager:spawnPlayer({ x = pos.x, y = pos.y, z = pos.z, heading = pos.w })
    end)
    if not ok then
        local ped = PlayerPedId()
        SetEntityCoords(ped, pos.x, pos.y, pos.z, false, false, false, false)
        SetEntityHeading(ped, pos.w)
    end

    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
end

-- Solo tutorial session + a short invincibility window, matching qbx_core's
-- own client/character.lua:105,505-510 ("since people apparently die during
-- char select"). Cheap insurance against fall/traffic damage while the ped is
-- still being positioned.
--
-- ⚠️ THE END CALL IS THE WHOLE POINT OF THIS FUNCTION'S SHAPE.
-- A solo tutorial session puts the local player in their OWN network instance:
-- while it is active they cannot see any other player and no other player can
-- see them. qbx_core pairs NetworkStartSoloTutorialSession with
-- NetworkEndTutorialSession once the ped is placed; an earlier version of this
-- file copied only the start half, and `NetworkEndTutorialSession` then existed
-- NOWHERE in this repo. Every join path calls this, so every player was
-- permanently instanced away from every other player - two people on the same
-- corner invisible to each other, all ped/vehicle sync between them dead.
-- The old loop even waited on `NetworkIsInTutorialSession()` for something to
-- end a session nothing ended.
--
-- The two windows are now separate and both bounded by wall clock, because
-- they protect against different things: the solo session hides the spawn
-- itself (short - being invisible to the server is not a state to linger in),
-- the invincibility covers the fall/traffic settle after it.
function Game.StartTutorialProtection()
    NetworkStartSoloTutorialSession()

    CreateThread(function()
        local cfg = Config.SpawnProtection
        local waited = 0
        local soloEnded = false

        while waited < cfg.invincibleMs do
            SetEntityInvincible(PlayerPedId(), true)

            -- End the solo session as soon as the ped has had time to settle,
            -- and keep going on invincibility for the rest of the window.
            if not soloEnded and waited >= cfg.soloSessionMs then
                NetworkEndTutorialSession()
                soloEnded = true
            end

            Wait(250)
            waited = waited + 250
        end

        -- Belt and braces: if the loop was ever shortened past the branch
        -- above, the session must STILL end. Ending one that is already ended
        -- is a no-op; leaving one open is a broken server.
        if not soloEnded then NetworkEndTutorialSession() end
        SetEntityInvincible(PlayerPedId(), false)
    end)
end

