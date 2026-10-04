-- ============================================================================
-- palm6_appearance/shared/config.lua
-- Tunables only. No native calls, no framework calls — safe to load shared.
-- ============================================================================

Config = {}

-- Only these two models may ever be previewed/spawned by this resource.
-- Both are stock MP freemode peds, already resident on every client that has
-- ever loaded into multiplayer — selecting them streams NOTHING new.
Config.AllowedPreviewModels = {
    male   = `mp_m_freemode_01`,
    female = `mp_f_freemode_01`,
}

-- The same two models as STRINGS. A saved appearance stamps the model name it
-- was captured on, and applying it refuses on a mismatch - docs/CUSTOM-CLOTHING.md
-- §5: "Male and female drawable index spaces are completely disjoint. The same
-- integer is a different garment on mp_m_freemode_01 and mp_f_freemode_01 ...
-- store the model string with the capture, and REFUSE to apply a capture whose
-- stored model does not match the target ped. Do not guess and do not fall back."
-- Stored as a name rather than a hash so a payload stays readable in the DB and
-- survives a hash-format change; compared via joaat() against GetEntityModel.
Config.PreviewModelNames = {
    male   = 'mp_m_freemode_01',
    female = 'mp_f_freemode_01',
}

-- Bumped whenever the shape of the saved payload changes in a way that makes
-- an older row unsafe to apply as-is. v1 is the first version that carries a
-- `model` stamp at all; a payload without one is refused outright (see
-- client/main.lua applySavedAppearance) rather than guessed at.
Config.AppearanceSchemaVersion = 1

-- Re-apply a character's saved appearance on spawn/rejoin.
--
-- ⚠️ VERIFY ON THE BOX BEFORE THE FIRST ENSURE. This is the one setting that
-- can collide with another resource rather than just not working. If the
-- recipe-deployed `illenium-appearance` (or any other appearance resource) is
-- running on this server, it ALSO applies a saved skin on player load, and two
-- resources dressing the same ped in the same frame is a race whose winner is
-- load-order dependent. Decide which one owns appearance and turn the other
-- off; do not run both. Nothing in this repo can detect that from here -
-- qbx_core and illenium-appearance are recipe-deployed outside
-- resources/[custom]/.
Config.RestoreOnPlayerLoaded = true

-- How long to wait for the appearance restore callback before giving up and
-- leaving the player in whatever look qbx_core spawned them with. A miss here
-- is cosmetic (wrong outfit until they re-edit), never a softlock.
Config.RestoreTimeoutMs = 10000

-- Camera focus regions. `bone` is a bone-tag NAME resolved at runtime via
-- Game.GetPedBoneCoords (wraps GetPedBoneIndex + GetWorldPositionOfEntityBone) —
-- never a hardcoded numeric offset guessed by hand.
Config.CameraRegions = {
    whole = { bone = 'SKEL_ROOT',   offset = vec3(0.0, 0.0, 0.00), distance = 2.90, pitch = 4.0,  fov = 45.0, dofStrength = 0.00 },
    head  = { bone = 'SKEL_Head',   offset = vec3(0.0, 0.0, 0.02), distance = 0.55, pitch = 2.0,  fov = 32.0, dofStrength = 0.55 },
    torso = { bone = 'SKEL_Spine2', offset = vec3(0.0, 0.0, 0.00), distance = 1.15, pitch = 3.0,  fov = 38.0, dofStrength = 0.30 },
    legs  = { bone = 'SKEL_Pelvis', offset = vec3(0.0, 0.0,-0.05), distance = 1.35, pitch = 1.0,  fov = 40.0, dofStrength = 0.30 },
    shoes = { bone = 'SKEL_L_Foot', offset = vec3(0.0, 0.0, 0.03), distance = 0.65, pitch = -6.0, fov = 30.0, dofStrength = 0.50 },
}
Config.CameraRegionOrder = { 'whole', 'head', 'torso', 'legs', 'shoes' }

Config.CameraSwapDurationMs = 250   -- SetCamActiveWithInterp duration
Config.CameraDofRampMs      = 220   -- DOF strength lerp duration, runs alongside the swap

Config.OrbitClamps = {
    yawMin = -180.0, yawMax = 180.0,              -- free spin, wrapped not clamped
    pitchMin = -12.0, pitchMax = 20.0,             -- relative to region base pitch
    distanceMinMul = 0.70, distanceMaxMul = 1.60,  -- multiplier on region.distance
}

-- NOTE: palette SIZES are not declared here. Config.HairColorRange /
-- Config.EyeColorRange below already state the valid index range, and a
-- second constant saying "64" would be a second source of truth for the same
-- fact - the kind that drifts the moment one of them is edited. The count is
-- derived from the range at the one call site that needs it
-- (client/main.lua's buildOpenPayload).
--
-- The REAL rgb for each hair index is read off the game at open time
-- (Game.GetHairRgbPalette / GET_PED_HAIR_RGB_COLOR), never authored here. Eye
-- colour has no rgb getter - eye colours are texture variations, not colours -
-- so the UI shows those as numbered chips rather than inventing a colour.

Config.HeadBlendRange = { min = 0, max = 45 }     -- valid freemode parent head IDs
Config.FaceFeatureCount = 20                       -- SET_PED_FACE_FEATURE indices 0-19
Config.FaceFeatureRange = { min = -1.0, max = 1.0 }

-- SET_PED_FACE_FEATURE index -> real trait name, not "Feature 0".."Feature 19".
-- Source: citizenfx/natives PED/SetPedFaceFeature.md (the canonical FiveM
-- native reference) - fixed game-native ordering, not project config, kept
-- here rather than hardcoded in html/script.js so it stays next to
-- FaceFeatureCount/FaceFeatureRange. Plain 1-indexed Lua array (position 1 =
-- feature index 0, ...) deliberately, NOT a [0]=... table - a 0-based Lua
-- table key serializes as a JSON object over SendNUIMessage, not an array;
-- a plain sequence serializes as a proper JSON array whose 0-based JS index
-- lines up with the native's 0-based feature index for free.
Config.FaceFeatureLabels = {
    'Nose Width', 'Nose Peak Height', 'Nose Peak Length', 'Nose Bone Curveness',
    'Nose Peak Lowering', 'Nose Bone Twist', 'Eyebrow Height', 'Eyebrow Depth',
    'Cheekbone Height', 'Cheekbone Width', 'Cheeks Width', 'Eyes Opening',
    'Lips Thickness', 'Jaw Bone Width', 'Jaw Bone Shape', 'Chin Bone Height',
    'Chin Bone Length', 'Chin Bone Shape', 'Chin Hole', 'Neck Thickness',
}

Config.HairColorRange = { min = 0, max = 63 }     -- standard freemode hair/makeup color range
Config.EyeColorRange = { min = 0, max = 31 }

-- Wardrobe component IDs this screen exposes (standard freemode slots).
-- No index catalog is hardcoded here — see client/wardrobe.lua, which
-- enumerates valid drawable/texture counts live off the ped's ALREADY
-- STREAMED collections. This file only lists which component SLOTS the UI
-- shows, never which VALUES are valid within a slot.
Config.WardrobeComponents = {
    { id = 2,  key = 'hair',       label = 'Hairstyle' },
    { id = 1,  key = 'mask',       label = 'Mask' },
    { id = 3,  key = 'torso',      label = 'Torso' },
    { id = 4,  key = 'legs',       label = 'Legs' },
    { id = 6,  key = 'shoes',      label = 'Shoes' },
    { id = 8,  key = 'undershirt', label = 'Undershirt' },
    { id = 11, key = 'jacket',     label = 'Jacket / Top' },
}
Config.WardrobeProps = {
    { id = 0, key = 'hat',     label = 'Hat' },
    { id = 1, key = 'glasses', label = 'Glasses' },
    { id = 2, key = 'ears',    label = 'Ears' },
}

-- Head overlay slots exposed in the UI (eyebrows, beard, blemishes, etc).
-- Values applied are always opacity floats [0,1] and index ints bounded by
-- the live overlay count read off the ped — never a hardcoded max per slot.
Config.HeadOverlays = {
    { id = 0,  key = 'blemishes',    label = 'Blemishes',    hasColor = false },
    { id = 1,  key = 'facial_hair',  label = 'Facial Hair',  hasColor = true  },
    { id = 2,  key = 'eyebrows',     label = 'Eyebrows',     hasColor = true  },
    { id = 3,  key = 'ageing',       label = 'Ageing',       hasColor = false },
    { id = 4,  key = 'makeup',       label = 'Makeup',       hasColor = true  },
    { id = 5,  key = 'blush',        label = 'Blush',        hasColor = true  },
    { id = 6,  key = 'complexion',   label = 'Complexion',   hasColor = false },
    { id = 7,  key = 'sun_damage',   label = 'Sun Damage',   hasColor = false },
    { id = 8,  key = 'lipstick',     label = 'Lipstick',     hasColor = true  },
    { id = 9,  key = 'freckles',     label = 'Freckles',     hasColor = false },
    { id = 10, key = 'chest_hair',   label = 'Chest Hair',   hasColor = true  },
    { id = 11, key = 'body_blemishes', label = 'Body Blemishes', hasColor = false },
}
