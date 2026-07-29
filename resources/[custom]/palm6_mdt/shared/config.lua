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
}
