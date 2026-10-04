-- ============================================================================
-- palm6_appearance/bridge/cl_game.lua
--
-- The ONLY file that calls GTA natives. client/*.lua calls Game.* only.
-- Camera, head-blend, wardrobe capture/reapply, and preview-ped lifecycle —
-- all native access for this resource funnels through here.
-- See docs/GTA6-READINESS.md §3.
-- ============================================================================

Game = {}

-- ---- Preview ped lifecycle -------------------------------------------------

function Game.SpawnPreviewPed(genderKey, coords, heading)
    local model = Config.AllowedPreviewModels[genderKey]
    if not model then return nil end   -- refuses anything not in the whitelist

    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 200 do
        RequestModel(model)
        Wait(10)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then return nil end

    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, heading, false, false)

    -- A freshly created freemode ped has NO component variation at all: it is
    -- the bare body. Without this the creator opens on an undressed ped, and
    -- because Wardrobe.CaptureAll then captures drawable 0 on every configured
    -- component, the SAVED payload records "naked" - which applyToRealPlayer
    -- writes back over the ped's defaults on every join, forever. A player who
    -- only edited the face would ship an undressed character permanently.
    -- palm6_charselect's stage ped already does this; the creator did not.
    SetPedDefaultComponentVariation(ped)

    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityVisible(ped, true, false)
    SetModelAsNoLongerNeeded(model)
    return ped
end

function Game.DeletePed(ped)
    if ped and DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
end

-- ---- Real player ped ---------------------------------------------------------
-- Everything above this line operates on the resource's OWN preview ped. These
-- four touch the actual player, and exist because the editor previously had no
-- path to the real ped at all: a player could spend ten minutes in the creator,
-- hit save, and spawn as whatever random freemode look qbx_core had already
-- assigned - the whole payload went to the database and nowhere else.

function Game.GetEntityModel(entity)
    return GetEntityModel(entity)
end

--- True only if `ped` is literally the model named by `modelName`. The one
--- gate standing between a saved capture and the wrong ped - a female capture
--- applied to mp_m_freemode_01 resolves every drawable index against a
--- completely different garment list (docs/CUSTOM-CLOTHING.md §5). Kept here
--- rather than in client/main.lua so joaat/GetEntityModel stay behind Game.*.
---@return boolean
function Game.PedModelMatches(ped, modelName)
    if type(modelName) ~= 'string' or modelName == '' then return false end
    if not ped or not DoesEntityExist(ped) then return false end
    return GetEntityModel(ped) == joaat(modelName)
end

--- Swaps the LOCAL PLAYER's ped model. Destructive by design: SET_PLAYER_MODEL
--- replaces the ped entirely, so every head blend / component / prop on the old
--- one is gone afterwards and the caller MUST re-apply the appearance against
--- the handle this returns, not a handle captured before the call.
--- Returns the new ped handle, or nil if the model never loaded (in which case
--- the player keeps the ped they had - degrade, never strand).
---@param modelHash number one of Config.AllowedPreviewModels - never a caller-supplied value
function Game.SetPlayerPedModel(modelHash)
    if GetEntityModel(PlayerPedId()) == modelHash then
        return PlayerPedId()   -- already the right model; skip the destructive swap
    end

    RequestModel(modelHash)
    local tries = 0
    while not HasModelLoaded(modelHash) and tries < 200 do
        RequestModel(modelHash)
        Wait(10)
        tries = tries + 1
    end
    if not HasModelLoaded(modelHash) then return nil end

    SetPlayerModel(PlayerId(), modelHash)
    -- A freshly-modelled freemode ped has NO component variation at all and
    -- renders as the naked default; this gives it a valid baseline so any
    -- component the saved payload doesn't cover still looks like clothing.
    SetPedDefaultComponentVariation(PlayerPedId())
    SetModelAsNoLongerNeeded(modelHash)
    return PlayerPedId()
end

function Game.FadeOut(ms)
    DoScreenFadeOut(ms or 400)
    -- DoScreenFadeOut is asynchronous - returning immediately means the caller
    -- would swap the player's model while the world is still visible. Wait for
    -- the fade to actually finish, bounded so a stuck fade can't hang the flow.
    local waited = 0
    while not IsScreenFadedOut() and waited < (ms or 400) + 500 do
        Wait(25); waited = waited + 25
    end
end

function Game.FadeIn(ms)
    DoScreenFadeIn(ms or 400)
end

-- qbx_core's loaded event, behind Game.* like every other framework touchpoint
-- in this repo (same convention as palm6_charselect/bridge/cl_game.lua and
-- palm6_onboarding/bridge/cl_game.lua).
function Game.OnPlayerLoaded(handler)
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', handler)
end

function Game.PlayPreviewIdle(ped)
    RequestAnimDict('anim@mp_player_intcelebrationmale@face_left')
    -- no-op placeholder for a idle breathing anim if/when one is confirmed
    -- resident; intentionally not requesting a new anim dict beyond what is
    -- already streamed by the base game clip sets. Left as a stationary
    -- default pose otherwise.
end

-- ---- Bone lookup (drives camera focus, never hand-guessed offsets) --------

function Game.GetPedBoneCoords(ped, boneName)
    local boneIndex = GetPedBoneIndex(ped, GetHashKey(boneName))
    if boneIndex == -1 then return GetEntityCoords(ped) end
    return GetWorldPositionOfEntityBone(ped, boneIndex)
end

-- ---- Camera ----------------------------------------------------------------

function Game.CreateOrbitCam(coords, fov)
    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(cam, coords.x, coords.y, coords.z)
    SetCamFov(cam, fov)
    return cam
end

function Game.PointCamAtCoord(cam, coords)
    PointCamAtCoord(cam, coords.x, coords.y, coords.z)
end

function Game.SetCamCoord(cam, coords)
    SetCamCoord(cam, coords.x, coords.y, coords.z)
end

function Game.SetCamFov(cam, fov)
    SetCamFov(cam, fov)
end

function Game.SetCamActive(cam, active)
    SetCamActive(cam, active)
end

function Game.SetCamActiveWithInterp(camTo, camFrom, durationMs, easeLocation, easeRotation)
    SetCamActiveWithInterp(camTo, camFrom, durationMs, easeLocation and 1 or 0, easeRotation and 1 or 0)
end

function Game.RenderScriptCams(render, ease, durationMs)
    RenderScriptCams(render, ease or false, durationMs or 0, true, false)
end

function Game.DestroyCam(cam, immediate)
    if cam and DoesCamExist(cam) then
        DestroyCam(cam, immediate)
    end
end

function Game.DoesCamExist(cam)
    return cam ~= nil and DoesCamExist(cam)
end

function Game.SetCamDofStrength(cam, strength)
    if Game.DoesCamExist(cam) then
        SetCamDofStrength(cam, strength)
    end
end

-- Depth-of-field toggle for the active scripted cam. SET_USE_HI_DOF takes no
-- arguments and only holds for the frame it's called on, so "enabling" it
-- means calling it every tick from Camera.RampDof's render thread; there is
-- no explicit "disable" native — simply stop calling it and the effect lapses
-- next frame. Paired native usage confirmed against palm6_fc_arena's
-- spectator cam pattern (CreateCam / DestroyCam) for scripted-camera DOF.
function Game.SetUseHiDof(enabled)
    if enabled then
        SetUseHiDof()
    end
end

function Game.SetCamNearDof(cam, near)
    if Game.DoesCamExist(cam) then
        SetCamNearDof(cam, near)
    end
end

function Game.SetCamFarDof(cam, far)
    if Game.DoesCamExist(cam) then
        SetCamFarDof(cam, far)
    end
end

-- ---- Head blend / face features / overlays ---------------------------------

function Game.SetPedHeadBlendData(ped, s1, s2, s3, k1, k2, k3, shapeMix, skinMix, thirdMix)
    SetPedHeadBlendData(ped, s1, s2, s3, k1, k2, k3, shapeMix, skinMix, thirdMix, false)
end

function Game.SetPedFaceFeature(ped, index, value)
    SetPedFaceFeature(ped, index, value)
end

function Game.SetPedHeadOverlay(ped, overlayId, index, opacity)
    SetPedHeadOverlay(ped, overlayId, index, opacity)
end

function Game.SetPedHeadOverlayColor(ped, overlayId, colorType, colorIndex, secondColorIndex)
    SetPedHeadOverlayColor(ped, overlayId, colorType, colorIndex, secondColorIndex)
end

function Game.GetNumHeadOverlayValues(overlayId)
    return GetNumHeadOverlayValues(overlayId)
end

function Game.SetPedHairColor(ped, colorId, highlightColorId)
    SetPedHairColor(ped, colorId, highlightColorId)
end

function Game.SetPedEyeColor(ped, colorId)
    SetPedEyeColor(ped, colorId)
end

--- The REAL hair-colour palette, read out of the game.
---
--- The NUI used to paint its colour swatches with a generated HSL rainbow
--- (`hsl(i/64*360, 55%, 45%)`), so swatch 10 rendered lime green while the
--- hair it selects is brown. GTA's 64 hair colours are mostly blacks, browns,
--- blondes and reds with a block of unnatural shades at the end - a rainbow
--- misrepresents every one of them, and a player picks a colour by looking at
--- the swatch.
---
--- GET_PED_HAIR_RGB_COLOR returns the actual r,g,b for a colour index, so the
--- palette is CAPTURED from the game rather than hand-authored - the same rule
--- docs/CUSTOM-CLOTHING.md applies to drawable indices. Guarded so a build
--- without the native degrades to "no palette" (the NUI then falls back to
--- neutral swatches) instead of erroring.
---@param count number how many indices to read (0..count-1)
---@return table[] list of { r, g, b }, or an empty table if unavailable
function Game.GetHairRgbPalette(count)
    local palette = {}
    if not GetPedHairRgbColor then return palette end
    for i = 0, (count or 64) - 1 do
        local ok, r, g, b = pcall(GetPedHairRgbColor, i)
        if not ok then return palette end
        palette[#palette + 1] = { r = r or 0, g = g or 0, b = b or 0 }
    end
    return palette
end

-- ---- Tattoo tiers: enumeration over the ped's already-mounted decorations --
-- VERIFY before enabling: GetPedDecorationsCount / GetPedDecorationCollectionAt
-- are the natives believed to expose the live per-ped decoration table, but
-- their exact names/signatures on this build's natives.lua have not been
-- confirmed against the live game box. Guarded with `and`-checks below so a
-- missing native degrades to "no tiers found" (control disabled) rather than
-- throwing — see headblend.lua's EnumerateTattooTiers for the caller-side
-- degrade path.
function Game.GetPedDecorationCollectionCount(ped)
    if GetPedDecorationsCount then
        return GetPedDecorationsCount(ped)
    end
    return 0
end

function Game.GetPedDecorationCollectionAt(ped, index)
    -- Returns collectionHash, presetHash — both already-streamed values off
    -- the live ped decoration table, never authored by hand.
    if GetPedDecorationCollectionAt then
        return GetPedDecorationCollectionAt(ped, index)
    end
    return nil, nil
end

function Game.DoesDecorationExist(collectionHash, presetHash)
    return DoesDecorationExist(collectionHash, presetHash)
end

function Game.GetPedDecorationZoneFromHashes(collectionHash, presetHash)
    if GetPedDecorationZoneFromHashes then
        return GetPedDecorationZoneFromHashes(collectionHash, presetHash)
    end
    return -1
end

function Game.AddPedDecorationFromHashes(ped, collectionHash, presetHash)
    AddPedDecorationFromHashes(ped, collectionHash, presetHash)
end

function Game.ClearPedDecorationsLeavingScars(ped)
    ClearPedDecorationsLeavingScars(ped)
end

-- ---- Wardrobe: capture-and-reapply ONLY, existing indices ONLY -------------
-- Never authors a drawable/texture/prop index by hand. Every value passed
-- into the Set* calls below must have come from either (a) a Get* capture
-- off a live ped, or (b) an enumeration loop bounded by GetNumPedCollection*.

function Game.GetPedDrawableVariationCollectionName(ped, componentId)
    return GetPedDrawableVariationCollectionName(ped, componentId)
end

function Game.GetPedDrawableVariationCollectionLocalIndex(ped, componentId)
    return GetPedDrawableVariationCollectionLocalIndex(ped, componentId)
end

function Game.GetPedTextureVariationFromComponent(ped, componentId)
    return GetPedTextureVariationFromComponent and GetPedTextureVariationFromComponent(ped, componentId) or 0
end

function Game.GetNumPedCollectionDrawableVariations(ped, componentId, collectionName)
    return GetNumberOfPedCollectionDrawableVariations(ped, componentId, collectionName)
end

function Game.GetNumPedCollectionTextureVariations(ped, componentId, collectionName, drawableId)
    return GetNumberOfPedCollectionTextureVariations(ped, componentId, collectionName, drawableId)
end

function Game.IsPedCollectionComponentVariationValid(ped, componentId, collectionName, drawableId, textureId)
    return IsPedCollectionComponentVariationValid(ped, componentId, collectionName, drawableId, textureId)
end

function Game.SetPedCollectionComponentVariation(ped, componentId, collectionName, drawableId, textureId)
    -- paletteId is ALWAYS 0. Never 2 — that was the retired palm6_threads bug.
    SetPedCollectionComponentVariation(ped, componentId, collectionName, drawableId, textureId, 0)
end

function Game.GetPedPropCollectionName(ped, propId)
    return GetPedPropCollectionName(ped, propId)
end

function Game.GetPedPropCollectionLocalIndex(ped, propId)
    return GetPedPropCollectionLocalIndex(ped, propId)
end

function Game.GetPedPropIndex(ped, propId)
    return GetPedPropIndex(ped, propId)
end

function Game.GetPedPropTextureIndex(ped, propId)
    return GetPedPropTextureIndex and GetPedPropTextureIndex(ped, propId) or 0
end

function Game.GetNumPedCollectionPropDrawableVariations(ped, propId, collectionName)
    return GetNumberOfPedCollectionPropDrawableVariations(ped, propId, collectionName)
end

function Game.GetNumPedCollectionPropTextureVariations(ped, propId, collectionName, drawableId)
    return GetNumberOfPedCollectionPropTextureVariations and
        GetNumberOfPedCollectionPropTextureVariations(ped, propId, collectionName, drawableId) or 1
end

function Game.IsPedCollectionPropValid(ped, propId, collectionName, drawableId, textureId)
    return IsPedCollectionPropValid(ped, propId, collectionName, drawableId, textureId)
end

function Game.SetPedCollectionPropIndex(ped, propId, collectionName, drawableId, textureId)
    SetPedCollectionPropIndex(ped, propId, collectionName, drawableId, textureId, true)
end

function Game.ClearPedProp(ped, propId)
    ClearPedProp(ped, propId)
end

function Game.Notify(msg, kind)
    lib.notify({ description = msg, type = kind or 'inform' })
end

function Game.SetNuiFocus(hasFocus, hasCursor)
    SetNuiFocus(hasFocus, hasCursor)
end

function Game.PlayerPedId()
    return PlayerPedId()
end

function Game.GetEntityCoords(entity)
    return GetEntityCoords(entity)
end

function Game.GetEntityHeading(entity)
    return GetEntityHeading(entity)
end

function Game.DisplayRadar(show)
    DisplayRadar(show)
end

function Game.DisplayHud(show)
    DisplayHud(show)
end
