-- ============================================================================
-- palm6_appearance/client/headblend.lua
--
-- 3-parent SetPedHeadBlendData, face features, head overlays, hair/eye color,
-- and tattoo "opacity" via tier-cycling across existing decoration hashes.
-- Calls Game.* only. Never calls a GTA native directly.
--
-- Tattoo tiering is a from-scratch reinterpretation inspired by the general
-- "layering" idea referenced from the open-source GPLv3 bl_appearance
-- project (Byte-Labs-Studio), redesigned to fit PALM6's absolute no-new-
-- asset constraint. It deliberately does NOT replicate any texture-swap
-- mechanism (AddReplaceTexture / DUI overlay), since that is banned in
-- docs/CUSTOM-CLOTHING.md §7 regardless of purpose.
-- ============================================================================

HeadBlend = {}

local blend = {
    shapeFirst = 0, shapeSecond = 0, shapeThird = 0,
    skinFirst  = 0, skinSecond  = 0, skinThird  = 0,
    shapeMix = 0.5, skinMix = 0.5, thirdMix = 0.0,
}

local faceFeatures = {}
for i = 0, Config.FaceFeatureCount - 1 do faceFeatures[i] = 0.0 end

local overlays = {}     -- [overlayId] = { index = n, opacity = f, color1 = n, color2 = n }
local hairColor, hairHighlight = 0, 0
local eyeColor = 0

-- Getter for the current preview ped, bound by client/main.lua via
-- HeadBlend.BindPedRef so this module never introduces a second source of
-- truth for "which ped" — set before EnumerateTattooTiers can be reached in
-- the normal open flow (Camera.Init/BindPedRef both run in
-- client/main.lua's openAppearanceScreen before any NUI callback fires).
local previewPedRef = nil

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function clampHeadId(id)
    return math.floor(clamp(id, Config.HeadBlendRange.min, Config.HeadBlendRange.max))
end

-- ---- Head blend parents -----------------------------------------------------

function HeadBlend.SetParents(ped, s1, s2, s3, k1, k2, k3)
    blend.shapeFirst  = clampHeadId(s1)
    blend.shapeSecond = clampHeadId(s2)
    blend.shapeThird  = clampHeadId(s3)
    blend.skinFirst    = clampHeadId(k1)
    blend.skinSecond   = clampHeadId(k2)
    blend.skinThird    = clampHeadId(k3)

    Game.SetPedHeadBlendData(
        ped,
        blend.shapeFirst, blend.shapeSecond, blend.shapeThird,
        blend.skinFirst, blend.skinSecond, blend.skinThird,
        blend.shapeMix, blend.skinMix, blend.thirdMix
    )
end

function HeadBlend.SetMix(ped, mixKey, value)
    if mixKey ~= 'shapeMix' and mixKey ~= 'skinMix' and mixKey ~= 'thirdMix' then return end
    blend[mixKey] = clamp(value, 0.0, 1.0)

    -- All ten params always sent together — matches the native's actual
    -- signature, no partial-apply.
    Game.SetPedHeadBlendData(
        ped,
        blend.shapeFirst, blend.shapeSecond, blend.shapeThird,
        blend.skinFirst, blend.skinSecond, blend.skinThird,
        blend.shapeMix, blend.skinMix, blend.thirdMix
    )
end

function HeadBlend.GetBlendState()
    return blend
end

-- ---- Face features -----------------------------------------------------

function HeadBlend.SetFaceFeature(ped, index, value)
    index = math.floor(clamp(index, 0, Config.FaceFeatureCount - 1))
    value = clamp(value, Config.FaceFeatureRange.min, Config.FaceFeatureRange.max)
    faceFeatures[index] = value
    Game.SetPedFaceFeature(ped, index, value)
end

function HeadBlend.GetFaceFeatures()
    return faceFeatures
end

-- ---- Head overlays (eyebrows, blemishes, makeup, etc) ----------------------

function HeadBlend.SetOverlay(ped, overlayId, index, opacity)
    opacity = clamp(opacity, 0.0, 1.0)
    overlays[overlayId] = overlays[overlayId] or {}
    overlays[overlayId].index = index
    overlays[overlayId].opacity = opacity
    Game.SetPedHeadOverlay(ped, overlayId, index, opacity)
end

function HeadBlend.SetOverlayColor(ped, overlayId, colorType, colorIndex, secondColorIndex)
    overlays[overlayId] = overlays[overlayId] or {}
    overlays[overlayId].color1 = colorIndex
    overlays[overlayId].color2 = secondColorIndex
    Game.SetPedHeadOverlayColor(ped, overlayId, colorType, colorIndex, secondColorIndex)
end

function HeadBlend.GetOverlays()
    return overlays
end

-- ---- Hair / eye color --------------------------------------------------

function HeadBlend.SetHairColor(ped, colorId, highlightColorId)
    hairColor = math.floor(clamp(colorId, Config.HairColorRange.min, Config.HairColorRange.max))
    hairHighlight = math.floor(clamp(highlightColorId, Config.HairColorRange.min, Config.HairColorRange.max))
    Game.SetPedHairColor(ped, hairColor, hairHighlight)
end

function HeadBlend.SetEyeColor(ped, colorId)
    eyeColor = math.floor(clamp(colorId, Config.EyeColorRange.min, Config.EyeColorRange.max))
    Game.SetPedEyeColor(ped, eyeColor)
end

function HeadBlend.GetColorState()
    return { hairColor = hairColor, hairHighlight = hairHighlight, eyeColor = eyeColor }
end

-- ---- Randomize (server-safe, pure math, no new assets) ---------------------

function HeadBlend.Randomize(ped)
    math.randomseed(GetGameTimer())

    local s1 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)
    local s2 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)
    local s3 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)
    local k1 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)
    local k2 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)
    local k3 = math.random(Config.HeadBlendRange.min, Config.HeadBlendRange.max)

    HeadBlend.SetParents(ped, s1, s2, s3, k1, k2, k3)
    HeadBlend.SetMix(ped, 'shapeMix', math.random())
    HeadBlend.SetMix(ped, 'skinMix', math.random())
    HeadBlend.SetMix(ped, 'thirdMix', math.random() * 0.4)   -- keep third parent subtle by default
end

-- Separate from HeadBlend.Randomize (face-only, bound to the plain
-- "Randomize" button) so 'randomizeAll' (client/main.lua) can compose this
-- with HeadBlend.Randomize + Wardrobe.RandomizeAll for "Randomize All".
function HeadBlend.RandomizeColors(ped)
    local hair = math.random(Config.HairColorRange.min, Config.HairColorRange.max)
    local highlight = math.random(Config.HairColorRange.min, Config.HairColorRange.max)
    HeadBlend.SetHairColor(ped, hair, highlight)
    HeadBlend.SetEyeColor(ped, math.random(Config.EyeColorRange.min, Config.EyeColorRange.max))
end

-- Rolls all 20 SET_PED_FACE_FEATURE sliders within Config.FaceFeatureRange.
-- Weighted toward the middle of the range (average of two rolls) rather than
-- a flat distribution - a flat roll on every one of 20 features simultaneously
-- reliably produces a distorted/uncanny face; premium "randomize" character
-- creators bias toward subtler combined results for the same reason.
function HeadBlend.RandomizeFeatures(ped)
    local lo, hi = Config.FaceFeatureRange.min, Config.FaceFeatureRange.max
    for i = 0, Config.FaceFeatureCount - 1 do
        local roll = ((math.random() + math.random()) / 2) * (hi - lo) + lo
        HeadBlend.SetFaceFeature(ped, i, roll)
    end
end

-- Rolls a random variant + opacity for every configured overlay, bounded by
-- the SAME live Game.GetNumHeadOverlayValues count the UI's variant picker
-- uses (client/main.lua's buildOpenPayload) - never a guessed index range.
-- Opacity is biased toward the lower half so e.g. blemishes/sun damage don't
-- roll at 100% strength by default.
function HeadBlend.RandomizeOverlays(ped)
    for _, def in ipairs(Config.HeadOverlays) do
        local count = Game.GetNumHeadOverlayValues(def.id)
        if count > 0 then
            local index = math.random(0, count - 1)
            local opacity = math.random() * 0.6
            HeadBlend.SetOverlay(ped, def.id, index, opacity)
            if def.hasColor then
                local colorIndex = math.random(Config.HairColorRange.min, Config.HairColorRange.max)
                HeadBlend.SetOverlayColor(ped, def.id, 1, colorIndex, colorIndex)
            end
        end
    end
end

-- ---- Tattoo tiers: cycle across existing pre-baked density variants -------
--
-- The native decoration system (AddPedDecorationFromHashes) has no opacity
-- parameter — it is a binary apply per zone. "Opacity" here is implemented
-- as tier-cycling across EXISTING sibling decoration hashes already mounted
-- on the ped's streamed collection (base game tattoo packs frequently ship a
-- design as 2-3 separately-hashed density variants — faded/medium/full —
-- under the same already-streamed collection). Never authors a new
-- decoration hash. If no siblings are found, tiering is unavailable for that
-- design and the caller (client/main.lua) disables the opacity control
-- rather than faking the effect.

local tattooTierCache = {}   -- [collectionHash] = { list of presetHash, in enumeration order }

-- VERIFY before enabling: relies on Game.GetPedDecorationCollectionCount /
-- Game.GetPedDecorationCollectionAt, which are themselves flagged VERIFY in
-- bridge/cl_game.lua. If those natives are unavailable on this build, this
-- returns an empty tier list and the caller disables the control — see
-- README.md's verification checklist.
function HeadBlend.EnumerateTattooTiers(collectionHash, baseHash)
    if tattooTierCache[collectionHash] then
        return tattooTierCache[collectionHash]
    end

    local tiers = {}
    local targetPed = previewPedRef and previewPedRef() or Game.PlayerPedId()
    local count = Game.GetPedDecorationCollectionCount(targetPed)
    for i = 0, count - 1 do
        local decoCollection, presetHash = Game.GetPedDecorationCollectionAt(targetPed, i)
        if decoCollection == collectionHash then
            tiers[#tiers + 1] = presetHash
        end
    end

    -- Fall back to a single-entry tier list containing only the base hash
    -- when no siblings are discoverable — "no tiering available", not a fake.
    if #tiers == 0 then
        tiers = { baseHash }
    end

    tattooTierCache[collectionHash] = tiers
    return tiers
end

function HeadBlend.ApplyTattooTier(ped, collectionHash, tierList, tierIndex)
    local presetHash = tierList[tierIndex]
    if not presetHash then return false end
    if not Game.DoesDecorationExist(collectionHash, presetHash) then return false end
    Game.AddPedDecorationFromHashes(ped, collectionHash, presetHash)
    return true
end

function HeadBlend.BindPedRef(getterFn)
    previewPedRef = getterFn
end

function HeadBlend.Reset()
    blend = {
        shapeFirst = 0, shapeSecond = 0, shapeThird = 0,
        skinFirst  = 0, skinSecond  = 0, skinThird  = 0,
        shapeMix = 0.5, skinMix = 0.5, thirdMix = 0.0,
    }
    for i = 0, Config.FaceFeatureCount - 1 do faceFeatures[i] = 0.0 end
    overlays = {}
    hairColor, hairHighlight, eyeColor = 0, 0, 0
    tattooTierCache = {}
end
