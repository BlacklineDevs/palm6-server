-- ============================================================================
-- palm6_uniform/shared/config.lua
--
-- Rank and season driven police uniforms.
--
-- THE ONE RULE THIS WHOLE RESOURCE EXISTS TO OBEY: not a single drawable or
-- texture id is authored anywhere in this repo. Every garment in the system
-- comes out of a real ped, in game, at capture time. The only integers below
-- are ENGINE CONSTANTS (which component slots exist, which prop slots exist)
-- and validation bounds, never a choice of clothing.
--
-- The reason is the same reason nobody here invents a world coordinate: a
-- drawable index is a position in a mount-ordered list (base game + official
-- DLC + every streamed addon pack). An id that merely looks plausible renders
-- as the wrong garment or as nothing at all, and there is no way to tell which
-- from outside the game.
-- ============================================================================

Config = {}

-- Master switch. Default ON so David can verify it in game. Turning this off
-- makes every command answer "disabled" and every automatic apply a no-op; it
-- does NOT undress anyone who is already wearing a uniform.
Config.Enabled = true

-- Extra console logging for the set-selection and apply decision path.
Config.Debug = false

-- ---------------------------------------------------------------------------
-- WHO THIS MAY EVER TOUCH
-- ---------------------------------------------------------------------------
-- POLICE ONLY, and that is enforced in three independent places, not just
-- here: server/main.lua re-derives the job from qbx_core before every single
-- apply, the capture command re-checks it, and the client refuses to apply a
-- payload whose ped model does not match. There is no code path in this
-- resource that reaches SetPedComponentVariation for a player whose
-- server-side job is not this string.
Config.PoliceJob = 'police'

-- The ACE that gates the whole admin family: /uniformcapture, /uniformshow,
-- /uniformlist, /uniformdelete, /uniformstatus, /uniformscramble,
-- /uniformseason, /uniformweather. One grant covers all eight because all
-- eight self-check this same string, which is the shape custom.cfg already
-- uses for the /placeped family and for /bizshell.
--
-- Every command in this resource is RegisterCommand(..., restricted = false)
-- and checks the ACE inside the handler. That is deliberate: a
-- RegisterCommand(..., true) with no add_ace line is runnable by group.owner
-- and by literally nobody else.
--
-- WITHOUT the matching `add_ace group.admin command.uniformcapture allow` line
-- in custom.cfg, only group.owner (via the blanket `add_ace group.owner
-- command allow` at custom.cfg:401) can run any of them. The audit's
-- command-aces check CANNOT see that gap, because it only reconciles
-- RESTRICTED commands against grants and none of these are restricted. So the
-- resource checks the grant itself at boot with IsPrincipalAceAllowed and
-- prints the exact missing line to the server console. See the BOOT block in
-- server/main.lua.
Config.AdminAce = 'command.uniformcapture'

-- The principals the boot check expects to hold Config.AdminAce. This list
-- drives a console warning only. It grants nothing and it cannot grant
-- anything: ACEs live in custom.cfg and nowhere else.
Config.ExpectedAcePrincipals = { 'group.admin' }

-- The two player-facing commands (/uniform and /uniformoff) take no ACE. They
-- are gated on being police, server-side, and they can only ever apply the
-- uniform the SERVER picks for the caller.
Config.PlayerCommand  = 'uniform'
Config.RestoreCommand = 'uniformoff'

-- ---------------------------------------------------------------------------
-- SEASON
-- ---------------------------------------------------------------------------
-- READ THIS BEFORE CHANGING ANYTHING BELOW.
--
-- GTA V and FiveM have NO built-in concept of a season. None. There is no
-- season native, no season event and no season field anywhere in the game or
-- in the CFX runtime. The closest thing is the in-game calendar
-- (GetClockMonth, client realm, 0-indexed), and that is NOT usable as an
-- authority here for two separate reasons:
--   1. it is client realm, so a modified client could report any month it
--      liked and dress itself in whatever uniform it wanted; and
--   2. the weather-sync resources that run on this kind of box only ever call
--      NetworkOverrideClockTime(hour, minute, second). None of them calls
--      SetClockDate, so the in-game calendar date is unmanaged and drifts.
--      It is display flavour, not state.
--
-- So the season is DERIVED, server-side, from the real-world date using the
-- schedule below. That is a config schedule and this comment is the promised
-- statement that it is one. Northern-hemisphere meteorological seasons, keyed
-- by the real month number 1-12 as returned by os.date('%m') on the server.
Config.SeasonByMonth = {
    [1]  = 'winter', [2]  = 'winter', [3]  = 'spring',
    [4]  = 'spring', [5]  = 'spring', [6]  = 'summer',
    [7]  = 'summer', [8]  = 'summer', [9]  = 'autumn',
    [10] = 'autumn', [11] = 'autumn', [12] = 'winter',
}

-- Pin the season to a fixed value, ignoring the schedule above. nil = use the
-- schedule. Must be one of Config.Seasons.
--
-- DO NOT edit this file to feel-test a season. Editing it needs
-- `restart palm6_uniform`, and a restart wipes the client-memory civilian
-- snapshot, which strands whoever is currently in uniform with nothing for
-- /uniformoff to put back. Use the in-game command instead:
--
--     /uniformseason winter      pin it, no restart
--     /uniformseason auto        hand it back to the schedule
--
-- This value is the BOOT DEFAULT for that runtime pin, nothing more.
Config.SeasonOverride = nil

-- Every season string a captured set is allowed to carry. 'any' is the
-- fallback bucket: a set stored as 'any' matches whatever the season is.
Config.Seasons = { 'any', 'winter', 'spring', 'summer', 'autumn' }

-- ---------------------------------------------------------------------------
-- WEATHER
-- ---------------------------------------------------------------------------
-- Weather IS a real game concept, but every weather native is client realm,
-- and a client-reported weather value is untrusted: spoof it and you pick
-- your own uniform. So the server reads it from the weather resource's
-- SERVER export instead. Neither weather resource lives in this repo, so the
-- call is soft (GetResourceState + pcall) and its absence is not an error -
-- with no weather resource running, every officer simply resolves to the
-- 'any' bucket and wears the season set.
--
-- Both qbx_weathersync and qb-weathersync expose getWeatherState() returning
-- the weather NAME as a string. Tried in order, first one running wins.
Config.WeatherResources = { 'qbx_weathersync', 'qb-weathersync' }

-- Weather NAMES that map to a bucket. EIGHT names are listed below. GTA V has
-- more weather names than that (CLEAR, CLOUDS, OVERCAST, FOGGY, SMOG, NEUTRAL
-- and the rest), and every one of them that is not listed here falls through
-- to 'any' on purpose. That is the whole design: only weather extreme enough
-- to justify a different garment gets its own bucket, because keying uniforms
-- on every weather name would mean a capture per name per rank per body, which
-- nobody will ever finish, and most of them would be missing on any given
-- night.
--
-- CLEARING -> 'wet' is a JUDGEMENT CALL, not a fact about the game. CLEARING
-- is the post-rain state, so the ground is still wet and a rain shell still
-- reads as sensible. If that looks wrong in game, move it to 'any' here; it
-- changes nothing else.
Config.WeatherBuckets = {
    ['RAIN']      = 'wet',
    ['THUNDER']   = 'wet',
    ['CLEARING']  = 'wet',
    ['SNOW']      = 'cold',
    ['SNOWLIGHT'] = 'cold',
    ['BLIZZARD']  = 'cold',
    ['XMAS']      = 'cold',
    ['EXTRASUNNY'] = 'hot',
}

-- Every weather bucket a captured set is allowed to carry.
Config.Weathers = { 'any', 'wet', 'cold', 'hot' }

-- Pin the weather bucket, ignoring the live weather. nil = read it live.
-- Same rule as Config.SeasonOverride: this is only the BOOT DEFAULT. To pin it
-- while the server is up, use /uniformweather <bucket|auto>, which needs no
-- restart and therefore cannot strand an officer mid-shift.
Config.WeatherOverride = nil

-- How often the server re-derives (season, weather bucket). When the pair
-- CHANGES, every on-duty officer is re-dressed. Nothing happens on a tick
-- where the pair is unchanged, so this is cheap.
Config.VariantTickSeconds = 120

-- ---------------------------------------------------------------------------
-- WHEN THE UNIFORM IS APPLIED
-- ---------------------------------------------------------------------------
-- AUTOMATIC applies (duty, promotion, spawn, season tick) all require the
-- player to be police AND ON DUTY. The MANUAL /uniform command requires police
-- but not duty, because it is an explicit request from the officer themselves.
-- Neither path can ever reach a player whose server-side job is not
-- Config.PoliceJob.
Config.ApplyOnDuty      = true   -- going ON duty as police dresses you
Config.RestoreOffDuty   = true   -- going OFF duty puts your civilian look back
Config.ApplyOnPromotion = true   -- a grade change re-dresses you, no relog
Config.ApplyOnSpawn     = true   -- an officer who relogs WHILE ON DUTY comes
                                 -- back dressed. An officer who went off duty
                                 -- first spawns in their civilian clothes,
                                 -- because the on-duty test above fails. This
                                 -- resource never writes a saved skin, so the
                                 -- civilian look is never at risk either way.

-- ---------------------------------------------------------------------------
-- ENGINE CONSTANTS. Not clothing choices - these are which slots exist.
-- ---------------------------------------------------------------------------
-- The twelve ped component slots. 0 head, 1 mask, 2 hair, 3 torso/arms,
-- 4 legs, 5 bag, 6 shoes, 7 accessory, 8 undershirt, 9 vest, 10 decals,
-- 11 tops/jacket.
Config.ComponentIds = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }

-- The prop slots a freemode outfit uses. 0 hat, 1 glasses, 2 ears, 6 watch,
-- 7 bracelet. 3/4/5 are unused on freemode peds.
Config.PropIds = { 0, 1, 2, 6, 7 }

-- Face (0) and hair (2) are NEVER written by a uniform. A uniform changes
-- what an officer wears, not who they are, and overwriting hair on duty is
-- the single most complained-about bug in every job-outfit script. These
-- slots are still CAPTURED (so a stored set is a complete record of the ped)
-- and simply skipped on apply.
Config.SkipComponents = { [0] = true, [2] = true }

-- The only two ped models a captured set may belong to.
--
-- mp_m_freemode_01 and mp_f_freemode_01 have COMPLETELY DISJOINT drawable
-- index spaces. The same integer is a different garment on each body, and the
-- per-slot counts differ. A male capture applied to a female ped renders as
-- the wrong clothing or as nothing. So the model is stored with every set,
-- it is part of the unique key, and both the server and the client refuse to
-- apply a set whose model does not match the wearer. Every uniform therefore
-- has to be captured TWICE, once on each body. That is not a limitation of
-- this resource, it is how the game works.
Config.Models = { 'mp_m_freemode_01', 'mp_f_freemode_01' }

-- Validation bounds for a capture payload. A payload outside these is
-- REJECTED, never clamped: an out-of-range value means a modified client, and
-- "fixing up" it would persist a lie. These are generous upper bounds chosen
-- to be far above any real index while still refusing obvious garbage.
Config.MaxDrawable = 2048
Config.MaxTexture  = 256

-- ---------------------------------------------------------------------------
-- RATE LIMITS (seconds between accepted calls, per source)
-- ---------------------------------------------------------------------------
-- These are the resource's OWN limits and they run inside the handler. The
-- palm6_eventguard budgets requested in README.md are a separate, blunter
-- outer bound that runs BEFORE the handler; neither replaces the other.
--
-- EVERY refusal on one of these limits SAYS SO, in chat, to the person who was
-- refused. A silent drop is indistinguishable from a broken command, and the
-- person on the other end reports it as a bug. See rlGate() in server/main.lua.
--
-- One key is deliberately still silent: `requestApply`. That event is raised by
-- the client by itself on spawn, so a refusal there is not a person being told
-- no, and answering it would let a modified client spam its own chat. The
-- justification is written at the call site too.
--
-- captureReply is DELIBERATELY a different key from capture. They used to be
-- one, and that was a bug: /uniformcapture consumed the budget and the
-- client's snapshot arrived a fraction of a second later against the same key,
-- so every capture was silently thrown away by its own rate limit. The reply
-- is additionally gated by a single-use server-minted token, so its budget
-- only has to bound a flood of unsolicited garbage.
--
-- `show` is ALSO deliberately its own key, and for the same class of reason.
-- /uniformshow and /uniformcapture used to share `capture`, and the documented
-- workflow runs them back to back. Anyone reading a numbered list types them
-- inside three seconds, so the capture was refused by the rate limit its own
-- sanity check had just consumed. /uniformshow stores nothing, so it does not
-- belong on the write budget at all.
-- The same reasoning splits /uniform and /uniformoff onto their own keys. They
-- used to share `command` with each other AND with the admin read commands, so
-- /uniform straight after /uniformoff, or /uniform straight after
-- /uniformseason, was refused. Every one of those pairs is a sequence the
-- checklist asks for on purpose, and none of them is abuse.
Config.RateLimits = {
    capture      = 3,   -- /uniformcapture, the command half of a WRITE
    show         = 1,   -- /uniformshow, read only, stores nothing
    captureReply = 1,   -- the snapshot coming back from the client
    requestApply = 5,   -- the client asking "dress me"
    scramble     = 2,   -- /uniformscramble, the visible-change test tool
    apply        = 2,   -- /uniform
    restore      = 2,   -- /uniformoff
    command      = 2,   -- every other command
}

-- How long a capture token stays valid after the command is run. The client
-- has to snapshot the ped and send it back inside this window or the reply is
-- dropped. Long enough for a laggy client, short enough that a stale token
-- cannot be replayed later.
Config.CaptureTokenTTL = 30
