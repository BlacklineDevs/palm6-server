# gtarp_drugs — Design Spec (a faithful *Schedule I* adaptation)

Engine-agnostic design spec (Tier-1 per `GTA6-READINESS.md`) for the drug
supply-chain resource. Models the Steam game **Schedule I** (TVGS): produce →
**mix custom branded products with stacking effects + quality** → sell → build a
customer base → hire dealers → launder → dodge heat → rank up.

**Stack:** FiveM · Qbox (`qbx_core`) · `ox_inventory` (item metadata) · `ox_target` ·
`ox_lib` · `oxmysql`. **Integrates with:** `gtarp_laundering`, `gtarp_evidence`,
police/dispatch, `gtarp_economy`, `gtarp_eventguard`.

---

## 1. Base drugs

| id | label | base_value | default_effect | unlock_rank |
|---|---|---|---|---|
| `weed_ogkush` | OG Kush | 38 | Calming | 0 |
| `weed_sourdiesel` | Sour Diesel | 40 | Refreshing | 0 |
| `weed_greencrack` | Green Crack | 43 | Energizing | 1 |
| `weed_gdp` | Granddaddy Purple | 44 | Sedating | 1 |
| `shrooms` | Shrooms | 36 | *(none)* | 3 |
| `meth` | Meth | 70 | *(none)* | 4 |
| `cocaine` | Cocaine | 150 | *(none)* | 6 |

Weed: seed → pot+soil → water/tend (wall-clock growth) → harvest buds → optional dry.
Meth: pseudo(+grade)+acid+red_phosphorus → cook. Coke: coca seed → leaves → +gasoline → cauldron.

## 2. Additives → base effect (the mix system)

Take a base product to a **mixing station**, add **one additive at a time** → new
product; then **name/brand** it. Each additive adds one base effect (if absent);
if the product already carries certain effects, the additive **transforms** them
(order-sensitive; A-then-B ≠ B-then-A). Up to **8 effects** per product.

| Additive | Effect | Additive | Effect |
|---|---|---|---|
| Cuke | Energizing | Banana | Gingeritis |
| Paracetamol | Sneaky | Donut | Calorie-Dense |
| Viagra | Tropic Thunder | Mouth Wash | Balding |
| Flu Medicine | Sedating | Gasoline | Toxic |
| Energy Drink | Athletic | Motor Oil | Slippery |
| Mega Bean | Foggy | Chili | Spicy |
| Battery | Bright-Eyed | Iodine | Jennerising |
| Addy | Thought-Provoking | Horse Semen | Long-Faced |

Grow additives (separate — set quality/yield, not mix effects): `fertilizer`→Premium,
`speed_grow`, `pgr`.

## 3. Effects & value multipliers

Positive (26): Shrinking .60, Zombifying .58, Cyclopean .56, Anti-Gravity .54,
Long-Faced .52, Electrifying .50, Glowing .48, Tropic Thunder .46, Thought-Provoking
.44, Jennerising .42, Bright-Eyed .40, Spicy .38, Foggy .36, Slippery .34, Athletic
.32, Balding .30, Calorie-Dense .28, Sedating .26, Sneaky .24, Energizing .22,
Gingeritis .20, Euphoric .18, Focused .16, Refreshing .14, Munchies .12, Calming .10.

Junk (0.00, some with downsides): Disorienting, Explosive, Laxative, Paranoia,
Schizophrenic, Seizure-Inducing, Smelly, Toxic.

Reaction/transform table (order-dependent) = Phase-2 config, filled from the live
mixing database. Bad mixes can inflict a junk effect (RP tension).

## 4. Quality tiers

| tier | key | markup | source |
|---|---|---|---|
| Trash | 0 | ×0.60 | over-additived grow |
| Poor | 1 | ×0.80 | single grow additive |
| Standard | 2 | ×1.00 | default (no additives) |
| Premium | 3 | ×1.15 | Fertilizer |
| Heavenly | 4 | ×1.30 | dried on rack |

## 5. Price formula (server-authoritative)

```
unit_price = round( base_value
                    × (1 + Σ effect_multipliers)   -- effects capped at 8
                    × quality_markup
                    × region_demand_mod )          -- default 1.0
```

Examples — Standard OG Kush no-mix: 38×1.10×1.00 = **$42**. Heavenly Green Crack +
Banana + Chili: 43×(1+.22+.20+.38)×1.30 = **$101**. Heavenly Coke, 4 top effects:
150×3.00×1.30 = **$585** (cap per-unit + region demand so it can't wreck the economy).

## 6. ox_inventory items & metadata

Register plain items (seeds, soil, fertilizer, speed_grow, pgr, wateringcan, pseudo
[grade meta], acid, red_phosphorus, gasoline) and raw metadata items (`weed_bud`,
`coca_leaf`, `meth_raw`, `shroom_raw` → `{strain,quality,effects,dried}`).

**Finished product = one item id per family** (`weed_product`, `meth_product`,
`coke_product`, `shroom_product`) differentiated ENTIRELY by metadata:

```
metadata = { brand="Purple Haze Deluxe", base="weed_gdp",
             effects=["Sedating","Spicy","Anti-Gravity"],  -- ≤8
             quality=4, unit_value=128, batch_id="uuid", producer="citizenid" }
```

Stacks combine only when brand+effects+quality+base match. Tooltip shows brand, star
rating, effect chips.

## 7. Mixing-station interaction (all server-validated)

`ox_target` zone → `ox_lib` menu: pick base stack → pick one additive (must possess)
→ **server** resolves effects (transform-or-append, 8-cap, order preserved), recomputes
quality + unit_value → on final step prompt to **brand** (sanitize/length/profanity) →
server writes finished item, consumes inputs, logs `batch_id`. Wrap in an `ox_lib`
progress/skill-check; failure risks a junk effect. Save named recipes (`gtarp_drugs_recipes`)
for one-click repeat.

## 8. NPC dealers & customers (Phase 2, server-authoritative)

Customers: per-region NPC pool `{affinity_drug, preferred_effects, min_quality,
base_addiction, dependence_mult, base_spend}`; a server scheduler has them "text"
orders (phone bridge); matching their standard pays a satisfaction bonus + trust +
faster addiction. Dealers: hire NPC (cash), assign ≤10 customers, stock a dealer
stash; a server tick sells stocked product → player gets **80%** (dealer keeps flat
**20%**), self-deal XP 20 / dealer-deal XP 10. Rate-limit the NPC faucet hard — real
players are the primary economy; NPCs are a bounded drain + passive faucet.

## 9. Integration

- **gtarp_laundering**: all drug income is DIRTY. Export/consume `AddDirtyCash(src, amount, "drugs")`; enforce a clean-deposit cap (bank suspicion) so players must launder.
- **Police/heat**: cooking (loud) + big harvests + public selling emit dispatch/heat; a server-rolled search-vs-concealment on carrying near cops; arrest confiscates product.
- **gtarp_evidence**: `batch_id`+`producer` on every unit; seizures + cook-site residue log to evidence tied to citizenid for police RP.
- **gtarp_economy**: feed volume/prices to the staff scoreboard/telemetry.

## 10. MVP (Phase 1) vs later

**MVP — the loop that FEELS like Schedule I:** weed only — buy seeds → plant pots at
grow spots → wall-clock growth + watering → harvest buds (quality metadata) →
**mixing station** (base+additives → branded product w/ effects+quality metadata) →
server price engine → sell to real players + one rate-limited NPC street-buyer → dirty
cash → `gtarp_laundering` + basic heat/evidence.
**Phase 2:** meth + shrooms, NPC customers + dealers, full reaction table, rank/XP.
**Phase 3:** cocaine + cauldron, employee-NPC semi-automation (property-gated cash sink),
property tiers, dynamic regional demand.
**Cut for a shared server:** full automation factories (perf/grief), the hide-item
body-search minigame (→ server roll), the 55-tier grind (→ ~8–10 unlock breakpoints).

## 11. SQL tables

`gtarp_drugs_plants` (owner_cid, coords, strain, soil_tier, planted_at, ready_at,
water_level, additives JSON, stage), `gtarp_drugs_processes` (cook/dry/mix timers),
`gtarp_drugs_recipes` (owner_cid, brand, base, steps_json, effects_json), `gtarp_drugs_progression`
(owner_cid, xp, rank_tier), `drugs_dealers`, `drugs_customers` (addiction, trust,
assigned_dealer), `gtarp_drugs_sales` (ledger: channel, brand, quality, units, gross,
cut_paid, net_dirty, region). Finished-product state lives in ox_inventory metadata,
not a table. Use wall-clock epoch timers resolved on demand (restart-safe, no client tick).

## 12. Anti-exploit (shared-server)

Never trust client price/effects/quality — recompute from config+metadata every sale.
Consume inputs before granting output; server-owned DB timers (relog-dupe resistant).
Caps: 8 effects, per-unit price ceiling, per-tick dealer throughput, per-day NPC-demand
faucet, mixing concurrency per player. Brand names sanitized/rate-limited. Every unit
carries batch_id+producer for dupe/laundering audit via gtarp_drugs_sales + gtarp_evidence.

---

*Sources: Schedule 1 Fandom wiki (Drugs/Effects/Quality/Customers/Ranks/Properties/
Police), Game Rant & Steam community mixing databases, Sportskeeda, GameSpot,
Switchblade Gaming, PCGamer, TheGamer, ScreenRant. Effect multipliers, additive→effect
map, base values, price formula, quality tiers, laundering fronts, dealer 20%/10-cust,
ranks/properties corroborated across multiple sources. Growth times/yields and the full
reaction table are intentionally server-defined / Phase-2 (version-volatile in-game).*
