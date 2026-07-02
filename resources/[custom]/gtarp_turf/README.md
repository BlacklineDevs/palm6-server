# gtarp_turf

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
  map, seeded into `gtarp_turf` on first boot (one row per zone,
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

## Deploy

- `ensure gtarp_turf` is wired into `custom.cfg`.
- SQL migration `sql/0013_turf.sql` creates `gtarp_turf` (one row per
  zone, seeded idempotently via `INSERT IGNORE` on every boot).

## GTA VI notes (Tier 3)

All six zone coords are Los Santos points; added to
`docs/GTA6-TIER3-RETUNE.md` §13. The zone/ownership/leaderboard lifecycle
itself is Tier 1 and carries.

## Deferred to v2

- No per-gang blip colour (all claimed zones render the same colour today).
- No contest mechanic — tagging is instant on a successful progress bar,
  no requirement that defenders be absent or notified in real time.
- No material reward for holding turf (payouts, perks) — pure reputation
  for v1.
- No cooldown on re-tagging a just-flipped zone.
