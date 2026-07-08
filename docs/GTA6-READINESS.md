# GTA6-READINESS — porting the gtarp custom layer to GTA VI

This document is the migration map for the day a community RP framework
exists for GTA VI. It audits every resource in this custom layer by how
much of it survives the engine change, defines the **bridge pattern** we
use to make the survivable parts portable, and gives a per-resource
migration plan.

It is a living document. Update it whenever a resource is added or its
bindings change.

---

## 1. Reality check (read this first)

We **cannot** write GTA VI RP code today, and not for lack of effort:

- GTA VI is not on PC yet. PC has historically lagged console by a year
  or more.
- **There is no FiveM / CFX equivalent for GTA VI.** No `qbx_core`, no
  `ox_inventory`, no `ox_target`, no natives, no map coordinates. The
  entire stack this server sits on has no GTA VI version.
- The community framework layer (a GTA VI Qbox/ESX analogue) will likely
  land 1–2+ years after PC launch, if history holds.

So "prepare for GTA VI" means three things we **can** do now, in priority
order:

1. **Decouple the portable brain from the game-specific body.** Isolate
   every framework and game-native call behind a thin bridge so the
   business logic ports unchanged. This work also improves the GTA V
   codebase today, so it is never wasted.
2. **Lock the design as engine-agnostic specs.** Economy math, price
   ladders, job payout ranges, feature rules — written as docs and data,
   not Lua. Specs survive any engine.
3. **Grow the real asset: the community.** Discord, allowlist, rules,
   staff, the players. None of it is GTA V specific. That is what carries
   to GTA VI. The GTA V server is the live product until GTA VI tooling
   matures, so hardening and growing it now *is* GTA VI prep.

**Do not freeze the GTA V server waiting for GTA VI.** Treat it as the
live product and run the decoupling track in parallel.

---

## 2. Portability tiers

Every line of this repo falls into one of four tiers.

### Tier 0 — Not ours (wait for the community)
The framework and FXServer itself: `qbx_core`, `ox_inventory`,
`ox_target`, `ox_lib`, `oxmysql`, the FXServer runtime. We do not own
these and cannot port them. We wait for the GTA VI equivalents and target
their APIs through our bridge.

### Tier 1 — Carries as-is or near-as-is (the moat)
The parts with no hard dependency on the GTA V engine or framework:

- Discord allowlist logic, role checks, the allowlist DB table.
- Community rules, staff role matrix, server identity copy.
- Economy **design**: paycheck cadence, starting funds, payout ranges,
  price-ladder formulas.
- Item **catalog data**: names, labels, weights, prices.
- Signature-feature **design**: the courier board's rules, escrow model,
  lifecycle.
- The auto-deploy pipeline (SFTP + panel restart) — engine-independent.
- SQL schema for **our own** tables (`courier_postings`, `audit_log`,
  `event_violations`, `allowlist`, `gtarp_properties`, `grind_skill`,
  `gtarp_evidence`, `gtarp_turf`, …).
- All of `docs/`.

### Tier 2 — Carries with a bridge rewrite (thin adapter swap)
Resources whose **logic** is portable but that call framework or game
APIs. The fix is the bridge pattern (Section 3): the logic stays, you
rewrite one small adapter file per resource against the GTA VI framework.

- `gtarp_courier` (bridged — reference implementation, see Section 4)
- `gtarp_whitelist_jobs`
- `gtarp_staff`
- `gtarp_eventguard`
- `gtarp_perf`
- `gtarp_allowlist` (mostly Tier 1; the `playerConnecting` deferral hook
  is the only runtime binding)
- `server_base`
- `server_identity` (loading screen is Tier 1; spawn handler is Tier 3)
- `gtarp_grind` (loop timing, yields, prices, XP are Tier 1; gather-spot
  and buyer coords are Tier 3 — see retune worksheet §10)
- `gtarp_robbery` (ATM-only — timers, rewards, dispatch logic are Tier 1/2;
  ATM coords are Tier 3 — see retune worksheet §11. Store robbery is
  recipe-owned `qbx_storerobbery`, not duplicated here)
- `gtarp_mechanic` (repair-invoice logic, no coords of its own — targets
  whatever damaged vehicle is nearby)
- `gtarp_evidence` (log/locker lifecycle is Tier 1/2; locker coords are
  Tier 3 — see retune worksheet §12)
- `gtarp_turf` (zone/ownership/leaderboard lifecycle is Tier 1/2; zone
  coords are Tier 3 — see retune worksheet §13)
- `gtarp_bounty` (contract ledger, warrant sync, escrow, and the capture
  guard are Tier 1/2; the Bounty Board desk coords are Tier 3)
- `gtarp_fightclub` (queue/pairing, betting pool, parimutuel payout math,
  and the knockout/forfeit sweep are Tier 1/2; the Ring coords are Tier 3)

### Tier 3 — Rewrite / retune (bound to the GTA V world)
Anything tied to the Los Santos map, the GTA V model set, or GTA V
natives. GTA VI ships a new map (Leonida / Vice City), new model names,
and new native ids. These do not "port"; they get re-authored against the
new world:

- Spawn coordinates (`vector4(195.17, -933.77, 30.69, 144.0)` Legion Sq.).
- Job location coords (police/EMS armouries, civilian job NPCs).
- Shop world coords.
- Vehicle and weapon **model names** in police/ambulance/civilian configs.
- Blip sprite ids, blip colours.
- Population-density natives (`qbx_density_overrides`).

The **values** are Tier 3, but the **structure** holding them is Tier 1 —
so the retune is "fill in new coords/models," not "rewrite the system."

---

## 3. The bridge pattern

The single technique that makes Tier 2 portable.

**Rule:** core logic never calls a framework export or a game native
directly. It calls a stable internal API that we own. Each resource ships
a `bridge/` folder that is the *only* place framework/native calls live.

```
gtarp_<resource>/
  bridge/
    sv_framework.lua   -- server: wraps qbx_core money/identity/notify
    cl_game.lua        -- client: wraps GTA natives (blips, coords, peds)
  server/main.lua      -- pure logic, calls Bridge.* only
  client/main.lua      -- pure logic, calls Game.* only
  shared/config.lua    -- engine-agnostic tunables
```

- **`Bridge.*`** (server) — the framework adapter. Today it wraps
  `qbx_core`. On GTA VI you rewrite *this file only* to wrap the new
  framework, and every net event, escrow rule, and validation above it is
  untouched.
- **`Game.*`** (client) — the game adapter. Today it wraps GTA V natives
  (`AddBlipForCoord`, `GetEntityCoords`, …). On GTA VI you rewrite *this
  file only* against the new natives.

**Migration cost per Tier 2 resource = rewrite 2 small files**, not the
resource. That is the entire point.

This is the same pattern real frameworks use (qbx's own bridges,
ESX/QB compatibility shims, ox compat layers). It is good engineering
independent of GTA VI: it makes the logic unit-reviewable, swappable, and
free of native noise.

### What goes in the bridge vs the logic

| Goes in `bridge/` | Stays in `server/`,`client/` logic |
|---|---|
| `exports.qbx_core:GetPlayer` | escrow rules, bounds checks |
| `Player.Functions.AddMoney/RemoveMoney` | posting lifecycle, sweep timing |
| `players.money` JSON DB writes | our own `courier_postings` SQL |
| `TriggerClientEvent('ox_lib:notify')` | what message to send, when |
| `AddBlipForCoord`, `SetBlipRoute` | which coord, which label |
| `GetEntityCoords`, `PlayerPedId` | arrival-distance comparison |
| `GetGameTimer` (perf sampler) | p95/p99 math, thresholds |
| `playerConnecting` deferral plumbing | allowlist decision, Discord call |

Note that our **own** SQL (the `courier_postings` table) stays in the
logic — it is our schema and fully portable. Only writes against the
**framework's** tables (`players.money`) belong in the bridge.

---

## 4. Reference implementation: gtarp_courier

`gtarp_courier` is the first resource bridged, as the pattern template.

**Server bridge — `bridge/sv_framework.lua`** exposes `Bridge`:
- `Bridge.GetCitizenId(src)` — stable player id
- `Bridge.GetBankBalance(src)` — for the escrow affordability check
- `Bridge.ChargeBank(src, amount, reason)` — debit escrow
- `Bridge.CreditBank(src, amount, reason)` — pay an online player
- `Bridge.CreditBankByCitizenId(citizenid, amount, reason)` — refund,
  online if present else an offline DB write (the only place the qbx
  `players.money` JSON shape is known)
- `Bridge.Notify(src, title, msg, type)` — player notification

**Client bridge — `bridge/cl_game.lua`** exposes `Game`:
- `Game.GetPlayerCoords()` → `{x,y,z}`
- `Game.GetWaypointCoords()` → `{x,y,z}` or `nil`
- `Game.DistanceBetween(a, b)` → metres
- `Game.CreateRouteBlip(coords, label, colour)` → handle
- `Game.RemoveBlip(handle)`
- `Game.Notify(opts)`

After the refactor, `server/main.lua` and `client/main.lua` contain **zero**
direct `qbx_core`, `ox_lib`, or native calls. Grep-verifiable (Section 6).

**To port the courier to GTA VI:** rewrite `bridge/sv_framework.lua`
against the new framework's money API and `bridge/cl_game.lua` against the
new blip/coord natives. The board, escrow, lifecycle, and sweep do not
change.

---

## 5. Per-resource migration plan

Ordered by how cheaply each ports. Tackle Tier-1-heavy resources first
when the GTA VI framework lands; save Tier-3 retunes for when the new map
coords are known.

| Resource | Dominant tier | Migration work |
|---|---|---|
| `gtarp_allowlist` | 1 | Re-point the connect-deferral hook; Discord call unchanged. |
| `gtarp_eventguard` | 1/2 | Logic unchanged; update the **guarded event names** to the new framework's money/inventory events. |
| `sql/*` (our tables) | 1 | Apply as-is. Re-check only migrations that assume qbx `players`/`jobs` shape. |
| deploy workflow | 1 | Repoint paths to the GTA VI server base; mechanism unchanged. |
| `gtarp_courier` | 2 | Rewrite 2 bridge files (done as template). |
| `gtarp_whitelist_jobs` | 2 | Bridge the `setjob`/`OnPlayerLoaded` calls; allow-table logic unchanged. |
| `gtarp_staff` | 2 | Bridge name/identifier lookups only; webhook + audit logic unchanged (commands removed 2026-07-03 — recipe owns them). |
| `gtarp_perf` | 2 | Bridge `GetGameTimer`; p95/p99 math unchanged. |
| `server_base` | 2 | Bridge `/coords` natives; banner/logger/`/serverinfo` unchanged. |
| `server_identity` | 2/3 | Loading screen carries as-is; **respawn coords** are Tier 3. |
| `gtarp_grind` | 2/3 | Bridge inventory/XP calls; loop timing and yields unchanged. **Gather-spot and buyer coords** (worksheet §10) are Tier 3. |
| `gtarp_robbery` | 2/3 | ATM-only. Bridge police-dispatch/notify calls; timers and rewards unchanged. **ATM coords** (worksheet §11) are Tier 3. Store robbery is recipe-owned `qbx_storerobbery`. |
| `gtarp_mechanic` | 2 | Bridge the framework money/job calls and repair natives; invoice logic unchanged. No coords of its own. |
| `gtarp_evidence` | 2/3 | Bridge the framework job/stash calls; log/locker logic unchanged. **Locker coords** (worksheet §12) are Tier 3. |
| `gtarp_turf` | 2/3 | Bridge the framework gang calls and blip natives; tag/ownership/leaderboard logic unchanged. **Zone coords** (worksheet §13) are Tier 3. |
| `gtarp_bounty` | 2/3 | Bridge the framework money/health/position calls; contract ledger, warrant sync, and capture-guard logic unchanged. **Bounty Board desk coords** are Tier 3. |
| `gtarp_fightclub` | 2/3 | Bridge the framework money/health/position/weapon calls; queue pairing, betting pool, knockout/forfeit sweep, and parimutuel payout math unchanged. **Ring coords** are Tier 3. |
| `[config_overrides]/qbx_economy` | 1 (values) | Re-wire to new framework's economy keys; **numbers carry**. |
| `[config_overrides]/ox_inventory` (items) | 1 (data) | Item catalog carries; re-wire to new inventory API; shop **coords** Tier 3. |
| `[config_overrides]/qbx_police` etc. | 3 | Re-author coords + **model names**; grade/salary **design** carries. |
| `[config_overrides]/qbx_density` | 3 | Rewrite against new population natives. |
| `[config_overrides]/qbx_core` | 0/3 | Depends entirely on the GTA VI framework's config surface. |

---

## 6. Verification gates (per the build roadmap)

A resource is "bridge-clean" when:

1. **Logic files contain no framework/native calls.** Grep the
   `server/` and `client/` logic files (excluding `bridge/`):
   ```
   grep -rn "qbx_core\|\.Functions\.\|PlayerData\|ox_lib:notify" server/ client/
   grep -rn "AddBlipFor\|GetEntityCoords\|PlayerPedId\|GetGameTimer" server/ client/
   ```
   Both return nothing (matches live only under `bridge/`).
2. **`fxmanifest.lua` loads the bridge before the logic** in each context
   (client bridge before client logic; server bridge after `@oxmysql`,
   before server logic).
3. **Behaviour is unchanged.** Same net events, same SQL, same player
   experience. The bridge is a pure extraction, not a rewrite.
4. **Lua parses clean** (`luac -p`, or the structural checker in
   `docs/notes/` when no Lua toolchain is present).

---

## 7. Open decisions for David

- **GTA VI framework bet.** When the scene forms, do we follow whoever
  ports Qbox, back ESX's successor, or stay framework-neutral behind the
  bridge until a winner is clear? The bridge buys us the option to wait.
- **Map re-authoring budget.** Tier 3 retunes (coords/models) are the
  bulk of launch-day GTA VI work. The fill-in-the-blanks worksheet is now
  pre-written — see `docs/GTA6-TIER3-RETUNE.md` (and the importable
  `docs/gta6-tier3-retune.csv`), which catalogs every current GTA V coord,
  vehicle/weapon model, blip id, and density lever with a blank GTA VI
  column and the exact source file to paste each value back into.
- **First-mover vs stability.** Being early on a new engine means broken
  natives and churn. Decide whether gtarp chases the GTA VI launch window
  or lets the framework layer stabilise first.
