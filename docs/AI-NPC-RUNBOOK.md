# PALM6 AI-NPC Living World — Deploy & Browser-Walk RUNBOOK

_The canonical, gate-by-gate procedure for lighting up the `palm6_brain` AI-NPC world safely. Everything ships **dark**; you flip one gate at a time, verify with a meter, and browser-walk each new behavior before moving on. The one that matters most is the money attack-path walk (§6) — do not skip it._

> Companion to `docs/AI-NPC-ROADMAP.md` (the plan). This is the **operations** doc: what's actually built, where every gate is, and how to turn it on without breaking a live server.

---

## 1. What's built (Phases 0→5, all in `resources/[custom]/palm6_brain` unless noted)

| Layer | Files | What it does |
|---|---|---|
| Ambient + named NPCs (P0/P1) | `client/main.lua`, `shared/config.lua` | Client-local ambient peds + 3 GLM-powered talkable NPCs (Tony/Rosa/Deak) |
| World-state (P2a) | `client/main.lua`, `server/main.lua` | NPCs know time/day/weather/who's-near |
| Director (P2b) | `server/director.lua` | Batched LLM assigns movers goals from a closed action enum; 3-layer validator; TTL goal store; graceful degradation |
| Client executor (P2b) | `client/main.lua` | Movers actuate goals (navmesh walk, timeout/stuck/arrival/fallback) |
| Crime (P2b) | `server/director.lua`, `bridge/sv_framework.lua`, `client/main.lua` | Committed crime verbs fire **throttled** 911s to on-duty cops |
| Passive money (P2b) | `palm6_business` (`AccrueNpcPassive`, `NpcStorefrontAt`) + `server/director.lua` | `orderAt` goals credit nearby owned shops off-peak, **sharing palm6_business's bounded daily faucet** (no new money ceiling) |
| Memory (P3) | `server/memory.lua` | NPCs remember notable interactions; teaches the Director for continuity |
| Factions (P4) | `server/factions.lua` | Crime creates decaying grudges; retaliation is **emergent** (LLM chooses) |
| Chatter (P5) | `client/chatter.lua` | Nearby peds exchange short canned overheard lines |

**Extension seam:** `server/director.lua` exposes `Director.RegisterContext(fn)` / `Director.OnAction(fn)`; memory & factions attach through it (must load AFTER `director.lua`).

---

## 2. Every gate (default state = the whole system is OFF)

| Gate | File | Default | Controls |
|---|---|---|---|
| `Config.Enabled` | palm6_brain `shared/config.lua` | **true** | Ambient/named/dialogue (already live) |
| `Config.Director.Enabled` | palm6_brain `shared/config.lua` | **false** | The Director tick loop + mover materialization |
| `Config.Director.DryRun` | palm6_brain `shared/config.lua` | **true** | true = decide+log only; false = commit goals + broadcast + actuate |
| `Config.Director.CrimeEnabled` | palm6_brain `shared/config.lua` | **false** | rob/deal/attack verbs + police dispatch |
| `Config.Director.MoneyEnabled` | palm6_brain `shared/config.lua` | **false** | orderAt/buyFrom verbs + passive income |
| `Config.NpcPassiveIncome` | **palm6_business** `shared/config.lua` | **false** | The palm6_business side of passive income (BOTH this and MoneyEnabled required) |
| `CFG.Enabled` (factions) | palm6_brain `server/factions.lua` | **false** | Grudge tracking + retaliation context |
| `CFG.Enabled` (chatter) | palm6_brain `client/chatter.lua` | **false** | Ambient overheard chatter |

> Rollback for ANY step = set that gate back to its default and redeploy.

---

## 3. Deploy

Deploy the custom layer (the same workflow used for prior `palm6_brain` deploys — "Deploy custom layer"). A resource restart of `palm6_brain` is enough for palm6_brain-only changes; palm6_business config changes need palm6_business restarted too.

After every deploy, in the **server console** run:

```
brainstatus     # one-shot: every gate state + live counts
brainvalidate   # expect: "validator: 21 passed, 0 failed"
braincrime      # expect: "crime throttle: 8 passed, 0 failed"
```

If `brainvalidate`/`braincrime` are green, the on-rails contract and the crime rate-limiter are proven in the live runtime. Proceed.

---

## 4. Gated browser-walk — theater (no money, no crime)

**Step A — Director on, still dry-run.** Set `Config.Director.Enabled = true` (leave `DryRun = true`), redeploy.
- `/tp` to Legion Square. You should see extra "mover" extras wandering ambiently.
- `braindirector` → prints a dry-run plan from real GLM (validated, nothing actuated).
- `braingoals` → empty (dry-run commits nothing).
- Walk-check: movers wander, don't freeze, don't fall through the map, despawn when you leave.

**Step B — Commit goals (movers follow the Director).** Set `Config.Director.DryRun = false`, redeploy.
- Within one tick (~60s) `braingoals` shows live goals; movers walk to `goTo` targets, linger at `queueAt`/`orderAt`, idle, etc.
- Walk-check the ped-jank paths: a mover sent to a far scene (does it path or fall back to wander after timeout?), a stuck mover (does it abandon and wander?), despawn while walking away, `/stop palm6_brain` (do all peds clean up?).
- `brainmemory` → recent notable events accumulate; the digest is fed back into the prompt.

---

## 5. Gated browser-walk — crime (needs a cop online)

Set `Config.Director.CrimeEnabled = true`, redeploy. **Have one player on-duty as police** (the throttle refuses to dispatch to an empty PD).
- Over several ticks, watch for occasional 911 blips + notifications on the officer's map ("Robbery in progress — Legion Square", etc.).
- **Attack path to walk:** confirm the throttle holds — no more than ~1 dispatch per tick, a global cooldown between any two (default 45s), a per-location cooldown (default 180s). It must NOT spam the cop. Tune `Config.Director.Crime.*` if needed.
- Confirm the mover plays an agitated stance but never actually fights a player (theater only).
- **Optional — factions:** set `CFG.Enabled = true` in `server/factions.lua`, redeploy. After a crime, the Director is told "X may seek payback"; over time watch for emergent retaliation. It's LLM-driven, so it's occasional, not guaranteed.

---

## 6. 🔴 Gated browser-walk — MONEY (the attack path that matters)

Passive income is designed so it is **NOT a new faucet**: `AccrueNpcPassive` runs the exact same atomic, supply-consuming, daily-capped write as the owner-present serve, sharing the same `day_npc_income` column + `DailyNpcIncome` cap. This walk exists to **prove that** on the live economy before trusting it.

Turn on BOTH gates: `Config.Director.MoneyEnabled = true` (palm6_brain) AND `Config.NpcPassiveIncome = true` (palm6_business). Redeploy both.

Then walk the **AFK-printer attack** explicitly:
1. **Stock a shop, then leave.** As a business owner, buy supply, then go fully offline (or far away). A mover `orderAt` near your storefront should credit the business passively.
2. **Confirm it trickles, not floods.** Income should arrive on the per-business cooldown (default 300s), not instantly.
3. **Confirm it STOPS at the daily cap.** Let it run; total NPC income (active serves + passive) must never exceed `palm6_business Config.DailyNpcIncome` (15000/day). Check the business `account_balance` and the ledger.
4. **Confirm it consumes supply.** Passive credits must decrement `supply_units`. With zero supply, passive income must be **$0** (no free mint).
5. **Confirm the ledger.** Passive credits appear as `npc_passive` rows (distinct from active `npc_sale`). Audit them.
6. **Try to break it:** two players hammering serves + passive at once (the atomic `WHERE ... <= cap` guard must never let combined income exceed the cap); a shop with a storefront right next to two scenes (still one shared daily bucket).

If ANY of these fails — income exceeds the cap, credits without supply, or floods — set both money gates back to false and redeploy. Only trust it live once all six hold.

---

## 7. Meters reference

| Command | Reports |
|---|---|
| `brainstatus` | Every gate state + roster/goal/GLM counts (start here) |
| `brainvalidate` | 21-case validator battery (the on-rails contract) |
| `braincrime` | 8-case crime-throttle battery |
| `braindirector` | Run one Director tick now, print the plan |
| `braingoals` | Live goal store + TTL remaining |
| `brainmemory` | Recent notable events (memory digest) |

All are ACE-restricted (`command.<name>`).

---

## 8. Known limitations (honest)

- **Movers are client-local.** They're theater — fine for movement, dispatch, and passive-income triggers, but a crime/money NPC is **not a shared entity** players can directly rob/interact with. That requires server-owned **networked peds** (OneSync ownership + state-bag task re-assert) — a separate, larger build.
- **Memory/factions are in-memory** (reset on restart). Persistence is a documented future hook.
- **Passive income only reaches shops near the ambient scenes** (movers patronize scenes; a storefront within `BusinessRadius` of a scene gets walk-ins). Placing a storefront near a busy scene is the emergent incentive.
- **Retaliation is emergent, not guaranteed** — the LLM may or may not act on a grudge.
- **The passive-income trickle cooldown is in-memory** (`lastPassive`), so a `palm6_brain` restart clears it: a shop credited moments before a restart can be credited again immediately, briefly bypassing `PerBusinessCooldownSec`. The **daily `DailyNpcIncome` cap is in the DB and is unaffected**, so total income stays bounded — only the smoothness of the trickle is affected, never the ceiling.
