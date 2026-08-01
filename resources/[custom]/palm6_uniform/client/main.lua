-- ============================================================================
-- palm6_uniform/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for every native and for every
-- illenium-appearance call. No direct native access here.
--
-- The client in this design is a HAND, not a BRAIN. It can do exactly three
-- things: photograph the ped it is standing in, put on a set the server sent
-- it, and put its own civilian clothes back. It never chooses a uniform, never
-- names a rank, and never tells the server what job it has. Everything it
-- sends is re-derived or re-validated server-side.
-- ============================================================================

-- The player's own pre-uniform look, kept in CLIENT memory only.
--
-- This is deliberately not persisted and deliberately not sent to the server.
-- It is the player's own civilian clothing, so there is nothing to protect it
-- from, and keeping it out of the database means this resource has no way to
-- overwrite a saved skin. That matters: the classic data-loss bug in job
-- outfit scripts is writing the uniform into the player's permanent
-- appearance row. Nothing here can do that, because nothing here writes an
-- appearance row at all.
--
-- Cost of the choice: a resource restart or a relog forgets the snapshot. If
-- that happens while an officer is in uniform, /uniformoff has nothing to put
-- back and says so instead of guessing. That is also why the season and
-- weather pins are runtime commands (/uniformseason, /uniformweather) rather
-- than config edits: a config edit needs a restart, and a restart is what
-- strands someone.
--
-- `civilian.model` is stored with it, because the ONLY condition under which
-- this snapshot becomes wrong is the ped model changing underneath it. A male
-- capture on a female ped is the wrong garment or an invisible one.
local civilian = nil

-- Currently wearing a set this resource's SERVER picked. Only this flag decides
-- whether a new civilian snapshot may be taken.
local inUniform = false

-- This resource has altered the ped's clothes since `civilian` was taken, so a
-- restore is a meaningful thing to do. Deliberately separate from `inUniform`:
-- /uniformscramble also changes your clothes, and it is emphatically NOT a
-- uniform, but /uniformoff must still put your own clothes back afterwards.
-- Collapsing the two into one flag made /uniformoff answer "you are not in a
-- uniform" to somebody standing there in randomised clothes.
local changedByUs = false

-- Set by the character-loaded signal and consumed by the boot routine. A
-- character load is the one event that genuinely invalidates the snapshot:
-- different person, possibly different body.
local freshCharacter = false

-- Debounce for the two spawn signals. On a join both playerSpawned and
-- QBCore:Client:OnPlayerLoaded fire within moments of each other, and without
-- this the boot routine would run twice and fire two requestApply events a few
-- milliseconds apart. The second would be refused by the server's 5s
-- requestApply limit, and since every refusal now SAYS so, that refusal would
-- show up in David's chat as a spurious "slow down" on a command he never
-- typed. Ten seconds is far longer than the gap between the two signals and
-- far shorter than any realistic time to a deliberate character switch.
local BOOT_DEBOUNCE_MS = 10000
local lastBootAt = -BOOT_DEBOUNCE_MS

local function saveCivilianOnce()
    if civilian ~= nil then return end
    local snap = Game.CaptureWornOutfit()
    if snap then civilian = snap end
end

-- ---------------------------------------------------------------------------
-- Boot. Probe the optional accelerator once the ped exists, then tell the
-- server we are in the world.
-- ---------------------------------------------------------------------------
CreateThread(function()
    if not Config.Enabled then return end
    -- The probe reads the local ped, so it has to wait for one. A short bounded
    -- wait, never a spin, and it gives up immediately when the accelerator is
    -- simply not on the box: retrying a resource that does not exist is a loop
    -- that can never succeed. Either way the raw-native path carries
    -- everything, so a failed probe costs nothing but a status line.
    for _ = 1, 60 do
        if not Game.AppearancePresent() then break end
        if Game.ProbeAppearance() then break end
        Game.Wait(1000)
    end
end)

-- ---------------------------------------------------------------------------
-- THE SPAWN ROUTINE, and the rules about the civilian snapshot.
--
-- Rule 1: the snapshot is DISCARDED on a character load, and on nothing else.
--         A different character can be a different body, and the components
--         belong to the body.
--
-- Rule 2: the snapshot SURVIVES death. Respawning does not change who you are
--         or which body you are in, and the old code's assumption that it did
--         is what produced the "restored the uniform and called it civilian
--         clothes" bug. If the ped model somehow HAS changed, rule 3 catches
--         it, and Game.ApplyOutfit refuses a model mismatch anyway.
--
-- Rule 3: if the model under the snapshot no longer matches the ped standing
--         here, the snapshot is wrong by definition. Drop it and take a new
--         one.
--
-- Rule 4: a new snapshot is only ever taken when this resource has NOT already
--         changed your clothes (`changedByUs`). This is the one that matters.
--         Photographing the ped while it is wearing a uniform, or a scrambled
--         test outfit, and filing that as "civilian clothes" is the whole bug.
-- ---------------------------------------------------------------------------
local function bootRoutine()
    if not Config.Enabled then return end

    local t = Game.Now()
    if (t - lastBootAt) < BOOT_DEBOUNCE_MS then
        -- Debounced. Clear the fresh-character flag rather than leaving it set,
        -- because the two spawn signals are not ordered: if playerSpawned wins
        -- the race on a login, the character-loaded signal arrives moments
        -- later and is swallowed here. A flag left standing would then be
        -- consumed by the NEXT boot, which on a police character is a respawn
        -- after death, and it would throw away a civilian snapshot that is
        -- still perfectly good.
        freshCharacter = false
        return
    end
    lastBootAt = t

    local wasFresh = freshCharacter
    freshCharacter = false

    CreateThread(function()
        -- Let the ped and its clothing finish streaming before anything reads
        -- or writes a component. Reading too early is the classic "every
        -- drawable came back 0" bug.
        Game.Wait(5000)
        Game.ProbeAppearance()

        if wasFresh then
            -- Rule 1.
            civilian, inUniform, changedByUs = nil, false, false
        elseif civilian and civilian.model ~= Game.CurrentModelName() then
            -- Rule 3.
            civilian, inUniform, changedByUs = nil, false, false
        end

        -- Rule 4. Taken BEFORE the server is asked to dress anyone, which is
        -- what guarantees it is the pre-uniform look.
        if not changedByUs then saveCivilianOnce() end

        if not Config.ApplyOnSpawn then return end
        -- "Dress me." The server decides whether that means anything.
        TriggerServerEvent('palm6_uniform:requestApply')
    end)
end

Game.OnCharacterLoaded(function()
    freshCharacter = true
    bootRoutine()
end)

Game.OnPlayerSpawned(bootRoutine)

-- ---------------------------------------------------------------------------
-- CAPTURE. The server asked for a photograph of this ped.
--
-- `token` is opaque and single-use; it comes from the server and goes straight
-- back. The client cannot mint one, so a client that fabricates this event
-- gets its payload dropped. `mode` is echoed back so the server knows whether
-- this snapshot was for storing or just for reading out.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:doCapture', function(token, mode)
    if not Config.Enabled then return end
    if type(token) ~= 'string' then return end
    local snap, err = Game.CaptureWornOutfit()
    if not snap then
        Game.Notify(('Capture failed: %s.'):format(tostring(err)), 'error')
        return
    end
    TriggerServerEvent('palm6_uniform:captured', {
        token      = token,
        mode       = mode,
        model      = snap.model,
        components = snap.components,
        props      = snap.props,
    })
end)

-- ---------------------------------------------------------------------------
-- APPLY. The server has already decided this is the right set for this
-- officer's job, grade, body, season and weather. The client's remaining job
-- is to refuse it if the ped standing here cannot actually wear it.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:apply', function(payload)
    if not Config.Enabled then return end
    if type(payload) ~= 'table' then return end
    if type(payload.components) ~= 'table' or type(payload.props) ~= 'table' then return end

    -- Last-resort snapshot. The spawn routine above normally already holds one
    -- taken before any uniform existed; this only fires when the resource was
    -- restarted mid-session, in which case the pre-uniform look is genuinely
    -- gone and the best available answer is what is on the ped right now.
    if not changedByUs then saveCivilianOnce() end

    local ok, why, changed = Game.ApplyOutfit(payload.model, payload.components, payload.props)
    if not ok then
        -- Nothing was written. Say what happened rather than leaving the
        -- officer to wonder why the command did nothing.
        Game.Notify(('Uniform not applied: %s'):format(tostring(why)), 'error')
        return
    end
    inUniform = true
    changedByUs = true

    if (changed or 0) == 0 then
        -- SUCCESS, AND NOTHING MOVED. Say it in full, because from the outside
        -- this is identical to a broken resource, and the most likely cause is
        -- the most common first mistake: capturing the outfit you are already
        -- standing in and then asking to be dressed in it.
        Game.Notify(('Uniform "%s" applied, but you were already wearing every slot of it, so nothing changed on screen. At the station wardrobe, pick "Randomise my clothes" and then the uniform again to see the swap.')
            :format(tostring(payload.label or 'uniform')), 'inform')
        Game.Chat(('applied "%s" - 0 slots changed, you were already wearing it. At the wardrobe: "Randomise my clothes", then pick the uniform again.')
            :format(tostring(payload.label or 'uniform')))
        return
    end

    Game.Notify(('Uniform: %s (%d slots changed)'):format(tostring(payload.label or 'applied'), changed), 'success')
end)

-- ---------------------------------------------------------------------------
-- RESTORE. Off duty, or /uniformoff.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:restore', function()
    if not Config.Enabled then return end
    if not changedByUs then
        Game.Notify('This resource has not changed your clothes since you spawned, so there is nothing to change back out of.', 'inform')
        return
    end
    if not civilian then
        Game.Notify('No civilian outfit was recorded this session, so there is nothing to change back into. This resource never writes your saved appearance, so a relog brings your own clothes back.', 'error')
        return
    end
    local ok, why, changed = Game.ApplyOutfit(civilian.model, civilian.components, civilian.props)
    if not ok then
        Game.Notify(('Could not restore civilian clothes: %s'):format(tostring(why)), 'error')
        return
    end
    inUniform = false
    changedByUs = false
    if (changed or 0) == 0 then
        Game.Notify('Back in civilian clothes, though every slot already matched them, so nothing changed on screen.', 'inform')
        return
    end
    Game.Notify(('Back in civilian clothes (%d slots changed).'):format(changed), 'inform')
end)

-- ---------------------------------------------------------------------------
-- SCRAMBLE. Admin-gated server side; this half just does it to the local ped.
--
-- This is the tool that makes the very first test visible. See
-- Game.RandomiseWornOutfit for why it authors no clothing id.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:scramble', function()
    if not Config.Enabled then return end

    -- Take the civilian snapshot BEFORE scrambling if we do not already hold
    -- one. Without this, scrambling on a player who has never worn a uniform
    -- this session would make the RANDOM outfit the thing /uniformoff restores.
    if not changedByUs then saveCivilianOnce() end

    local ok, why = Game.RandomiseWornOutfit()
    if not ok then
        Game.Notify(('Could not change your clothes: %s'):format(tostring(why)), 'error')
        return
    end
    -- Random clothes are not a uniform this resource chose, so inUniform goes
    -- false. changedByUs stays TRUE, because /uniformoff still has real work to
    -- do: putting the pre-scramble clothes back.
    inUniform = false
    changedByUs = true
    Game.Notify('Your clothes are now randomised. Face and hair are untouched. Open the station wardrobe and pick a uniform to snap into it, or "Back to my own clothes" to undo this.', 'inform')
    Game.Chat('clothes randomised. Open the station wardrobe: pick a uniform to put it on, or "Back to my own clothes" to go back to what you were wearing before this.')
end)

-- ---------------------------------------------------------------------------
-- STATUS line for /uniformstatus. Client half only: whether the accelerator
-- probe passed, and whether this player is currently wearing a stored set.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_uniform:statusLine', function()
    if not Config.Enabled then return end
    Game.Chat(('client: illenium-appearance %s | ped model %s | in uniform: %s | clothes changed by us: %s | civilian snapshot: %s')
        :format(Game.AppearanceState(), tostring(Game.CurrentModelName()),
                tostring(inUniform), tostring(changedByUs), civilian and 'held' or 'none'))
end)
