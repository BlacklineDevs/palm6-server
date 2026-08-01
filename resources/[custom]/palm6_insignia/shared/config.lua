-- ============================================================================
-- palm6_insignia/shared/config.lua
--
-- Officer identity on the uniform: NAME + BADGE NUMBER.
--
-- Read by both realms. The SERVER composes the two tape lines (it owns the
-- name, the rank and the badge number); the CLIENT only draws the strings it
-- was handed. That split is deliberate - a client that composed its own tape
-- could put any text it liked above its own ped.
--
-- ZERO world coordinates are authored in this file, and zero clothing
-- drawable/texture ids. Neither is needed: the tape is anchored to a ped BONE
-- (a skeleton constant, not a map position) and no garment is ever touched.
-- ============================================================================

Config = {}

-- Boot/diagnostic prints. Off in production.
Config.Debug = false

-- The qbx job name every gate in the palm6 police stack uses. Matches
-- palm6_pd_life/shared/config.lua:31.
Config.PoliceJob = 'police'

-- Department prefix printed on the tape's second line.
Config.Brand = 'PBPD'

-- ACE the badge-override command is gated on. The command itself is
-- registered UNRESTRICTED and refuses in its own handler unless the caller
-- holds this ace (console, src 0, always passes). Same shape as
-- palm6_pd_life's Config.PlacerAce, and it keeps the ace check server-side
-- where it cannot be bypassed.
--
-- REQUIRES a matching `add_ace group.admin command.setbadge allow` in
-- custom.cfg. Without it only group.owner can run /setbadge, via the blanket
-- `command` ace.
Config.AdminAce = 'command.setbadge'

-- ---------------------------------------------------------------------------
-- BADGE NUMBERS
--
-- WHY THIS RESOURCE OWNS THE NUMBER, instead of reusing something:
--   * qbx_police registers `/callsign` with NO gate at all - any officer can
--     set their own metadata.callsign to any string. A self-settable field is
--     not an authoritative badge number, and building on it would mean a
--     player could wear another officer's identity.
--   * Nothing in the palm6 custom layer had a badge or callsign concept before
--     this resource. palm6_mdt and palm6_pd_life were both read first; neither
--     stores one (palm6_mdt keys everything on citizenid, palm6_pd_life on
--     post ids). So this is the FIRST authority, not a competing second one.
--   * A qbx grade level is not unique (every patrol officer is grade 0), and a
--     citizenid is not a short human-readable number an officer can call over
--     the radio.
--
-- Consequence: palm6_insignia is the single authority, and it publishes
-- exports.palm6_insignia:GetBadge / GetBadgeByCitizenId / GetInsignia so a
-- future uniform, MDT or dispatch resource reads this number instead of
-- inventing a second one.
-- ---------------------------------------------------------------------------
Config.Badge = {
    -- Inclusive allocation range. The lowest FREE number in the range is
    -- assigned, so numbers stay short and human-readable and the roster reads
    -- like a real department rather than a set of database ids.
    Min = 100,
    Max = 999,

    -- Assign a number automatically the first time a police character is seen
    -- (spawn, promotion, duty change). With this off, an officer has no badge
    -- until an admin runs /setbadge, and the tape shows the name only.
    AutoAssign = true,

    -- A badge is bound to the CITIZENID and is kept across demotion, firing
    -- and rehire, so an officer who returns gets their old number back.
    --
    -- RETIREMENT, and why it exists.
    -- The claim "a number is never recycled" was false in the first revision.
    -- /setbadge moved a citizen to a new number and deleted the old one from
    -- both the in-memory taken set and (by UPDATE-ing the row) the database, so
    -- the next hire could be handed it by lowest-free allocation and every old
    -- MDT or citation record naming that number would then point at a different
    -- person. That is the precise failure the docs said could not happen.
    --
    -- With this on, a number that leaves a character is RETIRED: a tombstone
    -- row is written to palm6_officer_badges so the number stays taken across a
    -- restart, and lowest-free can never issue it again. The one exception is
    -- the original holder, who may be given their own retired number back by
    -- /setbadge, because that restores history rather than breaking it.
    --
    -- Turning this OFF makes /setbadge release the old number for reuse. Only
    -- do that if you accept that historical records naming that number become
    -- ambiguous. Tombstones already written stay honoured either way: they are
    -- rows, and boot loads them into the taken set without consulting this flag.
    RetireOnReassign = true,

    -- Bounded retries when a UNIQUE-key race means the number we picked was
    -- taken by another allocation in flight. Each retry picks the next free
    -- number. Five is far more than the number of concurrent joins this box
    -- can produce.
    MaxAllocAttempts = 5,

    -- Metres. /badge presents the card to players within this radius, using
    -- SERVER-read ped positions (never a client-supplied target).
    PresentRange = 6.0,

    -- How many nearby players one /badge may reach. Bounds the fan-out.
    PresentMaxTargets = 6,
}

-- ---------------------------------------------------------------------------
-- NAME ON THE TAPE
-- ---------------------------------------------------------------------------
Config.Name = {
    -- 'last'         -> OLVERSON
    -- 'initial_last' -> D. OLVERSON
    -- 'first_last'   -> DAVID OLVERSON
    Format = 'initial_last',

    Uppercase = true,

    -- Hard truncation. A long surname must not stretch the tape across half
    -- the screen, and the character allowlist below already drops anything
    -- exotic.
    MaxChars = 18,
}

-- ---------------------------------------------------------------------------
-- ROSTER PUBLICATION (server -> every client)
--
-- The roster is the ONLY way a client learns who is who. It contains one entry
-- per officer the server says is on duty: { id, l1, l2, badge }. A client
-- never sends identity up; it only ever receives it.
-- ---------------------------------------------------------------------------
Config.Roster = {
    -- Hard cap on published entries. The box is 48 slots, so this can never
    -- bind in practice; it exists so a framework bug that reports 500 police
    -- cannot turn one event into a large payload.
    MaxEntries = 48,

    -- Only publish officers whose job.onduty is true. Off-duty police are
    -- civilians in uniform terms, and an undercover officer must not be
    -- wearing a name tape.
    OnDutyOnly = true,

    -- Belt-and-braces reconcile. Every push is event-driven (load, job
    -- update, duty flip, drop); this tick re-derives the roster and pushes
    -- ONLY when the derived snapshot differs from the last one published, so
    -- a quiet server sends nothing. Set 0 to disable the tick entirely.
    ReconcileSec = 60,
}

-- ---------------------------------------------------------------------------
-- RENDER BUDGET (client)
--
-- THE BUDGET, STATED PLAINLY:
--   * The scan loop iterates the ROSTER (on-duty officers, <= MaxEntries),
--     never GetActivePlayers() and never every ped in the world. On a normal
--     shift that is under ten iterations, four times a second.
--   * The draw loop iterates a PRE-BUILT candidate list that the scan already
--     truncated to MaxTapes. So the per-frame cost is fixed at MaxTapes
--     regardless of how many officers or players exist.
--   * With the roster empty or no candidate in range, both loops fall back to
--     IdleIntervalMs and the resource costs nothing.
-- ---------------------------------------------------------------------------
Config.Render = {
    Enabled = true,

    -- Hard per-frame cap. Never draw more than this many tapes, whatever is
    -- on screen. The nearest MaxTapes officers win.
    MaxTapes = 5,

    -- Metres. Beyond this an officer has no tape at all. Sized so a tape is
    -- readable rather than a smear on the horizon.
    MaxDistance = 12.0,

    -- Candidate rebuild interval (ms) and the idle sleep used when there is
    -- nothing to draw.
    ScanIntervalMs = 250,
    IdleIntervalMs = 1000,

    -- Anchor bone, BY NAME, in preference order.
    --
    -- NO BONE NUMBER IS AUTHORED HERE, on purpose. A previous revision of this
    -- file hard-coded 24819 and claimed in a comment that it was SKEL_Spine3.
    -- It is not a ped bone at all, and nothing in the code could have noticed:
    -- a bad bone number resolves to the ped's origin and the tape lands at
    -- their feet with no error anywhere.
    --
    -- These are NAMES. bridge/cl_game.lua hands each one to
    -- GET_ENTITY_BONE_INDEX_BY_NAME against the ped actually standing there and
    -- takes the first that resolves; that native returns -1 for a name the
    -- model does not have, so the ENGINE decides, not this file. The list is
    -- walked in order, so an unusual ped skeleton falls back on its own.
    --
    -- If every name in the list fails, the tape is drawn at the ped's origin
    -- (their feet) and the client console prints a one-time warning naming the
    -- names it tried. That is the visible, reportable failure the in-game
    -- checklist asks David to look for.
    --
    -- /insigniabone <NAME> re-points this list on YOUR client only, live, so a
    -- wrong anchor can be corrected and captured in game rather than guessed.
    -- ABOVE THE HEAD, not on the chest.
    --
    -- This list used to start at SKEL_Spine3 with a forward offset, which was an
    -- attempt to make the text sit on the uniform like a real name tape. It does
    -- not read that way in practice: the text is flat billboarded 2D that always
    -- faces the camera, so anchored to the chest it looks like a label stuck to
    -- the torso and it swims as the ped turns. David's words were "ugly and
    -- plain and it sits very weirdly", and the weirdness is exactly that.
    -- A floating plate belongs where players already expect one, above the head.
    -- Real text ON the fabric needs an addon-DLC pack, see docs/CUSTOM-CLOTHING.md.
    BoneNames = {
        'SKEL_Head',
        'SKEL_Neck_1',
        'SKEL_Spine3',
        'SKEL_ROOT',
    },

    -- Offsets in metres, applied in WORLD space off the resolved bone:
    --   Forward -> along GET_ENTITY_FORWARD_VECTOR, the way the ped faces, so
    --              it pushes the tape out of the chest instead of into it.
    --   Up      -> along world Z.
    -- They are NOT bone-local. Bone-local axes in the GTA rig are not aligned
    -- with the ped's facing, so an offset expressed in them cannot be reasoned
    -- about from a config file. /insigniaoffset <forward> <up> tunes both live.
    -- No forward push now that the anchor is the head: the plate should float
    -- straight above, not out in front of the face. Up clears the tallest hats
    -- in the police roster (the campaign hat is the worst case) without leaving
    -- the plate detached from the player.
    OffsetForward = 0.0,
    OffsetUp = 0.38,

    -- Text style.
    Scale = 0.30,
    Font = 4,
    LineGap = 0.022,          -- screen-space gap between the two tape lines
    TextColour = { 244, 247, 252, 240 },
    PlateColour = { 12, 16, 24 },
    PlateAlpha = 190,
    PlatePadX = 0.010,
    PlatePadY = 0.007,

    -- A soft border drawn just outside the plate. Cheap way to lift it off a
    -- bright background (the PD forecourt is pale brick, which is where David
    -- screenshotted it looking washed out) without a texture asset.
    BorderColour = { 0, 0, 0 },
    BorderAlpha = 120,
    BorderX = 0.0035,
    BorderY = 0.005,

    -- Line 1 is the name, line 2 is the badge and rank. Drawing them at the same
    -- size and colour is what made it read as two rows of debug text, so line 2
    -- is smaller and takes the rank colour.
    NameScale = 1.0,
    SubScale  = 0.86,
    SubAlpha  = 235,

    -- The accent bar under the plate, in the rank colour. This is what makes
    -- rank readable at a glance before you can read any text.
    AccentHeight = 0.0035,

    -- RANK COLOURS, keyed by the rank name as it appears in the second line.
    -- Matched case-insensitively on a substring, so "Chief" catches "CHIEF" and
    -- "Deputy Chief". Anything unmatched uses Default, which is why an unknown
    -- rank degrades to a neutral plate rather than to no plate.
    --
    -- These are UI colours chosen for contrast against the dark plate, not an
    -- attempt to reproduce any real department's insignia.
    RankColours = {
        chief      = { 255, 196,  74 },   -- gold
        captain    = { 255, 196,  74 },
        lieutenant = { 122, 192, 255 },   -- light blue
        sergeant   = { 122, 192, 255 },
        corporal   = { 138, 226, 168 },   -- green
        officer    = { 214, 224, 238 },   -- near-white
        cadet      = { 178, 190, 206 },   -- grey
    },
    RankColourDefault = { 214, 224, 238 },

    -- Distance fade. Full strength until FadeStart (a fraction of MaxDistance),
    -- easing to FadeFloor at the edge. Never 0: a tape that disappears before
    -- the officer does reads as a bug rather than as distance.
    FadeStart = 0.55,
    FadeFloor = 0.35,

    -- Draw your OWN tape. Left ON so David can verify the feature solo, and
    -- because seeing your own tape is how a player learns the number exists.
    ShowOwn = true,

    -- Suppress your own tape in first person, where it would hang in the
    -- middle of the screen. Other officers' tapes are unaffected.
    HideOwnInFirstPerson = true,

    -- Skip an officer the camera cannot see. Cheap native, big saving in a
    -- crowded lobby.
    RequireOnScreen = true,
}

-- ---------------------------------------------------------------------------
-- Per-source cooldowns, in SECONDS. These are the resource's OWN floor and are
-- independent of palm6_eventguard: eventguard bounds the NET event, these
-- bound the command paths too, and either alone is enough to stop a spam loop.
-- ---------------------------------------------------------------------------
Config.RateLimits = {
    requestRoster = 3,
    badge = 5,
    mybadge = 3,
    setbadge = 1,
    insignia = 3,
}
