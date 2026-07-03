# gtarp_evidence

Police evidence log + locker — the `docs/BUILD-ROADMAP.md` Phase 6 signature
feature candidate ("evidence-locker workflow extension for police") that
was never built. Confirmed non-duplicative: no evidence/case-log resource
exists anywhere in the deployed Qbox recipe tree.

**v2** adds the scope v1 deferred: **case files**, **suspect linkage**, and
a small **frozen export API** so sibling resources can append to cases.

Bridge-pattern (see `docs/GTA6-READINESS.md`): all logic is in `server/`
and `client/`; every qbx/native/ox_lib call lives in `bridge/`.

## How it works

- **Log.** On-duty police: `/logevidence <description>` writes a row to
  `gtarp_evidence` — officer identity, description, coords, timestamp.
  No proximity gate; evidence gets logged wherever the officer is.
- **Review.** On-duty police: `/evidence` shows the most recent
  `Config.LogEntryLimit` entries in a read-only dialog (v1 behavior,
  unchanged). Subcommands browse case files — see below.
- **Locker.** A physical `[E]`-interact evidence locker (an `ox_inventory`
  stash) at the Mission Row police station — on-duty police only, gated
  server-side by job + proximity.
- **Case files (v2).** A case is `id + title + status (open/closed) +
  opening officer + timestamps`. Evidence entries can attach to a case
  (`case_id`); uncased flat entries stay fully legal — v1 rows and v1
  insert paths work unchanged.
- **Suspect linkage (v2).** A case links to a known suspect (`citizenid`)
  or to an *unknown suspect* placeholder (partial descriptors: clothing
  colour, mask y/n, vehicle class, partial plate, ...). Cases are
  searchable by suspect citizenid.

## Commands

| Command | Where | Effect |
| --- | --- | --- |
| `/logevidence <description>` | on-duty police, anywhere | log a flat (uncased) entry — v1, unchanged |
| `/evidence` | on-duty police, anywhere | view recent flat entries — v1, unchanged |
| `/evidence cases` | on-duty police | list recent case files |
| `/evidence case <id>` | on-duty police | full case detail: status, suspects, entries |
| `/evidence suspect <citizenid>` | on-duty police | list cases linked to that citizen |
| `/casenew <title>` | on-duty police | open a case file |
| `/caseadd <id> <description>` | on-duty police | attach an evidence entry to a case |
| `/casesuspect <id> <citizenid>` | on-duty police | link a known suspect |
| `/casesuspect <id> unknown <descriptors>` | on-duty police | link an unknown-suspect placeholder |
| `/caseclose <id>` / `/casereopen <id>` | on-duty police | flip case status |
| `[E]` at the locker | on-duty police, at the station | open the stash |

All commands are gated server-side (on-duty police check) and rate-limited
server-side (`Config.WriteCooldownMs` / `Config.ReadCooldownMs`). All case
views render through the same v1 client path
(`gtarp_evidence:showLog` → `Game.ShowLogDialog`), no new UI surface.

## Export API (server) — FROZEN

Server-side exports on `gtarp_evidence` for sibling resources (e.g. an
NPC-witness system appending partial suspect facts, or a counterfeit-cash
system tracing a serial at the locker terminal and appending leads).
These signatures are frozen — extend by adding new exports, never by
changing these.

```lua
-- Idempotent case handle for an incident. Same incidentKey always returns
-- the same case (UNIQUE key + INSERT IGNORE, race-safe). Pass nil
-- incidentKey to always create a fresh case. Returns caseId or nil.
local caseId = exports.gtarp_evidence:EnsureCase(incidentKey --[[string|nil]], title --[[string]], createdBy --[[string|nil]])

-- Append an entry to a case. kind is a freeform taxonomy tag
-- ('note' | 'fact' | 'lead' | ...). payload may be a string or a table
-- (tables are json-encoded). source names the writing system, e.g.
-- 'gtarp_witness'. Returns entryId or nil.
local entryId = exports.gtarp_evidence:AppendEntry(caseId --[[number]], kind --[[string]], payload --[[string|table]], source --[[string]])

-- Link a suspect. Known: pass citizenid (descriptor nil). Unknown: pass
-- citizenid nil + a descriptor string of partials. Duplicate links to the
-- same case are a no-op success. Returns boolean.
local ok = exports.gtarp_evidence:LinkSuspect(caseId --[[number]], citizenid --[[string|nil]], descriptor --[[string|nil]])

-- Read a case: { id, incident_key, title, status, created_by,
-- created_by_name, created_at, updated_at, suspects = {...},
-- entries = {...} } — or nil. Entries capped at Config.CaseEntryLimit.
local case = exports.gtarp_evidence:GetCase(caseId --[[number]])
```

Typical consumer pattern (witness sees a robbery):

```lua
local caseId = exports.gtarp_evidence:EnsureCase('robbery:' .. robberyId, 'Store robbery — 24/7 Strawberry', 'gtarp_witness')
if caseId then
    exports.gtarp_evidence:AppendEntry(caseId, 'fact', { mask = true, top_color = 'red', vehicle_class = 'muscle', plate_partial = '3KL' }, 'gtarp_witness')
    exports.gtarp_evidence:LinkSuspect(caseId, nil, 'red top, masked, muscle car, plate ..3KL..')
end
```

### Direct-insert compatibility (kept on purpose)

`gtarp_pumpcoin` writes rug-reveal fraud entries with a raw
`INSERT INTO gtarp_evidence (citizenid, officer_name, description)`.
That path is part of the compatibility contract: every v2 column
(`case_id`, `kind`, `source`) is nullable or defaulted, so v1-shaped
inserts keep working forever. New integrations should prefer the export
API above.

## Config (`shared/config.lua`)

- `InteractRadius`, `LockerCoords` — locker proximity gate.
- `LockerSlots`, `LockerMaxWeight` — stash capacity.
- `LogEntryLimit` — how many entries `/evidence` shows.
- `CaseListLimit`, `CaseEntryLimit` — case list / detail view caps.
- `CaseTitleMax`, `EntryMax` — server-side text clamps.
- `WriteCooldownMs`, `ReadCooldownMs` — command rate limits.

## Deploy

- `ensure gtarp_evidence` is wired into `custom.cfg`.
- SQL migration `sql/0012_evidence.sql` creates `gtarp_evidence` — named
  with the `gtarp_` prefix as a defensive convention after the
  `0010_properties.sql` collision with the recipe's own `qbx_properties`
  table (no collision exists here today; the prefix rules it out for good).
- SQL migration `sql/0018_evidence_v2.sql` (v2, additive only) creates
  `gtarp_evidence_cases` + `gtarp_evidence_suspects` and adds nullable /
  defaulted `case_id`, `kind`, `source` columns to `gtarp_evidence`. No
  existing column is altered. Apply after `0012_evidence.sql`.

## GTA VI notes (Tier 3)

`Config.LockerCoords` is a Los Santos point (Mission Row PD); add it to
`docs/GTA6-TIER3-RETUNE.md` and re-author for the VI map. The log/locker/
case lifecycle itself is Tier 1 and carries — the case tables and export
API contain zero engine bindings.

## Deferred to v3

- No evidence chain-of-custody on locker items (stash contents are not
  tied to log entries).
- No case assignment / detective ownership — any on-duty officer can edit
  any case.
- No full-text search across entries; browsing is by recency, case id,
  and suspect citizenid.
