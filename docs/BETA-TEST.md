# Palm6 — Beta Test Kit

**Server:** `193.31.31.27:30149` (Direct Connect → globe icon, or F8 console `connect 193.31.31.27:30149`)
**Live as of:** 2026-07-13 — prod healthy, 53 `gtarp_*` resources + `palm6_props` / `server_identity` / `mystudio_props` loaded, 0/48 players.
**Purpose:** everything a small group of beta testers (and the operator) needs to shake down Palm6 in one guided session. Ordered so the operator can verify every placeholder coordinate in a single in-game pass.

> This is an internal ops doc. The player-facing command reference is in-game via `/help` (and `/help <topic>`); it is the source of truth and is reproduced condensed in §7.

---

## §0 — Operator pre-flight (do these BEFORE inviting testers)

These are the standing gaps between "shipped to prod" and "ready for outside players." None block the operator's own solo shakedown, but a public beta wants them closed.

| # | Gap | Owner | Action | Blocks beta? |
|---|-----|-------|--------|--------------|
| 0.1 | **Server-browser name still `gtarp — Qbox RP`** (not "Palm6"). Not set in the repo — it lives in the panel-managed `server.cfg`. | David (panel) | RocketNode panel → server.cfg → set `sv_projectName "Palm6"` and `sv_hostname` to the branded name, restart. | Cosmetic, but first impression |
| 0.2 | **7 new item icons blank** (PNGs owed). See §5 manifest. | David (generate in ChatGPT) | Drop PNGs into `ox_inventory/web/images/`, re-deploy. | No — items work, just show the placeholder box |
| 0.3 | **Starter-vehicle garage name unconfirmed.** `gtarp_onboarding` grants a `blista` into garage `motelgarage`. If that garage name doesn't exist in the deployed `qbx_garages`, new players get the $1500 cash but the car silently no-ops. | Operator (in-game) | Onboard a fresh character, confirm the starter car is retrievable from a garage. If not, set `Config.StarterVehicle.garage` to a real garage name. | Yes — new players stranded without a car |
| 0.4 | **Allowlist/whitelist mode for beta.** `gtarp_allowlist` does role-OR-license gating; txAdmin whitelist must stay `disabled` or joins double-gate. | David | Decide open vs closed beta; if closed, seed the allowlist with tester identifiers. | Depends on beta model |
| 0.5 | **Placeholder coords un-walked.** ~8 systems still sit on round-number placeholder coordinates (§3). Verify/retune in the §2 pass. | Operator (in-game) | Walk each §3 POI; retune any that float/clip/are unreachable. | Yes for those systems |

---

## §1 — New player's first 5 minutes (what a tester experiences)

1. **Connect** → Palm6 branded loading screen (`server_identity`) with a live progress bar.
2. **Character creation** (qbx multichar) — pick/create a character.
3. **Mandatory rules dialog** (`gtarp_onboarding`) — 5 house rules (RP-first, fear-for-life, NLR, no-exploiting, staff-final). Must accept to continue.
4. **Starter grant** — **$1500 to bank** + a one-time **starter car** (blista, parked in a public garage) on first-ever join.
5. **Getting-started tour** — short text: bank/ATMs, jobs, `/rules` re-shows anytime, `/mdt` for aspiring police.
6. **`/help`** — opens the branded Palm6 NUI command panel (categorized). `/help crime`, `/help leo`, etc. drill in.

**Tester checklist:**
- [ ] Loading screen shows "Palm6" branding + progress bar
- [ ] Rules dialog appears on first join and blocks until accepted
- [ ] `/rules` re-shows the rules later
- [ ] $1500 landed in bank
- [ ] Starter car exists and is retrievable from a garage *(gap 0.3)*
- [ ] `/help` opens the NUI panel; a category drill-in (`/help crime`) works

---

## §2 — Guided in-game smoke test (single-session route)

Run these roughly in map order so the operator crosses the city once. Each row: **go to the coord / run the command → confirm the expected result → tick the box.** Coords marked ⚠️ are round-number placeholders (§3) — eyeball whether the ped/blip is on solid ground and reachable, and retune if not. Coords with decimals are already tuned to real LS spots — just confirm reachable.

### Economy / grind (legal earners)
- [ ] **Grind — fishing** `-1850.2,-1235.6,8.6` (pier) — get a fishing rod at the Hardware Store, catch `raw_fish`
- [ ] **Grind — mining** `2954.1,2782.3,40.5` (quarry) — pickaxe → `raw_ore`
- [ ] **Grind — hunting** `-1150.4,4880.7,220.1` (Chiliad) — hunting knife → `raw_meat` + `animal_pelt`
- [ ] **Market — Commodity Exchange** ⚠️`-40,-2530,6` — `/market`, sell raw goods, price moves with volume
- [ ] **Market — Refinery** ⚠️`1075,-2005,32` — refine raw→`refined_metal`/`cured_leather`/`fillet`/`cured_meat`, sell at exchange
- [ ] **Courier** `/courier list` → accept → drive to dropoff → payout (arrival re-validated server-side)
- [ ] **Dealership** — buy a car from the Palm6 catalog; confirm price is the catalog price and the car titles to you

### Crime economy
- [ ] **Drugs — grow** `2223.5,5150.4,59.8` — plant `weed_seed` + soil, wait, harvest `weed_bud`
- [ ] **Drugs — mix** `1391.2,3605.5,38.9` — mix bud + additive → branded `weed_product` (effects in metadata)
- [ ] **Drugs — NPC dealer** — hire a corner dealer, stock product, collect dirty cash over time
- [ ] **Laundering** `127.4,-1298.9,29.2` — `/launder`, `/dirtymoney` shows balance
- [ ] **Loanshark** `94.2,-1291.9,29.1` — `/borrow 5000`, `/loaninfo`, `/repay`
- [ ] **Numbers racket** `88.5,-1958.4,20.8` — `/numbers 100`, `/collectnumbers`, `/numbersinfo`
- [ ] **Smuggling** ⚠️`-119,-2489,6` (pickup) → ⚠️ drop coords — `/smuggle`, `/deliver`, `/smugglerun`
- [ ] **Gunrunning** — `/buyweapon` at the black-market runner
- [ ] **Protection racket** `25.7,-1347.3,29.49` — `/shakedown` a business (crew + turf gated), `/rackets`
- [ ] **Chop shop** — `/reportstolen`, `/sellstolen`
- [ ] **Counterfeit** ⚠️ zone centroids `180,-1730,29` etc. — print run at printer, `/counterfeit`, `/runserial` at evidence locker
- [ ] **Pumpcoin** `287.4,-1000.7,29.4` — `/shill`, `/pumpboard`
- [ ] **Fight club** — `/fcjoin`, `/fcbet 200`, `/fcmatches` (parimutuel)
- [ ] **Flashdrop** `158.9,-985.7,30.1` — `/flashdrop` sneaker drop
- [ ] **Clout / streaming** `195.17,-933.77,30.69` — `/golive`, `/clout`, `/streamers`, `/endstream`
- [ ] **Ransom** — `/demandransom`, `/payransom` (kidnapping ledger)
- [ ] **Bounty board** — `/bounties`, `/postbounty <id> <amt>`, `/capture <id>`

### Gangs / turf
- [ ] **Gangs** — `/gang` (menu: rank, vault, members), `/gangweb`, `/gangs`, `/ganginfo <tag>`
- [ ] **Turf** `195.17,-933.77,30.69` — `/turf` shows holdings

### Justice / records (any player)
- [ ] `/rapsheet` (own record), `/wanted`, `/amiwanted`
- [ ] `/fines`, `/payfine <id>`
- [ ] `/insure <plate>`, `/policy`, `/fileclaim <plate>`
- [ ] `/tip <what you saw>` (anonymous, from a payphone)

### Law enforcement (needs police job / duty)
- [ ] `/mdt` opens MDT; `/bolo`, `/bolos`, `/warrant <id>`, `/warrants`, `/book <id> <charges>`, `/calls`
- [ ] `/cite <id> <offense>`, `/priors <id>`, `/blotter`
- [ ] `/evidence`, `/casenew`, `/witnesses`, `/bodycam`
- [ ] `/seizedirty` (forfeit dirty money from a nearby suspect)
- [ ] Lawyer: `/expunge <booking>`

### EMS (needs EMS job / duty)
- [ ] `/treat`, `/emsbill <id> <amt>`, `/emscalls`
- [ ] Any player: `/medbills`, `/paymedbill <id>`

### Prison economy (while jailed)
- [ ] **Yard — labor** ⚠️`1800,2600,46` (Bolingbroke) — work to shave sentence (capped 50%)
- [ ] **Yard — commissary** ⚠️`1780,2600,46` — buy `yard_pruno` / snack / soap
- [ ] **Yard — bail** ⚠️`1690,2560,45` — pay superlinear bail to release early (re-issues warrant)

### City / season
- [ ] `/citystats`, `/season`, `/seasontop`

### Admin / staff (ace-gated)
- [ ] `/diag` — custom-layer health check (all resources OK)
- [ ] `/economy` — city crime-economy scoreboard
- [ ] `/seasonopen <name>`, `/seasonclose`

---

## §3 — Placeholder-coordinate retune worklist (prioritized)

These sit on obvious round-number placeholders and have never been stood on in-game. During the §2 pass, confirm each is on solid, reachable ground; retune the config value if it floats/clips. Decimal-precise coords elsewhere are already tuned (7/10 LS retune) and only need a "reachable? yes" glance.

| System | File | Current placeholder | What it is |
|--------|------|--------------------|-----------|
| Market exchange | `gtarp_market/shared/config.lua:23` | `-40, -2530, 6` | commodity exchange ped/blip |
| Market refinery | `gtarp_market/shared/config.lua:57` | `1075, -2005, 32` | refinery ped/blip |
| Yard labor | `gtarp_yard/shared/config.lua:31` | `1800, 2600, 46` | prison labor point |
| Yard commissary | `gtarp_yard/shared/config.lua:32` | `1780, 2600, 46` | commissary |
| Yard bail | `gtarp_yard/shared/config.lua:33` | `1690, 2560, 45` | bail desk |
| Smuggling pickup + drops | `gtarp_smuggling/shared/config.lua:35–48` | `-119,-2489,6` + 6 round drops | contraband run nodes |
| Counterfeit heat zones | `gtarp_counterfeit/shared/config.lua:65–70` | 6 round centroids | district heat zones (approximate is OK) |

---

## §4 — Money-exploit audit status (pre-beta hardening)

An independent adversarial money-exploit audit of the **10 newest un-audited resources** (lottery, numbers, fightclub, loanshark, dealership, seizure, protection, ransom, smuggling, gunrunning) ran 2026-07-13, three parallel auditors, each checked against this codebase's 8 known exploit classes (client-trust, double-payout race, consume-before-grant, NaN bypass, TOCTOU, faucet, eventguard gaps, RNG).

**Verdict: 10/10 CLEAN — no client-exploitable money-printing or dupe bugs. Zero fixes required for beta.**

Structural reason: every resource is **server-only** with no inbound net events — every money path is a chat command, so a modified client can only pass string args, never coords/targets/amounts. Proximity, role, balance, and payout are all re-derived server-side. Payout math is house-edge / zero-sum everywhere (lottery `payout = pot - 20% rake`; numbers `stake×60` on 100 outcomes; fightclub parimutuel `rake+purse+bettors == pool`; ransom is a zero-sum P2P transfer; gunrunning/seizure are pure sinks).

Low-severity notes (documented, **not** exploitable — no code change made):
- **Fightclub `/fcbet`** uses insert-before-charge (deviates from the charge-first idiom in lottery/numbers). Safe because qbx `RemoveMoney` never yields, so the resolve thread can't pay an unfunded row before the charge-fail delete. Deliberate, commented design — left as-is.
- **Protection** could leak a per-business `collectLock` if an *unexpected* Lua error fired between the two internally-`pcall`-wrapped calls in the lock window — would soft-brick that one business until restart. Availability nit, not money.
- **Dealership** has no runtime purchase logic — car buys run through qbx_core's native shop (prices patched from the catalog at deploy by `tools/patch-vehicle-prices.sh`). The custom catalog validator rejects bad prices/models. If qbx_core's shop hasn't had its own price-re-derivation audit, that's where any dealership money risk would live — flagged for a separate recipe-layer review, not a custom-layer beta blocker.

**Prod DB note (verify if in doubt):** numbers (`sql/0034`) and fightclub (`sql/0028`) tables — including fightclub's load-bearing `UNIQUE(match_id, citizenid)` double-bet key — are in the 0001–0038 range the 7/11 prod ledger recorded as already applied. `gtarp_dbmigrate` self-applies only 0040 + 0042–0047, so these two rely on that earlier apply. Expected present; confirm on prod if a double-bet is ever observed.

- [x] Audit complete, findings triaged — 10/10 clean
- [x] No confirmed findings requiring a fix
- [ ] (optional) apply fightclub charge-first + protection finally-release hardening in a future pass

### §4b — Systematic beta-readiness sweep (2026-07-13, 5 lenses × adversarial verify)

Second pass covering the WHOLE custom layer along 5 orthogonal lenses (boot/items, money-remaining-16, cross-resource contracts, new-player path, coords). 6 CONFIRMED findings, 10 UNCERTAIN (mostly coords needing in-game verify).

**FIXED (committed `d1509cf`, local):**
- **[HIGH] gtarp_insurance theft-claim faucet** — `insure → file theft/total-loss claim → policy retires → re-insure same plate` was a strictly net-positive loop (~54% of vehicle value payout vs 5% premium, every 15 min; theft claims also bypass the forensic deny gate because `vehCoords` is nil in the theft branch; vehicle never consumed). **Fix: a written-off plate (prior theft/total_loss claim) is no longer re-insurable** — kills the repeatable loop. Repairable minor damage stays insurable.
- **[LOW] gtarp_dbmigrate** — fxmanifest `lua54 'yes'` added; scope comments corrected (0040/0042/0043/0044 → 0040 + 0042-0047; code already applies 0045-0047).
- **[LOW] gtarp_help** — `/lottery` (real public command) added to the City menu (was missing).

**CLEARED during triage:** gtarp_yard's `xt-prison` dependency — confirmed **xt-prison IS running on prod** (base-recipe resource, correctly not in our custom.cfg). Not a blocker.

**David decisions / actions still open (from the sweep):**
- **Insurance theft semantics (deeper):** the repeatable faucet is closed, but manufactured theft (car state=0 + not in synced world, no real theft event) still pays once with no forensic gate. Decide: gate theft on a gtarp_replay scene or a real reported-stolen event, and/or consume the vehicle in `player_vehicles` on a theft/total-loss payout. *(my call: worth doing before a big beta, but not a repeatable exploit anymore)*
- **eventguard budgets:** counterfeit/flashdrop/pumpcoin/grind/witnesses money events + `gtarp_mechanic:acceptInvoice` have no eventguard rate-cap (defense-in-depth only — each resource's own cooldown already prevents dupes; not exploitable). Plus a stale gtarp_mechanic eventguard comment. *(I can add these; sizing needs each resource's cooldown read first — say the word.)*
- **evidence table-payload renders as raw JSON** to officers in `/mdtcase`/`/evidence case` — cosmetic UX (touches gtarp_mdt, currently owned by the Discord terminal — left to avoid collision).
- **gtarp_devtest** is convar-gated OFF in prod, so contract drift ships silently — consider enabling briefly on a staging boot.
- Coords: market exchange/refinery, yard stations, smuggling nodes remain Tier-3 placeholders (see §3).

---

## §5 — Owed item-icon PNG manifest (David generates in ChatGPT)

Drop 128×128 PNGs (transparent) named exactly `<item>.png` into `ox_inventory/web/images/`, then re-deploy. Until then these items are fully functional but show the blank placeholder box.

| Item | Label | Suggested icon |
|------|-------|----------------|
| `refined_metal` | Refined Metal | a clean metal ingot / bar |
| `cured_leather` | Cured Leather | a rolled tan leather hide |
| `fillet` | Fish Fillet | a raw fish fillet |
| `cured_meat` | Cured Meat | a dried/cured meat slab |
| `yard_pruno` | Pruno | prison hooch in a plastic bag/bottle |
| `yard_commissary_snack` | Commissary Snack | a wrapped snack bar |
| `yard_soap` | Bar of Soap | a plain bar of soap |

*(Other custom items — drugs, counterfeit, flashdrop precursors — reuse base-game or earlier-supplied icons; only these 7 are outstanding.)*

---

## §6 — Bug-report template (for testers)

Post in the Palm6 Discord `#beta-bugs` channel with:

```
**What I did:** (command / where I was / coords if known via /coords)
**What happened:** (actual result)
**What I expected:** (expected result)
**Repro:** (can you do it again? steps)
**Severity:** blocker / annoying / cosmetic
**Screenshot/clip:** (attach if visual)
```

Money/dupe exploits: **do not post publicly** — DM staff directly (rule #4: exploits get reported, not abused).

---

## §7 — Condensed command reference

Full, always-current list in-game: `/help` then `/help <topic>`.

- **Gangs:** `/gang` `/gangweb` `/gangs` `/ganginfo` `/turf`
- **Crime:** `/launder` `/dirtymoney` `/shakedown` `/rackets` `/borrow` `/repay` `/loaninfo` `/smuggle` `/deliver` `/smugglerun` `/numbers` `/collectnumbers` `/numbersinfo` `/buyweapon` `/demandransom` `/payransom` `/reportstolen` `/sellstolen` `/shill` `/pumpboard` `/fcjoin` `/fcleave` `/fcbet` `/fcmatches` `/flashdrop` `/golive` `/endstream` `/clout` `/streamers`
- **EMS:** `/medbills` `/paymedbill` `/emsbill` `/emscalls` `/treat`
- **City:** `/citystats` `/season` `/seasontop` `/rules`
- **Justice:** `/rapsheet` `/wanted` `/amiwanted` `/fines` `/payfine` `/insure` `/fileclaim` `/policy` `/bounties` `/postbounty` `/cancelbounty` `/capture` `/tip`
- **Law enforcement (on duty):** `/cite` `/mdt` `/bolo` `/bolos` `/warrant` `/warrants` `/book` `/calls` `/blotter` `/priors` `/evidence` `/casenew` `/witnesses` `/bodycam` `/seizedirty` `/expunge`
- **Jobs:** `/courier` `/courierpost`
- **Market/economy:** `/market` (exchange + refinery)
- **Admin (ace):** `/diag` `/economy` `/seasonopen` `/seasonclose`
- **Utility:** `/coords` (report your position, handy for bug reports)
