# palm6_replay — the city black-box

CSI-grade forensic reconstruction for FiveM. The server continuously records
lightweight movement/action telemetry from every player, and when shots ring
out or someone goes down, detectives stand at the scene and **replay the
crime as translucent ghost peds re-enacting exactly what happened** — pause
it, rewind it, watch it at 0.5x, and settle first-shooter disputes with
evidence instead of admin tickets.

Nothing on any FiveM store does in-world ghost reconstruction from
server-authoritative telemetry. This is not a video system: there are **no
clips, no Rockstar Editor, no recording natives** (the recipe's
`qbx_smallresources` owns `/record` and is untouched). It is pure telemetry —
a few KB of position/heading/speed/weapon frames per player, replayed
in-world where the crime happened.

Bridge-pattern (see `docs/GTA6-READINESS.md`): all logic is in `server/` and
`client/`; every qbx/native/ox_lib call lives in `bridge/`.

## How it works

1. **Record.** Every client keeps a rolling 90-second ring of compact frames
   at 4 Hz — position, heading, speed, weapon, stance flags (shooting,
   in-vehicle, downed, aiming, ragdoll). A shot poll at 10 Hz catches single
   gunshots between samples. It lives in memory only and **never leaves the
   client unless the server asks for it**.
2. **Flag.** An incident fires server-side — server-observed weapon damage, a
   downed player, a shots-fired report, a robbery trigger, an officer's
   `/bodycam`, or a staff `/replayflag`. The server (using **its own** read of
   player positions, never a client claim) invites everyone within
   `Config.Incident.Radius` to upload their ring.
3. **Persist.** Uploads are accepted only from invited clients, only within
   the upload window, only once each. Every frame is type-checked,
   bounds-checked, monotonicity-checked, and rebuilt from whitelisted fields;
   participant count and frame count are hard-capped. The scene lands in
   MariaDB keyed by incident.
4. **Reconstruct.** An on-duty investigator stands at the scene (server-side
   proximity gate), runs `/replayscenes` to see what the black-box holds
   nearby, then `/replay <id>`. Alpha-150 ghost peds — wearing each
   participant's recorded ped model — interpolate through the frames in real
   time with walk/run/sprint locomotion, floating name tags, and **red
   muzzle-flash markers at recorded shot frames**. Playback controls: pause,
   scrub ±5 s, 0.25x–2x speed, stop.
5. **File it.** `/replayattach <id> [note]` files the scene as a
   **REPLAY EXHIBIT** in the `palm6_evidence` case log, so `/evidence` shows
   it alongside conventional evidence with instructions to reconstruct on
   site.

## Commands

| Command | Who | Effect |
| --- | --- | --- |
| `/replayscenes` | on-duty investigator | list recorded scenes near you |
| `/replay <id>` | on-duty investigator, **at the scene** | ghost reconstruction |
| `/replaystop` | anyone (local) | end your reconstruction (or press `X`) |
| `/bodycam` | on-duty investigator | capture a snippet centred on yourself |
| `/replayattach <id> [note]` | on-duty investigator | file scene as an evidence exhibit |
| `/replayflag [label]` | ace `command.replayflag` | manually flag a scene (staff/testing) |

**Playback keys:** `SPACE` pause · `←`/`→` scrub · `↑`/`↓` speed · `X` stop.

## Incident triggers

| Trigger | Source of truth | Notes |
| --- | --- | --- |
| Weapon damage | `weaponDamageEvent` (networked game event) | highest trust available, but still client-emittable — flag-only like the rest |
| Player downed | client death report (baseevents) | flag-only; never pays/grants anything |
| Shots fired | client report, **server-read position** | per-player cooldown + global cap |
| Robbery | `palm6_robbery:started` (server-raised after every start gate passes) | read-only subscription; add more hooks in config |
| Bodycam / manual | officer / staff command | job + ace gated, cooldowns |

All triggers funnel through the same funnel: global scenes-per-minute cap →
**one shared per-source cooldown across every trigger type** (rotating
trigger types buys a griefer nothing) → same-type/same-area dedupe (one
firefight = one scene) → capped participant invite list. Auto-triggered
scenes record the triggering player's citizenid in `flagged_by`, so junk
scenes are attributable. A hostile client's absolute worst case is bounded
junk scenes, size-capped and signed with their own identity.

## Config (`shared/config.lua`)

- `Config.Recording` — `FrameHz` (4), `BufferSeconds` (90), `Enabled`.
- `Config.Incident` — capture `Radius`, `MaxParticipants`, `MaxFrames`,
  `MaxFrameDistance`, `UploadWindowSeconds`, `DedupeSeconds`/`DedupeRadius`,
  `GlobalPerMinuteCap`. **These are the anti-flood caps — raise with care.**
  Plus the anti-forgery knobs: `CorroborationTolerance` (max divergence
  between an uploaded ring and the server's own position read) and
  `ShotAnnotateWindowMs` (window for forcing server-observed shots onto
  uploaded frames).
- `Config.Triggers` — toggle each trigger; `AutoFlagEvents` subscribes to
  other resources' incident events (ships with `palm6_robbery:started`).
  Entries subscribe with `AddEventHandler` unless they carry an explicit
  `clientRaised = true`, so a new entry can never open a name to the network
  by omission.
- `Config.Access` — `Jobs` list + `OnDuty`; optional `RequiredItem` (see
  below).
- `Config.Playback` — `SceneQueryRadius`, `StartRadius` (stand-at-the-scene
  gate), `GhostAlpha`, `Speeds`, `ScrubSeconds`, `LoopPlayback`,
  `FallbackPedModel`.
- `Config.Bodycam` — `Radius`, `CooldownSeconds`, `Enabled`.
- `Config.Retention` — `Days` (7) and `MaxStoredScenes` (300); pruned on
  start and hourly.
- `Config.EvidenceIntegration` — write exhibits into the `palm6_evidence`
  log (auto-degrades to standalone if that table is absent).

### Optional forensic-scanner item

Set `Config.Access.RequiredItem = 'replay_scanner'` **after** adding an item
of that name to your `ox_inventory` data (this resource ships no item
definition of its own — it will not touch shared inventory files). The job
gate alone is the default and works out of the box.

## Install

1. Drop `palm6_replay` into `resources/[custom]/`.
2. Apply `sql/0015_replay.sql` (creates `palm6_replay_scenes` +
   `palm6_replay_participants`, both `palm6_`-prefixed, idempotent
   `CREATE TABLE IF NOT EXISTS`).
3. Add to your server cfg: `ensure palm6_replay` (after `qbx_core`,
   `ox_lib`, `oxmysql`).
4. Optional: `add_ace group.admin command.replayflag allow` for the staff
   flag command.
5. Restart. Console shows
   `[palm6_replay] black-box online — 4 Hz ring, 90s window, 7d retention`.

Smoke test: fire a weapon at a ped/vehicle (or use `/replayflag`), wait ~12
seconds for the upload window to close, then `/replayscenes` → `/replay <id>`
on an on-duty police character standing at the spot.

## Server authority & abuse resistance

- Clients upload buffers **only when invited** by capture id; uninvited,
  late, or duplicate uploads are dropped silently.
- Every frame is rebuilt server-side from whitelisted fields with bounds,
  speed, world-limit, and monotonic-timestamp checks; oversized or
  clock-spoofed uploads are voided.
- Uploads are **corroborated against server-observed truth**, not just shape-
  checked: the newest frame must agree with the server's own coord read of
  that player at invite time (beyond `Config.Incident.CorroborationTolerance`
  metres the ring is rejected as forged), and every `weaponDamageEvent` the
  server observed is forced onto the ring as a `FLAG_SHOOT` frame — a client
  that strips its shoot bits still shows SHOT markers where the server saw it
  deal damage.
- **Evidence trust model:** the corroborated parts of a reconstruction
  (participant position at capture time, server-observed weapon damage) are
  server-verified. Everything else in a ghost's ride-along — its exact path
  between samples, aim/ragdoll stances, shots that hit nothing — is the
  recorded player's **self-reported** telemetry. Treat a reconstruction as a
  witness statement backed by server-verified anchor points, not as raw
  server footage.
- Incident positions always come from the server's own `GetPlayerPed` read.
- Scene creation is dedupe-suppressed, per-source cooled down, and globally
  capped per minute; storage is bounded by participant/frame caps plus
  retention pruning (age + absolute row cap).
- All replay commands re-check job/duty/item **server-side**, and `/replay`
  enforces standing at the scene server-side.
- Nothing in this resource pays, charges, or grants items — worst-case abuse
  is bounded junk telemetry.

## Performance (48-slot)

- Recorder: one 100 ms poll (single native) + one full sample at 4 Hz. No
  per-frame client loops while idle.
- Playback: the per-frame loop exists **only during an active
  reconstruction** and exits the moment it stops.
- Server: event-driven; one 1 s capture-finalizer tick and an hourly prune.
- Net: buffers move only on incident (≤ ~25 KB per invited client);
  playback streams one participant per event.

## Integrations (read-only, zero coupling)

- **palm6_evidence** — `/replayattach` inserts a REPLAY EXHIBIT row into its
  `palm6_evidence` table (schema from `sql/0012_evidence.sql`); guarded so
  absence degrades gracefully. The resource itself is never modified.
- **palm6_robbery** — subscribes to its `palm6_robbery:started` signal as an
  incident trigger. That name is raised SERVER-side with `TriggerEvent` only
  after every start gate passed, so the subscription is a plain
  `AddEventHandler` and the name is never opened to the network (its
  client-triggerable sibling `palm6_robbery:start` is the wrong signal — it
  fires before any gate runs). The owning resource is untouched. Add more
  hooks via `Config.Triggers.AutoFlagEvents`.
- **palm6_turf** — no clean incident event exists today (turf tagging is
  non-violent); intentionally not hooked. Any future `palm6_*` conflict
  event can be added as one config line.

## GTA VI notes

This resource has **zero world coordinates** — the black-box works wherever
the crime happens, so there is no Tier 3 coord retune at all. The only GTA V
values are `Config.Playback.FallbackPedModel` (one model name), the anim
dicts/control ids inside `bridge/cl_game.lua`, and the engine damage/death
events inside `bridge/sv_framework.lua` — all bridge-file rewrites per
`docs/GTA6-READINESS.md` §3. The ring buffer, frame validation, capture
lifecycle, and playback math carry unchanged.

## Deferred to v2

- Full freemode appearance cloning (ghosts use the recorded ped **model**;
  MP freemode ghosts show default faces — translucent anyway).
- Ghost vehicles: in-vehicle participants replay as a gliding ghost ped on
  the vehicle's path rather than a ghost car.
- Synced squad playback from one command (today each officer runs `/replay`
  themselves; frames are identical so timelines match).
- Scene export/printout for court RP.
