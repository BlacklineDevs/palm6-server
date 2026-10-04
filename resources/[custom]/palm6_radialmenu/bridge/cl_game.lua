-- cl_game.lua is the ONLY file in palm6_radialmenu that calls a GTA native or an ox_lib UI
-- export directly. All other client logic calls Game.* only. This keeps the resource easy
-- to audit and easy to port if the underlying game/UI layer ever changes.
--
-- Deliberately NOT here: any camera native (GetGameplayCamCoords, etc). This menu is a 2D
-- HUD overlay synced to cursor position only, never to the game camera — see html/style.css
-- header comment and README.md for the explicit "no camera natives" flag.

Game = {}

--- Returns false when the player ped is in a state that should block opening the radial
--- (ragdolled, cuffed, or mid-parachute freefall). All other client code should gate
--- OpenRadial() through this function rather than calling the natives directly.
---@return boolean
function Game.CanOpenRadial()
    local ped = PlayerPedId()
    if IsPedRagdoll(ped) or IsPedCuffed(ped) or IsPedInParachuteFreeFall(ped) then
        return false
    end
    return true
end

--- True while the player is dead or dying.
---
--- Deliberately separate from CanOpenRadial: being dead should not just block
--- OPENING the menu, it has to CLOSE one that is already open (client/main.lua's
--- watchdog). A radial holding NUI focus over the death screen eats the hold-E
--- respawn and every ambulance control.
---@return boolean
function Game.IsPlayerDead()
    local ped = PlayerPedId()
    return IsEntityDead(ped) or IsPedFatallyInjured(ped)
end

--- True when another resource has already claimed the `radialmenu` command
--- name. Used for a one-shot startup warning: FiveM's command manager invokes
--- EVERY handler registered under a name, so both menus would open at once,
--- with two competing SetNuiFocus(true,true) owners and only ours releasing it.
--- The fix is a `stop qbx_radialmenu` line in custom.cfg (README.md "Before
--- First Ensure"); this only makes a missing one loud instead of mysterious.
---@return boolean
function Game.QbxRadialIsRunning()
    return GetResourceState('qbx_radialmenu') == 'started'
end

--- Thin wrapper over ox_lib's notify export so the rest of the resource never touches
--- `lib.*` directly.
---@param msg string
---@param notifyType string|nil 'inform' | 'success' | 'error' | 'warning' (ox_lib types)
function Game.Notify(msg, notifyType)
    lib.notify({ description = msg, type = notifyType or 'inform' })
end

--- Plays a stock frontend UI sound - the standard GTA HUD sound bank, already
--- resident on every client, so this streams nothing new. Discrete-event only
--- (open/select/close) - deliberately NOT wired to continuous hover, which
--- would fire dozens of times a second as the cursor crosses wedges and is a
--- perf/spam concern this resource hasn't taken on.
---@param soundName string e.g. 'SELECT', 'BACK', 'NAV_LEFT_RIGHT', 'ERROR'
function Game.PlaySound(soundName)
    PlaySoundFrontend(-1, soundName, 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end
