-- ============================================================================
-- palm6_insignia/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY client file in this resource that calls a
-- GTA native. client/main.lua calls Game.* only, so its logic ports to GTA VI
-- by rewriting THIS FILE (house §3, the bridge pattern).
--
-- NOTHING HERE TOUCHES CLOTHING. There is no SetPedComponentVariation, no
-- AddReplaceTexture, no CreateDui and no runtime txd anywhere in this
-- resource. The tape is drawn in world space with the standard text natives,
-- which is why it can never damage a garment or a base-game asset.
--
-- NO MAGIC IDS ARE AUTHORED IN THIS RESOURCE.
-- An earlier revision hard-coded a numeric bone id (24819) that was asserted to
-- be SKEL_Spine3 and was not a ped bone at all. Every anchor in this file is now
-- resolved AT RUNTIME by BONE NAME through GET_ENTITY_BONE_INDEX_BY_NAME, which
-- returns -1 for a name the model does not have. So the engine, not a comment,
-- decides whether the anchor is real, and a wrong name degrades visibly and
-- reportably instead of silently resolving to the ped's origin.
-- ============================================================================

Game = {}

-- Our own server id, so the render layer can tell "this is me" from "this is
-- another officer" without asking the server.
function Game.MyServerId()
    return GetPlayerServerId(PlayerId())
end

function Game.MyPed()
    return PlayerPedId()
end

-- Does this entity handle still refer to a live entity? client/main.lua re-asks
-- this every frame for a ped handle the scan captured up to ScanIntervalMs ago,
-- and it goes through the bridge so the "every native lives in this file" claim
-- is literally true rather than nearly true.
function Game.EntityExists(ent)
    return ent ~= nil and ent ~= 0 and DoesEntityExist(ent)
end

-- The local ped handle for a SERVER id, or nil when that player is not in
-- scope on this client. Returning nil (rather than 0 or -1) is what lets the
-- scan skip out-of-scope officers in one branch.
function Game.PedForServerId(serverId)
    local pid = GetPlayerFromServerId(serverId)
    if pid == -1 then return nil end
    local ped = GetPlayerPed(pid)
    if not Game.EntityExists(ped) then return nil end
    return ped
end

-- Metres between the local player and a ped, or nil when either is gone.
function Game.DistanceToPed(ped)
    local me = PlayerPedId()
    if not me or me == 0 or not ped or ped == 0 then return nil end
    return #(GetEntityCoords(me) - GetEntityCoords(ped))
end

function Game.IsPedOnScreen(ped)
    return IsEntityOnScreen(ped)
end

-- Follow-cam view mode 4 is first person. Used only to hide the LOCAL
-- player's own tape, which would otherwise hang in the middle of the screen.
function Game.IsFirstPerson()
    return GetFollowPedCamViewMode() == 4
end

-- ---------------------------------------------------------------------------
-- THE ANCHOR
--
-- GET_ENTITY_BONE_INDEX_BY_NAME(entity, boneName) returns the bone index for a
-- name on THAT model, or -1 when the model has no such bone. That is the whole
-- reason this resource authors no bone number: the value is produced by the
-- engine from the model actually standing in front of you.
--
-- The caller passes an ordered list of candidate names and takes the first that
-- resolves, so a ped model with an unusual skeleton falls back on its own
-- rather than needing a config edit.
-- ---------------------------------------------------------------------------

-- Returns boneIndex, boneName for the first name this ped actually has, or nil.
function Game.ResolveTapeBone(ped, names)
    if not Game.EntityExists(ped) or type(names) ~= 'table' then return nil end
    for i = 1, #names do
        local name = names[i]
        if type(name) == 'string' and name ~= '' then
            local idx = GetEntityBoneIndexByName(ped, name)
            if idx and idx ~= -1 then return idx, name end
        end
    end
    return nil
end

-- World position of the tape anchor.
--
-- boneIndex comes from Game.ResolveTapeBone, so it is an index the engine
-- handed us for this exact ped. GET_WORLD_POSITION_OF_ENTITY_BONE gives its
-- world position directly.
--
-- The two offsets are applied in WORLD space off that point, using axes we can
-- name honestly: `forward` runs along GET_ENTITY_FORWARD_VECTOR (the direction
-- the ped is facing, so it pushes the tape out of the chest rather than into
-- it) and `up` runs along world Z. They are NOT bone-local, because bone-local
-- axes in the GTA rig are not aligned with the ped's facing and an offset
-- expressed in them cannot be reasoned about from a config file.
--
-- boneIndex nil is the honest failure mode: the tape is drawn at the ped's own
-- origin, which is at their feet. That is deliberately obvious on screen and is
-- the exact symptom the in-game checklist tells David to look for.
function Game.TapeAnchor(ped, boneIndex, forward, up)
    local base
    if boneIndex then
        base = GetWorldPositionOfEntityBone(ped, boneIndex)
    else
        base = GetEntityCoords(ped)
    end
    local fwd = GetEntityForwardVector(ped)
    return base.x + (fwd.x * forward),
           base.y + (fwd.y * forward),
           base.z + up
end

-- Apply the tape text style. Split out from the draw so the width measurement
-- below is taken under EXACTLY the style the draw will use - measuring under a
-- different scale produces a plate that does not fit its text.
local function applyStyle(scale, font)
    SetTextScale(scale, scale)
    SetTextFont(font)
    SetTextProportional(true)
    SetTextCentre(true)
end

-- Screen-space width of a string at the tape's style. Called from the SCAN
-- loop (4x/second), never per frame: the strings are static per officer, so
-- the result is cached on the candidate.
function Game.MeasureText(text, scale, font)
    applyStyle(scale, font)
    BeginTextCommandGetWidth('STRING')
    AddTextComponentSubstringPlayerName(text)
    return EndTextCommandGetWidth(true)
end

-- Screen-space height of one rendered line at this style, from
-- GET_RENDERED_CHARACTER_HEIGHT. The backing plate is sized from this rather
-- than from a guessed constant, which is what makes the plate actually cover
-- both lines. Measured in the scan and cached, same as the widths.
--
-- Guarded, and the guard is not paranoia about a typo: this runs inside the
-- scan THREAD, and an "attempt to call a nil value" there kills the loop
-- outright, so the tape would stop appearing with one line in F8 and no other
-- symptom. Returning nil instead makes the caller fall back to its configured
-- line gap, which draws a slightly loose plate rather than nothing at all.
local warnedNoCharHeight = false
function Game.CharHeight(scale, font)
    if type(GetRenderedCharacterHeight) ~= 'function' then
        if not warnedNoCharHeight then
            warnedNoCharHeight = true
            print('[palm6_insignia] GetRenderedCharacterHeight is unavailable; '
                .. 'the tape plate falls back to Config.Render.LineGap for its height.')
        end
        return nil
    end
    return GetRenderedCharacterHeight(scale, font)
end

-- Draw one two-line name tape at a world position.
--
-- `style` carries everything from Config.Render that the draw needs, so this
-- function reads no globals and can be swapped wholesale on a port.
--
-- GEOMETRY, stated so it can be checked:
--   line 1 top edge  = -gap
--   line 2 top edge  =  0
--   gap              = max(style.lineGap, charH), so the lines never overlap
--   text block spans  -gap .. charH
--   plate spans       -gap - padY .. charH + padY
--   DrawRect takes a CENTRE, so plate centre y = (charH - gap) * 0.5
-- Under SetDrawOrigin, +y is down the screen, so line 1 (the name) sits above
-- line 2 (the badge line).
--
-- AddTextComponentSubstringPlayerName is the standard string entry. It is safe
-- here ONLY because the server strips '~' from every name before it is
-- published - see sanitiseTapeText in server/main.lua. A tilde left in a
-- player-typed surname would be parsed as a GTA text-markup colour code.
-- `accent` is the rank colour {r,g,b}. `dist` and `maxDist` drive the fade, so a
-- tape across the lobby is a quiet hint and a tape in front of you is legible.
function Game.DrawTape(x, y, z, line1, line2, w1, w2, style, charH, accent, dist, maxDist)
    SetDrawOrigin(x, y, z, 0)

    charH = charH or style.lineGap
    local gap = math.max(style.lineGap, charH)
    accent = accent or style.accent

    -- DISTANCE FADE. Full strength up to FadeStart, then down to FadeFloor at
    -- max range, so a crowded lobby does not become a wall of hard white boxes.
    -- Never reaches zero: a tape that vanishes early reads as a bug.
    local a = 1.0
    if dist and maxDist and maxDist > 0 then
        local fadeStart = maxDist * (style.fadeStart or 0.55)
        if dist > fadeStart then
            local t = (dist - fadeStart) / math.max(0.001, maxDist - fadeStart)
            a = 1.0 - (t * (1.0 - (style.fadeFloor or 0.35)))
            if a < 0.0 then a = 0.0 elseif a > 1.0 then a = 1.0 end
        end
    end
    local function A(v) return math.floor((v or 255) * a) end

    local w = math.max(w1 or 0.0, w2 or 0.0) + (style.padX * 2.0)
    local h = gap + charH + (style.padY * 2.0)
    local cy = (charH - gap) * 0.5

    -- Layered plate instead of one flat rectangle. The old version was a single
    -- dark box with white text in it, which is what "ugly and plain" meant.
    -- Three cheap DrawRects give it an edge and a rank colour without any
    -- texture asset: a soft outer border, the body, and an accent bar.
    DrawRect(0.0, cy, w + (style.borderX or 0.004), h + (style.borderY or 0.006),
        style.border[1], style.border[2], style.border[3], A(style.borderAlpha))
    DrawRect(0.0, cy, w, h,
        style.plate[1], style.plate[2], style.plate[3], A(style.plateAlpha))

    -- Accent bar along the bottom edge, in the officer's rank colour. This is
    -- the single thing that stops it reading as a generic debug label: rank is
    -- legible at a glance, before you can read the text.
    local barH = style.accentH or 0.0035
    DrawRect(0.0, cy + (h * 0.5) - (barH * 0.5), w, barH,
        accent[1], accent[2], accent[3], A(240))

    -- Line 1: the name. Slightly larger and pure white, so it is the thing the
    -- eye lands on first.
    applyStyle(style.scale * (style.nameScale or 1.0), style.font)
    SetTextColour(style.text[1], style.text[2], style.text[3], A(style.text[4]))
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(line1)
    DrawText(0.0, -gap)

    -- Line 2: badge and rank, smaller and in the rank colour, so the two lines
    -- read as a hierarchy rather than as two identical rows of text.
    applyStyle(style.scale * (style.subScale or 0.86), style.font)
    SetTextColour(accent[1], accent[2], accent[3], A(style.subAlpha or 235))
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(line2)
    DrawText(0.0, 0.0)

    ClearDrawOrigin()
end

function Game.Notify(title, msg, t)
    TriggerEvent('ox_lib:notify', {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Client console line. Used for the one-time "the bone name did not resolve"
-- warning, so a wrongly-placed tape leaves a trace David can paste back.
function Game.Print(msg)
    print('[palm6_insignia] ' .. tostring(msg))
end

-- Unrestricted client command. There is no gating here at all on purpose: the
-- client commands in this resource only ASK the server for something or change
-- what THIS client draws for itself, and every gate that matters lives
-- server-side.
function Game.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
