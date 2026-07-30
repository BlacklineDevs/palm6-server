-- ============================================================================
-- palm6_uniform/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls a GTA
-- native or touches illenium-appearance. client/main.lua calls Game.* and
-- nothing else, so this ports to GTA VI by rewriting THIS file.
--
-- Everything here operates on the LOCAL player's own ped. There is no path in
-- this file that writes a component on any other entity.
-- ============================================================================

Game = {}

-- ---------------------------------------------------------------------------
-- illenium-appearance is an OPTIONAL ACCELERATOR, never a dependency.
--
-- It is not in this repo and its fxmanifest declares version "main", so there
-- is no version string to gate on. The probe below is therefore a CAPABILITY
-- probe, not a version check: state must be 'started', and each export we
-- intend to call must survive one pcall. Every getter is probed against the
-- player's own ped, and the setters are NOT probed at all (probing a setter
-- means writing to the ped, and there is no safe no-op write), so the setter
-- path is pcall-guarded at every call site instead.
--
-- The getters and the raw natives produce byte-identical output, because
-- illenium's getPedComponents/setPedComponents are literal
-- GetPedDrawableVariation / SetPedComponentVariation round-trips. The raw
-- natives are the PRIMARY path here and illenium is the accelerator, not the
-- other way round. That means a fork swap, a downgrade, or a switch to a
-- different appearance resource breaks nothing in this resource.
-- ---------------------------------------------------------------------------
local ILL = 'illenium-appearance'
local illCan = { getComponents = false, getProps = false }
local illReady = false

local function illStarted()
    return GetResourceState(ILL) == 'started'
end

function Game.ProbeAppearance()
    illCan.getComponents, illCan.getProps, illReady = false, false, false
    if not illStarted() then return false end
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return false end
    local ok1 = pcall(function() return exports[ILL]:getPedComponents(ped) end)
    local ok2 = pcall(function() return exports[ILL]:getPedProps(ped) end)
    illCan.getComponents, illCan.getProps = ok1 == true, ok2 == true
    illReady = illCan.getComponents and illCan.getProps
    return illReady
end

-- Reported by /uniformstatus so David can see from in game whether the
-- accelerator is live or whether the raw-native path is carrying everything.
function Game.AppearanceState()
    if not illStarted() then return 'absent' end
    return illReady and 'started (probe ok)' or 'started (probe failed, using raw natives)'
end

-- Is there anything to probe at all? client/main.lua stops retrying when this
-- is false, because retrying a resource that is not on the box is a loop that
-- can never succeed.
function Game.AppearancePresent()
    return illStarted()
end

-- Does `rows` carry one entry for every id in `ids`, keyed on `field`? Used to
-- reject an incomplete accelerator result before it can be stored as if it
-- were a whole outfit.
local function coversEvery(rows, field, ids)
    local seen = {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == 'table' then
            local v = tonumber(r[field])
            if v then seen[math.floor(v)] = true end
        end
    end
    for i = 1, #ids do
        if not seen[ids[i]] then return false end
    end
    return true
end

-- Which of the two freemode models is the local ped, by NAME, or nil for
-- anything else. The name is what a drawable index belongs to and what the
-- server stores, so it is the only identity this resource uses.
function Game.CurrentModelName()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    if IsPedModel(ped, `mp_f_freemode_01`) then return 'mp_f_freemode_01' end
    if IsPedModel(ped, `mp_m_freemode_01`) then return 'mp_m_freemode_01' end
    return nil
end

-- Milliseconds since the game started. Used only to debounce the two spawn
-- events against each other; never compared against a wall clock.
function Game.Now()
    return GetGameTimer()
end

-- ---------------------------------------------------------------------------
-- CAPTURE. The whole point of the resource.
--
-- Read what the ped is ACTUALLY wearing right now and hand it back as plain
-- data. Nothing here decides what a uniform should look like; it only records
-- what David dialled in.
--
-- Returns { model = string, components = {...}, props = {...} } or nil, err.
-- ---------------------------------------------------------------------------
function Game.CaptureWornOutfit()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return nil, 'no ped'
    end

    -- Model string, not hash: the string is what the indices belong to, and it
    -- is what the server stores and compares. A ped that is neither freemode
    -- model is refused rather than guessed at - a capture taken on a custom
    -- ped is meaningless on a freemode one.
    local model
    if IsPedModel(ped, `mp_f_freemode_01`) then
        model = 'mp_f_freemode_01'
    elseif IsPedModel(ped, `mp_m_freemode_01`) then
        model = 'mp_m_freemode_01'
    else
        return nil, 'not a freemode ped'
    end

    local components, props

    -- Accelerator path first, but only when the probe passed. Identical shape.
    --
    -- COMPLETENESS IS CHECKED BEFORE THE RESULT IS ACCEPTED. illenium's
    -- getPedComponents returns all twelve slots, but this resource treats it as
    -- an optional accelerator that may be a fork, and a fork that returns a
    -- SHORTER list would otherwise be stored as a complete uniform: the missing
    -- slots would simply never be written on apply, so the officer would keep
    -- whatever was in them. That is a partial uniform wearing the label of a
    -- whole one. If anything is missing, the accelerator result is discarded
    -- and the raw natives below run instead. The server re-checks the same
    -- thing in validateCapture, because this file is client realm.
    if illReady then
        local okC, c = pcall(function() return exports[ILL]:getPedComponents(ped) end)
        local okP, p = pcall(function() return exports[ILL]:getPedProps(ped) end)
        if okC and okP and type(c) == 'table' and type(p) == 'table'
           and coversEvery(c, 'component_id', Config.ComponentIds)
           and coversEvery(p, 'prop_id', Config.PropIds) then
            components, props = c, p
        end
    end

    -- Raw natives. This is the safe common denominator and the reason the
    -- resource has no hard dependency on any appearance script.
    if not components then
        components = {}
        for i = 1, #Config.ComponentIds do
            local id = Config.ComponentIds[i]
            components[#components + 1] = {
                component_id = id,
                drawable     = GetPedDrawableVariation(ped, id),
                texture      = GetPedTextureVariation(ped, id),
            }
        end
    end
    if not props then
        props = {}
        for i = 1, #Config.PropIds do
            local id = Config.PropIds[i]
            props[#props + 1] = {
                prop_id  = id,
                drawable = GetPedPropIndex(ped, id),
                texture  = GetPedPropTextureIndex(ped, id),
            }
        end
    end

    return { model = model, components = components, props = props }
end

-- ---------------------------------------------------------------------------
-- APPLY.
--
-- Two hard rules live here and they are both refusals, not repairs:
--
--  1. WRONG BODY. If the stored model is not the model of the ped standing
--     here, nothing is written. A male set on a female ped is not "mostly
--     right", it is the wrong garment or an invisible one.
--
--  2. ALL OR NOTHING. Every component is validated BEFORE the first one is
--     written. One invalid slot aborts the entire apply and the officer keeps
--     what they had on. Applying the valid half of a set is how you end up
--     with an officer in a duty jacket and no trousers, which is worse than
--     the officer simply not changing and being told why.
--
-- Returns ok, reason, changed:
--   ok       true when the whole set was written, false when nothing was.
--   reason   nil on success, a human string on refusal.
--   changed  how many slots actually moved. ZERO IS A REAL AND IMPORTANT
--            ANSWER: it means the ped was already wearing this exact set, so
--            the apply succeeded and yet nothing on screen moved. The caller
--            says so out loud. That is the difference between "the resource is
--            broken" and "you captured the clothes you are already standing
--            in", and from outside the game those two look identical, which is
--            how a whole test session gets burned.
-- ---------------------------------------------------------------------------
function Game.ApplyOutfit(model, components, props)
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return false, 'no ped'
    end

    local isFemale = IsPedModel(ped, `mp_f_freemode_01`)
    local isMale   = IsPedModel(ped, `mp_m_freemode_01`)
    if not (isFemale or isMale) then
        return false, 'your ped is not a freemode model'
    end
    local wearing = isFemale and 'mp_f_freemode_01' or 'mp_m_freemode_01'
    if wearing ~= model then
        return false, ('this set was captured on %s, you are %s'):format(tostring(model), wearing)
    end

    -- ---- pass 1: validate everything, write nothing ------------------------
    for i = 1, #components do
        local c = components[i]
        local id = tonumber(c.component_id)
        local dr = tonumber(c.drawable)
        local tx = tonumber(c.texture)
        if id == nil or dr == nil or tx == nil then
            return false, 'malformed component row'
        end
        -- Face and hair are never written, so they are never validated either.
        if not Config.SkipComponents[id] then
            if not IsPedComponentVariationValid(ped, id, dr, tx) then
                return false, ('component %d (drawable %d, texture %d) is not valid on this ped')
                    :format(id, dr, tx)
            end
        end
    end
    for i = 1, #props do
        local p = props[i]
        local id = tonumber(p.prop_id)
        local dr = tonumber(p.drawable)
        local tx = tonumber(p.texture)
        if id == nil or dr == nil or tx == nil then
            return false, 'malformed prop row'
        end
        -- -1 means "clear this prop" and is always legal. Anything else is
        -- bounds-checked against what this ped really has, because there is no
        -- IsPedPropValid equivalent to lean on.
        if dr ~= -1 then
            local nd = GetNumberOfPedPropDrawableVariations(ped, id)
            if dr < 0 or dr >= nd then
                return false, ('prop %d drawable %d is out of range (%d available)'):format(id, dr, nd)
            end
            local nt = GetNumberOfPedPropTextureVariations(ped, id, dr)
            if tx < 0 or tx >= nt then
                return false, ('prop %d texture %d is out of range (%d available)'):format(id, tx, nt)
            end
        end
    end

    -- ---- pass 2: write, counting what actually moved -----------------------
    local changed = 0
    for i = 1, #components do
        local c = components[i]
        local id = tonumber(c.component_id)
        if not Config.SkipComponents[id] then
            local dr, tx = tonumber(c.drawable), tonumber(c.texture)
            -- Read before write. This is what makes "nothing visibly happened"
            -- reportable instead of mysterious.
            if GetPedDrawableVariation(ped, id) ~= dr or GetPedTextureVariation(ped, id) ~= tx then
                changed = changed + 1
            end
            -- paletteId is 0. This repo contains one site that passes 2
            -- (palm6_threads/client/debug.lua); that is the outlier, not the
            -- pattern, and mixing the two gives inconsistent results on
            -- palette-driven components.
            SetPedComponentVariation(ped, id, dr, tx, 0)
        end
    end
    for i = 1, #props do
        local p = props[i]
        local id = tonumber(p.prop_id)
        local dr = tonumber(p.drawable)
        local tx = tonumber(p.texture)
        -- GetPedPropIndex returns -1 for an empty prop slot, which is the same
        -- value this resource stores for "clear it", so the two comparands are
        -- already in the same units.
        if GetPedPropIndex(ped, id) ~= dr or (dr ~= -1 and GetPedPropTextureIndex(ped, id) ~= tx) then
            changed = changed + 1
        end
        if dr == -1 then
            ClearPedProp(ped, id)
        else
            SetPedPropIndex(ped, id, dr, tx, true)
        end
    end

    return true, nil, changed
end

-- ---------------------------------------------------------------------------
-- RANDOMISE. The visible-change tool, and it exists for exactly one reason.
--
-- The first thing anyone does with this resource is capture the outfit they
-- are standing in and then run /uniform. At that moment the ped is still
-- wearing the captured outfit, so the apply writes the same numbers back and
-- NOTHING ON SCREEN MOVES. Both commands report success and the resource looks
-- like a no-op. You need two different outfits to see a uniform swap, and
-- getting a second outfit normally means finding a clothing store.
--
-- SetPedRandomComponentVariation and SetPedRandomProps are the id-free way to
-- get one. They pick from the variations the ENGINE reports as valid for this
-- ped, so no drawable or texture index is authored here, in the same way that
-- resolving a bone by name is not the same as typing a bone id.
--
-- Face (component 0) and hair (component 2) are put back from a reading taken
-- off this ped a fraction of a second earlier, so the randomiser cannot leave
-- David wearing a stranger's face. Those two values come from the ped, not
-- from this file.
--
-- Returns ok, reason.
-- ---------------------------------------------------------------------------
function Game.RandomiseWornOutfit()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return false, 'no ped'
    end
    if not Game.CurrentModelName() then
        return false, 'your ped is not a freemode model'
    end

    -- Read face and hair off the ped BEFORE randomising, so they can be put
    -- straight back. Read, not chosen.
    local keep = {}
    for id in pairs(Config.SkipComponents) do
        keep[#keep + 1] = {
            id       = id,
            drawable = GetPedDrawableVariation(ped, id),
            texture  = GetPedTextureVariation(ped, id),
        }
    end

    SetPedRandomComponentVariation(ped, 0)
    SetPedRandomProps(ped)

    for i = 1, #keep do
        local k = keep[i]
        SetPedComponentVariation(ped, k.id, k.drawable, k.texture, 0)
    end
    return true
end

function Game.Chat(line)
    TriggerEvent('chat:addMessage', { color = { 120, 170, 255 }, args = { 'Uniform', line } })
end

-- FALLS BACK TO CHAT rather than going quiet.
--
-- ox_lib is a declared dependency and is ensured on this box, so lib.notify is
-- normally there. But this is the channel that carries "Uniform: Patrol (7
-- slots changed)", which is the confirmation that the whole feature worked. If
-- that one line goes missing because a dependency did not load, /uniform looks
-- like it did nothing, which is the exact failure this resource has already
-- been through once. Nothing in here is allowed to be silent.
function Game.Notify(msg, t)
    if lib and lib.notify then
        lib.notify({ title = 'Uniform', description = msg, type = t or 'inform' })
        return
    end
    Game.Chat(msg)
end

-- THE TWO SPAWN SIGNALS ARE DELIBERATELY SEPARATE, and conflating them was a
-- real bug in this file's first version.
--
--   playerSpawned          fires on a join AND ON EVERY RESPAWN AFTER DEATH.
--   QBCore:Client:OnPlayerLoaded  fires when a CHARACTER is loaded, and not on
--                                 a respawn.
--
-- The old code hooked both to one callback that threw away the civilian
-- snapshot. Police die routinely, so that callback ran mid-shift on an officer
-- who was standing there in uniform: the snapshot was dropped, the server
-- re-dressed them five seconds later, and the next snapshot taken was OF THE
-- UNIFORM. /uniformoff then put the uniform back on and announced "Back in
-- civilian clothes." Neither is a palm6_* name, so neither is this repo's to
-- rename, but which one means what is this repo's to get right.
function Game.OnPlayerSpawned(cb)
    AddEventHandler('playerSpawned', cb)
end

function Game.OnCharacterLoaded(cb)
    AddEventHandler('QBCore:Client:OnPlayerLoaded', cb)
end

function Game.Wait(ms)
    Wait(ms)
end
