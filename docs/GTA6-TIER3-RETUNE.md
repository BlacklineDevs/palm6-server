# GTA6-TIER3-RETUNE — the map/model fill-in-the-blanks worksheet

Tier 3 (see `docs/GTA6-READINESS.md` §2) is everything bound to the **Los
Santos map, the GTA V model set, or GTA V native ids**. GTA VI ships a new
map (Leonida / Vice City), new model names, and new native ids, so these
values do **not** port — they get re-authored against the new world.

The good news, and the whole point of the bridge work: the **structure**
holding these values is Tier 1 and already portable. So this is not a
rewrite — it is filling in a column. When GTA VI tooling exists:

1. Fill the **GTA VI value** column below (or edit the companion
   `gta6-tier3-retune.csv` in a spreadsheet).
2. Paste each value back into its **Source file**.
3. Keep the two spawn entries (§1) identical — they are cross-referenced.

Every "Current (GTA V)" value here was extracted from the live config on
2026-06-30. If a config changes, update this worksheet (it is a living doc,
like the readiness map).

> Item **catalog** data (labels, prices, weights) and job **design** (grades,
> salaries, payout bounds, densities-as-ratios) are **Tier 1** — they carry.
> Only the map coords, the GTA-model names, and the native-id levers below are
> Tier 3.

---

## 1. Spawn point

Keep both entries identical — `server_base` reads its copy as the canonical
value and `server_identity` repositions the character to it.

| Item | Current (GTA V) | GTA VI value | Source file |
| --- | --- | --- | --- |
| Default spawn — Legion Square | `vector4(195.17, -933.77, 30.69, 144.0)` | _TBD_ | `resources/[custom]/server_identity/config.lua` → `Config.SpawnPoint` |
| Default spawn (mirror) | `vector4(195.17, -933.77, 30.69, 144.0)` | _TBD_ | `resources/[custom]/server_base/config.lua` → `Config.DefaultSpawn` |

## 2. Emergency-services coords

Source: `resources/[custom]/[config_overrides]/qbx_police_overrides/config.lua`
and `.../qbx_ambulance_overrides/config.lua`.

| Item | Current (GTA V) | GTA VI value | Key |
| --- | --- | --- | --- |
| Police armoury — Mission Row | `vector3(461.79, -983.04, 30.69)` r1.2 | _TBD_ | police `Config.Armoury[1].coords` |
| Police duty toggle — Mission Row | `vector3(442.32, -988.43, 30.69)` r1.0 | _TBD_ | police `Config.DutyToggle.coords` |
| Ambulance hospital — Pillbox Hill | `vector3(307.7, -1433.4, 29.9)` r3.0 | _TBD_ | ambulance `Config.Hospitals[1].coords` |
| Ambulance duty toggle — Pillbox Hill | `vector3(311.5, -1432.0, 30.0)` r1.0 | _TBD_ | ambulance `Config.DutyToggle.coords` |

## 3. Civilian job starter NPCs

Source: `.../qbx_civilian_jobs_overrides/config.lua` → `Config.Jobs.<job>.starter_npc.coords`.

| Item | Current (GTA V) | GTA VI value | Key |
| --- | --- | --- | --- |
| Trucker Dispatch | `vector3(150.95, -3040.0, 7.04)` r1.5 | _TBD_ | `trucker` |
| Downtown Cab Co. (taxi) | `vector3(903.13, -174.83, 73.97)` r1.5 | _TBD_ | `taxi` |
| LS Sanitation (garbage) | `vector3(-322.65, -1545.13, 27.79)` r1.5 | _TBD_ | `garbage` |
| Benny's — LS Customs (mechanic) | `vector3(-205.45, -1311.66, 31.30)` r1.5 | _TBD_ | `mechanic` |

## 4. Shop world coords

Source: `.../ox_inventory_overrides/data/shops.lua` → `ExtraShops.<shop>.locations`.
Labels/prices/inventory are Tier 1 (carry); only the coords are Tier 3.

| Shop | # | Current (GTA V) | GTA VI value |
| --- | --- | --- | --- |
| General Store | 1 | `vector3(24.47, -1346.62, 29.50)` — Innocence Blvd | _TBD_ |
| General Store | 2 | `vector3(-3038.94, 585.95, 7.91)` — Pacific Bluffs | _TBD_ |
| General Store | 3 | `vector3(-3242.47, 1001.46, 12.83)` — Banham Canyon | _TBD_ |
| General Store | 4 | `vector3(1728.66, 6414.16, 35.04)` — Paleto Bay | _TBD_ |
| General Store | 5 | `vector3(1163.37, -323.80, 69.21)` — Mirror Park | _TBD_ |
| General Store | 6 | `vector3(2557.94, 382.05, 108.62)` — Tataviam Mtns | _TBD_ |
| General Store | 7 | `vector3(373.87, 325.89, 103.57)` — Downtown | _TBD_ |
| Ammu-Nation | 1 | `vector3(21.7, -1106.42, 29.80)` — Innocence Blvd | _TBD_ |
| Ammu-Nation | 2 | `vector3(810.25, -2157.6, 29.62)` — El Burro Heights | _TBD_ |
| Ammu-Nation | 3 | `vector3(1693.4, 3760.6, 34.71)` — Sandy Shores | _TBD_ |
| Hardware Store | 1 | `vector3(2748.4, 3473.4, 55.66)` — Sandy Shores | _TBD_ |
| Hardware Store | 2 | `vector3(-422.7, 6136.0, 31.86)` — Paleto Bay | _TBD_ |
| Suburban (clothing) | 1 | `vector3(127.0, -223.4, 54.56)` | _TBD_ |
| Police Armoury (society) | 1 | `vector3(461.79, -983.04, 30.69)` | _TBD_ |
| EMS Medical Supply (society) | 1 | `vector3(307.7, -1433.4, 29.9)` | _TBD_ |

## 5. Vehicle model names

Source: police/ambulance overrides `Config.VehicleAllowed`. GTA VI ships a new
vehicle model set — re-map each to its VI equivalent.

| Fleet | Current (GTA V models) | GTA VI models | Source |
| --- | --- | --- | --- |
| Police motor pool | `police, police2, police3, policeb, policet` | _TBD_ | `qbx_police_overrides/config.lua` |
| Ambulance motor pool | `ambulance` | _TBD_ | `qbx_ambulance_overrides/config.lua` |

## 6. Weapon model names (loadouts)

Source: police/ambulance overrides `Config.LoadoutAllowed`. The **item names**
are catalog data (Tier 1) *if* the same item exists in the new inventory, but
each `weapon_*` name maps to a GTA V weapon model/hash — re-map those. Non-
weapon items (ammo, handcuffs, radio, armor, bandage, medikit, etc.) are Tier 1
and carry.

| Job | GTA-model-bound entries (GTA V) | GTA VI equivalents | Source |
| --- | --- | --- | --- |
| Police | `weapon_combatpistol, weapon_stungun, weapon_nightstick, weapon_flashlight` | _TBD_ | `qbx_police_overrides/config.lua` |
| Ambulance | (no weapon models — all Tier 1 items) | n/a | `qbx_ambulance_overrides/config.lua` |

## 7. Blip sprites & colours

Source: `resources/[custom]/gtarp_courier/bridge/cl_game.lua` →
`Game.CreateRouteBlip`. Blip sprite/colour ids are GTA V native ids; re-map to
the GTA VI blip id table. (This is the only custom-authored blip — recipe jobs
own their own blips upstream.)

| Item | Current (GTA V) | GTA VI value |
| --- | --- | --- |
| Courier delivery blip — sprite | `1` | _TBD_ |
| Courier delivery blip — colour | `5` (default) | _TBD_ |

## 8. Population density levers

Source: `.../qbx_density_overrides/config.lua` → `Config.Density`. The
**values** (0.0–1.0 ratios) are design and likely carry, but they feed GTA V
population natives (`SetPedDensityMultiplierThisFrame`, etc.) — confirm the
GTA VI native names/behaviour and re-map the density-type keys if they change.

| Lever | Current value | GTA VI value | Note |
| --- | --- | --- | --- |
| `peds` | `0.9` | _carry?_ | walking civilians |
| `vehicle` | `0.7` | _carry?_ | moving traffic (heaviest perf cost) |
| `randomvehicles` | `0.7` | _carry?_ | rarer ambient vehicles |
| `parked` | `0.8` | _carry?_ | parked cars |
| `scenario` | `0.7` | _carry?_ | scripted scenario crowds |

## 9. Housing — doors & shell interiors

Source: `resources/[custom]/gtarp_housing/shared/config.lua`
(`Config.Properties[*].door` and `Config.Shells[*].interior`). The buy/sell/
keys/instancing lifecycle is Tier 1; only these coords are Tier 3.

| Item | Current (GTA V) | GTA VI value | Key |
| --- | --- | --- | --- |
| Property door — Integrity Way | `vector4(-47.24, -585.35, 36.96, 340.0)` | _TBD_ | `Properties integrity_1` |
| Property door — Del Perro Heights | `vector4(-1447.06, -538.79, 34.74, 145.0)` | _TBD_ | `Properties delperro_1` |
| Property door — Mirror Park Blvd | `vector4(1148.90, -1521.30, 34.90, 100.0)` | _TBD_ | `Properties mirror_1` |
| Property door — Alhambra Dr (Sandy) | `vector4(1972.40, 3815.20, 33.43, 120.0)` | _TBD_ | `Properties sandy_1` |
| Shell interior — apartment | `vector4(266.09, -1007.98, -101.01, 0.0)` | _TBD_ | `Shells apartment` |
| Shell interior — mid house | `vector4(346.20, -1013.10, -99.20, 0.0)` | _TBD_ | `Shells mid` |
| Shell interior — trailer | `vector4(1973.30, 3818.40, 33.43, 60.0)` | _TBD_ | `Shells trailer` |

## 10. Grind — gather spots & buyers

Source: `resources/[custom]/gtarp_grind/shared/config.lua`
(`Config.Activities[*].spots` and `.sell.coords`). Tools/yields/prices/XP are
Tier 1; only coords are Tier 3.

| Activity | Item | Current (GTA V) | GTA VI value |
| --- | --- | --- | --- |
| Fishing | spot 1 | `vector3(-1850.20, -1235.60, 8.62)` | _TBD_ |
| Fishing | spot 2 | `vector3(1299.80, 4224.90, 33.00)` | _TBD_ |
| Fishing | spot 3 | `vector3(-1607.90, 5261.30, 3.90)` | _TBD_ |
| Fishing | buyer | `vector3(-1817.30, -1193.20, 14.30)` | _TBD_ |
| Mining | spot 1 | `vector3(2954.10, 2782.30, 40.50)` | _TBD_ |
| Mining | spot 2 | `vector3(2969.40, 2835.60, 42.20)` | _TBD_ |
| Mining | spot 3 | `vector3(2915.00, 2792.00, 39.80)` | _TBD_ |
| Mining | buyer | `vector3(1109.60, -2007.90, 31.00)` | _TBD_ |
| Hunting | spot 1 | `vector3(-1150.40, 4880.70, 220.10)` | _TBD_ |
| Hunting | spot 2 | `vector3(-560.20, 5335.80, 70.40)` | _TBD_ |
| Hunting | spot 3 | `vector3(-778.10, 5591.40, 33.50)` | _TBD_ |
| Hunting | buyer | `vector3(85.20, 6410.30, 31.30)` | _TBD_ |

## 11. Robbery — registers & ATMs

Source: `resources/[custom]/gtarp_robbery/shared/config.lua`
(`Config.Stores.locations`, `Config.ATMs.locations`). Rewards/timers/dispatch
are Tier 1; only coords are Tier 3.

| Target | Current (GTA V) | GTA VI value |
| --- | --- | --- |
| Store — LTD Mirror Park | `vector3(1163.10, -322.90, 69.20)` | _TBD_ |
| Store — LTD Grove St | `vector3(-47.30, -1757.40, 29.42)` | _TBD_ |
| Store — 247 Sandy Shores | `vector3(1961.30, 3740.30, 32.34)` | _TBD_ |
| Store — 247 Grapeseed | `vector3(1697.90, 4924.20, 42.06)` | _TBD_ |
| Store — Rob's Liquor Vinewood | `vector3(-1222.10, -906.90, 12.33)` | _TBD_ |
| ATM — Legion Sq | `vector3(147.40, -1035.50, 29.34)` | _TBD_ |
| ATM — Del Perro | `vector3(-1204.60, -324.80, 37.87)` | _TBD_ |
| ATM — Sandy Shores | `vector3(1822.40, 3683.10, 34.28)` | _TBD_ |

## 12. Evidence — locker

Source: `resources/[custom]/gtarp_evidence/shared/config.lua`
(`Config.LockerCoords`). Log/locker lifecycle is Tier 1; only the coord is
Tier 3. Matches `qbx_police`'s own Mission Row station coords
(`config/shared.lua` `locations.duty[1]`) — keep the two in sync if either
changes.

| Item | Current (GTA V) | GTA VI value |
| --- | --- | --- |
| Evidence locker — Mission Row | `vector3(434.0, -983.0, 30.7)` | _TBD_ |

## 13. Turf — gang zones

Source: `resources/[custom]/gtarp_turf/shared/config.lua` (`Config.Zones`).
Tag/ownership/leaderboard lifecycle is Tier 1; only coords are Tier 3.
These reuse already-validated points from elsewhere in this worksheet
(spawn §1, shops §4, robbery §11) rather than new coords — retune those
sections and this one together if a shared point moves.

| Zone | Current (GTA V) | GTA VI value |
| --- | --- | --- |
| Legion Square | `vector3(195.17, -933.77, 30.69)` | _TBD_ |
| Grove Street | `vector3(-47.30, -1757.40, 29.42)` | _TBD_ |
| Mirror Park | `vector3(1163.10, -322.90, 69.20)` | _TBD_ |
| Vinewood | `vector3(-1222.10, -906.90, 12.33)` | _TBD_ |
| Sandy Shores | `vector3(1961.30, 3740.30, 32.34)` | _TBD_ |
| Paleto Bay | `vector3(1728.66, 6414.16, 35.04)` | _TBD_ |

---

## Not in this worksheet (intentionally)

- **Recipe-owned map values** (qbx_core default spawn fallback, recipe job
  blips, recipe garage/impound coords) — those live in Tier 0 resources we
  don't own; the community's GTA VI framework will re-author them.
- **Our own SQL, item catalog, economy math, allowlist, rules, staff matrix**
  — Tier 1, carries unchanged.
