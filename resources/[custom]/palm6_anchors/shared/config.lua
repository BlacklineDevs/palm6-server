-- ============================================================================
-- palm6_anchors/shared/config.lua - tunables for the anchor inspector.
--
-- THIS RESOURCE HOLDS NO WORLD COORDINATE OF ITS OWN. Not one. Every position
-- it knows about is transcribed in shared/registry.lua from the config file
-- that owns it, or captured in game from where an admin was standing. If you
-- ever find a vector3 with fresh numbers in this file, something has gone
-- wrong: this is a reading tool, not a placing tool.
-- ============================================================================

Config = {}

-- Master switch. Off makes every command answer "disabled", draws no markers
-- and serves no menu. It does not delete any capture.
Config.Enabled = true

-- Extra console logging on the capture and menu paths.
Config.Debug = false

-- ---------------------------------------------------------------------------
-- PERMISSION
-- ---------------------------------------------------------------------------
-- One ACE gates everything here: the menu, the markers, the teleport and the
-- capture. Same shape palm6_uniform uses (Config.AdminAce there), and for the
-- same reason: every command is RegisterCommand(..., restricted = false) with
-- the check inside the handler, because a restricted command with no add_ace
-- line is runnable by group.owner and by nobody else.
--
-- WITHOUT `add_ace group.admin command.anchors allow` in custom.cfg, only
-- group.owner can use this. The audit's command-aces check cannot see that gap
-- (it only reconciles RESTRICTED registrations), so this resource checks the
-- grant itself at boot and prints the exact missing line in red. See the BOOT
-- block in server/main.lua.
Config.AdminAce = 'command.anchors'

-- Principals the boot check expects to hold Config.AdminAce. Drives a console
-- warning only. It grants nothing and cannot: ACEs live in custom.cfg.
Config.ExpectedAcePrincipals = { 'group.admin' }

-- ---------------------------------------------------------------------------
-- HOW YOU OPEN IT
-- ---------------------------------------------------------------------------
-- The command and the keybind do the same thing. Both exist because a keybind
-- is what you want while walking a station, and a command is what still works
-- when a keybind is unbound or taken.
Config.Command = 'anchors'

-- Default key for the menu, rebindable in the pause menu like every other
-- keybind in this repo. F7 was picked because nothing in resources/[custom]
-- binds it today: the taken keys are E, Q, LMENU (palm6_fc_combat), U
-- (palm6_brain), F5 (palm6_mdt), B, H and L (palm6_mapeditor). A player who
-- clears it in the pause menu simply has no key, and /anchors still works.
Config.Keybind = 'F7'

-- The command that toggles the markers without opening the menu, so an admin
-- can turn them on, walk, and never touch a menu again.
Config.MarkerCommand = 'anchormarkers'

-- ---------------------------------------------------------------------------
-- THE LIVE VIEW
-- ---------------------------------------------------------------------------
Config.Markers = {
    -- OFF BY DEFAULT, and that is deliberate. Nobody but an admin correcting
    -- anchors wants floating chevrons over half the map, and a marker loop that
    -- runs for every player all session is a cost paid by everyone for a tool
    -- one person uses. With this false, the client thread sleeps on a long
    -- timer and draws nothing until an admin turns it on.
    DefaultOn = false,

    -- Only anchors within this many metres of the player are considered at all.
    -- Everything beyond it is skipped before any distance maths is drawn.
    Radius = 75.0,

    -- Hard cap on how many markers are drawn in one frame, after sorting by
    -- distance. Mission Row has nine anchors inside 40m; this ceiling exists so
    -- that a future registry with three hundred rows cannot turn into a frame
    -- -rate incident. The nearest N always win.
    MaxDrawn = 30,

    -- The label (the anchor key) is only drawn this close. A chevron is legible
    -- from far away; a floating string is not, and thirty of them is a wall of
    -- text.
    TextDistance = 20.0,

    -- Metres above the anchor point the chevron floats, so it clears the floor
    -- and is not swallowed by whatever prop is standing there.
    ZOffset = 0.9,

    -- Marker type 21 is the downward chevron this repo already uses for
    -- interaction points (palm6_uniform/bridge/cl_game.lua).
    Type = 21,
    Scale = 0.30,

    -- How often the cull list is recomputed while markers are on. Drawing has
    -- to happen every frame or the marker flickers; deciding WHICH anchors are
    -- near enough does not.
    RefreshMs = 500,

    -- Colours are r, g, b, a. Two of them, so an anchor that has a captured
    -- correction reads differently from one still sitting on its config value.
    ColourConfig   = { 255, 170,  40, 140 },  -- amber: still the config value
    ColourCaptured = {  60, 220, 120, 160 },  -- green: a capture exists for it
}

-- ---------------------------------------------------------------------------
-- THE MENU
-- ---------------------------------------------------------------------------
-- The menu lists anchors sorted by distance. This is how many rows it shows;
-- a hundred-row ox_lib context menu is not a list, it is a scroll bar.
Config.MenuRows = 25

-- Rows beyond MenuRows are dropped, and the menu SAYS how many were dropped
-- rather than quietly truncating. Nothing in this resource is allowed to be
-- silent about what it did not show.

-- ---------------------------------------------------------------------------
-- RATE LIMITS (seconds between accepted calls, per source)
-- ---------------------------------------------------------------------------
-- The resource's OWN limits, running inside the handler. The palm6_eventguard
-- budgets requested in README.md are a blunter outer bound that runs BEFORE the
-- handler; neither replaces the other.
--
-- Every refusal SAYS SO, with the seconds left. A silent drop is
-- indistinguishable from a broken command, which is precisely the failure mode
-- this whole resource exists to end.
--
-- `menu` is deliberately loose: opening a menu is a read that stores nothing,
-- and a menu that refuses to open looks broken.
Config.RateLimits = {
    menu     = 1,   -- opening the anchor list (a read)
    teleport = 2,   -- jumping to an anchor
    capture  = 3,   -- "this anchor belongs where I am standing" (a WRITE)
    toggle   = 1,   -- turning markers on or off
    command  = 2,   -- everything else

    -- The OUTER bound on the menuAction net event itself, applied before the
    -- action is even decoded. Each action then hits its own limit above, so a
    -- capture is still bounded at 3s; this exists so a modified client cannot
    -- spam the event with junk actions and pull one server reply per packet.
    -- Listed explicitly rather than relying on rl()'s "or 1" fallback, so the
    -- number is in the config where it can be seen and tuned.
    menuAction = 1,
}

-- ---------------------------------------------------------------------------
-- TELEPORT
-- ---------------------------------------------------------------------------
-- Teleporting to an anchor is how you check one that is nowhere near you. The
-- client does the move (it needs collision streaming around the destination,
-- which is client realm), but the server decides WHERE: it looks the key up in
-- the registry and sends that point. A client asking to be moved to arbitrary
-- coordinates is not a request this resource can make.
Config.TeleportEnabled = true

-- How many decimal places the printed config line carries.
--
-- TWO, matching every coords line already in the repo and matching what
-- palm6_uniform's "move this wardrobe" action prints. More digits would be
-- false precision: a ped standing still still jitters, and the number is a
-- place to stand, not a survey mark.
Config.CoordDecimals = 2
