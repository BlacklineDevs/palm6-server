# Changelog - Palm6 (gtarp server)

All notable changes to the Palm6 RP server's custom layer. **This is the
source of truth we post from** — every entry has an internal/technical list for
tracking *and* a ready-to-post **📣 Public** blurb (player-facing, no jargon) for
the Discord `#「📝」updates` channel, the website, and public announcements.

Format: newest first. Dates are EDT.

---

## 2026-07-10 — Player-run gangs (`gtarp_gangs`)

New custom resource: the **player-created gang layer Qbox does not ship**.
qbx_core owns only the STATIC gang registry (predefined gangs + grades,
`PlayerData.gang`, `/setgang`); this adds what qb-gangs/ps-gangs add to QBCore —
gangs players create and run themselves, membership + ranks, a shared cash
vault, and reputation. The static qbx model is **not** duplicated; it's read
read-only through the bridge, with an opt-in (default-off) mirror seam.

**Tracking (internal):**
- 🆕 **gtarp_gangs** — `/gang` menu. Create (unique name+tag, sanitised/length-
  limited/profanity-filtered, bank-charged founding cost) / disband (leader).
  Membership + ranks (Leader/Officer/Member): invite the closest eligible nearby
  player (server-chosen, never client-named), accept, leave, kick (officer+,
  lower ranks only), promote/demote (leader). **One gang per player** enforced by
  a PK on `citizenid`.
- 💰 **Shared CASH vault** — rank-gated deposit (any member) / withdraw
  (officer+). Deposits are consume-before-credit; withdraws use an **atomic
  guarded decrement** (no double-withdraw race, no overdraft) with rollback on a
  failed payout. Every move logged to `gtarp_gang_vault_log` with a balance
  snapshot. Disband pays the vault remainder back to the leader's bank.
- 📈 **Reputation** — per-gang `rep` + a server-only `AddRep(gangId, amount,
  reason)` export (floors at 0) so turf/protection/drugs can reward gang activity
  later. Exports: `GetGang`, `IsSameGang`, `AddRep`, `GetSummary`.
- 🔒 Server-authoritative throughout (rank/membership/amounts re-checked
  server-side; parameterised SQL; bridge-isolated per GTA6-readiness).
- 🔧 Wiring: `sql/0041_gangs.sql` (3 indexed, restart-safe tables); rate-limit
  budgets in `gtarp_eventguard`; devtest shape + table-map assertions; a `gangs:`
  line on the `/economy` scoreboard; `docs/TESTING.md` §43. (custom.cfg ensure
  line left for the operator — after qbx_core, near the crime resources, after
  `gtarp_eventguard`.)

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
- 🔴 **gtarp_courier** — fixed a **critical double-payout race**: `complete` now
  atomically gates the `UPDATE` on `status='taken' AND courier_citizenid` and only
  pays when rows-affected == 1. Same guard on cancel-refund and both lifetime sweeps.
- **gtarp_insurance** — policy is now consumed on claim (one payout per policy);
  no-scene damage claims are hard-denied instead of trusting client health.
- **gtarp_chopshop** — closed a free-money faucet: ambient/NPC cars (no
  `player_vehicles` row, no active stolen report) can no longer be sold.
- **gtarp_bounty** — fixed a city-money faucet: captured state contracts update in
  place (`status IN ('active','claimed')`) instead of re-posting every sweep.
- **gtarp_mechanic** — repairs now require a **customer consent handshake**
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

## 2026-07-10 — 🌿 New: `gtarp_drugs` (Schedule I-style) — MVP Phase 1 built

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
  (ox_target) to dry it over a **wall-clock `gtarp_drugs_processes` timer** (`kind='dry'`,
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
  Bad-mix roll can inflict a junk effect. Named recipes saved to `gtarp_drugs_recipes` for
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
  bounded by a **per-character daily faucet cap**. Logged to `gtarp_drugs_sales`.
- 🚔 **Heat/evidence (basic)** — sales warm a per-dealer heat model; a hot dealer or
  witness roll (and the odd big harvest) trips a native police alert +
  `gtarp_evidence` case. Every unit carries `batch_id`+`producer` for audit.
- 🧱 **Full §1–5 config** — 4 weed strains, 16 additives→effects, all 34 effect
  multipliers, 5 quality tiers, and the server-authoritative `Config.Price` helper.
- 🛡️ **Server-authoritative** — never trusts client price/effects/quality/amount;
  recomputes from config + metadata; consumes inputs before granting outputs;
  proximity re-derived server-side; all SQL parameterized. 12 net events registered
  in `gtarp_eventguard`. New items added to `ox_inventory_overrides` (replacing the
  earlier generic `cannabis_leaf`/`weed_baggie` draft). SQL: `gtarp_drugs_plants`,
  `gtarp_drugs_recipes`, `gtarp_drugs_progression`, `gtarp_drugs_sales` (`sql/0039_drugs.sql`) +
  `gtarp_drugs_processes` (the drying-rack timer, `sql/0040_drugs_drying.sql`).
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
