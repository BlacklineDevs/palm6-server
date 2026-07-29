# palm6_mdt — the police Mobile Data Terminal

The in-game READER for the case files the city's systems already produce.
Insurance fraud flags, witness canvasses, counterfeit leads, and pumpcoin
rug reveals all land in `palm6_evidence` — until this resource, the only
way police could see any of it was the database. The MDT surfaces it at
the `mdt_tablet` item, which `qbx_police_overrides` has shipped in the
armoury loadout since day one with nothing consuming it.

`qbx_police_overrides` also published a full MDT contract
(`Config.MDT` via its `GetMDT()` export — enabled flag, BOLO duration,
report minimum length) with no implementation behind it. This resource is
that implementation: it honours `GetMDT()` when the override resource is
running and falls back to identical built-in defaults when it isn't.
`enabled = false` in the contract disables every command at boot, loudly.

## Player surface (all: on-duty police + carrying `mdt_tablet`)

- `/mdt` — desk summary: active BOLOs, open case files, filing hints.
- `/id` - identify the nearest player: name, citizenid, active-warrant flag,
  and a copy-paste hint for the three commands that consume it. **The rung
  the ladder was missing** - `/cite`, `/warrant` and `/book` all wanted a raw
  citizenid an officer had no in-game way to learn. All three now take
  **either** form, so the hint prints the short server id for all three:
  `/warrant` and `/book` resolve it in process, `/cite` (in
  `palm6_citations`) resolves it through this resource's `ResolveTarget`
  export. Server-authoritative by
  construction: the officer sends no argument at all, the server picks the
  nearest ped from its own entity positions inside
  `Config.Identify.Radius`. Police-gated like everything else, so the
  citizenid it prints never reaches a civilian. Command name is
  configurable (`Config.Identify.Command`) and the whole command can be
  switched off (`Config.Identify.Enabled`, default `true`) in case the live
  box already has an `/id` - the last resource to register a name wins, and
  ~157 out-of-repo resources start after this one.
- `/runplate [plate]` - is this plate hot? Reads `palm6_chopshop`'s stolen
  registry (frozen `IsStolen` export, soft-dep), the registered keeper from
  the vehicle records, and that keeper's warrant status. Read-only. When the
  registered owner is the one who filed the theft report, the reply says so
  out loud so nobody books the victim.
- `/bolo [text]` — issue a BOLO (5-140 chars, expires after the contract's
  duration, default 60 min). Broadcast to every on-duty officer and to the
  police Discord feed when `palm6_discord` is configured.
- `/bolos` — active BOLOs with minutes remaining. `/boloclear [#]`
  resolves one (any on-duty officer).
- `/mdtcases` — open evidence cases (id, title, suspect count).
- `/mdtcase [#]` — the full file: status, opener, suspects (identified or
  descriptor-only), and the most recent entries.
- `/mdtreport [case# or 0] [text]` — written paperwork (contract minimum
  length, default 20 chars). Case-linked reports also land in the evidence
  file itself via the frozen `AppendEntry` export.
- `/warrant [citizenid or server id] [case# or 0] [reason]` - open an arrest
  order on a real citizen (server-validated against the character records,
  online or offline; one active warrant per citizen). Broadcast like a BOLO;
  case-linked warrants land in the file. Takes **either** a citizenid or the
  online server id `/id` prints; an all-digit argument is only read as a
  server id when a live character actually sits on it, so numeric citizenids
  still work.
- `/warrants` — active warrants with age and case. `/warrantclear [#]`
  drops one without an arrest.
- `/book [citizenid or server id] [case# or 0] [charges]` - arrest paperwork. Files the
  booking, auto-serves the citizen's active warrants, appends to the case,
  and tells the booked player if they're online. The PHYSICAL side
  (`/cuff`, `/jail`) stays the recipe's `qbx_police` — this is the paper
  trail it never wrote.
- `/mdtcase` suspect lines flag `ACTIVE WARRANT #N` on identified
  suspects, closing the loop: fraud flag → case file → warrant → booking.
- `/calls [n]` — the 911 log. A passive recorder on the recipe's central
  `police:server:policeAlert` funnel (houserobbery, storerobbery,
  counterfeit heat pings, witness gunfire reports all flow through it) —
  the recipe notifies whoever is on duty and forgets; the MDT remembers.
  Per-source flood guard, 7-day retention. Known coverage gap: the two
  producers that fire the officer notify directly client-side
  (qbx_truckrobbery, qbx_police's cam command) bypass the funnel and are
  not recorded.

  **Provenance stamp.** The funnel is a NET event, so a modified client can
  raise it. It is also raised from the client *by design* by the qbx robbery
  resources (`storerobbery`, `houserobbery`, `jewellery`, `bankrobbery`) —
  the marquee content of a dispatch log. So the recorder does not drop
  client-raised alerts; it **logs them and marks them**. A call raised
  across the net boundary is stamped `unverified` in its `src_label`, which
  `/calls` prints, so an officer can tell a dispatch a trusted server-side
  producer vouched for from one that could have been fabricated. The seven
  in-repo producers all raise server-side via `TriggerEvent` and are
  unmarked; they also keep the sanctioned direct path, the frozen `LogCall`
  export.

  The flood exploit is bounded elsewhere, not by this: `palm6_eventguard`
  budgets `police:server:policeAlert` for **client** raises only (its
  `guard()` exempts server-side raises), and `Config.Calls.PerSourceCdSec`
  puts a second per-source floor under the insert.

  `Config.Calls.RequireServerProvenance` (default **OFF**) is the opt-in
  hard drop for operators who would rather have no row than an unverified
  one. With it ON a client-raised alert writes nothing, still reaches the
  recipe's own notify path (separate registration, never cancelled — so
  dispatch still pings), and prints a throttled console line naming the
  dropped text. Turning it on will silence the four qbx robberies above in
  `/calls`; that is the trade, and it is why it ships off.

## Charge catalogue + sentence calculator (v0.4.0, SHIPS OFF)

`Config.Charges.Enabled = false`. With the flag off `/charges` is not
registered, the three exports below return `nil`, and nothing else changes.

**Free-text charges are untouched and always will be.** `/book` still takes
prose bounded only by `ChargesMin`/`ChargesMax`. The catalogue is an
*additional* vocabulary an officer may optionally use, never a replacement,
and nothing rewrites a filed charge string.

- `/charges [class]`: the catalogue, grouped under a `--- class ---` header,
  one line per charge: code, label, base sentence + unit, base fine. Read-only;
  it prints `Config` and touches nothing. The footer names the review command
  by asking `palm6_legal` for it (`GetSentenceCommand()`), so it can never
  advertise a command that is switched off or has been renamed.

The calculator lives in `shared/sentencing.lua`, deliberately alone in its own
file so "pure and deterministic" is checkable by reading one short file. It
calls no native, no framework export, no MySQL, and no `Bridge` function.

**The model.** The most serious charge is served in full; every other charge
in the same booking is served at `ConcurrentPct` of its base. That is what
stops nine petty charges out-sentencing one murder (verified: 26 vs 90).
Fines are the opposite — cumulative at full value, never touched by the priors
multiplier — so the money side stays a published schedule a player can predict
exactly. Priors are prior **unsealed** bookings filed before this one; each
adds `PriorsStepPct`, capped at `PriorsCap`. Because sealed bookings do not
count, winning an expungement petition in `palm6_legal` genuinely lowers your
next recommended sentence.

**No floating point.** Base sentences are integers, the concurrency factor and
priors step are integer *percentages*, the subtotal is kept in hundredths, the
multiplier leaves it in ten-thousandths, and exactly one rounding happens at
the end as integer division. There is no platform-dependent rounding and no
accumulated error. Charges are sorted by severity with a tiebreak chain ending
on the unique code, and the charge-count cap cuts from the *bottom* of that
sorted list, so the result never depends on the order the codes were typed.

Worked example — `gta` + `evade`, 3 priors:

```
gta   [felony]      Grand Theft Auto            15 x 100% = 15.00  (most serious)
evade [misdemeanor] Evading a Peace Officer      5 x  50% =  2.50  (concurrent)
subtotal 17.50, fine $10000 (cumulative)
priors 3 -> multiplier 130% (time only)
17.50 x 130% = 22.7500 -> rounded half up = 23
```

**The ceiling makes concurrency invisible above it.** `MaxSentence = 120` is a
hard clamp applied last. Re-run against the real catalogue: `murder_1` with 5
priors is 135 raw, `murder_1 + murder_2` with 5 priors is 180 raw, all 17 codes
with 5 priors is 321 raw, and all three print **120**. So "concurrency stops
charges stacking" is only observable *below* the ceiling; at or above it, an
extra charge changes the fine and nothing else. The breakdown says so out loud
when it fires, and `result.capped` / `cappedHigh` / `cappedLow` report it.

**Inference never produces a number, on purpose.** Omit the codes and the
booking text is still scanned (literal whole-token matching, never fuzzy), but
the hits come back as `suggested` and the result is a refusal. The scan cannot
see a compound code, and on this catalogue the compound codes are the severe
ones (`leo_assault` 20, `bank_robbery` 45, `murder_1` 90) while the single-word
ones are the mild ones (`trespass` 1, `assault` 8). Scanning *"assault on a
peace officer during a bank robbery"* finds `assault` alone: 8 months and
$3000, against the correct sheet's 55 months and $35,000. A confident, itemised
recommendation that is systematically too lenient is worse than no
recommendation, so a human has to type the codes.

**Sealed bookings are invisible here.** `RecommendForBooking` returns `nil` for
a booking with `sealed_at` set unless the caller passes
`opts.allowSealed`, which `palm6_legal` only does on its console/ace tier.
Anything else would have handed the citizenid, name and original charge text of
an *expunged* record to any on-duty officer who typed the booking number, which
is the whole expungement mechanic undone. Priors already count unsealed rows
only, so the printed prior count cannot betray a sealed booking either.

**A failed prior-record lookup refuses rather than guessing zero.** `sealed_at`
arrives only via `sql/0026_legal.sql`'s MariaDB-only `ADD COLUMN IF NOT EXISTS`,
so on an unpatched MySQL 8 box the priors query throws. Reporting that as "0
priors counted" inside a breakdown sold as reproducible-on-paper would tell
every citizen on the server, in writing, that they are a first offender.

Exports (additive, all `nil` while the flag is off):
`GetChargeCatalogue()`, `CalculateSentence(codes, priors)`,
`RecommendForBooking(bookingId, codes, opts)`. `opts.allowSealed` is the only
argument added since v0.4.0 and is optional, so existing callers are unaffected.

**This resource still cannot jail anybody.** `qbx_police` owns `/cuff` and
`/jail` and is not in this repo. `Config.Charges.SentenceUnit` is a display
label only — nothing here converts it to game time, because nothing here knows
what unit that command takes. The full handoff note is in
`palm6_legal/README.md`.

## Design notes

- **Server-only** — no client script at all. Every command reads server
  state and replies in chat (palm6_perf's `/diag` reply pattern), so there
  is nothing for a modified client to abuse.
- Evidence access goes through exports only: the frozen v2 API plus
  `ListCases` (an additive export added to `palm6_evidence` for this
  resource — read-only, no schema change). MDT never touches evidence
  tables directly.
- BOLOs expire passively (`resolved_at IS NULL AND expires_at > NOW()`) —
  no sweep thread, nothing is owed on expiry.
- **One resolver for the officer loop.** `ResolveTarget(arg)` →
  `{ citizenid, name }` or `nil` wraps this resource's
  `Bridge.ResolveTarget` so `/id`, `/warrant`, `/book`, `/cite`
  (`palm6_citations`) and `/casesuspect` (`palm6_evidence`) all read the
  same argument the same way. The two out-of-resource callers call it softly
  (`GetResourceState` + `pcall`) rather than each keeping a copy that could
  drift. It is read-only and gates nothing, so every caller runs its own
  police gate first. When `palm6_mdt` is stopped both callers fall back to
  their pre-existing citizenid-only path.
- Soft dependencies: `palm6_evidence` missing → case commands report
  "case system offline", BOLOs/reports still work; `palm6_discord`
  missing or feed unset → BOLOs still broadcast in-city.
- **Self-creating schema** - the `sql/` files are applied by hand and CI
  never touches the DB, so a fresh box that missed one left every query
  pcall-swallowed into silence. The resource now runs its own
  `CREATE TABLE IF NOT EXISTS` block at boot (after a 3s oxmysql-connect
  wait, per-statement pcall, `palm6_ems` pattern) and the boot banner says
  `schema MISSING` instead of reporting zeros. The DDL is copied **verbatim**
  from `sql/0022_mdt.sql`, `sql/0023_warrants.sql`, `sql/0025_calls.sql` and
  `sql/0026_legal.sql`'s `sealed_at` ALTER, so the two can never diverge;
  re-runs are no-ops on the live box.
- **Staff audit** - `/warrant` and `/book` write to
  `exports.palm6_staff:Log` (`mdt_warrant` / `mdt_booking`). A booking fires
  a Discord announce and a world-public cityfeed post naming a real citizen,
  and before this the entire police stack wrote to no audit sink at all.
  Soft-wrapped: a missing or broken sink never fails a booking.
- Exports: `GetSummary() -> { activeBolos, reports }`.

## Dup-gate (2026-07-07)

The recipe ships NO MDT, warrant, BOLO, booking, or report system
anywhere: `grep -riE "warrant|\bmdt\b|bolo|booking"` over deployed
`[qbx]`/`[ox]`/`[standalone]` matches only MIT license text. The
`mdt_tablet` item and the `qbx_police_overrides` `Config.MDT` block are
the documented-but-never-built layer — same class as the repair-invoice
stream that became `palm6_mechanic`.

What the recipe DOES own (and this resource deliberately does not
touch): the physical enforcement verbs — `/cuff`, `/sc`, `/escort`,
`/jail`, `/unjail` — plus plate tooling (`/flagplate`, `/plateinfo`) and
property seizure (`/seizecash`, `/impound`, `/depot`), all in
`qbx_police/server/commands.lua`. Its `/jail` is a pure client event
with no database record — warrants and bookings here are the paperwork
that arrest never filed. BOLOs (freeform APBs on people/situations) are
distinct from `/flagplate` (plate-keyed ANPR flags); both coexist.
