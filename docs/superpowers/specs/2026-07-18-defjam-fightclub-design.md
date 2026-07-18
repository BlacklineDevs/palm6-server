# Def Jam-Style Fight Club — Design Spec (MVP / "bigger Phase 0") — v3

**Date:** 2026-07-18 (v3 after a 2nd adversarial spec review: 40 raw → 37 confirmed / 7 critic gaps, grounded in the real `palm6_fightclub` code)
**Status:** Design — ready for implementation planning (writing-plans) once the flagged economic knob (§10a EntryStake) is set.
**Repo:** BlacklineDevs/gtarp (Palm6 FiveM/Qbox server). **Owner:** David Olverson.

> **v3 changelog (what the 2nd review changed vs v2):**
> 1. **Money-safety, betting-state void (was a CRITICAL strand):** the "refund via the existing bet-refund path" claim was false for a `betting`-status row — `settleMatch` only runs on a `resolved` row and `resolveMatch` is gated `WHERE status='live'`, so a pre-fight/countdown DC or a boot no-contest on a `betting` row could **never** refund. v3 adds an explicit **`VoidMatch(matchId)`** (guarded `betting→resolved,winner=NULL,settled=0` → `settleMatch` draw branch) and names its callers.
> 2. **Lifecycle vs DB status ENUM:** the ENUM is only `('betting','live','resolved')`. v3 keeps ACCEPTED/COUNTDOWN as **in-memory/client-only** states, the row staying `betting` until a **guarded `betting→live` flip at COUNTDOWN start** (which also closes `/fcbet`). No ENUM migration needed; every resolution guard now maps to a status that actually exists.
> 3. **Finisher ownership (false native premise):** a client cannot drive a ped it does not own. v3 rewrites §7 to the same correct model §6's KO already uses — **each fighter's own client drives its own half** at a server-broadcast shared origin + start-time; spectators/opponent are pure viewers via ped-anim replication.
> 4. **Combat numbers actually populated:** v2 claimed a move table but shipped none. v3 adds the **full move table + every combat constant** (§6a) as real `palm6_fc_core` config.
> 5. **Selection wired into the state machine** (§5 SELECT/challenge payload; `OpenMatch` extended with style/fighter).
> 6. **Funding fixed** (§10a entry-stake ante so a no-spectator fight still has a real, money-safe purse).
> 7. Plus: migration registration of the base tables, `rep_awarded DEFAULT 1` DDL fix, anim/model **preload** + appearance/loadout handling, **ring-confinement** (anti-godmode), rep cash-neutrality made real (style parity), eventguard combat-class budget, CHALLENGE input, spectator BETTING broadcast, stub OPEN/ADVANCE commands, `fc_core` shipped as `shared_scripts`, dbmigrate load-order, and Config.Enabled rollback semantics.

---

## 1. Goal & fidelity target

Rebuild the fight club into a **Def Jam: Fight for NY-flavored** brawler: pick a fighter,
strike/combo with stamina, build a **Blazin momentum meter**, land a **cinematic finish**,
KO your opponent in a hyped arena with a crowd and live **betting**, and climb a **rep career**.

**Fidelity target: convincing homage, not arcade-faithful port.** Deferred/simplified: frame-precise
reversals and flawless two-body grapple sync. (The finisher — §7 — is a two-body scene; we accept small
per-client phase drift on frozen, position-locked peds and choose a pose where that drift is invisible.)

**Hard IP line (enforced in the asset pipeline):** original-branded; no real rappers/celebrities/
copyrighted characters; no ripped Def Jam/Sifu/Sleeping Dogs/Yakuza assets. Roster = original
archetype "house" fighters + (later phase) player-created fighters. Every shipped asset carries a
provenance note (original / CC0 / CC-BY / licensed). Rationale: Take-Two owns Cfx.re and can pull the
server key **and** Tebex store; monetization strips any fan-use framing.

## 2. Scope

### In (MVP)
Server-authoritative match lifecycle **built on the existing `palm6_fightclub` match record + recoverable
payout**; real striking combat (server-driven move clock, server-owned HP/stamina/momentum); Blazin meter
+ **one** cinematic finisher (per-client own-ped scene pattern); fighter select with original house fighters +
styles; NUI HUD; arena (zone + crowd + spectator cam); rep/rank career; betting kept and driven by the new
resolver; **an entry-stake-funded purse** so a no-spectator fight still pays.

### Out (deferred — not MVP)
Grapple/throw + environmental finishers (custom synced scenes + mocap); build-your-own-fighter creator;
deep reversals/counters; full unlock tree / gear / seasons; multi-round / best-of formats; multiple
simultaneous rings (the schema is left ring-ready but MVP ships one ring).

## 3. Architecture — modules

palm6 bridge pattern (`bridge/sv_framework.lua` + `bridge/cl_game.lua`) + RFC-001 metadata + `palm6_<domain>`
naming throughout.

**Ensure/load order (custom.cfg), corrected for the real dependency graph:**
`palm6_eventguard` → **`palm6_dbmigrate`** → `palm6_fc_core` → `palm6_fightclub` (rewired) →
`palm6_fc_combat` → `palm6_fc_hud` / `palm6_fc_arena` → `palm6_fc_progression`.
`palm6_dbmigrate` is currently ensured at custom.cfg:208 — **after** `palm6_fightclub` (:108) — and the only
reason fightclub survives is its `Wait(8000)` boot-reconcile delay (main.lua:579). v3 requires **either**
moving dbmigrate ahead of every fc_* resource in the ensure order **or** replicating the boot-delay-until-
migrated guard in `palm6_fc_progression` (see §11). Do both if cheap.

| Resource | Responsibility | Realm & interface |
|---|---|---|
| `palm6_fc_core` | Shared data + constants only (no behavior): config; the **full move table + all combat constants (§6a)**; fighter/style data tables; statebag key constants; the seam's shape; **documents** which net events need eventguard budgets. | **`shared_scripts`** (NOT server-only — both the server move-clock validator AND the client combat/HUD read `GetMove/GetStyle/StateKeys`; the `palm6_fightclub`/`palm6_bounty` server-only precedent would fork this single source of truth). exports `GetFighter/GetStyle/GetMove/StateKeys/Config`. |
| `palm6_fightclub` (rewired) | **Owns the match record + money.** Keeps `palm6_fightclub_matches`/`_bets`, `/fcbet`, the betting window, and the crash-recoverable `settleMatch`/`reconcileUnsettled`/`claimBet`/`purse_paid`/`settled` payout. **Removes** the queue, `/fcjoin`/`/fcleave`, `sweepLiveMatches`/`checkFighter` (the native-health self-resolver), and `sweepBettingToLive`. Exposes `OpenMatch`/`GoLive`/`ResolveMatch`/`VoidMatch` **server exports** for combat to drive. | exports (server-only) `OpenMatch(aCid,bCid,styleA,styleB,fighterA,fighterB)→matchId:int`, `GoLive(matchId)→bool`, `ResolveMatch(matchId,winnerCid,method)→bool`, `VoidMatch(matchId)→bool`. Fires server-internal `fc:match:resolved`. |
| `palm6_fc_combat` | The fight engine (client+server): CHALLENGE input, SELECT, accept handshake, betting-window timer + `GoLive` flip, server-driven move clock, server-owned HP/stamina/momentum, KO, drives the finisher, **owns the `playerDropped` DC resolution** for fc matches. On fight end calls `ResolveMatch`; pre-LIVE aborts call `VoidMatch`. **Sole resolver.** | in: challenge/select/accept/strike/connect/block/break net events (all eventguard-budgeted; combat events use the **combat-class budget** §13). out: `OpenMatch`/`GoLive`/`ResolveMatch`/`VoidMatch` calls; fight statebags. |
| `palm6_fc_hud` | Own NUI resource (`ui_page` + html/js, mirroring `palm6_clout`/`palm6_pumpcoin`): two health bars, stamina, Blazin meter. Reads fight statebags. No authority. | in: statebags/`fc:hud:*`. |
| `palm6_fc_arena` | Zone + ring bounds + **server-authoritative fight-mark placement (§6/§K)** + crowd (local, non-networked peds) + spectator cam + the BETTING broadcast (§12). **Presentation + client UX only** — NOT the source of proximity truth. | client zone prompts; server owns the at-ring coords check (reuse `atRing()` main.lua:48). |
| `palm6_fc_progression` | Rep/rank/unlock ledger; atomic claim-before-credit + boot reconcile (delayed until dbmigrate has run); anti-farm gating. | in: consumes server-internal `fc:match:resolved`. out: `GetRep/GetRank/HasUnlock`. |

### The seam — server-internal, unforgeable
`fc:match:resolved` is a **server-side `TriggerEvent`**, **never** a `RegisterNetEvent`. Producers/consumers
are all server code; a modified client cannot fire it. Flow: `fc_combat` decides the winner from its own
server state → calls `exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method)` → fightclub settles
purse/bets via its existing recoverable path and emits server-internal
`fc:match:resolved{matchId,winnerCid,loserCid,method,startedAt,endedAt}` → `fc_progression` awards rep.
`matchId` is the **integer** `palm6_fightclub_matches.id` (one match record; no second namespace).

## 4. Data model

Reuse the existing `palm6_fightclub_matches` (id INT, fighter1/2_citizenid, fighter1/2_name, status,
winner_citizenid, purse_paid, settled, betting_ends_at, resolved_at, …) and `palm6_fightclub_bets` (paid) —
the money path is unchanged. **The status ENUM stays `('betting','live','resolved')` — NOT extended** (see §5:
ACCEPTED/COUNTDOWN are in-memory, the row is `betting` until the guarded `betting→live` flip).

New columns on `matches` (idempotent `ADD COLUMN IF NOT EXISTS` ALTERs):
- `style1 VARCHAR(24)`, `style2 VARCHAR(24)`, `fighter1_model VARCHAR(48)`, `fighter2_model VARCHAR(48)`
- `method VARCHAR(16)` — **VARCHAR, not ENUM** (an out-of-range ENUM write throws under strict SQL mode and is
  pcall-swallowed → a silent faucet/strand, per the sql/0065 lesson). Values: `ko`/`finisher`/`forfeit`/`draw`/`void`.
- `entry_pot INT NOT NULL DEFAULT 0` — the two fighters' escrowed entry stakes (§10a).
- `rep_awarded TINYINT NOT NULL DEFAULT 1` — **DEFAULT 1, load-bearing** (v2 §4 prose said DEFAULT 1 but the
  copy-ready DDL line said DEFAULT 0 — v3 fixes the DDL to match the reasoning).

New tables:
- `palm6_fc_progression(citizenid PK, rep INT DEFAULT 0, wins INT, losses INT, rank_tier INT, updated_at)`
- `palm6_fc_unlocks(citizenid, unlock_id, unlocked_at, UNIQUE(citizenid,unlock_id))` (INSERT IGNORE).

**Migration registration (hard Phase-0 task, was only a "confirm" in v2 — CONFIRMED MISSING):** the base
`palm6_fightclub_matches`/`_bets` CREATE (sql/0028) is **NOT** in `palm6_dbmigrate`'s inline STATEMENTS list —
so a dbmigrate-only DB rebuild runs the 0054 ALTERs (and all new fc ALTERs) against **non-existent tables**.
Add guarded `CREATE TABLE IF NOT EXISTS` entries mirroring 0028 for both base tables, ordered **before** the
0054 and all new fightclub ALTERs (STATEMENTS runs in array order — an ALTER before its CREATE fails on a
fresh DB). `palm6_dbmigrate` has no ledger → re-runs every stmt every boot → every new stmt MUST be idempotent
(`ADD COLUMN IF NOT EXISTS` / `CREATE TABLE IF NOT EXISTS` / `INSERT IGNORE`).

**Why `rep_awarded DEFAULT 1` (unchanged reasoning, kept):** it's a NEW column on the **existing** matches
table which already holds historical `resolved` rows, so `DEFAULT 0` would make the boot reconcile
(`WHERE status='resolved' AND rep_awarded=0`) award rep for **every historical match at once** on first boot.
`DEFAULT 1` backfills all pre-existing rows as already-awarded; the resolver **sets `rep_awarded=0` at the
moment it flips a row to `resolved`** (alongside `settled=0`) so only post-deploy matches are reconcilable —
**this reset is mandatory: without it, new matches inherit DEFAULT 1 and progression's `WHERE rep_awarded=0`
claim never fires, so NO post-deploy match ever grants rep.**

## 5. Match lifecycle (state machine — server-owned, single resolver)

DB `status` only ever holds `betting` / `live` / `resolved`. SELECT/CHALLENGE/ACCEPTED/COUNTDOWN are
**in-memory (fc_combat) + client** states before the row exists or before it goes live.

```
IDLE
 → CHALLENGE  A targets B at the ring — INPUT (decided): ox_target eye on a nearby player ped (preferred —
              matches the existing palm6 interaction pattern), with `/fcchallenge [serverid]` as a fallback.
              Server independently verifies BOTH cids at the ring via atRing() coords AND that neither has an
              in-flight match (DB check §5-races), then sends B an accept/decline prompt (a net event,
              eventguard-budgeted). TTL = Config.ChallengeTTL (20s) → auto-expire. No DB row yet.
 → SELECT     each side picks {fighterId, styleId} in the NUI (§8). Client only REQUESTS; server validates the
              pick against unlocks and snapshots it. A side that never opens the UI gets Config.DefaultFighter/
              DefaultStyle. (May be folded into the challenge/accept payload — see §C2 note.)
 → ACCEPTED   server charges each fighter Config.EntryStake into escrow (§10a), then calls
              palm6_fightclub:OpenMatch(A,B,styleA,styleB,fighterA,fighterB) → integer matchId. OpenMatch
              INSERTs the row exactly as createMatch does: status='betting', fighter1/2_name (resolved
              server-side from src), fighter1/2_model, style1/2, entry_pot = 2*EntryStake, betting_ends_at =
              NOW()+INTERVAL BetWindowSec. If either charge fails → refund the other → abort (no row).
 → BETTING    row status='betting'; window Config.BetWindowSec (60s); /fcbet open ONLY here. fc_combat runs a
              per-match server timer keyed off betting_ends_at; the arena broadcasts the open match (§12).
 → COUNTDOWN  (in-memory) at betting_ends_at: fc_combat runs GoLive(matchId) — a guarded
              `UPDATE ... SET status='live' WHERE id=? AND status='betting'` (affected==1 gates) — which
              **closes /fcbet by leaving 'betting'** and is the server-owned replacement for the deleted
              sweepBettingToLive. THEN preload (§6a) + fight-mark placement (§K) + a client 3-2-1. The HP/round
              clock does NOT start yet: a per-match in-memory `roundStarted` flag is set only at LIVE.
 → LIVE       row already status='live'. roundStarted=true; the round (§6) runs. Round cap Config.RoundSec (180s).
 → FINISH     KO (server HP≤0), finisher KO, ring-out forfeit, DC forfeit, or round-timer expiry.
 → RESOLVED   fc_combat computes winner+method, calls ResolveMatch(matchId,winner,method); teardown both clients.
 → IDLE
```

**Round resolution (MVP = single round):** first fighter to server-HP ≤ 0 loses (method=ko/finisher). If
`RoundSec` expires: higher HP% wins (method=ko); equal within Config.DrawBand → **draw** (method=draw, no rep,
bets fully refunded + entry stakes returned). Multi-round/best-of deferred.

**Ring occupancy:** derived **purely from the DB** (`status IN ('betting','live')` — which now covers
COUNTDOWN, since the row is `live` from COUNTDOWN-start). One active match per ring; a second challenge while
a ring is busy is rejected ("ring in use"). No in-memory ring lock (a crash must not strand the ring). The
schema is left ring-ready (add a `ring_id` column + per-ring busy check) but MVP ships one ring.

**Concurrency / races (DB-backed, survives restart):** `OpenMatch` and CHALLENGE both **reject any citizenid
that already has a `status IN ('betting','live')` row** (a DB check, not just the in-memory per-cid guard — the
in-memory guard is cleared by a restart, so without the DB check a cid could be re-paired before its old row
no-contests). Mutual simultaneous challenges: first to reach the server wins, the second is auto-declined.

**Disconnect / exit — handled at EVERY state, with the correct guarded transition for each:**
- **CHALLENGE / SELECT (no row yet):** drop the in-memory challenge; nothing to refund.
- **ACCEPTED / BETTING (row is `betting`):** **`VoidMatch(matchId)`** — a guarded
  `UPDATE ... SET status='resolved', winner_citizenid=NULL, method='void', settled=0 WHERE id=? AND
  status='betting'` (affected==1 gates) → `settleMatch` (the winner=NULL **draw branch** refunds every bet) +
  **entry stakes returned to both fighters**. This is a NEW routine (v2 wrongly called it "the existing path" —
  the existing path only reaches a `resolved` row, unreachable from `betting`).
- **COUNTDOWN / LIVE (row is `live`):** the disconnecting player forfeits →
  `ResolveMatch(matchId, opponentCid, 'forfeit')` (live-guarded, so it now actually fires). Purse (entry pot +
  parimutuel) settles to the opponent; opponent client runs teardown. **Owner: fc_combat's `playerDropped`
  handler** (fightclub's playerDropped no longer resolves matches).
- **Pre-LIVE forfeit ≠ in-LIVE forfeit:** a forfeit/DC before roundStarted (ACCEPTED/BETTING/COUNTDOWN) **voids
  and refunds** (a fight that never happened must not pay a winner — that's trivial DC bet-fixing). Only a
  forfeit once `status='live'` AND `roundStarted` pays the opponent.
- **Simultaneous KO+DC / double-trigger:** resolution is idempotent — the atomic
  `UPDATE ... status='resolved' WHERE id=? AND status='live'` (affected==1) means only the first caller
  resolves. fc_combat also holds a per-match in-process `resolving` flag. **Deterministic precedence: a DC
  ALWAYS forfeits, even mid-finisher** — `playerDropped` sets `resolving` and short-circuits the finisher-end
  resolve before it can call ResolveMatch (DC beats finisher-end), so the winner is never nondeterministic.

## 6. Combat model (`palm6_fc_combat`) — server-driven move clock

**Server owns all fight state.** HP, stamina, momentum are **server script vars** keyed by matchId+cid — never
ped health. Fighter peds are decoupled and hardened each LIVE tick, **re-fetching `PlayerPedId()` after the
model swap** (§8) and retargeting every native to the new handle:
- `SetPlayerInvincible(playerId,true)` + `SetEntityInvincible(ped,true)` — blocks health loss only.
- **`SetPedCanRagdoll(ped,false)`, re-asserted each frame** — stops a punch/vehicle/explosion from knocking the
  fighter into ragdoll and interrupting a clip (invincibility does NOT do this; the engine can re-enable player
  ragdoll, so this is a per-frame re-assert, not a one-shot).
- Pain/flinch suppression: `SetPedSuffersCriticalHits(ped,false)` + `SetPedConfigFlag(ped, 187, true)`
  (disables melee-hit reactions) + `SetPedConfigFlag(ped, 281, true)` where applicable. **Additionally, strike
  and finisher clips are played with a non-interruptible `TaskPlayAnim` flag (flag 2/16 as fits)** so a stray
  melee reaction cannot override the intended clip (invincible + CanRagdoll(false) alone do NOT stop a flinch).
- Native melee input suppression: `DisableControlAction(0, n)` each frame for
  n ∈ {24,25,140,141,142,143,257,262,263,264} (attack/aim/melee light+heavy+block+combo) **plus {21 (sprint-to-
  shove), 44 (cover), 36 (stealth)}** if feel-testing shows they leak; blocks the *local* fighter's own melee.
  `SetCurrentPedWeapon(ped, WEAPON_UNARMED)` + `SetWeaponsNoAutoswap` guarantee empty-handed only.
- **Third-party interference (handled):** a non-participant who hasn't disabled melee can still swing, but
  `SetPedCanRagdoll(false)`+invincibility+the non-interruptible clip flag neutralize it, and the server
  **ignores any hit whose attacker is not a snapshotted participant of that matchId**. Arena soft-repels
  non-participants from the ring interior. A §14 feel-test explicitly covers a non-participant punching a
  fighter mid-clip.
- **Ring confinement (anti-godmode, CONFIRMED gap):** the old left-ring detector is removed, so v3 must
  re-add server-side confinement or an invincible fighter walks out of the ring untouchable. LIVE fighters are
  confined by a **fast server coords poll (Config.RingPollSec, ~0.5s)** that force-resolves a ring-out
  (`method=forfeit`) within one poll AND **immediately runs client teardown to drop invincibility** the instant
  a fighter leaves `Config.Ring.radius` — invincibility must drop on ring-exit, not only at RESOLVED.
- **Ordering:** before any intended KO/finisher ragdoll, flip `SetPedCanRagdoll(ped,true)` first or
  `SetPedToRagdoll` no-ops.

**Move clock (the server can't read client anim state, so it owns move cadence instead):**
1. Client presses input → emits `fc:combat:strike{matchId,moveId}`.
2. Server validates: correct match+state (`live` + roundStarted), move exists, per-move cooldown elapsed
   (server timer), stamina ≥ cost. On pass: deduct stamina, start a server-side **active window** timer
   (`move.activeWindowMs`) for that move, tell BOTH clients to play the clip.
3. Attacker client, on visual connect, emits `fc:combat:connect{matchId,targetCid}`.
4. Server validates: connect arrived within the active window, target is a LIVE participant, within
   `move.reach` (server coords distance), target not in a valid block (§blocking). On pass: apply `move.damage`
   to server HP, add momentum (landed→attacker `MomentumPerLandedHit`, taken→target `MomentumPerTakenHit`),
   broadcast HP/stamina/momentum via **coalesced/throttled** statebags. Reject (rate-limit/log) otherwise.

**Blocking:** `block` is a held stance (`fc:combat:block{on/off}`, server records it). A connect against a
blocking target facing the attacker deals `move.chipPct` chip damage + drains the blocker's stamina by
`move.blockStamCost`; block breaks if stamina hits 0 (server-owned, unforgeable).

**Stamina:** heavy moves + blocking cost stamina; regenerates `StaminaRegenPerSec` when not attacking/blocking;
at 0 you can only throw light strikes (server-gated).

**KO:** server HP ≤ 0 → server orders **the victim's own client** to ragdoll itself (`SetPedCanRagdoll(true)` →
`SetPedToRagdoll` + `ApplyForceToEntity`) — each client only ragdolls the ped it owns → FINISH.

**Anti-cheat posture (documented limits):** no true server hit-detection exists in FiveM; the server owns
HP/stamina/momentum + the move clock and validates every event, so a cheater cannot mint rep/money (gated on
the server result + atomic claim) though they may desync visuals. Accepted, not hidden.

## 6a. Combat numbers (`palm6_fc_core` — the move table v2 claimed but never shipped)

**These are real starting values (tune in feel-test); the whole move clock is unbuildable without them.**

- **Fighter vitals:** `StartHP = 100`, `MaxStamina = 100`, `StaminaRegenPerSec = 12`, `BlazinFullThreshold =
  100` (momentum units to full meter).
- **Momentum:** `MomentumPerLandedHit = 12`, `MomentumPerTakenHit = 6` (both gain — the Def Jam feel).
- **Move table** (per style, but MVP ships all styles **stat-identical** — see §8/§9 for why): each entry
  `{moveId, kind, damage, staminaCost, cooldownMs, activeWindowMs, reach, chipPct, blockStamCost}`:

  | moveId | kind | damage | staminaCost | cooldownMs | activeWindowMs | reach(m) | chipPct | blockStamCost |
  |---|---|---|---|---|---|---|---|---|
  | `jab` | light | 6 | 4 | 450 | 350 | 1.6 | 0.15 | 8 |
  | `cross` | light | 9 | 7 | 650 | 400 | 1.6 | 0.15 | 10 |
  | `hook` | heavy | 15 | 14 | 1100 | 450 | 1.4 | 0.20 | 16 |
  | `uppercut` | heavy | 18 | 18 | 1300 | 450 | 1.3 | 0.20 | 20 |
  | `body` | heavy | 13 | 12 | 1000 | 450 | 1.4 | 0.10 | 14 |

  (5 moves → a KO is ~7–12 connects; a heavy is the finisher's "qualifying hit". `body` drains more than it
  damages — a stamina-pressure tool.) Anim dicts per move live in the style data (§8) and are **preloaded** at
  COUNTDOWN (§6 preload).

- **Timers (existing config, kept):** `ChallengeTTL = 20`, `BetWindowSec = 60` (kept at 60 — v2's 30s starves
  betting discoverability), `RoundSec = 180`, `DrawBand = 5` (HP% band for a timeout draw), `RingPollSec = 0.5`.

## 7. Blazin finisher (per-client OWN-ped scene — corrected ownership)

Trigger: a fighter whose momentum is full lands a **heavy** connect (the "qualifying hit") → server starts the
finisher. Fairness (MVP): telegraphed (a wind-up beat + audio cue) and the victim gets a short
**mash-to-reduce** window (`fc:combat:break` spam, see §13 for the eventguard treatment) that scales the
finisher damage down — a full meter is a big momentum swing, not a guaranteed instant KO unless the victim is
already low. It only KOs if it drops HP ≤ 0.

**Execution (never `NetworkCreateSynchronisedScene`; and NOT "every client drives both peds" — a client cannot
drive a ped it does not own):**
1. Server computes the finisher **origin + rotation** from the two peds (well-defined because §K squared them
   up at COUNTDOWN) and a **shared scene start timestamp**, picks the clip pair, and sends **each FIGHTER a
   "play your half on your OWN ped" order** (broadcast to in-range clients for late-join re-broadcast).
2. **Each fighter's own client** runs `CreateSynchronizedScene`/`TaskSynchronizedScene` on the ped **it owns**
   only, with `SetEntityCoordsNoOffset`+`FreezeEntityPosition(true)`+`SetEntityInvincible(true)`+
   `SetPedCanRagdoll(false)` on **its own** ped for the 2–4s duration, starting at the shared timestamp.
   The opponent and all spectators are **pure viewers** — they do NOT task/freeze a ped they don't own; they
   see both halves via normal ped-anim network replication (exactly the model §6's KO already uses correctly).
   Preload the clip dict first (§6 preload).
3. Participants get a scripted dolly cam + participant-only slow-mo (`SetTimeScale`) + brief screen FX.
   Spectators keep normal cam and see the replicated scene.
4. On scene end: **the SERVER** applies finisher damage authoritatively (never a client) → teardown →
   KO/RESOLVED. All temporary states reset in the canonical teardown (§11).
5. **Interruptible:** the finisher is abortable. A mid-finisher DC forfeits deterministically (§5); the
   canonical teardown **stops the per-frame scene task + clears the scene handle BEFORE** unfreeze/timescale/cam
   reset, the "on scene end apply damage" step **no-ops if the match already resolved**, and a per-client
   `inFinisher` flag that teardown clears prevents the scene loop from re-freezing a torn-down player.

**Accepted residual (documented):** two independent owner-local scenes can phase-drift (the deferred two-body
grapple-sync problem, §1). We constrain the finisher to a pose where small phase drift on frozen, position-
locked peds is visually acceptable, and prototype on a base-game takedown clip first.

## 8. Roster & styles (`palm6_fc_core` data)

- **Fighters** = data `{id,name,model,styleId,unlockId?}`. MVP ships ~4-6 **original house fighters** (original
  names/silhouettes) mapped to **existing base/MP ped models** (zero custom assets to ship). A fighter is just
  data+model, so custom original models swap in later. `Config.DefaultFighter` is the fallback if a player never
  opens SELECT.
- **Styles** = data `{id,name,movementClipset,moveTable, animDicts[]}`; ~3 styles (Brawler/Kickboxer/
  Wrestler-lite). **MVP moveTable parity (CONFIRMED anti-farm fix): all three styles share the SAME stat block
  (§6a) — they differ only in `movementClipset` + animation feel, NOT power** — so rep can be genuinely
  cash-neutral (§9). Styles are **free-select at launch for every player** (not rep-gated); rep unlocks only
  **cosmetic/name variants**, never a stronger moveTable. (If a future phase makes styles differ in strength,
  they must stay free-select, not rep-gated.) `SetPedMovementClipset` **requires `RequestClipSet` +
  wait-until-`HasClipSetLoaded`** (it silently no-ops otherwise).
- **Preload (COUNTDOWN, gates entry to LIVE):** `RequestAnimDict`+`HasAnimDictLoaded` for every selected
  style's strike/block/hit-react dicts AND the finisher dicts; `RequestClipSet`+`HasClipSetLoaded` for the
  movement clipset; `RequestModel`+`HasModelLoaded` before `SetPlayerModel`. If any load times out → abort the
  countdown gracefully (VoidMatch → no-contest, stakes/bets refunded).
- **Appearance safety (CONFIRMED insufficient in v2 — model-hash restore wipes components):** snapshot the
  player's **full appearance via the appearance resource (illenium-appearance / qbx)** before the swap, not just
  the model hash; on teardown/DC/error **reapply that snapshot via the appearance resource** (not `SetPlayerModel`
  alone); use a **non-persisting** client model swap so a DC self-heals on reconnect. Re-fetch `PlayerPedId()`
  after the swap and retarget all per-tick hardening natives (§6) to the new handle. Never leave a player stuck
  as a fighter model or stripped of components.
- **Loadout safety:** at match entry, snapshot and **holster/hide (or temporarily remove) carried weapons**,
  restore on canonical teardown; fighter peds stay invincible/never-killed so the inventory death-drop path is
  never triggered.
- **Select UX:** NUI list + stance-preview cam at the arena. Client only *requests* fighter/style; server
  validates against unlocks and snapshots into the match (persisted as style1/2 + fighter1/2_model by OpenMatch).

## 9. Progression (`palm6_fc_progression`) + anti-farm

- On server-internal `fc:match:resolved`: atomically claim `UPDATE matches SET rep_awarded=1 WHERE id=? AND
  rep_awarded=0` (affected==1 gates) → credit winner rep (+ optional small loser consolation), update
  wins/losses/rank. Rep claim-before-credit can **strand (never double-pay)** one award on a crash in the
  claim→credit window (matching the settleMatch honesty note); not a mint.
- Boot reconcile: `status='resolved' AND rep_awarded=0` matches created post-deploy are re-driven idempotently.
  **Delayed until dbmigrate has created the tables** (mirror fightclub's `Wait(8000)` or the corrected ensure
  order, §3/§11) — else a fresh boot reconciles nothing and strands first-boot rep.
- **Anti-farm (the server has a farmable-stat→cash history, so this is mandatory):**
  (a) rep is **display/rank only in MVP — it pays NO cash and unlocks only cosmetic/name items** (real because
  styles are stat-identical, §8), severing farm→money.
  (b) **no rep for a win vs an opponent already beaten within `Config.RepCooldownSec` — AND this same-opponent
  gate applies to the loser consolation too** (v2's cooldown was win-only, so dive-farming an alt still paid the
  loser every KO). Or drop loser-consolation from MVP.
  (c) no rep on `forfeit`/`draw`/`void`.
  (d) **daily rep cap + a distinct-opponents-per-day cap** so an N-alt rotation is bounded independent of the
  per-pair cooldown.
- **Concrete anti-farm numbers (were unspecified):** `RepCooldownSec = 3600` (1h per pairing),
  `DailyRepCap = 5` wins' worth of rep/day, `DailyDistinctOpponentCap = 4`. Tune in feel-test.
- **Match-fixing / collusion honesty (reworded — v2 overstated the bound):** parimutuel makes a **closed-ring**
  fix strictly **-EV** (colluders just return their own stakes minus rake → safe). The **residual** risk is
  fixers scooping *honest* bettors who backed the fixed loser — capped **per-bettor** by `MaxBet` but **not in
  aggregate**. If that residual matters, add a per-match total-pool cap or a max winning-side payout multiple
  (not just per-bettor MaxBet). Fighters consent + can't bet on their own match (existing guard).
- Exports: `GetRep/GetRank/HasUnlock`.

## 10. Betting (`palm6_fightclub`, rewired — money path unchanged)

Betting keeps its battle-tested recoverable payout (`settleMatch`/`reconcileUnsettled`/`claimBet`/`purse_paid`/
`settled`). Changes: (1) matches are opened by combat's `OpenMatch` (challenge-driven), not the queue; (2) the
BETTING window is a lifecycle state (§5) — `/fcbet` is open only while `status='betting'`, and **closes exactly
at the `GoLive` flip** (leaving `betting` closes the atomic-insert window automatically); (3) resolution comes
only from combat's `ResolveMatch`/`VoidMatch` — `settleMatch` already maps winnerCid→slot via
fighter1/2_citizenid, so no slot is transmitted; (4) the old `sweepLiveMatches`/`checkFighter` self-resolver AND
`sweepBettingToLive` are **removed** — combat now owns the betting→live flip (`GoLive`) and all DC resolution.
Bet refunds on pre-fight void / draw / forfeit-pre-LIVE all route through **`VoidMatch` → settleMatch draw
branch** (§5). `OpenMatch` must set every column `createMatch` set (fighter1/2_name, status, betting_ends_at,
purse_paid default) or the payout/board paths break.

## 10a. Purse funding — entry-stake ante (fixes "a no-bet fight pays the winner nothing")

**Problem the review surfaced:** `settleMatch` computes `purse = floor(totalPool * WinnerPursePct)` where
`totalPool` is the sum of **bets** (main.lua:379-387). The modal challenge-driven fight has **no spectators
betting in a 60s window**, so `totalPool = 0 → purse $0`, and cash-neutral rep pays nothing — the whole
"KO for a purse" loop collapses for the common case, with no fighter stake and no house purse.

**Resolution (money-safe, no mint):** each fighter **antes `Config.EntryStake` at ACCEPTED**, charged
consume-before-grant into the match's `entry_pot` escrow (recoverable: reconciled/refunded exactly like a bet).
The **winner takes the `entry_pot` (minus `RakePct`) as the base purse**, ON TOP of the parimutuel spectator
layer. This is **zero-sum between the two fighters** (no minted money), gives every fight real stakes even with
zero spectators, and makes the loss sting.
- `VoidMatch` / draw refunds `entry_pot` to both fighters (fight never happened / tie).
- `Config.EntryStake` default **$500** (David-tunable; **set to 0** to make MVP fights for-rep-only — the one
  economic knob that must be chosen before implementation planning).
- The entry-stake charge/refund/payout reuses the existing recoverable-payout discipline (charge-before-grant,
  `purse_paid`-style claim flag, boot reconcile) — no new money-safety pattern, just a second escrow column.

## 11. Restart-safety & teardown

- **Canonical teardown** (one function, called on KO, finisher-end, forfeit, void, DC, error, resource-stop):
  **abort any in-progress synchronized scene (stop the per-frame task, clear the scene handle) FIRST**, then
  unfreeze peds, `SetPedCanRagdoll` restore, invincibility off, pain flags restore, re-enable melee, release
  script cam, `SetTimeScale(1.0)`, close NUI HUD, **reapply real appearance via the appearance resource**,
  restore holstered loadout, clear per-match client state + the `inFinisher` flag.
- **fc_combat restart mid-match:** HP/momentum are in-memory and lost. On boot, any `palm6_fightclub_matches`
  row still `betting` **or** `live` is no-contested: a `betting` row via `VoidMatch` (draw-refund + entry-stake
  return), a `live` row via `VoidMatch`-equivalent (`UPDATE ... status='resolved',winner=NULL,method='void',
  settled=0 WHERE id=? AND status='live'` → settleMatch draw). Bets refunded, entry stakes returned, no purse on
  a no-contest, and connected clients receive a **boot "abort any fight" teardown broadcast** so no one is
  stranded invincible/frozen. **This boot no-contest must run BEFORE any new challenge is accepted** (or block
  challenges until it completes) so a restart can't re-pair a cid whose old row hasn't cleared. This is the
  honest restart story (v1/v2's "restart-safe" claim only holds with this path, which now actually reaches
  `betting` rows).

## 12. Arena, spectators, audio, performance

- **Arena:** ox_lib zone for ring bounds + spectator gallery; server owns the authoritative at-ring coords
  check (`atRing()`); crowd = cheap **local non-networked** peds (`CreatePed` client-side,
  `WORLD_HUMAN_CHEERING` scenarios, distance-culled, `Config.MaxCrowd`-capped, spawned only while LIVE).
- **Fight-mark placement (§K):** at COUNTDOWN the server sets both peds to **opposing fight marks facing each
  other** (a fixed offset around the ring center) — without this, two fighters who accepted from opposite edges
  of the 15m ring can't reach each other's `move.reach` and the finisher origin is undefined.
- **Spectators:** anyone in the arena zone; they see the fight + the finisher (replicated) and can `/fcbet`
  during BETTING. **A match entering BETTING broadcasts** (arena-zone or server-wide) matchId + fighters +
  `/fcbet` syntax — without it the 60s window + challenge-driven opens starve the betting economy. Non-
  participants are soft-repelled from the ring interior during LIVE.
- **Audio (the #1 driver of Def Jam feel — MVP includes a minimum):** crowd bed + reaction stings, per-hit SFX,
  a Blazin charge/ready cue, a finisher hit-stinger. **Mechanism decided:** native `PlaySoundFrontend` sets for
  MVP (zero shipped assets), OR a sound resource (xsound/interact-sound) + **CC0/original** clips with provenance
  notes. **The IP line is reworded to "zero *copyrighted* assets"** (not "zero custom assets") so provenance-
  clean audio is allowed. Announcer/licensed-music deferred.
- **Performance budget:** the LIVE combat tick + ring poll run only for the ≤2 active fighters; crowd peds are
  local, capped, distance-culled, LIVE-only; statebag HUD updates are **coalesced/throttled** (send on change,
  ≤ N/sec) not per-frame; spectator clients render-only. Target: no measurable server tick cost when idle,
  bounded during a fight.

## 13. Cross-cutting rules (palm6 discipline)

Money-safety (charge-before-grant; atomic claim-before-credit; boot reconcile) across bets AND the entry-stake
escrow. **Eventguard — combat needs a different model than money events (CONFIRMED conflict):** palm6_eventguard's
3-strike **session-cumulative kick** is hostile to high-frequency combat, and the finisher `fc:combat:break`
mash would trip it immediately. Resolve one of two ways in Phase 0: (a) **exempt `fc:combat:break` (and
strike/connect/block) from eventguard and gate them in-resource** (per-match server counter, **ignore-not-kick**,
tied to the server move cooldown), OR (b) extend eventguard with a **non-kicking "combat class" budget
(drop-only, no session kick)**. Do NOT ship combat events under the existing kick-at-3 model. eventguard still
ensures **before** the fc resources (custom.cfg order). Server-authoritative throughout (HP, winner, price, rep,
proximity all server-owned). Statebag HUD sync = targeted replication to the two fighters + spectators, throttled.
Bridge pattern + RFC-001 metadata + `palm6_<domain>` naming.

## 14. Testing / verification

- Per-resource `luaparse` on every `.lua`; boot-verify on a local FXServer (0 SCRIPT ERROR). **Note the base
  fightclub tables must be registered in dbmigrate (§4) or the local/fresh-DB boot-verify fails on the ALTERs.**
- **Stub mode must expose non-combat OPEN *and* ADVANCE (CONFIRMED gap — v2's stub only fired RESOLVE):** the
  removed `/fcjoin` was the ONLY non-combat match creator, so without new debug commands there is no way to get
  a row into `betting` (to test `/fcbet`) or into a resolvable `live` state before combat exists. Add
  **ace-gated** dev commands: `/fcdebug open <cidA> <cidB>`, `/fcdebug live <matchId>` (GoLive),
  `/fcdebug resolve <matchId> <winner>`, `/fcdebug void <matchId>`. **Ace-gate via an explicit in-handler
  `IsPlayerAceAllowed(src,'palm6_fc.debug')`** (Bridge.RegisterCommand hardcodes `restricted=false`, so it
  cannot gate on its own — an open command here is a rep/purse mint). This makes progression/betting/arena/HUD
  testable before real combat.
- Combat itself validated by two test clients (or one + a spawned bot) exercising challenge/select/strike/
  connect/block/KO/finisher/DC at each state, **plus a non-participant-interference test** (§6) and a
  **ring-out test** (§6 confinement drops invincibility).
- Money-safety regression: no double-resolve, no stranded bets/entry-stakes on DC/restart/void, rep gated +
  anti-farm caps enforced, `betting`-row void actually refunds.
- David feel-tests in-game before "done" (the standing rule).

## 15. Deploy / rollout (cutting over a LIVE resource)

`palm6_fightclub` is live in prod. **Config.Enabled semantics (v2 was contradictory — "disabled" = dead
feature):** ship combat's challenge+SELECT+OpenMatch+GoLive+countdown half **WITH** (not after) the fightclub
rewrite — otherwise "rewired behind Config.Enabled" leaves prod fightclub fully inert (no `/fcjoin`, no
OpenMatch caller → the live betting feature is dead, not toggled). Define `Enabled=false` precisely: **no new
matches open, betting frozen, existing settlement still reconciles**, AND a flip to false mid-match fires the
§11 no-contest abort/teardown broadcast. (Optionally keep the old `/fcjoin` queue path alive behind the same
flag as a genuine fallback until the new path is proven, then remove it.) Migrations additive/idempotent; deploy
during low pop; announce that `/fcjoin` is gone; verify prod boot + a live test match + a settled bet + an
entry-stake payout before "shipped". Follow the palm6 deploy path (push → CI → prod-verify info.json + DB).

## 16. Risks & mitigations
1. **IP/legal (existential)** → original brand + house/player-created roster + provenance manifest. (Decided.)
2. **Synced-scene desync** → per-client OWN-ped scene (§7) + freeze + shared start-time; accept small phase
   drift; prototype on base-game takedown clips first.
3. **No true server hit-detection** → server move clock + owned HP/stamina/momentum + validated events; rep/money
   gated on the atomic claim, never fight telemetry.
4. **Double-resolve / two resolvers** → old self-resolver removed; single atomic `live→resolved` claim; DC beats
   finisher-end deterministically.
5. **Money strand on betting-state void / restart** → `VoidMatch` reaches `betting` rows (the v2 gap); boot
   no-contest before accepting challenges; entry-stake escrow reconciled.
6. **Godmode-on-demand (invincible fighter leaves ring)** → server ring-confinement poll drops invincibility on
   exit (§6).
7. **rep→power farm** → styles are stat-identical + free-select; rep unlocks cosmetics only (§8/§9).
8. **Scope (XL)** → seam-gated loop + stub OPEN/ADVANCE first, then striking, defer grapples/mocap/creator.

## 17. MVP acceptance criteria

Two players challenge at the ring (server-verified proximity) → **each picks a fighter/style** → **both ante an
entry stake** → betting window (60s, broadcast so spectators can wager) → real striking (light/heavy/block,
server move clock with the §6a numbers, server-owned HP/stamina) → a Blazin meter that fills and triggers **one**
cinematic finisher rendered per-client on each owner's own ped (fair mash-to-reduce window) → server-side
KO/resolution → **purse (entry pot + parimutuel) settles off the resolver**, winner gains **cash-neutral** rep
(anti-farm capped) and can rank up. ≥4 original house fighters across ≥3 **stat-identical** styles. Crowd +
spectator cam + HUD + minimum (provenance-clean) audio present. **DC/void/restart never strand a player, a bet,
or an entry stake.** Zero *copyrighted* assets shipped. luaparse-clean; boot-verified (base tables registered in
dbmigrate); David feel-tests before ship.

## 18. Phasing beyond MVP (context)
Next: build-your-own-fighter + custom original models. Then: grapple/throw + environmental finishers (custom
synced scenes + mocap). Then: reversals/counters, full unlock tree, gear, seasons/ladder, multiple rings
(schema already ring-ready via a `ring_id` column).

## Appendix — open decision for David before writing-plans
- **`Config.EntryStake`** (§10a): default **$500** (fights have real stakes even with no spectators) vs **$0**
  (MVP fights are for-rep + bragging only, spectator purse is the sole money layer). Everything else in this
  spec is resolved; this is the one economic knob that changes the loop's feel.
