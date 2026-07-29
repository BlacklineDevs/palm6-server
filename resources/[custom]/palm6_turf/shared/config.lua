-- ============================================================================
-- palm6_turf/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
--
-- The Phase 6 roadmap candidate "faction reputation tracker"
-- (docs/BUILD-ROADMAP.md) — never built. qbx_core has gangs as a
-- first-class primitive (PlayerData.gang, /setgang) but no gameplay was
-- ever layered on top of it. Reputation here = turf zones held.
-- ============================================================================
Config = {}

Config.Debug = false

Config.InteractRadius = 3.0
Config.TagProgressMs = 8000

-- Zone coords reuse already-validated ground-level points from elsewhere
-- in this repo (spawn / shop / robbery locations) rather than new,
-- unverified coordinates — same city-wide spread, zero placement risk.
Config.Zones = {
    { id = 'legion_square', label = 'Legion Square',  coords = vector3(195.17, -933.77, 30.69) },
    { id = 'grove_street',  label = 'Grove Street',    coords = vector3(-47.30, -1757.40, 29.42) },
    { id = 'mirror_park',   label = 'Mirror Park',     coords = vector3(1163.10, -322.90, 69.20) },
    { id = 'vinewood',      label = 'Vinewood',        coords = vector3(-1222.10, -906.90, 12.33) },
    { id = 'sandy_shores',  label = 'Sandy Shores',    coords = vector3(1961.30, 3740.30, 32.34) },
    { id = 'paleto_bay',    label = 'Paleto Bay',      coords = vector3(1728.66, 6414.16, 35.04) },
}

-- Blip sprite/colour for an owned zone vs. unclaimed. GTA V native ids —
-- see docs/GTA6-TIER3-RETUNE.md §7 (blip sprites & colours).
Config.BlipSprite = 84
Config.UnclaimedColour = 0   -- white
Config.ClaimedColour = 1     -- red-ish; per-gang colour is deferred to v2
Config.BlipScale = 0.8

-- Reputation (palm6_gangs) awarded for a genuine turf TAKEOVER — capturing a
-- zone that a DIFFERENT player-run gang currently holds. Not granted for
-- claiming unowned turf. Bounded per-zone by RepCooldownSec so two gangs can't
-- ping-pong a single zone to farm rep. Set RepPerCapture = 0 to disable.
Config.RepPerCapture = 10
Config.RepCooldownSec = 600   -- a given zone can mint rep at most once / 10 min

-- ---------------------------------------------------------------------------
-- TURF CONFLICT (v2). SHIPS OFF.
--
-- With Enabled = false NOTHING below is read and the tag flow is exactly what
-- it has always been: walk up, hold [E] for TagProgressMs, the zone flips
-- instantly whether or not a rival gang held it. Every Conflict guard in
-- server/main.lua is written as `if Config.Conflict.Enabled and ...` so the
-- short-circuit skips it entirely.
--
-- With Enabled = true, tagging a zone a RIVAL gang holds no longer flips it.
-- It OPENS a contest: the defending gang is notified and the zone flips only
-- if the attacking gang accumulates HoldSeconds of net presence inside the
-- zone before the window expires. Claiming an UNOWNED zone stays instant,
-- because there is no defender to give a window to.
--
-- NOTHING here has been feel-tested in game. Every number is a starting point.
-- ---------------------------------------------------------------------------
Config.Conflict = {
    Enabled = false,

    -- Window length. The contest is abandoned (defender keeps the zone) if the
    -- attacker has not banked HoldSeconds of net presence by ContestSeconds.
    ContestSeconds = 300,
    HoldSeconds    = 120,
    TickSeconds    = 5,

    -- Presence radius around the zone center. This is a RADIUS, not a world
    -- position: no coordinate is authored anywhere in this feature. Deliberately
    -- much wider than InteractRadius (3.0, a single tagging point) so defenders
    -- do not have to stand on the exact spray spot to contest, and much tighter
    -- than palm6_protection's OwnedZoneRadius (200.0, a whole neighbourhood) so
    -- traffic driving past a zone is not counted as a defender. Untested feel.
    Radius = 50.0,

    -- Progress rules, in MEASURED wall seconds of net hold. There is
    -- deliberately NO count bonus: 6 attackers bank progress at exactly the same
    -- rate as 1. Numbers decide WHETHER you hold the zone, never HOW FAST, so
    -- stacking alts buys nothing on the clock.
    --
    -- "Measured" is load-bearing. The ticker resolves gang identity through a DB
    -- read and processes every live contest on one thread, so a pass takes
    -- longer than TickSeconds exactly when a fight is big. Progress is therefore
    -- accrued from the real gap between passes, never from TickSeconds, or a
    -- hard-fought contest would time out for reasons unrelated to defence.
    DefenderDecayMult = 2.0,   -- defenders present: progress bleeds 2x as fast as it built

    -- THE ANTI-LOCK CLOCK. Seconds the attacker may go without beating their own
    -- BEST progress before the contest collapses. Deliberately measured against
    -- the high-water mark rather than against presence: an "is anyone standing
    -- here" clock is reset for free by stepping in and out of the radius, and a
    -- contest that cannot be ended is a zone nobody else can attack. Measuring
    -- headway instead collapses every way of not taking the zone on one timer:
    -- walking away, oscillating across the radius edge, and being pinned at a
    -- standstill by defenders.
    AbandonSeconds    = 60,

    -- The other half of the anti-lock rule. A rival gang may TAKE OVER a contest
    -- once the current attacker has been stalled (see AbandonSeconds) for this
    -- long. Without it, one contest per zone means any crew can deny a zone to
    -- everyone else for the whole window just by keeping a contest technically
    -- alive, and two staggered throwaway crews cover the gaps. With it, the
    -- "already being contested" refusal only ever lasts while somebody is
    -- genuinely taking the zone: a squatter who is not gaining gets pushed aside
    -- by a crew that does the work, and an attacker who IS holding the zone is
    -- never stalled and so can never be pushed aside. One tick means "the server
    -- measured a full pass where you were not holding it".
    DisplaceAfterStallSec = 5,

    -- Ceiling on how many TickSeconds one pass may bank, so a single long server
    -- stall cannot hand out a whole capture off one presence sample taken after
    -- it. 4 x 5s = 20s, comfortably above a normal loaded pass.
    MaxCatchupTicks   = 4,

    -- THE BRAKE. A zone that just changed hands cannot be contested again for
    -- this long. Derived from palm6_turf.captured_at, which is already written
    -- on every flip, so it SURVIVES A RESTART: a reboot cannot be used to reset
    -- the anti-ping-pong cooldown (the same lesson as RepCooldownSec/rep_at).
    FlipCooldownSec = 1800,

    -- A contest the attacker LOST cools down the LOSING ATTACKER GANG, keyed on
    -- the immutable gang id, and only when the server actually saw a defender
    -- inside the radius during that contest. It is deliberately NOT keyed to the
    -- zone: a zone-keyed repel is a denial weapon, because any crew could open a
    -- throwaway contest, let the window run out, and lock the zone against every
    -- OTHER gang for this long. Keyed to the loser it penalises the only party
    -- that earned a penalty and no third party pays for it.
    RepelCooldownSec = 600,

    -- Anti-grief. OpenCooldownSec is per ATTACKING GANG (keyed on the immutable
    -- gang id, so swapping characters inside the gang does not reset it) and
    -- bounds how often one crew can start anything. NotifyCooldownSec is per
    -- DEFENDING GANG and bounds the aggregate ping rate onto one victim across
    -- ALL attackers AND across all three defender-facing messages (opened, held,
    -- lost) from one shared budget: throttling only the open ping would leave
    -- the same spam vector open in the close direction. A contest opened inside
    -- the window still opens, it just does not re-notify. Same reasoning as
    -- palm6_gangs' per-target pending invite guard, which caps a victim to one
    -- prompt at a time.
    OpenCooldownSec   = 600,
    NotifyCooldownSec = 300,

    -- For this long after the engine arms, no contest can open at all.
    --
    -- This is NOT what keeps the cooldowns above honest across a restart any
    -- more: OpenCooldownSec, RepelCooldownSec and NotifyCooldownSec are now
    -- stamped into palm6_turf_brakes (sql/0074_turf_brakes.sql) and reloaded at
    -- boot with their remaining time intact, and FlipCooldownSec has always come
    -- off palm6_turf.captured_at. What this grace still covers is the RECONNECT
    -- window: for the first minutes after a reboot the player list is still
    -- filling, so a defender headcount would wrongly read as "nobody online" and
    -- RequireDefenderOnline would wave through attacks it should refuse. It also
    -- remains the fallback if the brakes table cannot be created on a given box,
    -- which the boot banner says out loud ("brakes MEMORY ONLY").
    RestartGraceSec = 300,

    -- How often expired rows are deleted from palm6_turf_brakes. Pure
    -- housekeeping on its own thread, never on the contest ticker and never on a
    -- gate: a row that outlives a sweep still cannot gate anything, because
    -- every gate re-checks the window itself. Floored at 60s in code.
    BrakeSweepSec = 900,

    -- The 4am problem, stated precisely. A rival zone cannot be OPENED unless
    -- the owning gang has this many members CONNECTED TO THE SERVER. That is
    -- presence, not ability or willingness to respond: a member AFK across the
    -- map satisfies it, and the check happens only at open, so the defenders can
    -- log off a second later and the attacker holds an uncontested window.
    -- Re-checking mid-contest is deliberately NOT done, because aborting when
    -- the defenders go offline would hand every defending gang a guaranteed way
    -- to kill any attack on demand. The deliberate trade: turf freezes overnight
    -- rather than being farmed overnight. Turf held by a gang that no longer
    -- exists is already released by sql/0049_turf_identity_reset.sql, which
    -- palm6_dbmigrate re-runs every boot, so a dead crew's territory still frees
    -- up without a new mechanic.
    RequireDefenderOnline = true,
    MinDefendersOnline    = 1,

    -- How long a defenders-online headcount may be reused. The headcount is a
    -- DB read per online player, so the pre-check at [E] serves it from a short
    -- cache; the authoritative check when the contest actually opens forces a
    -- fresh read (maxAge 0).
    PresenceCacheSec = 15,

    -- Police attention on a SUCCESSFUL capture only. Never on the tag action,
    -- never on opening a contest, never on a failed contest: heat is minted
    -- exactly where the FlipCooldownSec brake already bounds the rate.
    -- Weight 12 is palm6_heat Config.Suggested.smuggle_run. Rationale: a turf
    -- capture is an organised, public, crew-scale territory crime, so it sits
    -- above a shakedown (6, the other gang-turf crime, which recurs every
    -- collect interval) and below a violent felony against a person
    -- (assault 18, murder 60). Bounded by FlipCooldownSec: at most one mint per
    -- zone per 30 min, 6 zones, so the whole map cannot exceed 12 heat per zone
    -- per half hour. Heat is a PENALTY, which is the structural reason a
    -- capture cannot be farmed: the thing minted is bad for the actor.
    HeatOnCapture     = 12,
    HeatMaxRecipients = 8,   -- caps the loop; a zerg cannot multiply the call count

    -- Minimum MEASURED seconds inside the radius before an attacker is eligible
    -- for capture heat, so someone who only drifted past the zone late in the
    -- contest does not eat a police-attention penalty for a capture he had no
    -- part in. When there are more eligible attackers than HeatMaxRecipients,
    -- the ones who were present LONGEST pay (ties broken on citizenid, so the
    -- selection is deterministic rather than player-list order).
    HeatMinPresenceSec = 60,

    -- palm6_pulse's "Turf War" (domain 'gang') window has shipped commented out
    -- since launch for want of a consumer. This is the consumer. Read-only and
    -- soft: if pulse is stopped, or the window is still commented out, the
    -- modifier is 1.0 and nothing changes. Applied ONLY to capture reputation,
    -- never to heat (a boost must never increase a penalty) and never to the
    -- clock. Re-clamped locally because a sibling's cap is not our guarantee.
    UsePulse      = true,
    MaxPulseMult  = 2.0,
}
