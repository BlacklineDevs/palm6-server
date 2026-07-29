# palm6_turf

Gang turf control — the `docs/BUILD-ROADMAP.md` Phase 6 signature-feature
candidate ("faction reputation tracker") that was never built.
`qbx_core` has gangs as a first-class primitive (`PlayerData.gang`,
`/setgang`) but no gameplay was ever layered on top of it. Confirmed
non-duplicative: no turf/territory/gang-war resource exists anywhere in
the deployed Qbox recipe tree.

Bridge-pattern (see `docs/GTA6-READINESS.md`): all logic is in `server/`
and `client/`; every qbx/native/ox_lib call lives in `bridge/`.

## How it works

- **Zones.** `Config.Zones` defines a handful of turf points around the
  map, seeded into `palm6_turf` on first boot (one row per zone,
  unclaimed). Each zone shows a blip — white while unclaimed, coloured
  once a gang holds it.
- **Tag.** Any player in a gang (`PlayerData.gang.name ~= 'none'`) can
  walk to a zone and `[E]` to start tagging. Already holding it for your
  own gang is refused; holding it for a rival gang is allowed — turf
  flips on a successful tag, no defenders-present check in v1.
- **Reputation.** `/turf` shows a leaderboard: gangs ranked by zones held,
  plus which zones are still unclaimed. Reputation *is* turf count — no
  separate score to track.

## Commands

| Command | Where | Effect |
| --- | --- | --- |
| `[E]` at a turf zone | in a gang | start tagging it for your gang |
| `/turf` | anywhere | view the turf-count leaderboard |

## Config (`shared/config.lua`)

- `InteractRadius`, `TagProgressMs` — proximity and tag duration.
- `Zones` — id/label/coords per turf point. Coords reuse already-validated
  ground-level points from elsewhere in this repo (spawn / shop / robbery
  locations) rather than new, unverified ones.
- `BlipSprite`, `UnclaimedColour`, `ClaimedColour`, `BlipScale`.

## Turf Conflict (v2): SHIPS OFF (`Config.Conflict.Enabled = false`)

With the flag **off**, everything above is exactly what runs and nothing in
this section executes. Every conflict branch is written as
`if Config.Conflict.Enabled and ...`, so the short-circuit skips it.

With the flag **on**, tagging a zone a **rival gang already holds** no longer
flips it. It **opens a contest**. Claiming an **unowned** zone stays instant,
because there is no defender to give a window to.

| Phase | What happens |
| --- | --- |
| `[E]` + progress bar | pre-checks the gates, then OPENS a contest (does not flip) |
| Contest open | the defending gang's online members are notified |
| Every `TickSeconds` | the server re-derives who is inside `Radius` and moves progress |
| `progress >= HoldSeconds` | the zone flips: rep, heat, `captured_at` cooldown start |
| `ContestSeconds` elapsed first | defenders held it; the **attacking gang** cools down for `RepelCooldownSec` |
| Attacker fails to beat their own best for `AbandonSeconds` | contest ends. Counted as a **defence** (with the repel) if the server ever saw a defender in the radius; a quiet **collapse** if nobody ever showed |
| Attacker stalls for `DisplaceAfterStallSec` | a **rival gang** may now take the contest over |

**Progress is server-authoritative and has no client input.** The server walks
the online player list, reads each ped's position itself through
`Bridge.GetCoords`, and only then resolves gang identity for the few who passed
the distance test. A client never reports its progress, position, gang, or
presence. Its only contribution is "I finished the tag animation", which the
existing handler already re-validates against the server's own clock.

**Progress is measured, not assumed.** A ticker pass is *not* `TickSeconds` of
real time: resolving gang identity is a DB read, and every live contest is
processed serially on one thread, so a big fight across several zones stretches
a pass well past its `Wait`. Since `ContestSeconds` and `AbandonSeconds` run on
the wall clock, banking a flat `TickSeconds` per pass would make the clock lie
*worst when the feature is busiest*. Every accumulator therefore uses the
measured gap between passes, capped at `MaxCatchupTicks` so one long stall
cannot bank a whole capture off a single presence sample. Gang lookups are also
memoised per pass, so six live contests cost one lookup per player, not six.

**There is deliberately no numbers bonus.** Six attackers bank progress at the
same rate as one. Headcount decides *whether* you hold the zone, never *how
fast*, so stacking alts buys nothing on the clock. Ties favour the defender.

### Persistence: contests do NOT survive a restart, on purpose

Contests are in-memory only. On a restart every open contest simply ceases to
exist and the **defender keeps the zone**, which is the fail-safe direction.
There is no `contested` flag in any table, so **a restart cannot leave a zone
locked**. There is nothing persisted that could stay stuck. No new table and
no new `sql/NNNN` file were needed.

Of the four brakes, only the anti-ping-pong **flip** cooldown outlives a
restart, and it does so for free: it is derived from `palm6_turf.captured_at`,
which every flip has always written (same lesson as `rep_at` /
`RepCooldownSec`). `OpenCooldownSec`, `RepelCooldownSec` and
`NotifyCooldownSec` are in-memory and a restart **does** clear them. That gap is
bounded, not hidden: `RestartGraceSec` blocks *every* contest from opening for
that long after the engine arms, so a scheduled reboot buys a gang that just
lost one a freeze rather than a free instant reopen. It also covers the
reconnect window, when the player list is still filling and a defender headcount
would wrongly read as "nobody online". Persisting the other three properly needs
a table this resource does not own yet, so it is deliberately deferred.

### Anti-grief

- **A contest must never be usable as a lock.** This is the property the whole
  design turns on, because a contest system whose main new capability is
  *denial* is worse than the instant flip it replaced. Four things enforce it:
  1. `AbandonSeconds` measures the attacker against **their own high-water
     mark**, not against presence. A presence clock is reset for free by
     stepping across the radius edge, which is exactly how a lone griefer used
     to keep a contest alive forever. Measuring headway collapses every way of
     *not* taking the zone on one timer: walking away, oscillating, and being
     pinned at a standstill by defenders.
  2. `DisplaceAfterStallSec` lets a **rival gang take a stalled contest over**.
     One contest per zone is the right model, but on its own "there is a contest
     here" is itself a lock: a crew can deny the zone to everyone for the whole
     window just by keeping a contest technically alive, and two staggered
     throwaway crews cover the gaps. Displacement means the refusal lasts only
     while somebody is *genuinely* taking the zone — a squatter who is not
     gaining gets pushed aside, and an attacker who is actually holding it is
     never stalled and so can never be pushed aside. The lock is removed, not
     handed to the challenger.
  3. `RepelCooldownSec` is keyed to the **losing attacker gang**, never to the
     zone. A zone-keyed repel was a denial weapon: any crew (including an alt
     crew run by the *owner*) could open a throwaway contest, run the window
     out, and lock the zone against every other gang.
  4. That repel is stamped only when the server actually **saw a defender**
     inside the radius during the contest. A window nobody defended is not a
     repel and pays nothing.
  A *collapsed* contest still stamps no repel at all, only the walking-away
  gang's own `OpenCooldownSec`. Net effect at the shipped numbers: the longest
  a rival gang can be refused by a contest that never captures is `HoldSeconds`,
  and reaching that requires the incumbent to gain on **every** pass for that
  whole time, which is what taking the zone looks like.
- **Notification spam.** A contest can only be opened by *completing* the
  `TagProgressMs` progress bar at the zone, so it is never free. On top of
  that: `OpenCooldownSec` per attacking gang (keyed on the immutable gang id,
  so swapping characters inside the gang does not reset it), and
  `NotifyCooldownSec` per *defending* gang. That one budget covers **all
  three** defender-facing messages (opened / held / lost) across **all**
  attackers: throttling only the open ping leaves the identical spam vector open
  in the close direction, where several contests ending in the same second would
  otherwise deliver several simultaneous unthrottled pings. A throttled contest
  still runs, it just does not re-ping, and `/turf` always shows every live
  contest, so a throttled defender is never blind.
- **Alt-gang zone trading.** `FlipCooldownSec` is owner-agnostic and persisted,
  so a zone physically cannot ping-pong. Both runtime writers of `captured_at`
  (the contest capture *and* the unowned instant claim) stamp the in-memory
  `captured_ts` the cooldown reads, so the brake is not silently skipped for
  zones claimed the instant way. Rep keeps its own separate persisted
  `RepCooldownSec`. And the thing minted on capture is **heat**, a penalty:
  the structural reason a capture cannot be farmed is that farming it costs the
  farmer police attention.
- **4am captures.** `RequireDefenderOnline` refuses to *open* a contest unless
  `MinDefendersOnline` members of the owning gang are **connected to the
  server**. Stated precisely, because it is weaker than it sounds: that is
  presence, not ability or willingness to respond (a member AFK across the map
  satisfies it), and it is checked only at open, so the defenders can log off a
  second later and the attacker holds an uncontested window. Re-checking
  mid-contest is deliberately *not* done: aborting when the defenders go offline
  would hand every defending gang a guaranteed way to kill any attack on demand,
  a strictly worse exploit than the one it would close. The deliberate trade is
  that turf freezes overnight rather than being farmed overnight. Turf held by a
  gang that no longer exists is already released by
  `sql/0049_turf_identity_reset.sql`, which `palm6_dbmigrate` re-runs every
  boot, so a dead crew's territory still frees up without a new mechanic.

### Heat and pulse

On a **successful capture only** (never on the tag action, never on opening a
contest, never on a failed one), the attacking-gang citizenids the server saw
inside the zone take `HeatOnCapture` heat (weight **12**, palm6_heat's
`Config.Suggested.smuggle_run`), capped at `HeatMaxRecipients` recipients.
*Who* pays is ranked by the seconds the server measured each attacker inside the
radius, ties broken on citizenid, so the cap pays out to the crew that did the
work rather than to whichever eight came first in player-list order; anyone
under `HeatMinPresenceSec` is skipped entirely, because heat is a penalty and
failing open is the safe direction for a bystander.
Soft-dep + `pcall`, identical in shape to `palm6_smuggling`'s delivery wire.
Rationale for 12: an organised, public, crew-scale territory crime sits above a
shakedown (6, which recurs every collect interval) and below a violent felony
against a person (assault 18).

`palm6_pulse`'s **Turf War** window (domain `gang`) has shipped commented out
since launch for want of a consumer. This is that consumer:
`GetActiveModifier('gang')` scales **capture reputation only**: never heat (a
boost must not increase a penalty) and never the clock. Read-only, soft, and
re-clamped locally to `MaxPulseMult`. **Enabling the window itself is a change
to `palm6_pulse/shared/config.lua`, which this resource does not own.**

### Exports added

```lua
exports.palm6_turf:GetContests()  --> { [zoneId] = { label, attackerGang, defenderGang,
                                       openedAt, endsAt, progress, holdSeconds } }
```
Always empty while the flag is off, so a consumer wired today is inert until
the flag flips rather than broken by it.

## Deploy

- `ensure palm6_turf` is wired into `custom.cfg`.
- SQL migration `sql/0013_turf.sql` creates `palm6_turf` (one row per
  zone, seeded idempotently via `INSERT IGNORE` on every boot).
- **Turf Conflict adds no migration.** It reuses `captured_at`, which
  `0013_turf.sql` already creates.

## GTA VI notes (Tier 3)

All six zone coords are Los Santos points; added to
`docs/GTA6-TIER3-RETUNE.md` §13. The zone/ownership/leaderboard lifecycle
itself is Tier 1 and carries.

## Still deferred

- No per-gang blip colour (all claimed zones render the same colour today).
- No material reward for holding turf (payouts, perks) beyond
  palm6_protection's shakedown income. Pure reputation otherwise.
- No live capture-progress HUD. Contest progress is visible through `/turf`
  and the open/resolve notifications, not as an on-screen bar.
- A gang that DISBANDS mid-contest still reads as the defender until the next
  boot (`0049` releases its turf then). In practice its headcount is zero, so
  the attacker simply captures.

## Unverified

Turf Conflict has **never been run in game**. Every number in
`Config.Conflict` (radius, hold time, window, cooldowns) is an untested
starting point, and the whole feature is behind `Enabled = false` for exactly
that reason. What is verified is that the files parse and that the disabled
path is unchanged. What is not: feel, pacing, and whether the presence radius
matches how the zones actually read on the ground.
