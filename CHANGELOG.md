# Changelog - Palm6 (palm6 server)

All notable changes to the Palm6 RP server's custom layer. **This is the
source of truth we post from** — every entry has an internal/technical list for
tracking *and* a ready-to-post **📣 Public** blurb (player-facing, no jargon) for
the Discord `#「📝」updates` channel, the website, and public announcements.

Format: newest first. Dates are EDT.

---

## 2026-07-16 - Payout recoverability: no money lost to a restart

The server restarts on every deploy, so a payout that was mid-flight when the
server went down could strand money forever. This pass makes every bank-money
payout **crash-recoverable**: if the server dies partway through paying someone,
the payout is finished automatically on the next boot — and, critically, it can
**never pay anyone twice** (each payout is claimed before the money moves, so a
replay skips anything already paid). A follow-up to the 2026-07-16 restart/
persistence integrity audit, extended into a full sweep of every payout resolver.

**Tracking (internal):**
- 💰 **13 payout resolvers made recoverable** with the same claim-before-credit +
  boot-reconcile idiom: `palm6_fightclub` (bets + purse), `palm6_flashdrop`
  (consignment sale), `palm6_pumpcoin` (coin delist), `palm6_bounty` (capture +
  cancel + TTL expiry escrow), `palm6_courier` (delivery payout + all refund
  paths), `palm6_insurance` (claim payout), `palm6_ransom` (kidnapper payout),
  `palm6_lottery` (winner payout), `palm6_clout` (brand-deal cashout, + the
  missing revert-on-failure), `palm6_season` (prize claim + close reorder).
  Each terminal payout now claims an idempotency flag **before** the credit and
  a delayed `onResourceStart` reconcile re-drives anything a crash interrupted.
- 🛡️ **First-boot-safe** — every new flag column is added `DEFAULT 1` so existing
  (already-paid) history is backfilled as settled and the reconcile can never
  re-pay the whole payment history on the first restart after deploy; the flag is
  reset to 0 only when a record newly reaches its payout state.
- 🧱 **`palm6_pumpcoin` delist** no longer deletes holdings before paying — it
  keeps them behind a per-holder settled flag + a pool/supply snapshot, so an
  interrupted delist finishes on boot instead of stranding holders.
- 🗄️ **Migration integrity** — registered the base drugs (`0039`) and gang
  (`0041`) table creates in `palm6_dbmigrate`, which the later `0043`/`0049`
  statements depend on; closes a rebuild-from-migrate gap. New migrations
  `0054`-`0063` (all idempotent `ADD COLUMN IF NOT EXISTS`).
- ✅ Verified: all 13 files parse clean; three adversarial review passes
  (find → implement → first-boot harden), each checking specifically for
  newly-introduced double-pays. Deliberately **not** reconciled: item-delivery
  payouts (`smuggling`/`numbers`) where an ox_inventory autosave replay could
  double-give; and synchronous online-credit paths with no real crash window.

**📣 Public:** Under-the-hood reliability pass — if the server ever restarts
right as you're getting paid (a fight-club purse, a consignment sale, a bounty,
an insurance claim, a lottery win, a season prize), the payout now always
completes and you'll never lose what you earned to a restart.

---

## 2026-07-15 - Economy coherence pass: crime unlocked, gangs unified, seasons pay out

A big pass over the whole economy — turning on content that was built but
unreachable, making the gang systems agree with each other, giving the season a
real payoff, and closing a few money loopholes.

**Tracking (internal):**
- 🆕 **Black Market** (`ox_inventory_overrides`) — a gated vendor selling meth
  precursors (pseudo/acid/red phosphorus) and counterfeiting supply
  (printer/paper/ink), all priced with a real cost basis. Both the **meth cook**
  and **counterfeit** verticals were shipped + enabled but had **no in-game input
  source**, so they teased dead stations; they are now fully playable, still
  bounded by the existing dirty-cash daily cap / rank gate / fence quota / heat.
- 🔗 **Gang identity unified** — turf ownership, the `/ganginfo` directory, the
  season ladders, and reputation now all key on the **player-run gang**
  (`palm6_gangs`) instead of a mix of that and the static qbx gang. `Turf held`
  finally shows real numbers; holding turf pays (protection racket) and earns
  **reputation** on a genuine takeover (persisted anti-farm cooldown).
- 🏆 **Season 1 is live and rewarding** — auto-opens on boot; `/season`,
  `/seasontop`, and end-of-season **cash prizes** claimed with **`/seasonclaim`**
  (offline-safe, one-time). Five boards: Top Crews (rep, display-only), **Turf
  Held**, Drug Empire, Dirtiest Hustler, and **City Pulse** (most check-ins).
  Gang prizes pay the crew leader.
- 🔧 **`repair_kit` / `tirepack` now work** — use a Repair Kit from your
  inventory to fix the nearest vehicle, or a Tire Pack to fit fresh tyres
  (self-service, no mechanic needed; complements the mechanic invoice job).
- 🚚 **Courier runs require the pickup** — deliveries now make you visit the
  pickup before the dropoff will pay (was dropoff-only).
- 🛒 Grind tools (fishing rod / pickaxe / hunting knife) now also stocked at the
  **24/7 General Store** so a fresh spawn can start earning in-city.
- 🎥 **Going live needs a Streamer Phone** — clout streaming now requires a
  `streamer_phone` (General Store, $2500), so it isn't free money-printing.
- 🚔 **Warrants bite harder** — you can't launder dirty money while you have an
  active warrant, and **posting bail now protects you from instant re-arrest**
  for a short grace window.
- 🧪 Shipped across 7 commits, each boot-verified; three multi-agent adversarial
  review passes caught and closed five issues (incl. a rep-farm→cash exploit and
  a gang-prize name-reuse exploit) before they reached players.

**📣 Public:** Huge economy update dropped. **Meth cooking and counterfeiting are
now fully playable** — grab your supplies from the new **Black Market**. **Gangs
got real**: hold turf, run protection, climb the reputation board. **Season 1 is
live** with leaderboards and **cash prizes** you claim with `/seasonclaim` — top
the Drug Empire, Dirtiest Hustler, Turf, or City Pulse boards. **Repair Kits and
Tire Packs finally work** — fix your own ride from your inventory. Plus: grind
tools sold in the city now, going live needs a Streamer Phone, and skipping bail
or laundering while wanted just got riskier. Type `/season` and `/help` to see
what's new.

---

## 2026-07-13 - Prison economy (`palm6_yard`)

Jail stops being dead time. Inside Bolingbroke you can now **work to shave your
sentence** and earn commissary cash, buy from a **commissary**, or **post bail**
to walk early (with a catch).

**Tracking (internal):**
- 🆕 **`palm6_yard`** — three server-authoritative loops on top of the existing
  xt-prison jail: **labor** (`E` at the yard: a task pays a small trickle and
  shaves your sentence), **commissary** (buy-only cash shop), **bail** (pay to
  release early).
- ⛏️ **Labor**: pay ~$75 per ~35s task (deliberately below street earning), each
  task shaves 1 min but the **total shave is capped at 50% of the sentence** so
  jail always costs something. The shave is computed server-side from the
  sentence baseline (never the client) and bound to the live clock, and a
  **persisted** per-character cooldown means relogging can't reset it.
- 🏪 **Commissary**: server-owned prices, a **daily per-item cap** (kills the
  buy-low/resell-high loop), consume-before-grant with a refund ladder.
- ⚖️ **Bail**: superlinear price (short sentences are cheap to skip, long ones
  hurt) with a floor above typical crime payout so it stays a deterrent. Money
  is taken **before** release; if release fails it refunds. Bail is **not a
  clean slate** — it re-issues an `palm6_mdt` warrant (so `palm6_bounty`
  auto-posts a contract on the skipper) and stamps a re-arrest cooldown.
- 🔒 Server-authoritative sentence: stored/persisted via xt-prison's own Qbox
  `injail` metadata, keyed to citizenid; disconnect/death/restart never clears
  it; only timer expiry, paid bail, or admin release does. Never trusts a client
  "I'm free" or a client shave/price/amount.
- 🔧 Wiring: `sql/0047` (4 palm6_-prefixed tables); 3 `palm6_eventguard` budgets;
  3 ox contraband/commissary items (`yard_pruno`, `yard_commissary_snack`,
  `yard_soap`); self-disables loudly if xt-prison isn't running or an item is
  missing. Bridge-pattern native (§6 clean). **Coords are Bolingbroke Tier-3
  placeholders — VERIFY IN-GAME.** Item PNGs owed (David).

**📣 Public:** Doing time just got real. In prison you can now **work the yard**
to knock time off your sentence and earn commissary money, hit the **commissary**
for supplies, or **post bail** to get out early. But skipping court isn't free:
bail puts a fresh warrant on your head, so bounty hunters and cops get a payday
for bringing you back in.

---

## 2026-07-13 - Refining tier (`palm6_market` v2)

The Commodity Exchange gets a value-add tier: turn raw goods into **refined
goods** worth more, at a new **Refinery**.

**Tracking (internal):**
- 🆕 **Refinery** — `E` at the refinery converts raw stacks into refined goods:
  3 `raw_ore` -> `refined_metal`, 2 `animal_pelt` -> `cured_leather`, 2
  `raw_fish` -> `fillet`, 2 `raw_meat` -> `cured_meat`. Instant, lossless-by-
  ratio, integer batches.
- 📈 Refined goods sell **only** at the exchange, priced at ~1.4x
  (raw_base x ratio), and they ride the **same dynamic marginal-crash + recovery
  curve** as raws — so flooding the market with refined goods crashes their price
  faster than it recovers. Self-limiting, no money printer (the exchange is
  sell-only, so there's no round-trip arbitrage).
- 🔒 Instant is safe here because the throttle is the dynamic **sell** side
  (cooldown + marginal crash + per-sale cap), not the conversion: atomic per-
  player refine cooldown before any yield, server-side proximity, consume-before-
  grant with a refund ladder, refinery self-disables if a refined item def is
  missing.
- 🔧 Wiring: 4 new ox items (`refined_metal`, `cured_leather`, `fillet`,
  `cured_meat`); `palm6_market:refine` eventguard budget; no new SQL table.
  **Refinery coords are a Tier-3 placeholder — VERIFY IN-GAME.** Item PNGs owed.

**📣 Public:** The exchange now has a **Refinery**. Turn your raw ore, pelts,
fish and meat into refined metal, cured leather, fillets and cured meat, then
sell the refined goods for a premium. Just don't flood the market with them, or
the price drops the same way raw goods do.

---

## 2026-07-13 - Commodity Exchange (`palm6_market`)

The legal grind gets a real market. A new **Palm6 Commodity Exchange** buys raw
goods (`palm6_grind` outputs) at a **live price that moves with supply and
demand** instead of a flat vendor rate — and it's the first place you can ever
sell **animal pelts**, which hunting drops but nothing used to buy.

**Tracking (internal):**
- 🆕 **`palm6_market`** — sell all raw goods (`raw_fish`, `raw_ore`, `raw_meat`,
  `animal_pelt`) at the exchange counter with **E**; check live prices any time
  with **`/market`** (a branded `palm6_ui` panel).
- 📈 **Dynamic price model, server-authoritative, no client ticks.** Price is a
  pure function of the last persisted `{price, timestamp}` and the current time:
  it recovers toward a rested `base` over wall-clock time and drops per unit
  sold — **marginally within a single sale**, so dumping a big stack crashes the
  price as it sells (no selling 500 units at the top). Floored at `floorPct` of
  base. Restart- and relog-safe, same discipline as the drug grow/dry/cook
  timers.
- 🐟 `raw_fish`/`raw_ore`/`raw_meat` can be sold at *either* their fixed
  `palm6_grind` buyer (the safe floor, with the grind XP bonus) *or* the
  fluctuating exchange — a genuine sell-now-or-time-it choice. **`animal_pelt`
  is exchange-only** (fixes the confirmed orphan).
- 🔒 Money/dupe-safe: atomic per-player cooldown set before any yield;
  server-side proximity (the client sends no items, amounts or prices);
  consume-before-grant; the market only moves on a completed sale; in-memory
  price set before the DB write so concurrent sellers can't double-dip the top
  price; marginal loop hard-capped.
- 🔧 Wiring: `sql/0046` (`palm6_market_state` + `palm6_market_trades`,
  `palm6_`-prefixed); `palm6_eventguard` budgets `palm6_market:sell` (now
  guarding 51 events); `palm6_economy` shows an informational **clean-cash**
  line via a `GetSummary` export. Bridge-pattern native (§6 gate clean).
  **Exchange coords are a Tier-3 placeholder — VERIFY IN-GAME.** No new items,
  so no PNG debt. Refining tier (`raw_ore→refined_metal`, `pelt→cured_leather`)
  deferred to v2.

**📣 Public:** The city has a **Commodity Exchange**. Fish it, mine it, hunt it,
then bring your raw goods to the exchange and sell at a **price that actually
moves** — flood the market and it drops, let it rest and it climbs back. It's
also the only place to sell **animal pelts**. Sell now, or hold for a better
price. Check the board any time with **/market**.

---

## 2026-07-13 - Branded UI: NUI panel + loading screen (`palm6_ui`, `server_identity`)

The server got its look. Command output moved out of the raw chat feed into a
branded panel, and the first thing every player sees is now a Palm6 loading
screen.

**Tracking (internal):**
- 🆕 **`palm6_ui`** — a shared `ox_lib` panel renderer. Nine server-only commands
  (help, gangs, economy, city stats, wanted, and more) route their multi-line
  output through one branded panel instead of dumping lines into chat; a
  one-liner falls back to a non-blocking toast so it never freezes the player.
- 🎛️ **Branded NUI panel (Phase 2)** — a self-contained dark glassmorphism panel
  with a per-command accent colour, section styling, scroll, and ESC-to-close.
  XSS-safe (game text is rendered as text, never HTML), releases focus on close.
- 🖥️ **`server_identity`** — a Palm6-branded loading screen with a live progress
  bar, the first impression for every join.

**📣 Public:** Palm6 has a fresh look. Commands now open in a clean branded panel
instead of spamming chat, and there's a new Palm6 loading screen when you join.

---

## 2026-07-12 - Nine civic + info systems shipped to live

A batch of quality-of-life and civic systems went live together, filling in the
city's public-facing layer.

**Tracking (internal):**
- 🆕 Shipped nine self-contained resources: **`palm6_help`** (in-game command
  directory), **`palm6_citystats`** (live city economy stats), **`palm6_ems`**
  (EMS billing + dispatch reader), **`palm6_lottery`** (scheduled civic lottery),
  **`palm6_blotter`** / **`palm6_wanted`** (public crime + wanted boards),
  **`palm6_rapsheet`** (criminal history), **`palm6_ganginfo`** (public gang
  directory), **`palm6_season`** (season framework).
- 🎨 Shipped a branded **`palm6_props`** prop set into the live custom layer.
- 🔧 Fixed EMS/lottery commands registering behind a boot delay instead of at
  boot, and granted the correct staff ACEs.

**📣 Public:** Type `/help` in-game to see everything you can do. New civic
systems are live: city stats, EMS billing, a lottery, public wanted + crime
boards, rap sheets, and a gang directory.

---

## 2026-07-11 - Palm6 dealership + new-arrival starter kit

**Tracking (internal):**
- 🚗 Branded **Palm6 dealership catalog** of purchasable vehicles.
- 🎁 New-arrival **starter kit** (a car + clothes) so fresh players aren't
  dropped into the city with nothing.

**📣 Public:** New in town? You start with a car and a fresh outfit, and the
Palm6 dealership is open for your next upgrade.

---

## 2026-07-11 - The server is now Palm6

**Tracking (internal):**
- 🌴 Rebranded the entire custom layer from "Horizon" to **Palm6** — every
  banner, label and reference across all custom resources.

**📣 Public:** Welcome to **Palm6**. New name, same city we've been building.

---

## 2026-07-11 - Meth cook lab (`palm6_drugs` §9)

The Schedule I supply chain gets its second drug: **meth**, via a new cook
station. Meth is not a strain (it can never be planted); the cook lab is its
only source. It reuses the same restart-safe, wall-clock, resolve-on-interaction
timer as the drying rack, so there are no client ticks and nothing to dupe on
relog.

**Tracking (internal):**
- 🆕 **Cook station** (3 burners). Load a pseudo stack (its grade sets the
  quality floor) plus acid and red phosphorus; the batch cooks over wall-clock
  time in `palm6_drugs_processes` (`kind='cook'`, reusing the drying table) and
  mints `meth_raw` crystal on collect.
- 🎲 **Outcome rolled AND stored at start**, never at collect: success (scales
  with rank, capped at 0.9), quality (grade floor, one tier lower on a failed
  cook), yield (config range plus a per-4-ranks bonus, one less on failure), and
  a possible junk effect on a bad batch. Re-collecting can never re-roll a
  better result.
- 🔒 Money/dupe-safe, mirroring grow and dry: precursors consumed before the row
  is written (full refund ladder on any failure), an atomic `running` to
  `collecting` claim so a double-fire can't collect twice, crystal reverted if
  your hands are full, and a per-character concurrent-cook cap. A stranded
  `collecting` row is deleted at boot (err toward loss, never a dupe).
- 🚔 **Cooking is loud**: it warms dealer heat faster than a street sale and has
  a high flat chance to ping police and open a `palm6_evidence` case the moment
  the burner lights.
- 💊 `meth_raw` and `meth_product` flow through the existing mix, sell and price
  engine automatically (base-agnostic refactor: the base id is `meta.base or
  meta.strain`). Also fixed a latent bug where the street buyer offered meth but
  the sell handler still hardcoded weed items and rejected the sale.
- 🔧 Wiring: 5 ox_inventory items (`pseudo`, `acid`, `red_phosphorus`,
  `meth_raw`, `meth_product`); `palm6_eventguard` budgets for the 3 cook events;
  a soft boot gate that leaves the lab dark (weed unaffected) until all five
  items are registered. **No new SQL migration** (reuses `palm6_drugs_processes`).
  Cook coords are a placeholder to verify in-game; item PNGs are still needed
  (David) before icons render.

**📣 Public:** The city has a new product. Set up in the **meth lab**: load your
pseudo, acid and red phosphorus into a burner and let it cook. Higher-grade
pseudo and more experience mean purer crystal and bigger yields, but a sloppy
cook comes out dirty, and cooking is **loud**, so expect the heat. Rank up
through weed to unlock it.

---

## 2026-07-11 - Gang rename (`palm6_gangs`)

**Tracking (internal):**
- ➕ `/gang` gains a leader-only **Rename** action: change your gang's name and
  tag for a bank-charged fee (refunded if the change fails). The server
  re-derives leadership from the DB, sanitises and uniqueness-checks the new
  name and tag (excluding your own gang), rejects a no-op before charging, and
  re-mirrors every online member's gang label on success.

**📣 Public:** Gang leaders can now **rename** their crew (name and tag) from the
`/gang` menu for a fee.

---

## 2026-07-10 — Player-run gangs (`palm6_gangs`)

New custom resource: the **player-created gang layer Qbox does not ship**.
qbx_core owns only the STATIC gang registry (predefined gangs + grades,
`PlayerData.gang`, `/setgang`); this adds what qb-gangs/ps-gangs add to QBCore —
gangs players create and run themselves, membership + ranks, a shared cash
vault, and reputation. The static qbx model is **not** duplicated; it's read
read-only through the bridge, with an opt-in (default-off) mirror seam.

**Tracking (internal):**
- 🆕 **palm6_gangs** — `/gang` menu. Create (unique name+tag, sanitised/length-
  limited/profanity-filtered, bank-charged founding cost) / disband (leader).
  Membership + ranks (Leader/Officer/Member): invite the closest eligible nearby
  player (server-chosen, never client-named), accept, leave, kick (officer+,
  lower ranks only), promote/demote (leader). **One gang per player** enforced by
  a PK on `citizenid`.
- 💰 **Shared CASH vault** — rank-gated deposit (any member) / withdraw
  (officer+). Deposits are consume-before-credit; withdraws use an **atomic
  guarded decrement** (no double-withdraw race, no overdraft) with rollback on a
  failed payout. Every move logged to `palm6_gang_vault_log` with a balance
  snapshot. Disband pays the vault remainder back to the leader's bank.
- 📈 **Reputation** — per-gang `rep` + a server-only `AddRep(gangId, amount,
  reason)` export (floors at 0) so turf/protection/drugs can reward gang activity
  later. Exports: `GetGang`, `IsSameGang`, `AddRep`, `GetSummary`.
- 🔒 Server-authoritative throughout (rank/membership/amounts re-checked
  server-side; parameterised SQL; bridge-isolated per GTA6-readiness).
- 🔧 Wiring: `sql/0041_gangs.sql` (3 indexed, restart-safe tables); rate-limit
  budgets in `palm6_eventguard`; devtest shape + table-map assertions; a `gangs:`
  line on the `/economy` scoreboard; `docs/TESTING.md` §43. (custom.cfg ensure
  line left for the operator — after qbx_core, near the crime resources, after
  `palm6_eventguard`.)

**📣 Public:** Start your own **crew**. Found a gang with a name and a tag, run
your roster with officer and member ranks, invite people, and pool your money in
a **shared gang vault** only your officers can pull from. Gangs also build a
**reputation** as you run the streets — the foundation for turf and crime payouts
to come. Type `/gang` to get started.

---

## 2026-07-10 — Economy anti-exploit hardening + coord retune

A server-wide adversarial audit of the money-handling systems (find →
independently verify → fix), plus real-location retuning of placeholder coords
and a continued bridge-pattern rollout. **8 confirmed-exploitable bugs fixed;
the other 12 audited resources came back clean.**

**Tracking (internal):**
- 🔴 **palm6_courier** — fixed a **critical double-payout race**: `complete` now
  atomically gates the `UPDATE` on `status='taken' AND courier_citizenid` and only
  pays when rows-affected == 1. Same guard on cancel-refund and both lifetime sweeps.
- **palm6_insurance** — policy is now consumed on claim (one payout per policy);
  no-scene damage claims are hard-denied instead of trusting client health.
- **palm6_chopshop** — closed a free-money faucet: ambient/NPC cars (no
  `player_vehicles` row, no active stolen report) can no longer be sold.
- **palm6_bounty** — fixed a city-money faucet: captured state contracts update in
  place (`status IN ('active','claimed')`) instead of re-posting every sweep.
- **palm6_mechanic** — repairs now require a **customer consent handshake**
  (offer → confirm → accept, re-validated server-side) plus a per-customer cooldown;
  a mechanic can no longer force-charge a non-consenting nearby player.
- 🧩 **Bridge pattern** — extended to `ox_inventory_overrides` (isolated its
  `ox_inventory`/`ox_target`/native calls behind `bridge/`), per GTA6-readiness. The
  other candidate resources already had adapters.
- 📍 **Coord retune** — replaced Tier-3 placeholder map coords with real Los Santos
  locations across bounty, fightclub, gunrunning, laundering, loanshark, numbers,
  protection, and robbery. All flagged `VERIFY IN-GAME`.
- Audited clean (no fixes needed): laundering, numbers, loanshark, protection,
  seizure, smuggling, pumpcoin, economy, ransom, gunrunning, counterfeit, grind.

**📣 Public:**
> 🔧 **Server maintenance — economy hardening**
> We ran a full security sweep of the crime economy and patched several money
> exploits (courier payouts, insurance claims, chop-shop, bounties). Repairs from
> mechanics now ask for your approval before charging you. Plus we moved a bunch of
> racket locations to their real spots around the city. Cleaner, fairer hustle. 💰

## 2026-07-10 — 🌿 New: `palm6_drugs` (Schedule I-style) — MVP Phase 1 built

The missing drug supply chain — a faithful adaptation of **Schedule I**. Design
locked in `docs/DRUGS-SPEC.md`; **MVP (weed only) built**: grow → mix a custom
branded product with stacking effects + quality → sell → dirty cash → laundering
+ heat/evidence. Not yet wired into `custom.cfg` (operator step).

**Tracking (internal):**
- 🌱 **Grow loop** — buy `weed_seed` + `soil` (+ optional grow additive), plant at
  an ox_target grow plot, water over **wall-clock DB timers resolved on
  interaction** (restart-safe, no client ticks), harvest `weed_bud` with
  `{strain,quality,effects,dried}` metadata. Neglect (water → 0%) drops quality/yield.
- 🌬️ **Drying rack → Heavenly** — hang a stack of fresh `weed_bud` on the rack
  (ox_target) to dry it over a **wall-clock `palm6_drugs_processes` timer** (`kind='dry'`,
  epoch seconds, resolved on interaction like the grow timers). On collect the buds
  come back **bumped to Heavenly (tier 4, ×1.30)** with `dried=true`, and the price
  engine applies the markup on any later mix/sell. One run per rack slot (UNIQUE
  `(kind,station_id)`); server-owned by its starter; **atomic `running→collecting`
  collect claim**; a crash-stranded run reverts to `running` at boot (never lost).
  No new item — the rack is a world station.
- 🧪 **Mixing station** — pick a base stack + one additive; the **server** resolves
  effects (**reactions first, then append-if-absent, 8-cap, order kept**), recomputes
  quality + unit price via the spec §5 formula, sanitizes a player brand, mints one
  `weed_product` (`{brand,base,effects[],quality,unit_value,batch_id,producer}`).
  Bad-mix roll can inflict a junk effect. Named recipes saved to `palm6_drugs_recipes` for
  one-click repeat.
- ⚗️ **Effect reaction/transform system** — the signature Schedule I mechanic:
  mixing now **transforms** existing effects into other (often higher-value) ones
  when an additive reacts with them, so the result is **order-dependent**
  (`Cuke→Banana` ≠ `Banana→Cuke`). `Config.Reactions` (112 real reaction rules
  across all 16 additives, cross-checked 2026-07-10 against the Schedule 1 Fandom
  wiki + Steam "Complete Mixing Database" / "Full Transformation Guide" + calculator
  charts) is the tuning surface; deterministic, server-side (`reactEffects` in
  `doMix`), 8-cap preserved. Retune vs the live mixing DB as the game patches it.
- 💵 **Selling** — real players via ox_inventory trade, plus one **rate-limited NPC
  street-buyer** paying DIRTY `black_money` priced from the item's real metadata,
  bounded by a **per-character daily faucet cap**. Logged to `palm6_drugs_sales`.
- 🚔 **Heat/evidence (basic)** — sales warm a per-dealer heat model; a hot dealer or
  witness roll (and the odd big harvest) trips a native police alert +
  `palm6_evidence` case. Every unit carries `batch_id`+`producer` for audit.
- 🧱 **Full §1–5 config** — 4 weed strains, 16 additives→effects, all 34 effect
  multipliers, 5 quality tiers, and the server-authoritative `Config.Price` helper.
- 🛡️ **Server-authoritative** — never trusts client price/effects/quality/amount;
  recomputes from config + metadata; consumes inputs before granting outputs;
  proximity re-derived server-side; all SQL parameterized. 12 net events registered
  in `palm6_eventguard`. New items added to `ox_inventory_overrides` (replacing the
  earlier generic `cannabis_leaf`/`weed_baggie` draft). SQL: `palm6_drugs_plants`,
  `palm6_drugs_recipes`, `palm6_drugs_progression`, `palm6_drugs_sales` (`sql/0039_drugs.sql`) +
  `palm6_drugs_processes` (the drying-rack timer, `sql/0040_drugs_drying.sql`).
- ⏭️ **Deferred to Phase 2/3:** meth/shrooms/coke, NPC customers + hired dealers,
  and rank/XP-gated properties.

**📣 Public:**
> 🌿 **New hustle incoming — grow, cook, and brand your own product**
> Plant strains, keep them watered, then take your buds to the mixing bench and
> cut them with additives to build custom effects and quality — then slap your own
> brand on it. Better product, better payout. Sell to other players or move it fast
> to a street buyer for dirty cash you'll need to launder. Bring heat if you get
> greedy. 💨

<!-- Template:
## YYYY-MM-DD — <title>
**Tracking (internal):**
- <change> (`resource`)
**📣 Public:**
> 🎮 <player-facing line(s)>
-->
