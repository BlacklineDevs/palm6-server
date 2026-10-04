-- ============================================================================
-- palm6_appearance/client/main.lua
--
-- Orchestration + NUI message contract. Owns the Camera / HeadBlend /
-- Wardrobe module lifecycle, registers all RegisterNUICallback handlers, and
-- tears everything down on close / resource stop so a hot-reload can never
-- strand the cursor or leave a dangling cam — mirrors palm6_ui's
-- onResourceStop guard rail.
-- ============================================================================

local RESOURCE_NAME = GetCurrentResourceName()

local isOpen = false
local previewPed = nil
local previewGender = 'male'   -- retained across a randomize-triggered re-render
local mode = 'create'          -- 'create' | 'edit'
local openingPayload = nil     -- the ped's appearance the moment this screen opened, for Reset
local pendingCallback = nil    -- fn(appearanceTable) — resolved on save, used by the qbx_core export hand-off

-- ---- Helpers ----------------------------------------------------------------

--- Recursive copy. A SNAPSHOT THAT SHARES STORAGE WITH ITS SUBJECT IS NOT A
--- SNAPSHOT, and this one is load-bearing twice over.
---
--- HeadBlend.GetBlendState/GetFaceFeatures/GetOverlays and Wardrobe's capture
--- cache all return the module-local tables themselves, and edits mutate them
--- in place. Reset stores that payload at open and re-applies it later - so
--- without a copy, "reset" replayed whatever the player had just done. The
--- faceFeatures case was the mirror image: HeadBlend.Reset() zeroes that table
--- IN PLACE, i.e. it zeroed the very snapshot that was about to be applied.
--- Reset is the only undo in create mode (there is no Cancel), so this was the
--- difference between an undo and a no-op.
local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local function buildAppearancePayload()
    local blend = HeadBlend.GetBlendState()
    local colors = HeadBlend.GetColorState()
    local wardrobe = Wardrobe.CaptureAll(previewPed)

    return deepCopy({
        -- The model this capture was taken ON. Load-bearing, not metadata:
        -- every drawable/texture index below is only meaningful against this
        -- exact model, and applySavedAppearance refuses a payload whose model
        -- doesn't match the target ped rather than applying a female wardrobe
        -- to a male body (docs/CUSTOM-CLOTHING.md §5). A payload without it is
        -- refused outright - the payload shape shipped without this field
        -- originally, which is precisely the "do not guess and do not fall
        -- back" case that document is about.
        version = Config.AppearanceSchemaVersion,
        model = Config.PreviewModelNames[previewGender],
        gender = previewGender,

        headBlend = blend,
        faceFeatures = HeadBlend.GetFaceFeatures(),
        overlays = HeadBlend.GetOverlays(),
        hairColor = colors.hairColor,
        hairHighlight = colors.hairHighlight,
        eyeColor = colors.eyeColor,
        components = wardrobe.components,
        props = wardrobe.props,
    })
end

-- Applies a previously-saved appearance table back onto a freshly spawned
-- preview ped (edit-mode entry, or reopening after a save). Every wardrobe
-- value here still passes through Wardrobe/Game's IsPedCollection*Valid
-- gate — a saved payload is re-validated exactly like a live cycle, since
-- component availability can shift if streamed collections change between
-- sessions.
local function applySavedAppearance(ped, saved)
    if type(saved) ~= 'table' then return false end

    -- THE GENDER GATE. docs/CUSTOM-CLOTHING.md §5: male and female drawable
    -- index spaces are completely disjoint, so the same integer is a different
    -- garment on each model - "store the model string with the capture, and
    -- REFUSE to apply a capture whose stored model does not match the target
    -- ped. Do not guess and do not fall back." A payload with no model stamp
    -- (pre-v1 shape) is unknowable, so it gets the same refusal. Refusing is
    -- visible and recoverable (the player re-edits); applying the wrong index
    -- space silently dresses them in something nobody chose, and invalid
    -- component data has crashed clients.
    if not Game.PedModelMatches(ped, saved.model) then
        print(('[palm6_appearance] refused an appearance capture: saved model %s does not match the target ped. Not applied.')
            :format(tostring(saved.model)))
        return false
    end

    if saved.headBlend then
        local b = saved.headBlend
        HeadBlend.SetParents(ped, b.shapeFirst, b.shapeSecond, b.shapeThird, b.skinFirst, b.skinSecond, b.skinThird)
        HeadBlend.SetMix(ped, 'shapeMix', b.shapeMix)
        HeadBlend.SetMix(ped, 'skinMix', b.skinMix)
        HeadBlend.SetMix(ped, 'thirdMix', b.thirdMix)
    end

    if saved.faceFeatures then
        for index, value in pairs(saved.faceFeatures) do
            HeadBlend.SetFaceFeature(ped, tonumber(index), value)
        end
    end

    if saved.overlays then
        for overlayId, ov in pairs(saved.overlays) do
            HeadBlend.SetOverlay(ped, tonumber(overlayId), ov.index, ov.opacity)
            if ov.color1 then
                HeadBlend.SetOverlayColor(ped, tonumber(overlayId), 1, ov.color1, ov.color2 or ov.color1)
            end
        end
    end

    if saved.hairColor then
        HeadBlend.SetHairColor(ped, saved.hairColor, saved.hairHighlight or saved.hairColor)
    end
    if saved.eyeColor then
        HeadBlend.SetEyeColor(ped, saved.eyeColor)
    end

    if saved.components then
        for _, entry in ipairs(saved.components) do
            local s = entry.state
            if s and s.collectionName and Game.IsPedCollectionComponentVariationValid(ped, entry.id, s.collectionName, s.drawableId, s.textureId) then
                Game.SetPedCollectionComponentVariation(ped, entry.id, s.collectionName, s.drawableId, s.textureId)
            end
        end
    end

    if saved.props then
        for _, entry in ipairs(saved.props) do
            local s = entry.state
            if s and s.active and s.collectionName and Game.IsPedCollectionPropValid(ped, entry.id, s.collectionName, s.drawableId, s.textureId) then
                Game.SetPedCollectionPropIndex(ped, entry.id, s.collectionName, s.drawableId, s.textureId)
            elseif s and s.active == false then
                -- "NO HAT" IS A CHOICE AND HAS TO BE APPLIED.
                -- Only the worn branch existed, so an inactive prop was read
                -- and then silently dropped. The server deliberately preserves
                -- these entries (sanitizeAppearance keeps active=false rather
                -- than discarding them) precisely so this branch can act on
                -- them - without it, taking a hat off never stuck: the model
                -- swap early-returns when the model already matches, the apply
                -- skipped the entry, and the player walked out still wearing
                -- the hat they had just removed. Same shape blocked Reset from
                -- removing a randomized hat.
                Game.ClearPedProp(ped, entry.id)
            end
        end
    end

    Wardrobe.Reset()   -- force a fresh capture next cycle so cursor state matches what was just applied
    return true
end

-- ---- Applying to the REAL player --------------------------------------------
--
-- Everything above dresses this resource's own preview ped. This is the half
-- that was missing entirely: the editor built a payload, sent it to the
-- database, deleted the preview ped, and handed control back - and nothing,
-- anywhere, ever put that appearance on the actual player. A brand-new
-- character spawned in whatever random freemode look qbx_core's own
-- createCharacter had already assigned (client/character.lua's `randomPeds`),
-- and every subsequent rejoin did the same, because the load callback in
-- server/main.lua was registered and never called by anything.
--
-- Model first, THEN the payload: SetPlayerPedModel replaces the ped outright,
-- so a payload applied before the swap is discarded by it.
--- Resolves a payload's stored model NAME to a hash, and only ever to one of
--- the two allowlisted freemode models.
---
--- This is a security gate, not a lookup convenience. A saved payload is
--- ultimately client-supplied data (it arrives via the
--- palm6_appearance:server:save net event, is stored verbatim, and comes back
--- out on the next join), and the value is about to be handed to
--- SET_PLAYER_MODEL. Reading the model straight off the payload would let a
--- modified client persist any model string it liked and be spawned as it -
--- an animal, a cutscene ped, anything - on every subsequent join. Resolving
--- through the allowlist instead means an unrecognised name yields nothing and
--- the appearance is simply refused.
---@return number|nil
local function allowlistedModelHash(payload)
    local name = payload.model
    if type(name) ~= 'string' then return nil end
    for genderKey, allowedName in pairs(Config.PreviewModelNames) do
        if allowedName == name then return Config.AllowedPreviewModels[genderKey] end
    end
    return nil
end

--- The gender key a stored model NAME corresponds to, or nil if it is not one
--- of the two allowlisted freemode models.
---
--- The same reversal as allowlistedModelHash, and it exists for the same
--- reason: `model` is the field the apply path and its §5 guard both key off,
--- so anything that decides which body to spawn has to key off it too. The
--- editor used to spawn its preview from `payload.gender` instead - the other,
--- independently-validated field - so a row where the two disagreed spawned
--- the wrong-gender preview, had its own apply silently refused by the model
--- guard, and then let the first Save overwrite the real look with a blank.
---@return string|nil
local function genderKeyForModel(modelName)
    if type(modelName) ~= 'string' then return nil end
    for genderKey, allowedName in pairs(Config.PreviewModelNames) do
        if allowedName == modelName then return genderKey end
    end
    return nil
end

---@return boolean applied
local function applyToRealPlayer(payload)
    if type(payload) ~= 'table' then return false end

    -- Keyed off payload.model (the stamp applySavedAppearance will check the
    -- ped against), NOT payload.gender - two fields that can disagree must
    -- never each drive half of this, or the model gets set from one and the
    -- guard evaluated against the other.
    local modelHash = allowlistedModelHash(payload)
    if not modelHash then return false end

    local ped = Game.SetPlayerPedModel(modelHash)
    if not ped then
        Game.Notify('Could not load your character model - your saved look was not applied.', 'error')
        return false
    end

    return applySavedAppearance(ped, payload)
end

local function buildOpenPayload(genderKey)
    -- Live-captures current drawable/texture cursor state for every
    -- configured component/prop, so the NUI can initialize cycle-row counts
    -- and swatch selection to what's ACTUALLY on the ped, rather than
    -- rendering "0 / 0" placeholders until the player clicks an arrow.
    local wardrobe = previewPed and Wardrobe.CaptureAll(previewPed) or { components = {}, props = {} }

    -- Config.HeadOverlays is static (id/key/label/hasColor) - variant COUNT
    -- is live-enumerated per overlay (GetNumHeadOverlayValues) and merged in
    -- here rather than mutating the shared Config table. Lets the NUI offer
    -- a variant cycle control instead of being stuck on whatever index the
    -- ped happened to load with.
    local overlayDefs = {}
    for i, def in ipairs(Config.HeadOverlays) do
        overlayDefs[i] = {
            id = def.id, key = def.key, label = def.label, hasColor = def.hasColor,
            count = Game.GetNumHeadOverlayValues(def.id),
        }
    end

    return {
        mode = mode,
        accent = 'gold',
        ped = {
            gender = genderKey,
            headBlend = HeadBlend.GetBlendState(),
            faceFeatures = HeadBlend.GetFaceFeatures(),
            hairColor = HeadBlend.GetColorState().hairColor,
            hairHighlight = HeadBlend.GetColorState().hairHighlight,
            eyeColor = HeadBlend.GetColorState().eyeColor,
            overlays = HeadBlend.GetOverlays(),
            components = Config.WardrobeComponents,
            props = Config.WardrobeProps,
            overlayDefs = overlayDefs,
            faceFeatureLabels = Config.FaceFeatureLabels,
            wardrobeState = wardrobe,
            -- The real per-index hair colours, read off the game
            -- (GET_PED_HAIR_RGB_COLOR). The NUI painted its swatches with a
            -- generated HSL rainbow before this, so the colour a player
            -- clicked had nothing to do with the colour their hair became.
            hairPalette = Game.GetHairRgbPalette(
                Config.HairColorRange.max - Config.HairColorRange.min + 1),
        },
        regions = Config.CameraRegionOrder,
    }
end

-- ---- Open / close -----------------------------------------------------------

-- genderKey: 'male' | 'female'. openMode: 'create' | 'edit'. savedAppearance:
-- previously-saved payload table (edit mode) or nil (fresh new-character).
-- onSaveOrClose(appearanceTable|nil): resolved with the final appearance
-- table on save, or nil on cancel/close — used by the qbx_core export hand-
-- off in §14's plan so a caller awaiting a callback always gets resolved.
local function openAppearanceScreen(genderKey, openMode, savedAppearance, onSaveOrClose)
    if isOpen then return end

    -- THE SAVED PAYLOAD'S MODEL STAMP DECIDES THE BODY, NOT THE CALLER'S
    -- GENDER ARGUMENT. See genderKeyForModel: `model` is what the apply path
    -- and its docs/CUSTOM-CLOTHING.md §5 guard key off, and two fields that
    -- can disagree must never each drive half of this.
    if type(savedAppearance) == 'table' and savedAppearance.model ~= nil then
        local keyed = genderKeyForModel(savedAppearance.model)
        if not keyed then
            -- A stored model we do not recognise cannot be previewed OR
            -- applied. Opening anyway would put the player in front of a
            -- default blank ped whose first Save silently overwrites the row
            -- their real look lives in.
            Game.Notify('Your saved appearance could not be read, so the editor was not opened.', 'error')
            if onSaveOrClose then onSaveOrClose(nil) end
            return
        end
        genderKey = keyed
    end

    isOpen = true
    mode = openMode or 'create'
    pendingCallback = onSaveOrClose
    previewGender = genderKey or 'male'

    local playerPed = Game.PlayerPedId()
    local coords = Game.GetEntityCoords(playerPed)
    local heading = Game.GetEntityHeading(playerPed)

    previewPed = Game.SpawnPreviewPed(genderKey, coords, heading)
    if not previewPed then
        isOpen = false
        Game.Notify('Failed to spawn preview model.', 'error')
        if pendingCallback then pendingCallback(nil) end
        return
    end

    HeadBlend.Reset()
    Wardrobe.Reset()
    HeadBlend.BindPedRef(function() return previewPed end)

    -- Sensible default parents so the screen never opens with an undefined
    -- blend (0/0/0 shape+skin is a valid but visually blank starting point;
    -- this keeps it deterministic and matches base freemode defaults).
    HeadBlend.SetParents(previewPed, 0, 0, 0, 0, 0, 0)
    HeadBlend.SetMix(previewPed, 'shapeMix', 0.5)
    HeadBlend.SetMix(previewPed, 'skinMix', 0.5)

    if savedAppearance then
        -- The boolean is not decoration. It used to be discarded, so a payload
        -- the apply refused left the player editing a DEFAULT ped that looked
        -- nothing like their character - and the first Save captured that
        -- default and upserted it over the real row, with Reset restoring the
        -- same blank because that is what the screen opened with. There is no
        -- undo past that point. Refusing to open is recoverable; opening on a
        -- lie is not.
        if not applySavedAppearance(previewPed, savedAppearance) then
            Game.DeletePed(previewPed)
            previewPed = nil
            isOpen = false
            pendingCallback = nil
            Game.Notify('Your saved appearance could not be applied, so the editor was not opened.', 'error')
            if onSaveOrClose then onSaveOrClose(nil) end
            return
        end
    end

    Camera.Init(previewPed)
    Game.SetNuiFocus(true, true)
    Game.DisplayRadar(false)
    Game.DisplayHud(false)

    -- Snapshot for Reset, taken AFTER the defaults and any saved appearance
    -- have been applied - so "reset" means "how this screen looked when it
    -- opened", which is what a player who just mangled a randomize expects.
    -- Create mode has no cancel button (creation is mandatory), so without
    -- this there is no way back from a bad "Randomize All" at all.
    openingPayload = buildAppearancePayload()

    SendNUIMessage({ action = 'open', payload = buildOpenPayload(genderKey) })

    -- FADE IN. Non-optional, and the reason it isn't just polish: the
    -- new-character caller (palm6_charselect) hands off via
    -- Game.TeardownSceneKeepPedHidden, whose last line is DoScreenFadeOut(0) -
    -- an INSTANT fade to black. This resource had no fade call of any kind, so
    -- the entire character creator ran behind a fully black screen: NUI panel
    -- floating over nothing, preview ped invisible, camera pointed at the
    -- dark. Nothing faded back in until charselect's post-creation callback,
    -- long after the player was done. Fading in here (rather than asking the
    -- caller to) also keeps the editor correct for any future caller, and is a
    -- harmless no-op in edit mode where the screen is already visible.
    Wait(100)   -- one beat for the NUI to paint before the world is revealed
    Game.FadeIn(400)
end

-- resolveValue is the finished appearance payload on save, nil on cancel/close.
-- "Saved" therefore means `resolveValue ~= nil`, and that is the only case that
-- touches the real player ped.
--- @param immediate boolean|nil skip every fade and yield. Set ONLY by the
--- onResourceStop guard rail: that handler must not yield (the resource is
--- being torn down around it and there is no guarantee a coroutine resumes),
--- and a fade to black is worthless on a screen that is about to lose the
--- resource drawing it anyway. Same rule as
--- feedback_fivem_onresourcestop_no_await.
local function closeAppearanceScreen(resolveValue, immediate)
    if not isOpen then return end
    isOpen = false
    local closingMode = mode

    -- Black out BEFORE the ped changes. applyToRealPlayer swaps the player's
    -- model, which spawns a fresh, default-dressed ped for a frame or two right
    -- where the preview ped is standing - visible as a naked double otherwise.
    -- In create mode we always fade out even without a save, because the caller
    -- teleports the player to their spawn point immediately after this returns.
    local needsFade = not immediate and (resolveValue ~= nil or closingMode == 'create')
    if needsFade then Game.FadeOut(300) end

    -- Also skipped when `immediate`: applyToRealPlayer loads a model, which
    -- yields. A resource stopping mid-edit leaves the player in the look they
    -- already had, which is the correct outcome for an edit that was never
    -- saved anyway.
    if resolveValue and not immediate then
        applyToRealPlayer(resolveValue)
    end

    Camera.Destroy()
    Game.SetNuiFocus(false, false)
    Game.DisplayRadar(true)
    Game.DisplayHud(true)
    Game.DeletePed(previewPed)
    previewPed = nil

    SendNUIMessage({ action = 'close', payload = {} })

    -- Edit mode ends here, so it owns fading back in. Create mode deliberately
    -- hands control back BLACK: palm6_charselect still has to reveal the real
    -- ped and spawn it at a world position, and it fades in once that's done.
    if closingMode == 'edit' and needsFade then
        Game.FadeIn(400)
    end

    if pendingCallback then
        local cb = pendingCallback
        pendingCallback = nil
        cb(resolveValue)
    end
end

-- ---- NUI callbacks (JS -> Lua) ----------------------------------------------
-- All handlers ack with cb('ok') per the palm6_ui idiom; failures are
-- notified in-game rather than thrown across the NUI boundary.

RegisterNUICallback('setCameraFocus', function(data, cb)
    if isOpen and data and data.region then
        local ok = Camera.FocusRegion(data.region)
        if ok then
            SendNUIMessage({ action = 'regionFocused', payload = { region = data.region } })
        end
    end
    cb('ok')
end)

RegisterNUICallback('rotateCamera', function(data, cb)
    if isOpen and data then
        Camera.Rotate(tonumber(data.deltaYaw) or 0.0, tonumber(data.deltaPitch) or 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('zoomCamera', function(data, cb)
    if isOpen and data then
        Camera.Zoom(tonumber(data.delta) or 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('setHeadBlendParents', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetParents(
            previewPed,
            tonumber(data.shapeFirst) or 0, tonumber(data.shapeSecond) or 0, tonumber(data.shapeThird) or 0,
            tonumber(data.skinFirst) or 0, tonumber(data.skinSecond) or 0, tonumber(data.skinThird) or 0
        )
    end
    cb('ok')
end)

RegisterNUICallback('setHeadBlendMix', function(data, cb)
    if isOpen and data and previewPed and data.key then
        HeadBlend.SetMix(previewPed, data.key, tonumber(data.value) or 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('randomizeHeadBlend', function(_, cb)
    if isOpen and previewPed then
        HeadBlend.Randomize(previewPed)
        SendNUIMessage({ action = 'refresh', payload = buildOpenPayload(previewGender) })
    end
    cb('ok')
end)

-- 'Randomize All' (distinct from plain 'Randomize' above, which is face-blend
-- only): face blend + face features + overlays + hair/eye color + every
-- configured wardrobe component/prop. Actually comprehensive, not a subset
-- wearing the "All" label.
RegisterNUICallback('randomizeAll', function(_, cb)
    if isOpen and previewPed then
        HeadBlend.Randomize(previewPed)
        HeadBlend.RandomizeFeatures(previewPed)
        HeadBlend.RandomizeOverlays(previewPed)
        HeadBlend.RandomizeColors(previewPed)
        Wardrobe.RandomizeAll(previewPed)
        SendNUIMessage({ action = 'refresh', payload = buildOpenPayload(previewGender) })
    end
    cb('ok')
end)

RegisterNUICallback('setFaceFeature', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetFaceFeature(previewPed, tonumber(data.index) or 0, tonumber(data.value) or 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('setHeadOverlay', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetOverlay(previewPed, tonumber(data.overlayId), tonumber(data.index) or 0, tonumber(data.opacity) or 1.0)
    end
    cb('ok')
end)

RegisterNUICallback('setHeadOverlayColor', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetOverlayColor(previewPed, tonumber(data.overlayId), tonumber(data.colorType) or 1, tonumber(data.colorIndex) or 0, tonumber(data.secondColorIndex) or tonumber(data.colorIndex) or 0)
    end
    cb('ok')
end)

-- NOT wired to any UI control yet - see README.md "Tattoos: current scope"
-- for why (no catalog to pick a NEW design from, so this only ever fires if
-- a future caller already knows a collectionHash/baseHash the ped is
-- carrying). Left in place as a working, validated primitive rather than
-- dead code, in case a catalog-backed tattoo shop resource wires into it
-- later. `clearTattoos` below is the one tattoo control actually exposed to
-- players today.
RegisterNUICallback('setTattooTier', function(data, cb)
    if isOpen and data and previewPed and data.collectionHash then
        local baseHash = data.baseHash or data.collectionHash
        local tiers = HeadBlend.EnumerateTattooTiers(data.collectionHash, baseHash)
        local applied = HeadBlend.ApplyTattooTier(previewPed, data.collectionHash, tiers, tonumber(data.tierIndex) or 1)
        if applied then
            SendNUIMessage({ action = 'tattooTiers', payload = { collectionHash = data.collectionHash, tierCount = #tiers, tierIndex = tonumber(data.tierIndex) or 1 } })
        end
    end
    cb('ok')
end)

-- The one tattoo control this resource actually ships: wipes any decoration
-- layers the preview ped is carrying (e.g. inherited from a previous
-- appearance-edit session on this same ped, or a saved character that had
-- tattoos from before this resource existed) while leaving scars/damage
-- textures alone. Real design application/persistence is out of scope - see
-- README.md.
RegisterNUICallback('clearTattoos', function(_, cb)
    if isOpen and previewPed then
        Game.ClearPedDecorationsLeavingScars(previewPed)
        SendNUIMessage({ action = 'tattoosCleared' })
    end
    cb('ok')
end)

RegisterNUICallback('cycleComponent', function(data, cb)
    if isOpen and data and previewPed then
        local ok, state = Wardrobe.CycleComponent(previewPed, tonumber(data.componentId), tonumber(data.direction) or 1)
        if ok then
            SendNUIMessage({ action = 'wardrobeState', payload = {
                componentId = tonumber(data.componentId),
                collectionName = state.collectionName,
                drawableId = state.drawableId,
                drawableCount = state.drawableCount,
                textureId = state.textureId,
                textureCount = state.textureCount,
            } })
        end
    end
    cb('ok')
end)

RegisterNUICallback('cycleTexture', function(data, cb)
    if isOpen and data and previewPed then
        local ok, state = Wardrobe.CycleTexture(previewPed, tonumber(data.componentId), tonumber(data.direction) or 1)
        if ok then
            SendNUIMessage({ action = 'wardrobeState', payload = {
                componentId = tonumber(data.componentId),
                collectionName = state.collectionName,
                drawableId = state.drawableId,
                drawableCount = state.drawableCount,
                textureId = state.textureId,
                textureCount = state.textureCount,
            } })
        end
    end
    cb('ok')
end)

RegisterNUICallback('cycleProp', function(data, cb)
    if isOpen and data and previewPed then
        local ok, state = Wardrobe.CycleProp(previewPed, tonumber(data.propId), tonumber(data.direction) or 1)
        if ok then
            SendNUIMessage({ action = 'wardrobeState', payload = {
                propId = tonumber(data.propId),
                collectionName = state.collectionName,
                drawableId = state.drawableId,
                drawableCount = state.drawableCount,
                textureId = state.textureId,
                textureCount = state.textureCount,
                active = state.active,
            } })
        end
    end
    cb('ok')
end)

-- The prop half of colourway cycling. Wardrobe.CyclePropTexture already
-- existed and had NO callback registered at all, so hats/glasses could never
-- change colourway even once the component side was reachable.
RegisterNUICallback('cyclePropTexture', function(data, cb)
    if isOpen and data and previewPed then
        local ok, state = Wardrobe.CyclePropTexture(previewPed, tonumber(data.propId), tonumber(data.direction) or 1)
        if ok then
            SendNUIMessage({ action = 'wardrobeState', payload = {
                propId = tonumber(data.propId),
                collectionName = state.collectionName,
                drawableId = state.drawableId,
                drawableCount = state.drawableCount,
                textureId = state.textureId,
                textureCount = state.textureCount,
                active = state.active,
            } })
        end
    end
    cb('ok')
end)

RegisterNUICallback('setHairColor', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetHairColor(previewPed, tonumber(data.colorId) or 0, tonumber(data.highlightColorId) or tonumber(data.colorId) or 0)
    end
    cb('ok')
end)

RegisterNUICallback('setEyeColor', function(data, cb)
    if isOpen and data and previewPed then
        HeadBlend.SetEyeColor(previewPed, tonumber(data.colorId) or 0)
    end
    cb('ok')
end)

-- Every handler below ACKs (cb('ok')) BEFORE calling closeAppearanceScreen:
-- the close path now fades the screen and swaps the player's ped model, so it
-- yields for the better part of a second. Acking first keeps the NUI's fetch
-- promise from hanging for the whole transition.
RegisterNUICallback('save', function(_, cb)
    local payload = (isOpen and previewPed) and buildAppearancePayload() or nil
    cb('ok')
    if payload then
        TriggerServerEvent('palm6_appearance:server:save', payload)
        closeAppearanceScreen(payload)
    end
end)

-- Revert the preview ped to the look this screen opened with, then rebuild
-- every control from the reverted ped. Does NOT close the screen: it is an
-- undo, not an exit.
RegisterNUICallback('reset', function(_, cb)
    cb('ok')
    if not isOpen or not previewPed or not openingPayload then return end

    -- Order matters and is the same order openAppearanceScreen uses: clear the
    -- module state FIRST, then apply. HeadBlend.Reset() zeroes every cached
    -- blend/feature/overlay value, so running it AFTER the apply would wipe
    -- exactly what was just restored - the ped would show the reverted look
    -- while buildOpenPayload reported zeros and every slider snapped to 0.
    HeadBlend.Reset()
    Wardrobe.Reset()

    -- Same apply path (and therefore the same model guard) as any other
    -- restore. The snapshot was captured off THIS ped, so the guard passes;
    -- if it somehow doesn't, refusing is still the right outcome.
    if not applySavedAppearance(previewPed, openingPayload) then
        Game.Notify('Could not reset your appearance.', 'error')
        return
    end
    -- `refresh`, not `open`: the sliders, cycle rows and swatches re-seed from
    -- what is actually on the ped now, but the player stays on the tab they
    -- were using, at the scroll position they were at, with the camera where
    -- they framed it. Same message the randomize handlers use.
    SendNUIMessage({ action = 'refresh', payload = buildOpenPayload(previewGender) })
end)

RegisterNUICallback('cancel', function(_, cb)
    -- Edit-mode only — the new-character flow has no cancel path (mandatory
    -- step, matches qbx_core's mandatory-dialog precedent).
    local canCancel = isOpen and mode == 'edit'
    cb('ok')
    if canCancel then closeAppearanceScreen(nil) end
end)

RegisterNUICallback('close', function(_, cb)
    cb('ok')
    closeAppearanceScreen(nil)
end)

-- ---- qbx_core hand-off export ------------------------------------------------
--
-- VERIFY before enabling: this export's name/signature mirrors the
-- documented `illenium-appearance`-style startPlayerCustomization(callback,
-- config) contract, on the assumption that qbx_core's new-character flow
-- calls out to a pluggable external appearance resource the same way. The
-- exact qbx_core config key (if any) that redirects that call site at
-- palm6_appearance instead of illenium-appearance, and whether that needs a
-- one-line patch to qbx_core's client/character.lua, is UNCONFIRMED — see
-- README.md's "qbx_core integration" section for the full checklist. If
-- qbx_core ends up calling this export directly (config-key redirect or a
-- patched call site), no logic here needs to change: the callback contract
-- degrades safely regardless of how the call site is wired.
exports('startPlayerCustomization', function(callback, config)
    config = config or {}
    local genderKey = config.gender or 'male'
    local savedAppearance = config.appearance or nil

    openAppearanceScreen(genderKey, 'create', savedAppearance, function(appearanceTable)
        if type(callback) == 'function' then
            callback(appearanceTable)
        end
    end)
end)

-- Re-edit entry point for an already-created character (post-onboarding
-- wardrobe/appearance change). Separate from the qbx_core mandatory-step
-- export above since this path is NOT the new-character flow and does allow
-- cancel.
-- savedAppearance may be omitted: the editor then loads the character's own
-- stored appearance so a re-edit opens on the look they are actually wearing,
-- which is what every barbershop/clothing-store flow on the market does.
-- Opening on a blank default and making the player rebuild from scratch is the
-- behaviour this fallback exists to prevent. genderKey may be omitted too - the
-- stored payload knows which model it was captured on, and that is more
-- trustworthy than a caller's guess.
--- The re-edit open path, shared by the export below and the admin command's
--- net event. Extracted because having two entry points into "edit an existing
--- character" with only ONE of them loading the existing character is exactly
--- how /palm6appearance came to open on a blank default ped and overwrite a
--- real saved look on the first Save.
---
--- genderKey is only ever a fallback for a character with nothing stored yet:
--- once a payload is loaded, openAppearanceScreen derives the body from its
--- model stamp and ignores the argument (see genderKeyForModel).
local function openEditorForExistingCharacter(genderKey, savedAppearance, onDone)
    if not savedAppearance then
        local ok, stored = pcall(lib.callback.await, 'palm6_appearance:server:load', Config.RestoreTimeoutMs)
        if ok and type(stored) == 'table' then savedAppearance = stored end
    end

    openAppearanceScreen(genderKey or 'male', 'edit', savedAppearance, function(appearanceTable)
        if type(onDone) == 'function' then
            onDone(appearanceTable)
        end
    end)
end

exports('openAppearanceEditor', openEditorForExistingCharacter)

--- Close the editor RIGHT NOW without resolving the pending callback.
---
--- For palm6_charselect's admin bail-out (/palm6charselect_release), which is
--- most likely to be aimed at a player stuck mid-creation - i.e. stuck in this
--- resource, not in charselect. NUI focus and RenderScriptCams are per-client
--- and global, so charselect releasing focus while this editor is still
--- rendering full-screen strips its cursor and camera and leaves a dead UI
--- with no cancel path.
---
--- The pending callback is deliberately DROPPED rather than resolved: that
--- callback is charselect's own "creation finished" handler, which spawns the
--- player and clears its busy flag, and the rescue does both itself. Firing
--- both would spawn twice.
---@return boolean closed - false means the editor was not open
exports('forceCloseEditor', function()
    if not isOpen then return false end
    pendingCallback = nil
    closeAppearanceScreen(nil)
    return true
end)

-- Applies a stored payload to ANY ped the caller owns - specifically
-- palm6_charselect's character-select preview ped, so the select screen can
-- show the real character instead of a lettered silhouette. Exposed rather
-- than duplicated because the model guard (docs/CUSTOM-CLOTHING.md §5) has to
-- live in exactly one place; a second copy in another resource is a second
-- copy to get wrong.
---@return boolean applied - false means the payload was refused or malformed
exports('applyAppearanceToPed', function(ped, payload)
    if not ped or not payload then return false end
    return applySavedAppearance(ped, payload) == true
end)

-- ---- Restore on spawn / rejoin ----------------------------------------------
--
-- The other half of persistence. `palm6_appearance:server:load` shipped
-- registered and CALLED BY NOTHING - repo-wide grep found exactly one hit, its
-- own registration - so every appearance this resource saved was written and
-- never read. A player customised a character once and then rejoined forever
-- into qbx_core's random default look, with their real saved appearance
-- sitting untouched in palm6_appearance_data.
--
-- Fires on QBCore:Client:OnPlayerLoaded, which palm6_charselect raises as part
-- of its spawn pipeline (bridge/cl_game.lua Game.SpawnAtPosition) and which
-- qbx_core raises on its own when charselect isn't the thing spawning.
--
-- Deliberately best-effort: a failed/timed-out restore leaves the player in
-- the look they spawned with and says so. Cosmetic, never a softlock, never a
-- reason to hold the spawn.
local function restoreSavedAppearance()
    if not Config.RestoreOnPlayerLoaded then return end
    if isOpen then return end   -- the editor is authoritative while it's open

    local ok, saved = pcall(lib.callback.await, 'palm6_appearance:server:load', Config.RestoreTimeoutMs)
    if not ok then
        -- ox_lib rejects the awaited promise on timeout or if the callback was
        -- never registered (this resource's server side failed to boot, e.g.
        -- the DB was unreachable and ensureSchema left it inert).
        print('[palm6_appearance] appearance restore call failed; leaving the spawned look in place.')
        return
    end
    if type(saved) ~= 'table' then return end   -- no saved appearance yet: brand-new character, nothing to restore

    -- No fade: the player is already spawned and in the world by the time this
    -- runs, and a black screen on every join to hide a one-frame model swap is
    -- worse than the swap. The screen is typically still faded in from the
    -- spawn pipeline anyway.
    applyToRealPlayer(saved)
end

Game.OnPlayerLoaded(function()
    CreateThread(function()
        -- Off the event handler's own thread: this awaits a server callback,
        -- and every other resource listening for OnPlayerLoaded is waiting
        -- behind this handler returning.
        restoreSavedAppearance()
    end)
end)

-- Staging/QA entry point: opens the editor on demand to check the camera,
-- blend and wardrobe systems in isolation. NOT part of the production
-- new-character flow.
--
-- ⚠️ THIS IS NOW ADMIN-ONLY, AND THAT IS A SECURITY FIX, NOT TIDINESS.
-- It used to be `RegisterCommand('palm6appearance', ..., false)` registered
-- CLIENT-side - unrestricted, and unrestrictable, because ACE checks only mean
-- anything on the server. That was harmless while the editor was inert: it
-- applied nothing to the real ped and persisted nothing. Making the editor
-- actually work turned the same command into a **free, unlimited barbershop
-- for every player on the server** - retype it any time, change your face, and
-- it saves. Any appearance economy (barbershop fees, job-locked looks) would
-- have been bypassable with one chat command.
--
-- So the command is registered on the SERVER with restricted = true and only
-- reaches this client through an event the server sends after the ACE check.
-- Requires `add_ace group.admin command.palm6appearance allow` in custom.cfg,
-- which is wired alongside the palm6_charselect admin commands.
--
-- Routed through openEditorForExistingCharacter, NOT straight into
-- openAppearanceScreen with a nil payload. Calling the screen directly meant
-- this path skipped the stored-appearance load that lives in the export, so
-- the editor opened on a default freemode ped (parents 0/0/0, mix 0.5) that
-- was not the admin's character at all - and one slider nudge plus Save
-- captured that default and upserted it over the real row. No diff check, no
-- undo: Reset restores what the screen opened with, which was the same blank.
RegisterNetEvent('palm6_appearance:client:openEditor', function(genderKey)
    openEditorForExistingCharacter(genderKey == 'female' and 'female' or 'male', nil, function(appearanceTable)
        if appearanceTable then
            Game.Notify('Appearance editor closed (saved).', 'success')
        else
            Game.Notify('Appearance editor closed (cancelled).', 'inform')
        end
    end)
end)

-- ---- Resource-stop guard rail ------------------------------------------------

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE_NAME then return end
    if isOpen then
        -- immediate=true: no fade, no model load, no yield of any kind. This
        -- handler runs while the resource is being torn down.
        closeAppearanceScreen(nil, true)
    end
end)
