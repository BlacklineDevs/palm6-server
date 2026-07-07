# gtarp_mdt — the police Mobile Data Terminal

The in-game READER for the case files the city's systems already produce.
Insurance fraud flags, witness canvasses, counterfeit leads, and pumpcoin
rug reveals all land in `gtarp_evidence` — until this resource, the only
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
- `/bolo [text]` — issue a BOLO (5-140 chars, expires after the contract's
  duration, default 60 min). Broadcast to every on-duty officer and to the
  police Discord feed when `gtarp_discord` is configured.
- `/bolos` — active BOLOs with minutes remaining. `/boloclear [#]`
  resolves one (any on-duty officer).
- `/mdtcases` — open evidence cases (id, title, suspect count).
- `/mdtcase [#]` — the full file: status, opener, suspects (identified or
  descriptor-only), and the most recent entries.
- `/mdtreport [case# or 0] [text]` — written paperwork (contract minimum
  length, default 20 chars). Case-linked reports also land in the evidence
  file itself via the frozen `AppendEntry` export.
- `/warrant [citizenid] [case# or 0] [reason]` — open an arrest order on a
  real citizen (server-validated against the character records, online or
  offline; one active warrant per citizen). Broadcast like a BOLO;
  case-linked warrants land in the file.
- `/warrants` — active warrants with age and case. `/warrantclear [#]`
  drops one without an arrest.
- `/book [citizenid] [case# or 0] [charges]` — arrest paperwork. Files the
  booking, auto-serves the citizen's active warrants, appends to the case,
  and tells the booked player if they're online. The PHYSICAL side
  (`/cuff`, `/jail`) stays the recipe's `qbx_police` — this is the paper
  trail it never wrote.
- `/mdtcase` suspect lines flag `ACTIVE WARRANT #N` on identified
  suspects, closing the loop: fraud flag → case file → warrant → booking.

## Design notes

- **Server-only** — no client script at all. Every command reads server
  state and replies in chat (gtarp_perf's `/diag` reply pattern), so there
  is nothing for a modified client to abuse.
- Evidence access goes through exports only: the frozen v2 API plus
  `ListCases` (an additive export added to `gtarp_evidence` for this
  resource — read-only, no schema change). MDT never touches evidence
  tables directly.
- BOLOs expire passively (`resolved_at IS NULL AND expires_at > NOW()`) —
  no sweep thread, nothing is owed on expiry.
- Soft dependencies: `gtarp_evidence` missing → case commands report
  "case system offline", BOLOs/reports still work; `gtarp_discord`
  missing or feed unset → BOLOs still broadcast in-city.
- Exports: `GetSummary() -> { activeBolos, reports }`.

## Dup-gate (2026-07-07)

The recipe ships NO MDT, warrant, BOLO, booking, or report system
anywhere: `grep -riE "warrant|\bmdt\b|bolo|booking"` over deployed
`[qbx]`/`[ox]`/`[standalone]` matches only MIT license text. The
`mdt_tablet` item and the `qbx_police_overrides` `Config.MDT` block are
the documented-but-never-built layer — same class as the repair-invoice
stream that became `gtarp_mechanic`.

What the recipe DOES own (and this resource deliberately does not
touch): the physical enforcement verbs — `/cuff`, `/sc`, `/escort`,
`/jail`, `/unjail` — plus plate tooling (`/flagplate`, `/plateinfo`) and
property seizure (`/seizecash`, `/impound`, `/depot`), all in
`qbx_police/server/commands.lua`. Its `/jail` is a pure client event
with no database record — warrants and bookings here are the paperwork
that arrest never filed. BOLOs (freeform APBs on people/situations) are
distinct from `/flagplate` (plate-keyed ANPR flags); both coexist.
