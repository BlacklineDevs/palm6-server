-- ============================================================================
-- palm6_charselect/shared/config.lua
--
-- Tunables shared between client and server. Nothing here calls a native,
-- a framework export, or touches NUI directly - pure data.
-- ============================================================================

Config = {}

-- OUR OWN pre-submit UX guardrail on the name/DOB fields - NOT synced to
-- qbx_core in any way. Verified against the live qbx_core source
-- (server/character.lua's sanitizeNewCharInfo): its own server-side rule is
-- just "non-empty string, <=50 chars" for firstname/lastname/nationality, no
-- letter-only regex, no length floor, no DOB bound at all. These tighter
-- client-side rules exist purely so a player gets fast, friendly feedback
-- ("letters only", "must be 1960-2006") before the round trip, not because
-- qbx_core enforces them - it will happily accept whatever passes ITS rule
-- even if it fails this one first (this UI just never lets that submit).
Config.NameRules = {
    regex = "^[A-Za-z][A-Za-z%-' ]+$",
    minLen = 2,
    maxLen = 24,
    dobMinYear = 1960,
    dobMaxYear = 2006,
}

-- Card entrance stagger. Card N's CSS animation-delay = BaseDelayMs + (N * StepMs).
Config.EntranceBaseDelayMs = 120
Config.EntranceStepMs = 80

-- Hover-tilt clamp, degrees, applied as rotateX/rotateY via JS pointermove.
Config.CardTiltMaxDeg = 9

-- Cinematic camera swap duration on character select (matches CSS 180ms
-- panel motion x this multiplier so the camera settles just after the UI does).
Config.SelectCameraDurationMs = 900

-- Default scene camera. NOT a guess: (-540.58, -212.02, 37.65) is qbx_core's
-- OWN `defaultSpawn` coordinate (config/shared.lua, near Legion Square) -
-- the exact point qbx_core itself considers safe to place a freshly-loaded
-- player. Reused here rather than inventing a separate "menu camera" spot,
-- since it's the one coordinate this repo can cite a real source for. Still
-- worth an in-game look before the first live ensure (a safe SPAWN point
-- isn't necessarily a good CAMERA angle - crowds/traffic at that exact spot
-- are plausible even if it's not the ocean floor), but this is no longer a
-- placeholder that forces a broken default if nobody replaces it.
Config.SceneCamera = {
    pos = vector3(-540.58, -212.02, 39.5),
    lookAt = vector3(-540.58, -208.0, 37.65),
    fov = 45.0,
}

-- Same coordinate, heading included (matches qbx_core's defaultSpawn vec4
-- exactly) - used for the actual character SPAWN, not just the camera. See
-- client/main.lua's spawn handling. An EXISTING character's saved position
-- (returned by Game.GetCharacters, qbx_core's own `players.position` column)
-- is used instead of this whenever one is available; this is the
-- new-character / no-saved-position fallback only.
Config.DefaultSpawn = vector4(-540.58, -212.02, 37.65, 208.88)

-- "Cinematic" select swap: NOT a move to a different location (this
-- resource has no per-character world position to cut to, and guessing one
-- would be worse than not pretending to). It's a push-in on the SAME scene
-- camera - distance/FOV pulled toward the selected card's on-screen
-- position - so PlaySelectCinematic's interp target is genuinely different
-- from sceneCam instead of two identical cameras (which is what shipped
-- originally: the interp had nothing to move between).
Config.SelectZoomDistance = 0.55   -- fraction of the pos->lookAt distance to close on select
Config.SelectZoomFov = 32.0

-- ---------------------------------------------------------------------------
-- Character preview stage
--
-- The one feature every premium multicharacter script on the market has and
-- this screen did not: the actual character standing in front of you while you
-- pick, instead of a card with their initials in a circle. The ped-preview
-- primitives (Game.SpawnPreviewPed/DestroyPreviewPed) already existed here and
-- were never called by anything.
--
-- Nothing below authors a world coordinate. The ped stands at
-- Config.SceneCamera.lookAt - the point the camera is already pointed at, by
-- construction the middle of the frame - snapped down onto whatever the ground
-- probe reports there. If the probe finds no ground (world not streamed in
-- yet, or the camera got moved somewhere with no surface under it), NO ped is
-- spawned and the screen falls back to exactly the lettered-silhouette cards
-- it showed before. A preview that can't be placed honestly is not placed.
-- ---------------------------------------------------------------------------
Config.PreviewStage = {
    enabled = true,

    -- Ground probe. Starts above the framed point and looks down; retried
    -- while collision streams in around a freshly-connected client.
    probeHeightAbove = 5.0,
    probeAttempts = 20,
    probeIntervalMs = 100,

    -- Hovering across a row of cards must not spawn a ped per card.
    switchDebounceMs = 120,

    -- Deterministic lighting so the same character does not look like a
    -- silhouette at 03:00 and washed out at noon. Client-local overrides,
    -- cleared on every teardown path (see Game.ClearStageEnvironment).
    lockEnvironment = true,
    clockHour = 14,
    clockMinute = 20,
    weather = 'EXTRASUNNY',

    -- Slow turntable. A character standing dead still reads as a mannequin;
    -- every premium select screen rotates the ped so you can see the outfit.
    -- Degrees per second, applied by a render thread that stops the moment the
    -- ped is destroyed. Deliberately slow - this is ambient motion, not a
    -- spin - and it starts from the heading that faces the camera so the
    -- character is looking at the player when they arrive.
    turntable = true,
    turntableDegreesPerSecond = 7.0,
}

-- Spawn protection, two separate windows (see Game.StartTutorialProtection).
--
-- `soloSessionMs` is how long the player stays in a SOLO NETWORK INSTANCE while
-- the ped is placed. Keep it short: for its whole duration the player cannot
-- see, or be seen by, anybody else on the server. It must always end — a
-- version of this resource that never ended it made every player permanently
-- invisible to every other player.
--
-- `invincibleMs` is the longer fall/traffic settle window, and costs nothing
-- socially because it does not instance the player.
Config.SpawnProtection = {
    soloSessionMs = 2000,
    invincibleMs = 10000,
}

-- How often a running play session is banked to the database. The flush exists
-- because a crash or a hard kill never fires playerDropped, so without it an
-- unclean shutdown would lose every session since the last restart. Five
-- minutes bounds that loss without writing on a hot path.
Config.PlaytimeFlushIntervalMs = 300000

Config.NUI = {
    resourceName = 'palm6_charselect',
    closeAnimationMs = 180,
}
