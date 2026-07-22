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

## Wiring (this ships UNWIRED)

Nothing calls `AddHeat` yet — same as every palm6 civic resource shipped first,
wired second. To wire a crime resource, add ONE line where it pays out / commits
the crime, using a weight from `Config.Suggested`:

```lua
-- e.g. in palm6_robbery on a successful ATM job:
exports.palm6_heat:AddHeat(citizenid, 8, 'atm_robbery', playerName)
```

Suggested weights live in one place (`Config.Suggested`) so every wirer pulls
from the same table: a petty ATM barely registers (3–8), a bank heist maxes you
out fast (55). Adding heat is loose-coupled and non-breaking — if `palm6_heat`
is stopped, the `exports.palm6_heat:AddHeat` call is a harmless no-op.

### Two consumers this unblocks

- **`palm6_season` Most-Wanted ladder** (currently commented out because no
  durable wanted score existed): re-enable it to read `GetTop` / `GetSummary`.
- **`palm6_dispatch` (planned)** and **`palm6_laundering`**: treat a citizen at
  or above `Config.DispatchPriorityTier` (`HOT`) as priority — louder dispatch,
  extra launder scrutiny — via `GetTier`.

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
