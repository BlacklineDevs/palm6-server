-- ============================================================================
-- palm6_fc_combat/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file here that calls GTA natives / ox_target /
-- ox_lib UI. client/main.lua calls Game.* only. Presentation + local ped only;
-- server owns all authority.
-- ============================================================================

Game = {}

local hasTarget = GetResourceState('ox_target') == 'started'
local saved = { model = nil, appearance = nil, active = false }

function Game.MyServerId()
    return GetPlayerServerId(PlayerId())
end

-- Server id of the remote player this ped belongs to, or nil.
function Game.ServerIdFromPed(ped)
    if not ped or ped == 0 then return nil end
    local p = NetworkGetPlayerIndexFromPed(ped)
    if p == -1 then return nil end
    return GetPlayerServerId(p)
end

function Game.PedIsRemotePlayer(ped)
    return ped and ped ~= 0 and IsPedAPlayer(ped) and ped ~= PlayerPedId()
end

-- ox_target eye on any nearby player: "Challenge to a fight".
function Game.AddChallengeTarget(onSelectServerId)
    if not hasTarget then return end
    exports.ox_target:addGlobalPlayer({
        {
            name = 'palm6_fc_challenge',
            icon = 'fa-solid fa-hand-fist',
            label = 'Challenge to a fight',
            distance = 2.5,
            canInteract = function(entity) return Game.PedIsRemotePlayer(entity) end,
            onSelect = function(data)
                local sid = Game.ServerIdFromPed(data.entity)
                if sid then onSelectServerId(sid) end
            end,
        },
    })
end

function Game.Notify(opts)
    lib.notify(opts)
end

-- Accept/decline modal. Returns true on accept.
function Game.ConfirmDialog(title, msg, ttlSec)
    local res = lib.alertDialog({
        header = title,
        content = msg,
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })
    return res == 'confirm'
end

-- ox_lib context menu. options = { { title, description, onSelect=fn }, ... }.
function Game.OpenMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

-- 3-2-1 client countdown (visual only; server owns the real clock).
function Game.RunCountdown(sec)
    CreateThread(function()
        for i = sec, 1, -1 do
            lib.notify({ title = 'Fight Club', description = tostring(i), type = 'inform', duration = 900 })
            Wait(1000)
        end
    end)
end

-- Preload every anim dict + the movement clipset for a style (COUNTDOWN gate, §8).
function Game.PreloadStyle(styleId)
    local st = exports.palm6_fc_core:GetStyle(styleId)
    if not st then return end
    for _, d in pairs(st.animDicts or {}) do
        if type(d) == 'string' then
            RequestAnimDict(d)
            local dl = GetGameTimer() + 3000
            while not HasAnimDictLoaded(d) and GetGameTimer() < dl do Wait(25) end
        end
    end
    local cs = st.movementClipset
    if cs then
        RequestClipSet(cs)
        local dl = GetGameTimer() + 3000
        while not HasClipSetLoaded(cs) and GetGameTimer() < dl do Wait(25) end
    end
end

-- Snapshot real appearance (illenium) + hash, then swap to the fighter model.
-- Non-persisting: a DC self-heals on reconnect. Defensive: falls back to the
-- model hash if illenium isn't present.
function Game.SwapToFighter(model, styleId)
    local ped = PlayerPedId()
    local ok, ap = pcall(function() return exports['illenium-appearance']:getPedAppearance(ped) end)
    saved.appearance = ok and ap or nil
    saved.model = GetEntityModel(ped)
    saved.active = true
    Game.PreloadStyle(styleId)
    local hash = joaat(model)
    if not IsModelValid(hash) then return end
    RequestModel(hash)
    local dl = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(50) end
    if HasModelLoaded(hash) then
        SetPlayerModel(PlayerId(), hash)
        SetModelAsNoLongerNeeded(hash)
    end
end

-- Canonical client unwind — restore the real ped + saved appearance.
function Game.RestoreAppearance()
    if not saved.active then return end
    saved.active = false
    if saved.model and saved.model ~= 0 then
        RequestModel(saved.model)
        local dl = GetGameTimer() + 5000
        while not HasModelLoaded(saved.model) and GetGameTimer() < dl do Wait(50) end
        if HasModelLoaded(saved.model) then
            SetPlayerModel(PlayerId(), saved.model)
            SetModelAsNoLongerNeeded(saved.model)
        end
    end
    if saved.appearance then
        pcall(function() exports['illenium-appearance']:setPedAppearance(PlayerPedId(), saved.appearance) end)
    end
    saved.appearance = nil
    saved.model = nil
end

-- Place the fighter on its fight-mark facing the opponent (§K). Driven by T10's
-- palm6_fc_arena:squareUp emission (T6 no longer emits it — C7).
function Game.SquareUp(coords, heading)
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
end

-- ============================================================================
-- T7: LIVE fighter ped hardening / strike clip / KO ragdoll / restore.
-- Every native re-fetches PlayerPedId() so a model swap (§8) never leaves us
-- operating on a stale handle.
-- ============================================================================

local FC_MELEE_CONTROLS = { 24, 25, 140, 141, 142, 143, 257, 262, 263, 264 }  -- attack/aim/melee light+heavy+block+combo
local FC_UNARMED = joaat('WEAPON_UNARMED')

-- One frame of hardening on the LOCAL fighter's own ped (§6): invincible (blocks
-- health loss only), ragdoll OFF (re-asserted each frame so a punch/blast can't
-- interrupt a clip), pain/flinch off, own melee suppressed, empty-handed.
function Game.HardenFighterPed()
    local pid = PlayerId()
    local ped = PlayerPedId()
    SetPlayerInvincible(pid, true)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedSuffersCriticalHits(ped, false)
    SetPedConfigFlag(ped, 187, true)          -- disable melee-hit reactions
    SetPedConfigFlag(ped, 281, true)
    SetCurrentPedWeapon(ped, FC_UNARMED, true)
    SetWeaponsNoAutoswap(true)
    for i = 1, #FC_MELEE_CONTROLS do
        DisableControlAction(0, FC_MELEE_CONTROLS[i], true)
    end
end

-- Play a strike clip on the LOCAL fighter's own ped, non-interruptibly (flag 2)
-- so a stray reaction can't override the intended swing (§6).
function Game.PlayStrikeClip(animDict, animName)
    if type(animDict) ~= 'string' or type(animName) ~= 'string' then return end
    RequestAnimDict(animDict)
    local deadline = GetGameTimer() + 1000
    while not HasAnimDictLoaded(animDict) and GetGameTimer() < deadline do Wait(0) end
    if not HasAnimDictLoaded(animDict) then return end
    TaskPlayAnim(PlayerPedId(), animDict, animName, 8.0, -8.0, -1, 2, 0.0, false, false, false)
end

-- KO: the victim's own client ragdolls its own ped. §6 ordering — the caller
-- MUST have stopped the hardening loop first; here we enable ragdoll then apply.
-- C6: FreezeEntityPosition(false) FIRST so a Task-8 finisher-KO (victim ped frozen
-- by the finisher scene) actually ragdolls instead of no-opping.
function Game.RagdollSelf()
    FreezeEntityPosition(PlayerPedId(), false)
    local ped = PlayerPedId()
    SetPlayerInvincible(PlayerId(), false)
    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)
    SetPedToRagdoll(ped, 3500, 3500, 0, false, false, false)
    ApplyForceToEntity(ped, 1, 0.0, -1.5, 0.4, 0.0, 0.0, 0.0, 0, false, true, true, false, true)
end

-- Teardown of hardening: reverse everything HardenFighterPed asserted (§11).
function Game.RestoreFighterPed()
    local pid = PlayerId()
    local ped = PlayerPedId()
    SetPlayerInvincible(pid, false)
    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)
    SetPedSuffersCriticalHits(ped, true)
    SetPedConfigFlag(ped, 187, false)
    SetPedConfigFlag(ped, 281, false)
    SetWeaponsNoAutoswap(false)
    ClearPedTasks(ped)
end
