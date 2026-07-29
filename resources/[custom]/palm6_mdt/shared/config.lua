-- ============================================================================
-- palm6_mdt/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to VI). The MDT is the police-side READER for the systems the city
-- already runs: palm6_evidence case files surface here, BOLOs and written
-- reports are filed here. qbx_police_overrides published the MDT contract
-- (Config.MDT via its GetMDT export) with no implementation behind it —
-- this resource is that implementation, and it honours GetMDT() values
-- when the override resource is running.
-- ============================================================================
Config = {}

Config.Debug = false

-- The item an officer must be carrying to use any MDT command. Already in
-- qbx_police_overrides' LoadoutAllowed and sold at the armoury shop —
-- until this resource existed, nothing consumed it.
Config.TabletItem = 'mdt_tablet'

-- Fallbacks for the qbx_police_overrides GetMDT() contract, used only when
-- that resource is not running. Keys mirror its Config.MDT exactly.
Config.MDTDefaults = {
    enabled = true,
    bolo_default_duration_minutes = 60,
    report_min_chars = 20,
}

-- BOLO text bounds (chars).
Config.Bolo = {
    MinChars = 5,
    MaxChars = 140,
    ListLimit = 8,     -- /bolos shows at most this many active entries
}

-- Case browsing.
Config.Cases = {
    ListLimit = 10,    -- /mdtcases shows at most this many open cases
    EntryLines = 5,    -- /mdtcase shows at most this many recent entries
    EntryTrim = 100,   -- each entry line trimmed to this many chars
}

-- Report body upper bound (lower bound comes from the GetMDT contract).
Config.ReportMaxChars = 1000

-- Warrants + bookings (v0.2.0). The recipe's qbx_police owns the
-- PHYSICAL side (/cuff /jail) — this is the paper trail on top of it.
Config.Warrants = {
    ReasonMinChars = 5,
    ReasonMaxChars = 200,
    ListLimit      = 8,
    ChargesMin     = 5,     -- /book charges text bounds
    ChargesMax     = 500,

    -- Require the booked citizen to be ONLINE and within PresenceRadius of the
    -- booking officer. SHIPS DARK (false) - flip after a feel-test. Booking
    -- happens at a desk with the suspect already cuffed by qbx_police, so the
    -- radius is deliberately generous: it exists to stop desk-booking someone
    -- on the other side of the map, not to demand pixel proximity.
    -- Deliberately NOT applied to /warrant: a warrant is an order issued IN
    -- ABSENTIA on someone you could not find, so a presence gate there would
    -- break the feature rather than harden it.
    RequirePresence = false,
    PresenceRadius  = 12.0,
}

-- ---------------------------------------------------------------------------
-- Charge catalogue + sentence calculator (v0.4.0). SHIPS OFF (Enabled=false).
--
-- SCOPE, STATED HONESTLY: this repo cannot jail anybody. qbx_police owns the
-- PHYSICAL side (/cuff, /jail) and is NOT in this repo — it lives on the game
-- box. What IS ownable here is the PAPERWORK: a structured charge list, a
-- deterministic recommendation derived from it, and a review step a human can
-- read. Nothing below puts a player in a cell, moves money, or changes a
-- booking. It is a read-only advisory layer that a human then acts on.
--
-- Free-text charges are UNCHANGED. /book still takes prose bounded only by
-- ChargesMin/ChargesMax above, and always will: the catalogue is an ADDITIONAL
-- vocabulary an officer may optionally use, never a replacement. With
-- Enabled=false nothing here is registered or reachable at all.
-- ---------------------------------------------------------------------------
Config.Charges = {
    -- Master flag. false = /charges is not registered, and the
    -- CalculateSentence / RecommendForBooking exports return nil. Existing
    -- behaviour is bit-for-bit unchanged.
    Enabled = false,

    -- Command name for the in-game catalogue reader. Configurable for the same
    -- reason Config.Identify.Command is: the live box runs ~157 resources this
    -- repo cannot see and the LAST resource to RegisterCommand a name wins.
    Command = 'charges',

    -- PURE LABEL. Nothing in this repo converts this number into game time —
    -- see the qbx_police handoff note in README.md. The operator wiring the
    -- physical side must confirm what unit their jail command actually takes
    -- before mapping a recommendation onto it. Changing this string changes
    -- display text and nothing else.
    SentenceUnit = 'months',

    -- ARITHMETIC. All three are INTEGER PERCENTAGES on purpose: the whole
    -- calculation runs in integer hundredths and rounds once at the end, so
    -- there is no floating point anywhere in the result and the same inputs
    -- always produce the same output on any machine.
    --
    -- ConcurrentPct: concurrent sentencing. The single most serious charge is
    -- served in full; every other charge in the same booking is served at this
    -- percentage of its base. This is why stacking six petty charges does not
    -- out-sentence one murder.
    ConcurrentPct = 50,

    -- Fines are CUMULATIVE, not concurrent, and priors do NOT multiply them.
    -- Deliberate: time is the escalating penalty, money is a fixed schedule.
    -- A player can read the catalogue and predict their fine exactly.

    -- PriorsStepPct: each prior unsealed booking adds this many percent to the
    -- TIME subtotal only. PriorsCap bounds how many priors can ever count, so
    -- the multiplier tops out at 100 + PriorsCap * PriorsStepPct percent
    -- (default 150%). Without the cap a long-lived character would drift into
    -- permanent maximum sentences with no way back.
    PriorsStepPct = 10,
    PriorsCap     = 5,

    -- Hard bounds on the recommendation. MaxSentence is the real anti-runaway:
    -- no combination of charges and priors can ever recommend more than this.
    MinSentence = 1,
    MaxSentence = 120,
    MaxFine     = 250000,

    -- Most charges accepted in one calculation. Bounds both the arithmetic and
    -- the number of chat lines a single command can emit.
    MaxCodes = 10,

    -- Display order for /charges.
    ClassOrder = { 'infraction', 'misdemeanor', 'felony' },

    -- THE CATALOGUE. code (lowercase, no spaces — it is typed in chat), label
    -- (what a human reads), class, base sentence, base fine.
    --
    -- Codes are stable identifiers: renaming one silently changes what every
    -- previously-typed charge string means, so add new codes rather than
    -- repurposing old ones. Numbers below are a STARTING SCHEDULE, not a
    -- balance pass — they are ordered sanely relative to each other and are
    -- meant to be tuned by whoever runs the city.
    Catalogue = {
        -- infractions
        { code = 'trespass',      label = 'Criminal Trespass',                 class = 'infraction',   sentence = 1,  fine = 500 },
        { code = 'disorder',      label = 'Disorderly Conduct',                class = 'infraction',   sentence = 1,  fine = 750 },
        { code = 'obstruct',      label = 'Obstruction of Justice',            class = 'infraction',   sentence = 2,  fine = 1000 },
        -- misdemeanors
        { code = 'theft_petty',   label = 'Petty Theft',                       class = 'misdemeanor',  sentence = 4,  fine = 1500 },
        { code = 'evade',         label = 'Evading a Peace Officer',           class = 'misdemeanor',  sentence = 5,  fine = 2500 },
        { code = 'poss_ctrl',     label = 'Possession of a Controlled Substance', class = 'misdemeanor', sentence = 5, fine = 2000 },
        { code = 'weapon_unlic',  label = 'Unlicensed Firearm',                class = 'misdemeanor',  sentence = 6,  fine = 4000 },
        { code = 'assault',       label = 'Assault',                           class = 'misdemeanor',  sentence = 8,  fine = 3000 },
        { code = 'burglary',      label = 'Burglary',                          class = 'misdemeanor',  sentence = 10, fine = 5000 },
        -- felonies
        { code = 'gta',           label = 'Grand Theft Auto',                  class = 'felony',       sentence = 15, fine = 7500 },
        { code = 'leo_assault',   label = 'Assault on a Peace Officer',        class = 'felony',       sentence = 20, fine = 10000 },
        { code = 'robbery_armed', label = 'Armed Robbery',                     class = 'felony',       sentence = 25, fine = 12000 },
        { code = 'traff_ctrl',    label = 'Trafficking a Controlled Substance', class = 'felony',      sentence = 30, fine = 15000 },
        { code = 'kidnap',        label = 'Kidnapping',                        class = 'felony',       sentence = 35, fine = 20000 },
        { code = 'bank_robbery',  label = 'Bank Robbery',                      class = 'felony',       sentence = 45, fine = 25000 },
        { code = 'murder_2',      label = 'Murder (Second Degree)',            class = 'felony',       sentence = 60, fine = 40000 },
        { code = 'murder_1',      label = 'Murder (First Degree)',             class = 'felony',       sentence = 90, fine = 60000 },
    },
}

-- Suspect identification (/id). The single missing rung in the justice ladder:
-- /warrant and /book wanted a raw citizenid an officer had no in-game way to
-- learn, so everything downstream of an arrest was unusable. /id is
-- server-authoritative by construction - the officer sends NOTHING, the server
-- re-derives the nearest ped from its own entity positions.
Config.Identify = {
    -- Kill switch, same shape as Config.RunPlate.Enabled. `/id` is a common
    -- name in the wider FiveM ecosystem and the live box runs ~157 resources
    -- this repo cannot see; the LAST resource to RegisterCommand a name wins,
    -- and those ~157 all start after palm6_mdt. If another resource's /id is
    -- the one an operator wants, rename via Command below or switch this off
    -- here - neither needs a code change.
    Enabled = true,
    -- Command name. Configurable because `/id` is a common name in the wider
    -- FiveM ecosystem and the live box runs ~157 resources this repo cannot
    -- see; rename here if it ever collides.
    Command = 'id',
    Radius  = 4.0,   -- metres: close enough to be talking to them
}

-- /runplate - the police counterplay to the chop-shop registry. Read-only.
Config.RunPlate = {
    Enabled     = true,
    MaxLen      = 12,   -- GTA plates are 8 chars; a little slack, then reject
}

-- Dispatch call history (v0.3.0) — a passive recorder on the recipe's
-- central police:server:policeAlert funnel. The recipe notifies on-duty
-- officers and forgets; /calls reads the log back.
Config.Calls = {
    Enabled        = true,
    TextMax        = 140,   -- alert text stored/displayed at most this long
    PerSourceCdSec = 5,     -- one logged alert per reporting source per window
    ListDefault    = 8,     -- /calls default rows
    ListMax        = 20,    -- /calls [n] cap
    RetentionDays  = 7,     -- prune rows older than this (boot + every 12h)

    -- SHIPS OFF, deliberately. A row in /calls is a persistent police record
    -- and police:server:policeAlert is net-registered, so a client CAN raise
    -- it. But the loudest producers on that event raise it from the client BY
    -- DESIGN: qbx_storerobbery's client-side alertPolice(), plus houserobbery,
    -- jewellery and bankrobbery (named in palm6_witnesses/server/main.lua
    -- :481-484, which reasoned the same trust boundary out first, and in
    -- palm6_eventguard's own sizing note on this event key). Those four are
    -- the marquee content of a dispatch log. DROPPING client-raised alerts
    -- would empty /calls of exactly the calls officers care about, so the
    -- recorder logs them and STAMPS them instead: a client-raised call gets
    -- `unverified` in its src_label, so /calls shows at a glance which rows
    -- came from a trusted server-side producer and which crossed the net
    -- boundary and could have been fabricated. Content kept, caveat kept.
    --
    -- The forged-flood threat is bounded outside this flag, not by it:
    -- palm6_eventguard budgets police:server:policeAlert for CLIENT raises
    -- only (its guard() exempts server-side raises), and PerSourceCdSec above
    -- puts a second per-source floor under the insert. A scripted flood cannot
    -- outrun either, which is why "unlimited fabricated rows" was never the
    -- real exposure.
    --
    -- Turn this ON only if you decide an unverified row is worth less than no
    -- row at all. Then a client-raised alert writes nothing, still reaches the
    -- recipe's own notify path (separate registration, never cancelled, so
    -- dispatch still pings), and prints a throttled console line naming the
    -- dropped text so a legitimate client-side producer stays discoverable.
    --
    -- Provenance is inferred from the event's `source` (nil / <= 0 / 65535 =
    -- server-raised), the same predicate palm6_witnesses uses on this event.
    -- All seven in-repo producers raise it with a server-side TriggerEvent, so
    -- they read as verified; the out-of-repo qbx robberies read as unverified.
    RequireServerProvenance = false,
}

-- ---------------------------------------------------------------------------
-- Heat-aware dispatch priority (v0.5.0). SHIPS OFF (Enabled = false).
--
-- palm6_heat has carried Config.DispatchPriorityTier = 'HOT' since it was
-- written, pointing at a dispatch consumer that did not exist. This block is
-- that consumer. There is no new resource and no new table: /calls is already
-- the city's dispatch surface, so the priority read lands here.
--
-- DERIVED AT READ TIME, ON PURPOSE. Nothing is written when a call is
-- recorded and palm6_mdt_calls gains no column. Three reasons, in order of
-- weight:
--   1. The recorder is the one path a live player can reach without an officer
--      present. Leaving recordCall byte-for-byte untouched means this feature
--      cannot break the 911 log even if every assumption below is wrong.
--   2. A stored flag would be a snapshot of the heat a citizen had at 03:12 and
--      would still say WANTED an hour after they cooled off. Heat is a decaying
--      number whose whole point is that it moves; a persisted copy of it is
--      stale the moment it is written. Read time is the only time the answer is
--      true.
--   3. No schema change means no MariaDB-only ALTER, no sql/ migration to apply
--      by hand on a box nobody is testing, and no half-migrated state.
-- The cost is that the flag answers "is this caller dangerous NOW", not "were
-- they dangerous when they called". For an officer scanning a live board that
-- is the more useful question, but it IS a different question, and an operator
-- who wants the historical answer needs the column after all.
--
-- WHICH CITIZEN A CALL BELONGS TO: only the alert recorder attributes a row to
-- a person, and it does so in src_label as `citizen <cid>`. Rows from the
-- LogCall export (palm6_tips' `anonymous`, palm6_brain's bus label) name no
-- citizen and are therefore never priority. That is correct, not a gap: an
-- anonymous tip has no caller to be hot.
--
-- SOFT DEP. palm6_heat is read only through its frozen GetTier export, behind
-- the house GetResourceState + pcall guard. If palm6_heat is stopped, still
-- booting, or throwing, every call is simply normal priority and /calls prints
-- exactly what it prints today. palm6_heat is deliberately NOT added to this
-- resource's fxmanifest dependencies: a hard dependency would stop the whole
-- MDT booting over an optional flag, which is a far worse failure than a
-- missing marker.
-- ---------------------------------------------------------------------------
Config.CallPriority = {
    -- Master flag. false = /calls does not read heat at all and its output is
    -- bit-for-bit the v0.4.0 output.
    Enabled = false,

    -- The palm6_heat tier strings that count as priority, as a SET.
    --
    -- A set rather than a ">= this tier" comparison because the tier ladder
    -- lives in palm6_heat's Config.Tiers, which this resource cannot read (a
    -- separate resource is a separate Lua state), so there is no ordinal here
    -- to compare against and inventing one would mean duplicating a ladder that
    -- could then drift. Same shape palm6_laundering's Config.HeatScrutiny keys
    -- its surcharge on, for the same reason.
    --
    -- This is the wired meaning of palm6_heat's Config.DispatchPriorityTier =
    -- 'HOT', i.e. HOT and everything above it. palm6_heat currently ships five
    -- tiers (CLEAN, COOL, WARM, HOT, WANTED); if a tier above HOT is ever added
    -- there, add it here too or it will not be treated as priority.
    Tiers = { HOT = true, WANTED = true },

    -- Prefix stamped on a priority row in /calls, followed by one space. Rows
    -- that are not priority are printed unchanged, so a board with no hot
    -- callers looks exactly as it does today.
    Marker = '[PRIORITY]',

    -- Float priority rows to the top of the SAME result set. This re-orders the
    -- n rows /calls already fetched; it never pulls a row in or pushes one out,
    -- so nothing disappears from the board. Order within each group stays
    -- newest-first. Set false to keep strict newest-first and rely on the
    -- marker alone.
    SortFirst = true,

    -- Memoise a citizen's tier this long (seconds). /calls can list up to
    -- Config.Calls.ListMax rows and GetTier is one indexed DB read each, so
    -- without this a board full of distinct callers is that many round trips
    -- every time any officer types the command.
    --
    -- Staleness is bounded and small: palm6_heat sheds Config.DecayPerMin (0.75
    -- as shipped) points per minute, so 30s of cache is at most ~0.4 points of
    -- drift against tier bands that are 29 points wide at their narrowest. Set
    -- 0 to disable the cache and read live every time.
    TierCacheSec = 30,

    -- Hard ceiling on heat lookups per /calls invocation. Distinct citizens
    -- beyond this many in one listing are left unflagged rather than costing
    -- another DB read. Default matches Config.Calls.ListMax, so under the
    -- shipped config it never truncates anything.
    MaxLookups = 20,
}

-- Per-source command cooldowns (seconds).
Config.RateLimits = {
    mdt          = 2,
    bolo         = 10,
    bolos        = 2,
    boloclear    = 2,
    mdtcases     = 2,
    mdtcase      = 2,
    mdtreport    = 10,
    warrant      = 10,
    warrants     = 2,
    warrantclear = 2,
    book         = 10,
    calls        = 2,
    id           = 3,
    runplate     = 3,
    charges      = 5,
}
