-- ============================================================================
-- palm6_appearance/client/wardrobe.lua
--
-- Capture-and-reapply wardrobe ONLY. No static drawable/texture/prop catalog
-- is hand-authored anywhere in this module. Every valid value is derived
-- live off the ped via GetNumPedCollection* enumeration or captured off the
-- ped's current state, then validated with IsPedCollection*Valid immediately
-- before every apply. Invalid slots are skipped, never applied.
--
-- Explicit compliance statement: this module ships zero streamed clothing
-- assets. paletteId is hardcoded 0 everywhere it appears (see
-- bridge/cl_game.lua), never 2 — the retired palm6_threads bug is not
-- repeated here.
-- ============================================================================

Wardrobe = {}

-- Per-component/prop cursor state, so texture cycling knows the currently
-- selected drawable without re-querying the ped every call.
local componentState = {}   -- [componentId] = { collectionName, drawableId, textureId, drawableCount, textureCount }
local propState = {}        -- [propId] = { collectionName, drawableId, textureId, drawableCount, textureCount, active }

-- ---- Components (torso, legs, shoes, mask, jacket, undershirt) ------------

function Wardrobe.CaptureCurrent(ped, componentId)
    local collectionName = Game.GetPedDrawableVariationCollectionName(ped, componentId)
    local drawableId = Game.GetPedDrawableVariationCollectionLocalIndex(ped, componentId)
    local textureId = Game.GetPedTextureVariationFromComponent(ped, componentId)
    local drawableCount = Game.GetNumPedCollectionDrawableVariations(ped, componentId, collectionName)
    local textureCount = Game.GetNumPedCollectionTextureVariations(ped, componentId, collectionName, drawableId)

    local state = {
        collectionName = collectionName,
        drawableId = drawableId,
        textureId = textureId,
        drawableCount = drawableCount,
        textureCount = textureCount,
    }
    componentState[componentId] = state
    return state
end

function Wardrobe.GetComponentState(ped, componentId)
    return componentState[componentId] or Wardrobe.CaptureCurrent(ped, componentId)
end

function Wardrobe.CycleComponent(ped, componentId, direction)
    local current = Wardrobe.GetComponentState(ped, componentId)
    local count = Game.GetNumPedCollectionDrawableVariations(ped, componentId, current.collectionName)
    if count <= 0 then return false end

    -- KEEP SEARCHING PAST AN INVALID DRAWABLE, don't stop on it.
    --
    -- This used to test one candidate and `return false` if it was invalid.
    -- The cursor then never advanced and, because a false return sends no
    -- wardrobeState, the arrow simply looked broken. With ONE invalid slot the
    -- player could still go the long way round; with TWO the invalid entries
    -- cut the ring into arcs and permanently confined the cursor to whichever
    -- arc it started in - a chunk of the wardrobe was unreachable, with no
    -- feedback saying so. A drawable whose texture count is 0 is equally
    -- unusable and is skipped for the same reason.
    local nextTexture = 0   -- reset to texture 0 whenever the drawable changes
    local nextDrawable, textureCount

    local candidate = current.drawableId
    for _ = 1, count do
        candidate = (candidate + direction) % count
        local candidateTextures = Game.GetNumPedCollectionTextureVariations(ped, componentId, current.collectionName, candidate)
        if candidateTextures > 0
            and Game.IsPedCollectionComponentVariationValid(ped, componentId, current.collectionName, candidate, nextTexture)
        then
            nextDrawable, textureCount = candidate, candidateTextures
            break
        end
    end

    -- Only give up once the WHOLE collection has been shown to be unusable.
    if not nextDrawable then return false end

    Game.SetPedCollectionComponentVariation(ped, componentId, current.collectionName, nextDrawable, nextTexture)

    componentState[componentId] = {
        collectionName = current.collectionName,
        drawableId = nextDrawable,
        textureId = nextTexture,
        drawableCount = count,
        textureCount = textureCount,
    }
    return true, componentState[componentId]
end

function Wardrobe.CycleTexture(ped, componentId, direction)
    local current = Wardrobe.GetComponentState(ped, componentId)
    local textureCount = Game.GetNumPedCollectionTextureVariations(ped, componentId, current.collectionName, current.drawableId)
    if textureCount <= 0 then return false end

    -- Same search-don't-stop rule as CycleComponent above: one invalid texture
    -- must not wall the cursor off from the rest of the colourways.
    local nextTexture
    local candidate = current.textureId
    for _ = 1, textureCount do
        candidate = (candidate + direction) % textureCount
        if Game.IsPedCollectionComponentVariationValid(ped, componentId, current.collectionName, current.drawableId, candidate) then
            nextTexture = candidate
            break
        end
    end
    if not nextTexture then return false end

    Game.SetPedCollectionComponentVariation(ped, componentId, current.collectionName, current.drawableId, nextTexture)

    componentState[componentId].textureId = nextTexture
    componentState[componentId].textureCount = textureCount
    return true, componentState[componentId]
end

-- ---- Props (hat, glasses, ears) --------------------------------------------

function Wardrobe.CaptureCurrentProp(ped, propId)
    local index = Game.GetPedPropIndex(ped, propId)
    local active = index ~= -1

    local collectionName, drawableId, textureId, drawableCount = nil, -1, 0, 0
    if active then
        collectionName = Game.GetPedPropCollectionName(ped, propId)
        drawableId = Game.GetPedPropCollectionLocalIndex(ped, propId)
        textureId = Game.GetPedPropTextureIndex(ped, propId)
        drawableCount = Game.GetNumPedCollectionPropDrawableVariations(ped, propId, collectionName)
    end

    local state = {
        collectionName = collectionName,
        drawableId = drawableId,
        textureId = textureId,
        drawableCount = drawableCount,
        textureCount = active and Game.GetNumPedCollectionPropTextureVariations(ped, propId, collectionName, drawableId) or 0,
        active = active,
    }
    propState[propId] = state
    return state
end

function Wardrobe.GetPropState(ped, propId)
    return propState[propId] or Wardrobe.CaptureCurrentProp(ped, propId)
end

-- direction cycling past the last index clears the prop ("no prop" state);
-- direction cycling before index 0 from a cleared prop re-enters the list at
-- its last valid drawable.
function Wardrobe.CycleProp(ped, propId, direction)
    local current = Wardrobe.GetPropState(ped, propId)

    -- Need a collection name even when currently cleared. A FRESH preview ped
    -- wears no props at all, so CaptureCurrentProp records active=false with a
    -- nil collectionName and caches it - which meant this used to `return
    -- false` on every single click, forever, on every new character. The Hat,
    -- Glasses and Ears rows rendered enabled with full hover states and did
    -- nothing, and because a false return sends no wardrobeState the NUI could
    -- not even say so. Wardrobe.RandomizeAll already had this exact fallback,
    -- so a random roll was the ONLY way to ever wear a hat.
    --
    -- Asking the game for the prop's collection is still a capture, not an
    -- invented index: Game.GetNumPedCollectionPropDrawableVariations then
    -- bounds every value used below, and a collection that enumerates nothing
    -- still bails.
    local collectionName = current.collectionName or Game.GetPedPropCollectionName(ped, propId)
    local drawableCount = collectionName and Game.GetNumPedCollectionPropDrawableVariations(ped, propId, collectionName) or 0
    if drawableCount <= 0 then return false end

    local curDrawable = current.active and current.drawableId or -1
    local nextDrawable = curDrawable + direction

    if nextDrawable < -1 then
        nextDrawable = drawableCount - 1   -- wrap from "cleared" downward into the last valid drawable
    elseif nextDrawable >= drawableCount then
        nextDrawable = -1                   -- wrap past the last drawable into "cleared"
    end

    if nextDrawable == -1 then
        Game.ClearPedProp(ped, propId)
        propState[propId] = {
            collectionName = collectionName,
            drawableId = -1,
            textureId = 0,
            drawableCount = drawableCount,
            textureCount = 0,
            active = false,
        }
        return true, propState[propId]
    end

    local nextTexture = 0
    if not Game.IsPedCollectionPropValid(ped, propId, collectionName, nextDrawable, nextTexture) then
        return false
    end

    Game.SetPedCollectionPropIndex(ped, propId, collectionName, nextDrawable, nextTexture)

    propState[propId] = {
        collectionName = collectionName,
        drawableId = nextDrawable,
        textureId = nextTexture,
        drawableCount = drawableCount,
        textureCount = Game.GetNumPedCollectionPropTextureVariations(ped, propId, collectionName, nextDrawable),
        active = true,
    }
    return true, propState[propId]
end

function Wardrobe.CyclePropTexture(ped, propId, direction)
    local current = Wardrobe.GetPropState(ped, propId)
    if not current.active then return false end

    local textureCount = Game.GetNumPedCollectionPropTextureVariations(ped, propId, current.collectionName, current.drawableId)
    if textureCount <= 0 then return false end

    local nextTexture = (current.textureId + direction) % textureCount
    if not Game.IsPedCollectionPropValid(ped, propId, current.collectionName, current.drawableId, nextTexture) then
        return false
    end

    Game.SetPedCollectionPropIndex(ped, propId, current.collectionName, current.drawableId, nextTexture)
    propState[propId].textureId = nextTexture
    propState[propId].textureCount = textureCount
    return true, propState[propId]
end

-- ---- Bulk snapshot for save/open payloads ----------------------------------

function Wardrobe.CaptureAll(ped)
    local components = {}
    for _, def in ipairs(Config.WardrobeComponents) do
        components[#components + 1] = {
            id = def.id,
            key = def.key,
            state = Wardrobe.CaptureCurrent(ped, def.id),
        }
    end

    local props = {}
    for _, def in ipairs(Config.WardrobeProps) do
        props[#props + 1] = {
            id = def.id,
            key = def.key,
            state = Wardrobe.CaptureCurrentProp(ped, def.id),
        }
    end

    return { components = components, props = props }
end

function Wardrobe.Reset()
    componentState = {}
    propState = {}
end

-- ---- Randomize (still live-enumerated, still validated — never a guessed index) --

-- Picks a random valid drawable+texture for every configured component, and
-- for every configured prop either a random valid drawable+texture OR "no
-- prop" (cleared) with equal weight to the rest of the range, so randomizing
-- doesn't force a hat/glasses/ears onto every character. Called by the
-- 'randomizeAll' NUI callback (client/main.lua) - the plain 'Randomize'
-- button only touches HeadBlend (face), this is what makes "Randomize All"
-- actually mean all.
function Wardrobe.RandomizeAll(ped)
    for _, def in ipairs(Config.WardrobeComponents) do
        local collectionName = Game.GetPedDrawableVariationCollectionName(ped, def.id)
        local drawableCount = Game.GetNumPedCollectionDrawableVariations(ped, def.id, collectionName)
        if drawableCount > 0 then
            local drawableId = math.random(0, drawableCount - 1)
            local textureCount = Game.GetNumPedCollectionTextureVariations(ped, def.id, collectionName, drawableId)
            local textureId = textureCount > 0 and math.random(0, textureCount - 1) or 0
            if Game.IsPedCollectionComponentVariationValid(ped, def.id, collectionName, drawableId, textureId) then
                Game.SetPedCollectionComponentVariation(ped, def.id, collectionName, drawableId, textureId)
                componentState[def.id] = {
                    collectionName = collectionName,
                    drawableId = drawableId,
                    textureId = textureId,
                    drawableCount = drawableCount,
                    textureCount = textureCount,
                }
            end
        end
    end

    for _, def in ipairs(Config.WardrobeProps) do
        local current = Wardrobe.GetPropState(ped, def.id)
        local collectionName = current.collectionName or Game.GetPedPropCollectionName(ped, def.id)
        local drawableCount = collectionName and Game.GetNumPedCollectionPropDrawableVariations(ped, def.id, collectionName) or 0

        -- Range is [-1, drawableCount-1] inclusive: -1 means "no prop".
        local drawableId = drawableCount > 0 and math.random(-1, drawableCount - 1) or -1

        if drawableId == -1 then
            Game.ClearPedProp(ped, def.id)
            propState[def.id] = {
                collectionName = collectionName, drawableId = -1, textureId = 0,
                drawableCount = drawableCount, textureCount = 0, active = false,
            }
        else
            local textureCount = Game.GetNumPedCollectionPropTextureVariations(ped, def.id, collectionName, drawableId)
            local textureId = textureCount > 0 and math.random(0, textureCount - 1) or 0
            if Game.IsPedCollectionPropValid(ped, def.id, collectionName, drawableId, textureId) then
                Game.SetPedCollectionPropIndex(ped, def.id, collectionName, drawableId, textureId)
                propState[def.id] = {
                    collectionName = collectionName, drawableId = drawableId, textureId = textureId,
                    drawableCount = drawableCount, textureCount = textureCount, active = true,
                }
            end
        end
    end
end
