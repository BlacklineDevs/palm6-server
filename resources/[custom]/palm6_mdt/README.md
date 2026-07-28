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
