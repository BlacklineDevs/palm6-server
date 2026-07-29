# palm6_heat

**Persistent, decaying police attention.** The crime loop mints money and
reputation but, until this resource, no *lasting* heat — heat was transient (a
live chase, then gone). `palm6_heat` is the durable per-citizen "heat" score:
crime raises it, wall-clock time bleeds it off, and police / dispatch / the
season Most-Wanted ladder read it. **Crime should follow you home.**

Self-contained, the `palm6_wanted` / `palm6_ems` pattern: it owns exactly one
table (`palm6_heat_state`, self-created at boot), writes nothing else, edits no
crime file, and soft-degrades if the DB is unreachable — so a fault here can
never break the crime layer.

## Model

Heat is an `INT` stored with the row's `updated_at`. Effective heat is derived
on **read**:

```
eff = max(0, stored - floor(minutes_since_update * DecayPerMin))
```

The DB is written only when heat is **added** (or a fully-decayed row is swept)
— never once-per-tick-per-citizen. **Getting arrested or dying does NOT clear
heat; only time does.** Defaults: cap 150, decay 0.75/min (≈3h20m to fully cool
from maxed), single-add clamp 60.

## Commands

| Command | Who | What |
|---|---|---|
| `/heat` | on-duty police | live priority board of the hottest citizens |
| `/myheat` | any citizen | your own heat, tier, and cool-down ETA |

Tiers (Config.Tiers): `CLEAN → COOL → WARM → HOT → WANTED`.

## Exports (frozen)

```lua
exports.palm6_heat:AddHeat(citizenid, amount, reason, name?) --> { heat, tier } | nil
exports.palm6_heat:GetHeat(citizenid)  --> integer effective heat (0 if clean)
exports.palm6_heat:GetTier(citizenid)  --> 'CLEAN'|'COOL'|'WARM'|'HOT'|'WANTED'
exports.palm6_heat:GetTop(limit?)      --> { { citizenid, name, heat, tier, reason }, ... }
exports.palm6_heat:GetSummary()        --> { tracked, warm, hot, wanted, lifetime }
```

`AddHeat` is server-authoritative and input-safe: `amount` is clamped to
`Config.MaxAddPerCall`, garbage returns `nil` (a no-op) rather than throwing,
and `name` is optional (falls back to an online citizenid→name lookup, never
touching the qbx `players` schema — the name is denormalised onto our row).

## Wiring (this is WIRED; earlier revisions of this file said otherwise)

`AddHeat` is called from **ten** resources. This section used to claim the
resource "ships UNWIRED"; that has not been true for a long time, and the stale
claim is what let heat drift into being a leaderboard nobody felt.

| Resource | Reason string | Fires on |
|---|---|---|
| `palm6_robbery` | `atm_robbery` | successful ATM job |
| `palm6_chopshop` | `chopshop` | committed vehicle sale (+bonus if reported stolen) |
| `palm6_smuggling` | `smuggle_run` | committed delivery payout |
| `palm6_gunrunning` | `gun_deal` | committed black-market weapon purchase |
| `palm6_laundering` | `launder` | committed wash, **amount-proportional** (does *not* use `Config.Suggested.launder`; see its `Config.PlayerHeat`) |
| `palm6_protection` | `shakedown` | collected extortion payment |
| `palm6_drugs` | `drug_sale`, `drug_lab` | street sale / lab collect (1 add per cid **per reason** per min) |
| `palm6_counterfeit` | `counterfeit` | completed print cycle (after the jam bail) |
| `palm6_ransom` | `kidnap_ransom` | the ransom **demand**, never the payout |
| `palm6_witnesses` | `reported_crime`, `shots_fired`, `intimidation` | a persisted incident |

`palm6_witnesses` is the load-bearing one. The heaviest crimes (murder, the
bank job, jewellery, house robbery) live in `qbx_*` resources that are **not in
this repo**, so there is no file to add a line to. They all funnel through
`police:server:policeAlert`, which `palm6_witnesses` already shadow-listens on,
making its `finalizeIncident` the only portable hook that reaches them.

That alert is a *shared* bus, not a qbx-only one: seven in-repo resources raise
it as well, and most of them already call `AddHeat` on the same code path. So
`palm6_witnesses` suppresses its own `reported_crime` charge for any alert that
arrived from a server-side `TriggerEvent` (which every in-repo emitter uses) and
only scores client-fired alerts. See `palm6_witnesses/shared/config.lua`
`Config.Heat`. **If you add a `Bridge.PoliceAlert` call to a resource, you own
its heat wire**. The witness layer will not price it for you.

To wire a NEW crime resource, add ONE block where it pays out / commits the
crime, keyed to the **actor's own** citizenid, using a weight from
`Config.Suggested` and the soft-dep shape every existing wire uses:

```lua
-- e.g. in palm6_robbery on a successful ATM job:
if GetResourceState('palm6_heat') == 'started' then
    pcall(function()
        exports.palm6_heat:AddHeat(citizenid, 8, 'atm_robbery', playerName)
    end)
end
```

Suggested weights live in one place (`Config.Suggested`) so every wirer pulls
from the same table: a petty ATM barely registers (3–8), a bank heist maxes you
out fast (55). Adding heat is loose-coupled and non-breaking — if `palm6_heat`
is stopped, the whole block is a no-op.

**Anti-farm is the wirer's job.** Every wire must sit *after* the payout is
committed, must key to the actor (never a client-supplied citizenid, so nobody
can heat up a rival), and must be bounded by something: a per-character
cooldown, a daily cap, a consumable, or its own throttle. Where the owning
resource's cooldown was too loose to carry a heat wire (`palm6_drugs`, whose
sell cooldown is 8s), the wire carries its own.

### Consumers

- **`palm6_laundering`** (live): reads `GetTier` and skims extra off a `HOT` or
  `WANTED` launderer. See its `Config.HeatScrutiny`.
- **`palm6_season` Most-Wanted ladder**: reads `GetTop` (`noPrize` ladder F).
- **`palm6_dispatch`** (planned, not built): would treat a citizen at or above
  `Config.DispatchPriorityTier` (`HOT`) as priority.

## Housekeeping

The 5-minute sweep **settles** a fully-decayed row to `heat = 0` rather than
deleting it: `heat` re-derives from `updated_at` on every read, but `lifetime`
is a cumulative career total that `GetSummary` returns as part of this contract,
and deleting the row destroyed it. A settled row is deleted only after
`Config.SweepRetainDays` (30) of no crime at all.

## Schema (self-created at boot, idempotent)

```sql
CREATE TABLE IF NOT EXISTS `palm6_heat_state` (
    `citizenid`    VARCHAR(64)  NOT NULL,
    `citizen_name` VARCHAR(96)  DEFAULT NULL,
    `heat`         INT UNSIGNED NOT NULL DEFAULT 0,
    `lifetime`     BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `last_reason`  VARCHAR(64)  DEFAULT NULL,
    `updated_at`   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_heat` (`heat`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```
