# gtarp_drugs

A faithful **Schedule I**-style drug supply chain (MVP: **weed only**). The loop
that feels like the Steam game: **grow → mix a custom branded product with
stacking effects + quality → sell → dirty cash → launder**. The server already
had the downstream sinks (`gtarp_laundering` washes `black_money`,
`gtarp_evidence` tracks cases); this resource is the **producer + the price
engine**.

Bridge-pattern (see `docs/GTA6-READINESS.md` §3): all logic lives in `server/` +
`client/`; every qbx / ox_inventory / ox_target / qbx_police / native / ox_lib
call is isolated in `bridge/`. Its own `drugs_*` schema stays in the logic. To
port to GTA VI, rewrite the two bridge files, not the logic.

## The loop

1. **Grow.** Buy a `weed_seed` + `soil` (and optionally one grow additive), walk
   to a **grow plot** (ox_target), plant, and **water** it over wall-clock time.
   Growth timers are **DB-persisted** and resolved on interaction — restart-safe,
   **no client ticks**. Harvest yields **`weed_bud`** carrying
   `{ strain, quality, effects, dried }` metadata. Only the grower can tend or
   harvest a plant; let the water hit 0% and quality/yield drop a tier.
2. **Dry (optional → Heavenly).** Hang a stack of **fresh (undried) `weed_bud`**
   on the **drying rack** (ox_target, next to the mixing station). Drying is a
   **wall-clock DB timer** (`gtarp_drugs_processes`, `kind='dry'`) resolved on
   interaction — restart-safe, no client ticks, exactly like the grow timers.
   The buds are consumed into the rack slot at load time and handed back on
   collect **bumped to Heavenly (tier 4, ×1.30)** with `dried = true`. One run
   per rack slot; the run is server-owned by its starter; collect is an atomic
   `running → collecting` claim so it can't double-collect. It needs **no new
   item** — the rack is a world station.
3. **Mix.** At the **mixing station** (ox_target), pick a base stack (`weed_bud`
   or an existing `weed_product`) + **one additive**. The **server** resolves the
   effect list — it **FIRST transforms** any existing effects the additive reacts
   with (the order-dependent Schedule I **reaction table**, see below), **THEN**
   appends the additive's own base effect if absent (order preserved, 8-effect
   cap). It recomputes quality + unit price, asks you to **brand** it (sanitized +
   length-limited), then mints one **`weed_product`** whose metadata is
   `{ brand, base, effects[], quality, unit_value, batch_id, producer }`. Inputs
   are consumed first. The named recipe is saved to `gtarp_drugs_recipes` for one-click
   repeat. A bad-mix roll can inflict a junk (0-value) effect.
4. **Sell.** Hand-to-hand to **real players** is left to ox_inventory trade
   (products stack only when brand+effects+quality+base match). Plus one
   **rate-limited NPC street-buyer** (ox_target on a spawned ped) that pays
   **DIRTY cash** (`black_money`) priced from the item's real metadata, bounded
   by a **per-character daily faucet cap**. Every sale logs to `gtarp_drugs_sales`.
5. **Launder.** All drug income is `black_money` — the exact item
   `gtarp_laundering` washes into clean bank funds and `gtarp_seizure` can take.
   The two resources are decoupled: this one only ever grants the item; it never
   calls into laundering.

| Stage | Location | In → Out |
| --- | --- | --- |
| Grow | Grow plots (Grapeseed backwoods) | `weed_seed` + `soil` → `weed_bud` (metadata) |
| Dry | Drying rack (Grand Senora) | fresh `weed_bud` → `weed_bud` (dried, **Heavenly** q4) |
| Mix | Mixing station (Grand Senora) | `weed_bud`/`weed_product` + 1 additive → branded `weed_product` |
| Sell | NPC street-buyer (Sandy Shores) | `weed_product`/`weed_bud` → `black_money` (dirty) |

## Price formula (server-authoritative, spec §5)

```
unit_price = round( base_value
                    × (1 + Σ effect_multipliers)   -- effects summed over ≤ 8
                    × quality_markup
                    × region_demand )              -- default 1.0
```
then clamped to `[1, Config.MaxUnitPrice]` (per-unit ceiling, §12). `base_value`
comes from the strain (`Config.Drugs`), the effect multipliers from
`Config.Effects` (26 positive .10–.60, 8 junk 0.00), and `quality_markup` from
`Config.Quality` (Trash ×0.60 · Poor ×0.80 · Standard ×1.00 · Premium ×1.15 ·
Heavenly ×1.30 — reached by drying fresh buds on the rack). `Config.Price(base,
effects, quality)` implements it and is the
**only** number ever trusted for a payout — the client's copy is display-only.

## Effect reactions — the order-dependent transform system (spec §3)

The signature Schedule I mechanic. Each additive still carries **one base effect**
(`Config.Additives`), but before that base effect is appended the mix **transforms**
existing effects: if the product already carries an effect the additive reacts
with, that effect is **converted** into another (often higher-value) one. Because
a mix applies **one additive at a time**, the outcome is genuinely
**order-dependent** — `Cuke → Banana` ≠ `Banana → Cuke` — which is what gives the
loop its strategic depth. All matching effects transform at once, against the
current set, in a single pass (a freshly-produced effect isn't re-transformed by
the same additive); a transform that would duplicate an existing effect collapses
to the first occurrence, so the reaction pass never grows the list and the
**8-effect cap** is preserved. Resolution is entirely **server-side and
deterministic** (`reactEffects` in `server/main.lua`, called from `doMix`).

**`Config.Reactions` is the tuning surface.** It maps
`Reactions[additiveKey] = { [existingEffect] = newEffect, ... }` using the exact
additive keys and effect names from `Config.Additives` / `Config.Effects`. 112
rules across all 16 additives ship. The data was cross-checked (2026-07-10)
against the **Schedule 1 Fandom wiki** per-ingredient pages, the Steam **"Complete
Mixing Database (2026)"** and **"How to Get Every Effect (Full Transformation
Guide)"** guides, and the **scheduleonemixer / prodigygamers** transformation
charts. The live game **patches these during early access** — retune
`Config.Reactions` against the current in-game mixing DB when the game updates.

## Anti-exploit (all server-side, spec §12)

- **Never trusts client price/effects/quality/amount.** Every sale and mix
  re-derives effects, quality, and price from `Config` + the item's **real
  ox_inventory metadata** read at the moment of the action. The client sends
  only a slot index, an additive name, and a brand string.
- **Proximity is server-checked** against the caller's real ped position — plot,
  station, and buyer are all re-derived server-side; a bad plot index **fails
  closed**.
- **Inputs consumed before outputs granted.** Seeds/soil/additives/base stacks
  are removed first; anything already taken is **handed back** if a later step
  fails, so a run is never a partial loss and money/items are never granted for
  inputs that weren't actually removed.
- **Caps:** 8 effects per product; per-unit price ceiling (`Config.MaxUnitPrice`);
  per-player action cooldowns; a **per-character daily NPC-faucet cap**
  (`SUM(net_dirty) WHERE channel='npc' AND created_at >= CURDATE()`) that sells
  only up to the remaining budget; brand names sanitized (charset + length) and
  rate-limited by cooldown + eventguard.
- **Server-owned DB timers** (epoch seconds) resolve growth/watering on
  interaction — relog/dupe resistant, no client tick to spoof. Harvest uses an
  **atomic `growing → harvested` claim** so a double-fire can't harvest twice.
- **Every unit carries `batch_id` + `producer`** for a dupe / laundering /
  seizure audit trail via `gtarp_drugs_sales` + `gtarp_evidence`.

## Heat & evidence (basic, present)

Selling warms a per-dealer heat model (server-only, decays each sweep); a hot
dealer or an unlucky witness roll trips a **native police alert**
(`police:server:policeAlert`, rendered by qbx_police, with an on-duty fan-out
fallback) plus a **`gtarp_evidence` v2 case** (frozen
`EnsureCase`/`AppendEntry`/`LinkSuspect` exports — never its tables). Big
harvests are occasionally spotted too. Kept light for the MVP but wired.

## Items (register in `ox_inventory_overrides/data/items.lua`)

Core (boot-checked, resource self-disables if any is missing): `weed_seed`,
`soil`, `wateringcan`, `weed_bud`, `weed_product`, `black_money` (existing).
Grow additives: `fertilizer`, `speed_grow`, `pgr`. Mix additives (16, warn-only
if missing): `cuke`, `banana`, `paracetamol`, `donut`, `viagra`, `mouthwash`,
`flu_medicine`, `gasoline`, `energy_drink` (reused), `motor_oil`, `mega_bean`,
`chili`, `battery`, `iodine`, `addy`, `horse_semen`. These **replace** the
earlier generic-draft `cannabis_leaf` / `weed_baggie`.

> **Buying supplies is an operator step.** Like `gtarp_grind` (whose tools are
> sold from a shop defined elsewhere), this resource does not add a shop — add
> `weed_seed` / `soil` / grow + mix additives to an `ExtraShops` dealer so
> players can buy them.

## Depends on / wiring

- `sql/0039_drugs.sql` — `gtarp_drugs_plants`, `gtarp_drugs_recipes`, `gtarp_drugs_progression`,
  `gtarp_drugs_sales`. `sql/0040_drugs_drying.sql` — `gtarp_drugs_processes` (the drying-rack
  wall-clock timer). Product state lives in ox_inventory metadata, not a table.
- `gtarp_eventguard` — the 12 net events (`gtarp_drugs:plotMenu` / `plant` /
  `water` / `harvest` / `mixMenu` / `mix` / `mixRecipe` / `sellMenu` / `sell` /
  `dryMenu` / `dryStart` / `dryCollect`) are registered in its `config.lua` as
  defense-in-depth on top of the in-resource cooldowns. eventguard must `ensure`
  **before** gtarp_drugs.
- `gtarp_laundering` (soft) — washes the `black_money` this resource pays out.
- `gtarp_evidence` (soft) — flagged events open/append a case if it's running.
- `ox_target` (soft) — used for all interactions when started; falls back to a
  `lib.points` marker + `[E]` prompt otherwise.
- **Not wired into `custom.cfg`** — the operator adds `ensure gtarp_drugs`
  (after `gtarp_laundering`, and after `gtarp_eventguard`) when ready to enable.

## Roadmap (spec §10)

- **Shipped since MVP:** **drying racks → Heavenly quality** — hang fresh buds on
  the rack to dry them over a wall-clock `gtarp_drugs_processes` timer, bumping them to
  Heavenly (tier 4, ×1.30). See the **Dry** step above. · The full order-dependent
  effect **reaction/transform table** (`Config.Reactions`, 112 rules) — see the
  **Effect reactions** section above.
- **Phase 2:** meth + shrooms; NPC customers + hired dealers (the 80/20 split,
  ≤10 customers each); rank/XP-gated properties.
- **Phase 3:** cocaine + cauldron; property-gated employee-NPC semi-automation;
  property tiers; dynamic regional demand (`region_demand_mod`).

## GTA VI notes (Tier 3)

All `*.coords` / `*.plots` in `shared/config.lua` are Los Santos placeholders
marked **VERIFY IN-GAME** — retune with a coords tool (mirror in
`docs/GTA6-TIER3-RETUNE.md`). Base values, effect multipliers, quality markups,
the price formula, yields, cooldowns and the heat model are Tier 1 and carry.
