-- ============================================================================
-- palm6_charselect/client/main.lua
--
-- Decides WHEN to open charselect, drives the NUI + Game.* camera/preview
-- calls, and handles the inbound RegisterNUICallback handlers. Only calls
-- Game.* (see bridge/cl_game.lua) - never a native, never a framework
-- export/callback directly.
--
-- Character listing/creation/login are qbx_core lib.callback.register'd
-- SERVER callbacks, which ox_lib only allows a CLIENT to invoke (see
-- bridge/cl_game.lua's header comment) - so those three calls happen HERE,
-- directly, rather than round-tripping through our own server/main.lua. Our
-- server still owns the restart-safety gate, the post-login confirmation
-- check, and the (entirely our own) soft-delete feature.
--
-- This file also owns the spawn pipeline (Game.DisableAutoSpawn /
-- ShutdownLoadingScreen / SpawnAtPosition / StartTutorialProtection) -
-- setting useExternalCharacters=true in qbx_core routes its ENTIRE
-- client/character.lua out, including autospawn suppression, loading-screen
-- shutdown, the actual spawn, and firing QBCore:*:OnPlayerLoaded. None of
-- that happens for free; taking over character selection means taking over
-- all of it, not just the NUI.
-- ============================================================================

local RESOURCE_NAME = 'palm6_charselect'
local isOpen = false
local busy = false   -- true while a select/create request is in flight - blocks a second click from reaching qbx_core's own double-login exploit-drop (server/player.lua: QBX.Players[source] already set -> DropPlayer)
local hiddenCitizenIds = {}     -- set, citizenid -> true; refreshed on clearToOpen and after a delete
local characterPositions = {}   -- citizenid -> vector4, captured from Game.GetCharacters() so the actual spawn can use each character's real saved position
local appearances = {}          -- citizenid -> saved appearance payload, for the stage ped
local visibleOrder = {}         -- citizenids in the same order the cards are rendered, so the stage can open on the FIRST card rather than an arbitrary pairs() key
local stageToken = 0            -- bumped per stage request; a stale in-flight spawn checks this and bails
local pendingCreateGender = nil -- carried across the confirmCreate round trip (see the createCharacter callback)

Game.DisableAutoSpawn()

-- Only ASKS the server whether charselect is needed - does not touch NUI
-- focus or the scene yet. The server may answer 'alreadyLoaded' (this client
-- already has an active qbx_core player object, e.g. THIS resource was
-- restarted mid-game) instead of 'clearToOpen', in which case nothing opens.
local function requestCharSelect()
    if isOpen then return end
    SendNUIMessage({ action = 'loading' })
    TriggerServerEvent('palm6_charselect:requestCharacters')
end

-- Fetches the real character list from qbx_core, filters out anything this
-- player has soft-deleted, and shows the panel (opening NUI focus/scene,
-- disabling the loading screen, only on first open - a refresh after delete
-- re-renders in place).
-- Takes the screen over: closes the real FiveM loading screen, builds the
-- scene and grabs NUI focus. Hoisted OUT of the success path and called BEFORE
-- the fallible qbx_core round trip below, which is the whole point.
--
-- It used to live only after Game.GetCharacters() succeeded, so a qbx_core
-- failure returned early with the FiveM loading screen still painted over
-- everything: the player never saw the error toast (it rendered underneath),
-- was never spawned (autospawn is disabled at boot), and could not be rescued -
-- the admin bail-out did not shut the loading screen down either. qbx_core
-- still booting on a fast join is enough to trigger it.
local function takeOverScreen()
    if isOpen then return end
    isOpen = true
    Game.ShutdownLoadingScreen()
    Game.SetupScene(Config.SceneCamera)
    SetNuiFocus(true, true)
end

local function loadAndShowCharacters()
    takeOverScreen()

    local ok, characters, maxSlots = Game.GetCharacters()
    if not ok then
        SendNUIMessage({ action = 'error', code = 'qbx_unavailable', message = 'Character system did not respond. Please rejoin.' })
        return
    end
    characters = characters or {}
    maxSlots = maxSlots or 2

    characterPositions = {}
    local visible = {}
    local hiddenCount = 0
    for _, char in ipairs(characters) do
        characterPositions[char.citizenid] = char.position
        if hiddenCitizenIds[char.citizenid] then
            hiddenCount = hiddenCount + 1
        else
            -- The district the character was last standing in. Resolved here
            -- rather than in the NUI because it needs a game native, and the
            -- position is otherwise only ever used to teleport with.
            char.zoneLabel = Game.GetZoneLabel(char.position)
            visible[#visible + 1] = char
        end
    end

    -- SLOT ACCOUNTING TELLS THE TRUTH, WHICH IS THAT A SOFT DELETE DOES NOT
    -- FREE A SLOT.
    --
    -- qbx_core's cap counts EVERY row in `players`, including ones this
    -- resource has soft-hidden - it has no idea palm6_charselect_hidden
    -- exists, and this resource deliberately never issues a real DELETE.
    -- The previous line here was `math.max(maxSlots - hiddenCount, #visible)`
    -- under a comment claiming it freed the slot up. It cannot, and the
    -- arithmetic self-cancels at cap for any N: max(N-k, N-k). Worse, hiding
    -- every character gave max(0, 0) = 0 - "0 / 0 slots", create button
    -- disabled, nothing to play, NUI focus held, and no cancel path by design.
    -- That state SURVIVED REJOINS, because the hidden rows are re-sent every
    -- time. Only an ACE-gated /palm6charselect_restore could undo it.
    --
    -- So: report qbx_core's real cap, and report how many of those slots are
    -- actually consumed (visible + hidden). The NUI disables "New Character"
    -- when they are all consumed and says WHY, instead of silently offering a
    -- create that qbx_core would reject.
    local usedSlots = #visible + hiddenCount

    takeOverScreen()
    SendNUIMessage({
        action = 'show',
        characters = visible,
        maxSlots = maxSlots,
        usedSlots = usedSlots,
        hiddenCount = hiddenCount,
        nameRules = Config.NameRules,
    })

    -- Ask for the saved appearances behind these characters so the stage ped
    -- can show the real person instead of a lettered circle. Asynchronous and
    -- entirely optional: the card grid above is already usable, and if this
    -- answer never arrives (palm6_appearance not running, no saved look yet)
    -- the screen simply stays as it is.
    visibleOrder = {}
    for i = 1, #visible do visibleOrder[i] = visible[i].citizenid end

    if Config.PreviewStage.enabled and #visibleOrder > 0 then
        TriggerServerEvent('palm6_charselect:requestAppearances', visibleOrder)
    end
end

-- Puts `citizenid` on the stage. Runs on its own thread because spawning
-- involves a model load and a ground probe that can take seconds on a client
-- that just connected; `stageToken` makes a superseded request abandon its
-- own spawn rather than fight the newer one (a player sweeping the mouse
-- across three cards fires three of these).
local function showOnStage(citizenid)
    stageToken = stageToken + 1
    local myToken = stageToken

    local appearance = appearances[citizenid]

    -- NOTHING TO SHOW IS AN ANSWER, NOT A SILENCE.
    --
    -- This used to just `return` for a character with no saved appearance,
    -- which left the PREVIOUS character's ped standing lit on the stage while
    -- the nameplate and details rail switched to the new one - one character's
    -- body under another character's name, reachable by arrowing across any
    -- mixed roster. Destroy the ped and tell the NUI so it can drop back to
    -- the medallion for the character actually focused.
    if not appearance or type(appearance.model) ~= 'string' then
        Game.DestroyStagePed()
        SendNUIMessage({ action = 'stage', citizenid = citizenid, live = false })
        return
    end

    CreateThread(function()
        Wait(Config.PreviewStage.switchDebounceMs)
        if myToken ~= stageToken or not isOpen then return end

        -- The token goes INTO the bridge as well as being checked around it:
        -- SetStageCharacter yields on a ground probe and a model load, and a
        -- check that only happens after it returns cannot stop the ped from
        -- being created in the first place.
        local ok = Game.SetStageCharacter(citizenid, appearance.model, appearance, function()
            return myToken ~= stageToken or not isOpen
        end)
        if myToken ~= stageToken or not isOpen then
            -- Superseded (or the screen closed) while the spawn was in flight.
            -- A newer request is about to place its own ped; nothing to clean
            -- up here, since SetStageCharacter only ever keeps one.
            return
        end
        SendNUIMessage({ action = 'stage', citizenid = citizenid, live = ok })
    end)
end

-- Invalidates any in-flight showOnStage thread. MUST be called before every
-- teardown, because a stage spawn is not instant: Game.SetStageCharacter waits
-- on a model load (up to 5s) and, on the very first call, a ground probe (up to
-- 2s while collision streams in around a freshly-connected client). A thread
-- that resumes AFTER the scene is gone spawns a ped nobody destroys - and the
-- create path is the one that really bites, because it tears the scene down and
-- then sits in the appearance editor for minutes with no further teardown to
-- clean up after it. Bumping the token is exactly what the token is for.
local function cancelPendingStage()
    stageToken = stageToken + 1
end

-- One round trip carries everything the server knows about these characters
-- that qbx_core's own list does not: their saved appearance (for the stage ped)
-- and their playtime (which qbx_core does not track at all). Both are keyed by
-- the same ownership-checked citizenid list, so neither is a way to probe for
-- someone else's character.
RegisterNetEvent('palm6_charselect:appearances', function(payload)
    if type(payload) ~= 'table' then return end
    appearances = type(payload.appearances) == 'table' and payload.appearances or {}

    -- Ordered by the card grid, not by pairs(): the stage opens on the FIRST
    -- CARD's character, which is the one the player is looking at.
    local previewable = {}
    for i = 1, #visibleOrder do
        if appearances[visibleOrder[i]] then previewable[#previewable + 1] = visibleOrder[i] end
    end
    -- THE NUI'S FOCUS IS THE ONLY THING THAT DRIVES THE STAGE.
    --
    -- This used to also stage previewable[1] itself. That is the first
    -- character WITH an appearance, which is not necessarily the first CARD -
    -- so on any roster where character 1 has no saved look, the screen opened
    -- with character 2's ped standing under character 1's name and "No saved
    -- appearance" note. Two independent things deciding who is on stage can
    -- always disagree; now the NUI re-posts previewCharacter for whoever it
    -- has focused once it knows which characters are previewable, and that is
    -- the single path in.
    SendNUIMessage({
        action = 'previewable',
        citizenids = previewable,
        playtime = type(payload.playtime) == 'table' and payload.playtime or {},
    })
end)

-- Navigation feedback. Allowlisted rather than passing the NUI's string
-- straight to PlaySoundFrontend: the sound name is a client-supplied value
-- reaching a game native, and the same "never trust the payload, look it up in
-- our own table" rule that fixed palm6_radialmenu's dispatch applies to a
-- sound bank too. Stock GTA HUD sounds only - streams nothing.
local UI_SOUNDS = {
    nav = 'NAV_UP_DOWN',
    focus = 'NAV_LEFT_RIGHT',
    back = 'BACK',
    error = 'ERROR',
}

RegisterNUICallback('uiSound', function(data, cb)
    cb('ok')
    local soundName = UI_SOUNDS[data and data.name]
    if soundName then Game.PlaySound(soundName) end
end)

-- Hover/focus/arrow-key movement across the cards drives the stage.
RegisterNUICallback('previewCharacter', function(data, cb)
    cb('ok')
    if busy or type(data.citizenid) ~= 'string' then return end
    showOnStage(data.citizenid)
end)

-- The roster went empty (last character deleted). No focus left to drive the
-- stage, so the NUI asks directly rather than leaving the deleted character
-- standing spotlit next to "Create your first character".
RegisterNUICallback('clearStage', function(_, cb)
    cb('ok')
    cancelPendingStage()
    Game.DestroyStagePed()
end)

RegisterNetEvent('palm6_charselect:clearToOpen', function(payload)
    hiddenCitizenIds = {}
    for _, citizenid in ipairs((payload and payload.hiddenCitizenIds) or {}) do
        hiddenCitizenIds[citizenid] = true
    end
    loadAndShowCharacters()
end)

-- Server confirmed this client already has an active character this session
-- (see server/main.lua's Bridge.IsPlayerLoaded guard) - clear the loading
-- state from requestCharSelect() above; nothing else to open.
RegisterNetEvent('palm6_charselect:alreadyLoaded', function()
    SendNUIMessage({ action = 'hide' })
end)

-- Admin bail-out (server/main.lua's /palm6charselect_release). Tears down
-- NUI focus and the scene unconditionally, regardless of whether a
-- login/create attempt is in flight - the one way out of the panel if
-- something in the qbx_core hand-off hangs.
--
-- `loaded` is the server's answer to "does qbx_core have a player object for
-- this client", and it decides how the rescue ENDS. See the two branches at
-- the bottom; getting this wrong in either direction is worse than the stuck
-- state it is rescuing from.
RegisterNetEvent('palm6_charselect:forceRelease', function(loaded)
    cancelPendingStage()

    -- CLOSE THE APPEARANCE EDITOR FIRST, IF IT IS THE THING THEY ARE STUCK IN.
    --
    -- The most likely moment to need rescuing is mid-creation, which is inside
    -- palm6_appearance, not this resource. NUI focus and RenderScriptCams are
    -- per-client and global: releasing focus and killing the camera here while
    -- that editor is still rendering full-screen strips its cursor and
    -- keyboard and leaves the player looking at a dead UI with no cancel and
    -- no Escape - a "rescue" that makes them strictly less interactive than
    -- before. pcall'd because palm6_appearance may not be running at all, in
    -- which case there is nothing to close and this is a no-op.
    --
    -- forceCloseEditor deliberately does NOT run the editor's completion
    -- callback (the one that would spawn and clear busy); the branches below
    -- own that, so the two can never both fire.
    pcall(function() exports.palm6_appearance:forceCloseEditor() end)

    -- The rescue has to close the real FiveM loading screen too. If the player
    -- got stuck BEFORE takeOverScreen ran (a qbx_core callback that never
    -- answered), the loading screen is still painted over everything and
    -- releasing NUI focus alone leaves them staring at it. Shutting down an
    -- already-shut-down loading screen is a no-op.
    Game.ShutdownLoadingScreen()
    SetNuiFocus(false, false)
    Game.RevealRealPed()
    Game.TeardownScene()
    SendNUIMessage({ action = 'hide' })
    isOpen = false
    busy = false
    pendingCreateGender = nil

    if loaded then
        -- qbx_core has a character for this client; they were simply never
        -- put into the world (autospawn is disabled at boot). Spawning is
        -- both safe and the only thing that finishes the rescue.
        Game.SpawnAtPosition(Config.DefaultSpawn)
        Game.StartTutorialProtection()
        Game.FadeIn(400)
        return
    end

    -- No player object. Deliberately NOT spawning: Game.SpawnAtPosition fires
    -- QBCore:*:OnPlayerLoaded, which must never fire for a client that has no
    -- character - seven other palm6_* resources listen on it. The honest
    -- rescue is to put them back at the start of the flow they fell out of.
    -- (The previous comment here claimed clearing `busy` made a retry
    -- possible; it did not - requestCharSelect had exactly one call site,
    -- onResourceStart, so nothing ever re-asked.)
    Game.FadeIn(400)
    requestCharSelect()
end)

RegisterNUICallback('selectCharacter', function(data, cb)
    if busy or type(data.citizenid) ~= 'string' then cb('ok'); return end
    busy = true
    cb('ok')
    SendNUIMessage({ action = 'busy' })

    cancelPendingStage()

    local citizenid = data.citizenid
    Game.PlaySound('SELECT')
    Game.LoginCharacterViaQbx(citizenid)
    -- No argument: the server reads the citizenid off qbx_core's loaded player
    -- object rather than trusting this one (see server/main.lua's confirmSelect
    -- handler). It comes back on selectAccepted, which is what the spawn below
    -- keys off.
    TriggerServerEvent('palm6_charselect:confirmSelect')
end)

RegisterNUICallback('deleteCharacter', function(data, cb)
    TriggerServerEvent('palm6_charselect:deleteCharacter', data.citizenid)
    cb('ok')
end)

RegisterNetEvent('palm6_charselect:deleteConfirmed', function(citizenid)
    hiddenCitizenIds[citizenid] = true
    loadAndShowCharacters()
end)

RegisterNUICallback('createCharacter', function(data, cb)
    if busy then cb('ok'); return end
    busy = true
    cb('ok')
    SendNUIMessage({ action = 'busy' })

    cancelPendingStage()

    local form = data.form
    if type(form) ~= 'table' then busy = false; return end

    -- qbx_core's own createCharacter callback shape (client/character.lua):
    -- gender is 0 (male) / 1 (female), a NUMBER, and the field is named
    -- birthdate, not dob. The NUI form still collects gender as a
    -- 'male'/'female' string (friendlier for a <select>) and dob (matches
    -- the HTML date input's own name) - converted here, at the one seam
    -- that has to match qbx_core's real contract.
    local qbxForm = {
        firstname = form.firstname,
        lastname = form.lastname,
        nationality = form.nationality,
        gender = form.gender == 'female' and 1 or 0,
        birthdate = form.dob,
    }

    local ok, newData = Game.CreateCharacterViaQbx(qbxForm)
    if not ok or not newData then
        busy = false
        SendNUIMessage({ action = 'error', code = 'create_failed', message = 'Character creation failed. Please try again.' })
        return
    end

    -- The gender the player just picked has to survive the round trip below,
    -- because the hand-off into palm6_appearance now happens in the
    -- createAccepted handler rather than inline here.
    pendingCreateGender = qbxForm.gender == 1 and 'female' or 'male'

    -- ASK THE SERVER TO CONFIRM BEFORE TOUCHING THE SCENE.
    --
    -- Two separate holes closed here. (1) The create path never told the
    -- server a character had loaded, so the playtime clock - which is only
    -- ever started by the confirm handler - never started for a brand new
    -- character: its entire first session banked as zero, every time.
    -- (2) Game.CreateCharacterViaQbx returning does NOT mean qbx_core logged
    -- the player in; qbx_core's create callback communicates neither success
    -- nor failure to its caller. The old code proceeded straight into the
    -- teardown, the appearance editor and a spawn on that assumption. This is
    -- the same server-side Bridge.GetLoadedCitizenId proof the select path
    -- already waited on, and a failure now arrives on palm6_charselect:error
    -- (which clears busy and shows a real message) instead of silently
    -- spawning a player with no character.
    TriggerServerEvent('palm6_charselect:confirmCreate')
end)

-- Server confirmed the create actually produced a loaded qbx_core player (and
-- started the playtime clock against it). Everything from here down used to
-- run inline in the createCharacter callback on nothing but hope.
RegisterNetEvent('palm6_charselect:createAccepted', function()
    -- `busy` is set by the createCharacter callback and cleared by every exit
    -- from it, so it is exactly "a create is in flight". Without this, a
    -- duplicate or late accept - or one arriving after the admin bail-out
    -- already rescued this client - would tear the scene down and re-open the
    -- appearance editor over a player who is already in the world.
    if not busy then return end

    local genderKey = pendingCreateGender or 'male'
    pendingCreateGender = nil

    -- Close OUR NUI/camera - but KEEP the real ped hidden/frozen
    -- (Game.TeardownSceneKeepPedHidden, not the full teardown) so it doesn't
    -- flash visible for one frame right before palm6_appearance spawns its
    -- own preview ped over the same spot. No cinematic here: this is a
    -- straight hand-off into another full-screen UI, not a "you're in the
    -- world now" moment yet.
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'hide' })
    Game.TeardownSceneKeepPedHidden()

    -- The gender the player just picked travels with the hand-off (resolved
    -- above, before the confirm round trip). palm6_appearance's export
    -- defaults to 'male' when config.gender is absent, and this call used to
    -- compute genderKey and then never pass it - so every female character was
    -- created on a male preview ped, and the appearance saved against
    -- mp_m_freemode_01 (whose drawable index space is completely disjoint from
    -- the female one, docs/CUSTOM-CLOTHING.md §5).
    local appearanceOpened = pcall(function()
        exports.palm6_appearance:startPlayerCustomization(function(_)
            -- The callback argument is nil on cancel/failure INSIDE
            -- palm6_appearance (its own preview-ped-spawn-failed path, or
            -- isOpen already true) as well as on success - either way,
            -- palm6_appearance only ever manages its OWN separate preview
            -- ped, never this resource's hidden real one, so RevealRealPed
            -- is required unconditionally here, not just on a failure
            -- branch. palm6_appearance's own closeAppearanceScreen already
            -- restored HUD/radar/its NUI focus before this callback fires -
            -- and, as of the appearance fix pass, has already applied the
            -- finished look (model + wardrobe) to the real player ped and
            -- handed control back with the screen deliberately still black,
            -- so the spawn below is covered.
            Game.RevealRealPed()
            Game.SpawnAtPosition(Config.DefaultSpawn)
            Game.StartTutorialProtection()
            Game.FadeIn(500)
            isOpen = false
            busy = false
        end, { gender = genderKey })
    end)

    if not appearanceOpened then
        -- exports.palm6_appearance:startPlayerCustomization itself threw or
        -- doesn't exist (resource not running) - no callback is ever coming,
        -- so this path has to do its own cleanup rather than waiting on one.
        Game.RevealRealPed()
        Game.SpawnAtPosition(Config.DefaultSpawn)
        Game.StartTutorialProtection()
        Game.Notify({ description = 'Appearance editor unavailable - continuing with default look.', type = 'inform' })
        Game.FadeIn(500)
        isOpen = false
        busy = false
    end
end)

-- NOT the same name as the client->server 'palm6_charselect:confirmSelect'
-- trigger above, on purpose - same-name events used in both directions are
-- technically independent (server RegisterNetEvent vs client RegisterNetEvent
-- are separate registrations even under an identical string), but reusing
-- the name makes the direction ambiguous to read and to the repo's own
-- tools/audit event-graph checker. server/main.lua's confirmSelect handler
-- answers with THIS event once Bridge.IsPlayerLoaded confirms the login the
-- client just attempted actually took effect.
RegisterNetEvent('palm6_charselect:selectAccepted', function(citizenid)
    -- Same in-flight guard as createAccepted above: a late or duplicate accept
    -- must not re-run the cinematic and re-spawn a player who is already
    -- playing (or who the admin bail-out has already rescued).
    if not busy then return end

    -- Server has confirmed that Game.LoginCharacterViaQbx
    -- in the selectCharacter callback above actually logged this client in -
    -- qbx_core's own loadCharacter callback doesn't communicate success or
    -- failure to the caller at all, so this server round trip is the real
    -- signal, not the lib.callback.await returning.
    Game.PlaySelectCinematic(nil, Config.SelectCameraDurationMs)
    SendNUIMessage({ action = 'confirmSelect' })
    -- Release focus as soon as the cinematic starts, not after the teardown
    -- wait below - the mouse was held captive over an already-invisible UI
    -- for the whole fade/teardown sequence otherwise.
    SetNuiFocus(false, false)
    Game.FadeOut(300)
    Wait(300)
    Game.TeardownScene()

    local pos = characterPositions[citizenid] or Config.DefaultSpawn
    Game.SpawnAtPosition(pos)
    Game.StartTutorialProtection()
    Game.FadeIn(400)

    isOpen = false
    busy = false
end)

RegisterNetEvent('palm6_charselect:error', function(code, message)
    busy = false
    SendNUIMessage({ action = 'error', code = code, message = message })
end)

-- §1.8 fallback plan: charselect opens on its own onResourceStart, grabs
-- NUI focus, and paints a full-viewport branded panel over whatever qbx_core's
-- own multichar UI may render underneath - the player only ever sees/
-- interacts with the Palm6 skin regardless of which suppression mechanism
-- (if any) is live on the box. See README.md "qbx_core integration" -
-- config.characters.useExternalCharacters must be set true in qbx_core's
-- OWN config/client.lua on the live box for this to be the ONLY multichar UI
-- a player sees; this resource cannot set that itself (qbx_core is not
-- vendored in this repo).
AddEventHandler('onResourceStart', function(res)
    if res == RESOURCE_NAME then requestCharSelect() end
end)

AddEventHandler('onResourceStop', function(res)
    if res == RESOURCE_NAME and isOpen then
        cancelPendingStage()
        SetNuiFocus(false, false)
        Game.RevealRealPed()
        Game.TeardownScene()
        Game.FadeIn(200)
        isOpen = false
    end
end)
