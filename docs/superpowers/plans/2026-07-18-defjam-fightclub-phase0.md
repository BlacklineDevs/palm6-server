# Def Jam Fight Club — Phase 0 (PvP MVP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the PvP MVP of the Def Jam-style fight club — challenge at the ring → sportsbook betting window → server-driven striking with a Blazin finisher → KO → purse (entry ante + parimutuel) settles and the winner gains cash-neutral rep — across the `palm6_fc_*` resources plus a rewired `palm6_fightclub`, all behind `Config.Enabled`, money-safe and farm-safe per the v4 spec (`docs/superpowers/specs/2026-07-18-defjam-fightclub-design.md`).

**Architecture:** Server owns all authority (HP/stamina/momentum/winner/money/proximity are server script vars; a single atomic `live→resolved` resolver; a server-internal `fc:match:resolved` seam). The existing `palm6_fightclub` recoverable payout is reused (charge-before-grant, claim-before-credit, boot reconcile) and extended with an entry-stake ante; combat drives it via `OpenMatch/GoLive/ResolveMatch/VoidMatch` exports. `palm6_fc_core` (shared_scripts) is the single data source both server and client read. The finisher renders per-client on each owner's own ped. Betting is parimutuel (zero house liability) with a client-side sportsbook odds display. Solo/story PvE (spec §19) is a LATER plan — only its dark columns/gates land here.

**Tech Stack:** FiveM/Qbox Lua 5.4, oxmysql (`MySQL.*`), ox_lib (zones/menus), ox_target (challenge interaction), NUI (html/js for the HUD), the palm6 bridge pattern (`bridge/sv_framework.lua` + `bridge/cl_game.lua`), `palm6_dbmigrate` (idempotent inline migrations), `palm6_eventguard` (net-event budgets). Verification: `npx luaparse`, local FXServer boot-verify, ace-gated `/fcdebug` stub commands, David in-game feel-test.

## Global Constraints

# Plan-Wide GLOBAL CONSTRAINTS (every task preserves these at every step)

## Naming & structure
- `palm6_<domain>` naming throughout. New resources: `palm6_fc_core`, `palm6_fc_combat`, `palm6_fc_hud`, `palm6_fc_arena`, `palm6_fc_progression`. `palm6_fightclub` is REWIRED in place (live prod resource).
- Bridge pattern preserved: server logic calls `Bridge.*` only (`bridge/sv_framework.lua`), client logic calls `Game.*` only (`bridge/cl_game.lua`). All framework/native access stays in the bridge files (GTA VI portability). RFC-001 metadata (`fx_version 'cerulean'`, `game 'gta5'`, `lua54 'yes'`, author/version/description) on every fxmanifest.
- `palm6_fc_core` ships as **`shared_scripts`** (server move-clock validator AND client combat/HUD both read `GetMove/GetStyle/StateKeys/Config`) — do NOT fork it server-only.

## The real Bridge.* API (do NOT invent signatures — grounded in sv_framework.lua)
`Bridge.GetCitizenId(src)→cid|nil` · `Bridge.GetPlayerName(src)→string` · `Bridge.Notify(src,title,msg,type)` · `Bridge.Reply(src,lines[])` · `Bridge.ChargeBank(src,amount,reason)→bool` (charge-before-grant; checks bank balance) · `Bridge.CreditBankByCitizenId(cid,amount,reason)→bool` (online AND offline via `UPDATE players ... JSON_SET`) · `Bridge.GetSourceByCitizenId(cid)→src|nil` · `Bridge.GetCoords(src)→{x,y,z}|nil` · `Bridge.Distance(a,b)→number` · `Bridge.GetHealth(src)` · `Bridge.GetCurrentWeaponHash(src)` · `Bridge.UnarmedHash()` · `Bridge.ResourceStarted(name)→bool` · `Bridge.RegisterCommand(name,handler)` **hardcodes `restricted=false`** (so /fcdebug MUST self-gate with `IsPlayerAceAllowed(src,'palm6_fc.debug')`, never rely on Bridge.RegisterCommand to gate). Server-internal `atRing(src)` (main.lua:48) and `rl(src,key)` rate-limit (main.lua:39, keyed off `Config.RateLimits`) reused for proximity/spam.

## Money-safety invariants (NEVER violated — this server has a farmable-stat→cash history)
- **Charge-before-grant** (`Bridge.ChargeBank` FIRST, then INSERT; the /fcbet main.lua:224-232 discipline). **Claim-before-credit**: flip an idempotency flag 0→1 in a guarded UPDATE (affected==1) BEFORE the bank credit (`claimBet`/`purse_paid`/`entry_paid1`/`entry_paid2`/`rep_awarded`). A crash between claim and credit STRANDS one payout (self-inflicted, bounded) — it NEVER double-pays and NEVER mints.
- **The entry-pot settle block runs BEFORE `markSettled(matchId)`** in BOTH winner and draw branches (a block after markSettled would strand on crash — `reconcileUnsettled WHERE settled=0` would never re-drive it). `markSettled` stays the single final statement of each branch.
- **Winner entry cut is the RESIDUAL:** `winnerCut = entry_pot - entryRake - loserCut` (NEVER `entry_pot - entryRake` independent of loserCut — that mints when consolation is enabled). `entry_pot` is stored on the row and read back at settle, NEVER recomputed from live config. Conservation: `winnerCut+loserCut+entryRake == entry_pot` by construction; floor rounding only ever leaves money UNPAID (extra sink).
- **OpenMatch INSERT-fail refunds BOTH antes** (caller charges A then B; B-fail refunds A and aborts with no row; INSERT-fail-after-both-charges refunds both via `CreditBankByCitizenId`). OpenMatch returns nil/0 on INSERT failure so the caller unwinds.
- **EntryStake=0 guard:** `if EntryStake > 0 then ChargeBank(...) end`; entry_pot=0 → WIN/DRAW blocks no-op.
- **Boot reconcile** re-drives interrupted payouts idempotently (`WHERE status='resolved' AND settled=0` for fightclub; `WHERE status='resolved' AND rep_awarded=0 AND is_pve=0` for progression), delayed until dbmigrate ran.
- **Parimutuel only** — zero house liability (`out ≤ in`; `forBettors = max(0, pool - rake - purse)`). No fixed-odds, no house seed. The "sportsbook" is a CLIENT-DISPLAY layer that changes zero money math.
- **Betting-state void actually refunds:** `VoidMatch` reaches `betting` rows (`WHERE status='betting'`); the live no-contest uses the `WHERE status='live'` primitive (`LiveVoidMatch`) — never VoidMatch on a live row (no-ops → deadlock).
- **Pre-LIVE forfeit/DC voids-and-refunds** (never pays a winner for a fight that did not happen); only a forfeit once `status='live'` AND `roundStarted` pays the opponent.
- **DC ALWAYS beats finisher-end** (playerDropped sets `resolving` and short-circuits the finisher resolve). Resolution idempotent via the atomic `WHERE status='live'` (affected==1) — only the first caller resolves.
- **Reserved `'__'` prefix:** progression rep-credit and the bank helpers reject any cid with the `'__'` prefix; the PvE CPU sentinel is `'__CPU__:'..matchId`.

## Anti-farm / rep (money-neutral)
- `Config.RepPerPvpWin = 100` — single source of truth; §19 PvE bases are FRACTIONS of it. `Config.Fight.EntryStake = 500` (RESOLVED). Rep pays NO cash in MVP (unlocks cosmetic/name only), real because the 3 styles are STAT-IDENTICAL (§6a shared move table) and free-select.
- No rep on forfeit/draw/void; same-opponent `RepCooldownSec` gate on win AND loser-consolation; shared `palm6_fc_daily` rolling-24h `DailyRepCap=5`/`DailyDistinctOpponentCap=4`, increment-before-credit; `AND is_pve=0` on the §9 rep claim (a CPU win must not mint ~100 PvP rep).

## Gating / rollout
- Ships behind `Config.Enabled` (fc_core), prod-inert until proven. Combat's challenge+SELECT+OpenMatch+GoLive+countdown ship WITH the fightclub rewire (not after) so prod isn't left inert. `Enabled=false` = no new matches open, betting frozen, settlement still reconciles; a mid-match flip to false fires the §11 no-contest teardown broadcast.
- `/fcdebug` is ace-gated (`IsPlayerAceAllowed(src,'palm6_fc.debug')`), NOT Bridge.RegisterCommand-gated.

## Load order / migrations
- custom.cfg ensure order: `palm6_eventguard` → `palm6_dbmigrate` → `palm6_fc_core` → `palm6_fightclub` → `palm6_fc_combat` → `palm6_fc_hud`/`palm6_fc_arena` → `palm6_fc_progression`. `palm6_dbmigrate` MUST move ahead of every fc_* resource (currently at :208, after fightclub :108) — AND progression keeps a boot-delay-until-migrated guard. eventguard ensures BEFORE the fc resources (handler-chain registration order).
- All new DB statements idempotent (`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` / `INSERT IGNORE`) and registered in `palm6_dbmigrate` STATEMENTS (base `palm6_fightclub_matches`/`_bets` CREATEs registered too, ORDERED BEFORE the ALTERs — an ALTER before its CREATE fails on a fresh DB; dbmigrate has no ledger → re-runs every stmt every boot). `method` is VARCHAR(16) not ENUM (out-of-range ENUM write throws under strict SQL mode → pcall-swallowed strand). `rep_awarded TINYINT NOT NULL DEFAULT 1` (backfills history as awarded; resolver sets it 0 at the live→resolved flip). `entry_pot INT NOT NULL DEFAULT 0`.

## Eventguard combat class
- Combat events (`palm6_fc_combat:strike/connect/block/break`) use a **drop-not-kick combat-class budget** (never the existing kick-at-3 session-cumulative model — the finisher mash would trip it). eventguard still ensures before the fc resources.

## Testing gates (FiveM reality — no pytest/vitest)
- (1) `npx luaparse <file>` clean on EVERY .lua touched; (2) boot-verify on local FXServer (0 SCRIPT ERROR, resource loads — base tables must be registered in dbmigrate or the ALTERs fail on a fresh DB); (3) exercise ace-gated `/fcdebug open/live/resolve/void` to drive betting/progression/HUD before real combat; (4) David's in-game feel-test (the standing rule — plan notes WHAT to feel-test, does not automate). Money-safety verify = no double-resolve, no stranded bets/entry-stakes on DC/restart/void, rep gated + anti-farm caps enforced, betting-row void actually refunds.
- Bite-sized steps (2-5 min): write-the-change → luaparse → (boot/stub exercise) → commit. Frequent commits. COMPLETE real Lua in every code step — no "TODO"/placeholder/"similar to Task N".
- The seam `fc:match:resolved` is a server-side `TriggerEvent`, NEVER `RegisterNetEvent` (a modified client cannot fire it). `matchId` is the integer `palm6_fightclub_matches.id` (one namespace).

---

## Plan Review Corrections (AUTHORITATIVE — apply these; they OVERRIDE the task text below)

A 3-lens adversarial review (build-order / spec-coverage / money-safety+placeholders) of this plan found 13
cross-task defects (deduped to 8 corrections). **When a task's body conflicts with a correction here, the
correction wins.** The money-safety invariants in Global Constraints were all preserved by the draft; these are
integration-seam fixes.

- **C1 (CRITICAL — Task 7, KO & ring-out).** T7's connect-KO branch (Step 5) and ring-out poll (Step 6) call
  `exports.palm6_fightclub:ResolveMatch(...)` **directly**, bypassing T6's `resolveFight()` hub — the ONLY path
  that sends `palm6_fc_combat:teardown` to both fighters (restores appearance/model/loadout) and clears
  `matches[]`/`activeByCid`/`activeBySrc`. As drafted, after every KO/ring-out the **winner is left stuck in the
  fighter ped** (violates §8/§11). **Fix:** both paths call the in-file `resolveFight(matchId, winnerCid, method)`
  — KO: `resolveFight(matchId, attCid, 'ko')`; ring-out: `resolveFight(matchId, oppCid, 'forfeit')`. **Remove the
  premature `st.resolving = true`** first (resolveFight guards on and sets `m.resolving` itself; pre-setting makes
  it early-return and no-op). T8's finisher-KO already uses `resolveFight` — match it.

- **C2 (CRITICAL — Task 8, finisher state model).** T8 was authored against file-locals `fightHp` / `fightMom` /
  `writeMatchState` that **T7 never defines** — T7's real state is `Combat[ckey(matchId,cid)]` with fields
  `.hp/.stam/.blazin`, flushed via `flush(matchId)` gated by `Dirty[matchId]`. As drafted T8 throws at runtime (nil
  global) or silently mutates a phantom HP the KO check never reads. **Fix — rewrite T8's server against T7's real
  symbols:** meter/momentum = `Combat[ckey(m,cid)].blazin`; HP = `Combat[ckey(m,cid)].hp`; `Fin.tryTrigger` reads
  `Combat[ckey(m,attCid)].blazin >= FinCfg.Blazin.FullThreshold`; `Fin.start` spends via
  `Combat[ckey(m,attCid)].blazin = 0`; `Fin.applyDamage` mutates `Combat[dk].hp` then sets `Dirty[matchId]=true`
  (or `flush(matchId)`), and on `hp<=0` calls `resolveFight(matchId, attCid, 'finisher')`. **Step 6 anchor:**
  insert `Fin.tryTrigger(matchId, attCid, tgtCid, move.moveId)` immediately after T7's
  `att.blazin = math.min(cap, att.blazin + MOM.PerLandedHit)` line in the connect handler (before `att.active` is
  cleared), using T7's real locals. Delete the "grep and adapt if spelled differently" hedge. T8's "Consumes"
  interface block = `Combat[key].hp/.blazin`, `flush(matchId)`, `Dirty[matchId]`, `resolveFight`, `matches[matchId]`.

- **C3 (HIGH — Task 4, RateLimits Edit).** Task 3 Step 1 already deletes `fcjoin`/`fcleave` from
  `Config.RateLimits`, so T4 Step 4's Edit (old_string still containing `fcjoin=3, fcleave=2`) **won't match after
  T3 lands**. **Fix:** T4 Step 4 edits the POST-T3 block — old_string `Config.RateLimits = {\n    fcbet = 2,\n
  fcmatches = 2,\n    -- fcjoin/fcleave removed (queue deleted)\n}`, new_string adds `    fcdebug = 1,` inside it.
  Do NOT re-add fcjoin/fcleave; delete the "leave fcjoin/fcleave in place" note.

- **C4 (MEDIUM — Task 6, sportsbook closing line / 2s tote board — spec §10b unimplemented).** No task runs the
  recurring `OddsBroadcastSec` (2s) broadcast or the CLOSED flip at GoLive (T3 only broadcasts on each `/fcbet`).
  **Fix:** in T6, `startBettingTimer` loops `exports.palm6_fightclub:BroadcastOdds(matchId)` every
  `fcCore().Betting.OddsBroadcastSec` seconds (guard match still `betting`) until `betting_ends_at`, then calls
  `goLiveAndCountdown(matchId)`, then calls `BroadcastOdds(matchId)` ONCE MORE after the flip so T9's board gets a
  final `oddsUpdate` (status `live`, `secsLeft=0`) and shows "CLOSED — closing line".

- **C5 (MEDIUM — Task 3, money-mirror drift assert).** T1 defers a hard invariant to T3 (fc_core's mirrored
  `WinnerPursePct`/`Betting.RakePct` MUST equal fightclub's real `Config.Fight.WinnerPursePct`/
  `Config.Betting.RakePct` — the HUD quotes odds off the mirror, settlement pays off fightclub's values), but T3
  never implements it. **Fix:** add to T3's delayed `onResourceStart` boot (pcall-guarded so a not-yet-started
  fc_core degrades to a warning): `local core = exports.palm6_fc_core:Config(); assert(math.abs(core.WinnerPursePct
  - Config.Fight.WinnerPursePct) < 1e-9 and math.abs(core.Betting.RakePct - Config.Betting.RakePct) < 1e-9,
  '[palm6_fightclub] money-mirror drift')`.

- **C6 (MEDIUM — Task 7, finisher-KO ragdoll).** T7's `Game.RagdollSelf()` never unfreezes, but T8's finisher
  freezes the victim ped, so a finisher-KO `koRagdoll` no-ops (no ragdoll). **Fix:** add
  `FreezeEntityPosition(PlayerPedId(), false)` as the FIRST line of T7's `Game.RagdollSelf()` (before
  `SetPedToRagdoll`) — fixes both plain-KO and finisher-KO.

- **C7 (LOW — Task 6 / Task 10, duplicate squareUp).** Both T6's `goLiveAndCountdown` and T10's `fc:match:countdown`
  handler emit `palm6_fc_arena:squareUp` → double teleport. **Fix:** T10 owns the mark geometry + emission; remove
  the squareUp send + `getFightMarks()` fallback from T6 and let T6 only fire the `fc:match:countdown` seam.

- **C8 (LOW — Task 6 / Task 7, dead seam + dead handler).** T6 fires `fc:combat:live` but T7 never consumes it
  (uses a 1s DB poll → ~1s dead-zone at "FIGHT!"), and T6 Step 8 ships a no-op duplicate `playerDropped` handler.
  **Fix:** in T7 add `AddEventHandler('fc:combat:live', function(d) if type(d)=='table' and tonumber(d.matchId)
  then startRound(tonumber(d.matchId)) end end)` (keep the 1s poll as a boot/reconnect backstop); remove the
  trailing no-op `AddEventHandler('playerDropped', function() end)` from T6 Step 8.

---

### Task 1: palm6_fc_core — shared data + constants (prod-inert)

Creates the new **`resources/[custom]/palm6_fc_core/`** resource: a `shared_scripts`-only, zero-behavior data module that every other fc resource reads through `exports.palm6_fc_core:*`. It is the COMBAT + CLIENT-DISPLAY authority (the money authority stays `palm6_fightclub/shared/config.lua`). No dependencies, no events, no threads, no DB — it is the root of the Phase-0 dependency graph and therefore Task 1. All money/combat downstream tasks consume its exports.

**Files:**
- CREATE `resources/[custom]/palm6_fc_core/fxmanifest.lua`
- CREATE `resources/[custom]/palm6_fc_core/config.lua`
- CREATE `resources/[custom]/palm6_fc_core/data.lua`
- CREATE `resources/[custom]/palm6_fc_core/exports.lua`
- (throwaway, NOT committed) `scratch/fc_core_stub.lua` for the optional offline exercise

**Interfaces:**
- **Consumes:** nothing (root task, zero deps).
- **Produces** (exact export surface — every downstream author binds to these names/shapes; both realms, since `shared_scripts` runs in server AND client VMs):
  - `exports.palm6_fc_core:Config()` → the full `Config` table (returns the live table, not a copy).
  - `exports.palm6_fc_core:GetFighter(fighterId)` → `{ id, name, model, styleId, unlockId? }` or `nil`.
  - `exports.palm6_fc_core:GetStyle(styleId)` → `{ id, name, movementClipset, animDicts={ strike, block, hitreact, finisher } }` or `nil`.
  - `exports.palm6_fc_core:GetMove(moveId)` → `{ moveId, kind, damage, staminaCost, cooldownMs, activeWindowMs, reach, chipPct, blockStamCost }` or `nil`.
  - `exports.palm6_fc_core:StateKeys()` → `{ MATCH_PREFIX='fc:match:', PLAYER_ACTIVE='fc:active', PLAYER_SLOT='fc:slot', matchKey=function(matchId) return 'fc:match:'..matchId end }`.
  - **Documented (not written here):** the statebag shape `GlobalState['fc:match:'..matchId] = { status, roundStarted, slot={ [1]={hp,stam,blazin,name,model},[2]={...} } }` and `Player(src).state['fc:active']` / `['fc:slot']` — T7 writes, T9 reads.
  - **Cross-resource invariant (documented, cross-asserted in T3 not here):** `Config.WinnerPursePct` (0.15) and `Config.Betting.RakePct` (0.10) MUST equal `palm6_fightclub/shared/config.lua`'s `Config.Fight.WinnerPursePct` / `Config.Betting.RakePct`. fc_core cannot read fightclub's isolated Lua state at its own boot, so the equality assert lives in T3's fightclub boot (which can call `exports.palm6_fc_core:Config()`).

- [ ] **Step 1: Write `fxmanifest.lua` (RFC-001 header + shared_scripts only, no client/server split, no deps).**
  Create `resources/[custom]/palm6_fc_core/fxmanifest.lua`:
  ```lua
  fx_version 'cerulean'
  game 'gta5'
  lua54 'yes'

  author 'EvThatGuy'
  version '0.1.0'
  description 'palm6 fc_core — shared Def Jam fight-club data + constants (no behavior)'

  -- shared_scripts (NOT server-only): the server move-clock validator AND the
  -- client combat/HUD both read GetMove/GetStyle/StateKeys/Config, so this single
  -- source of truth loads in BOTH realms. Data only — zero events, threads, DB.
  shared_scripts {
      'config.lua',
      'data.lua',
      'exports.lua',
  }
  ```
  (No `dependencies` block: fc_core depends on nothing; other resources depend on IT.)

- [ ] **Step 2: Write `config.lua` (the full §6a/§10b/§19.3 Config table — scalars + move/timer/rep/blazin/pve tables).**
  Create `resources/[custom]/palm6_fc_core/config.lua`:
  ```lua
  -- ============================================================================
  -- palm6_fc_core/config.lua — Def Jam fight-club SHARED data + constants.
  -- COMBAT + CLIENT-DISPLAY authority (MONEY authority = palm6_fightclub/
  -- shared/config.lua). Reached ONLY via exports.palm6_fc_core:Config() — never
  -- a bare `Config` global from another resource (each resource = isolated Lua
  -- state). DATA ONLY: zero behavior/events/threads. Loads in BOTH realms.
  -- ============================================================================
  Config = {}

  -- HARD prod gate. Every fc resource checks exports.palm6_fc_core:Config().Enabled
  -- before opening a match / running combat. Ships false = prod-inert.
  Config.Enabled = false

  -- Canonical ring (combat/arena read THIS; palm6_fightclub keeps its own
  -- Config.Ring for atRing()). Coords retuned 2026-07-10 — VERIFY IN-GAME
  -- (on-ground / reachable) before the combat feel-test (T6/T10 gate).
  Config.Ring = {
      coords = { x = 108.0, y = -1305.0, z = 29.19 },  -- Vanilla Unicorn back lot, Strawberry
      radius = 15.0,
      label  = 'the fight ring (Vanilla Unicorn back lot)',
  }

  -- Fighter vitals (§6a). Server-owned per match; NEVER ped health.
  Config.Vitals = {
      StartHP             = 100,
      MaxStamina          = 100,
      StaminaRegenPerSec  = 12,
      BlazinFullThreshold = 100,
  }

  -- Momentum gain (both fighters gain — the Def Jam feel).
  Config.Momentum = {
      PerLandedHit = 12,
      PerTakenHit  = 6,
  }

  -- Move table (§6a) keyed by moveId. MVP ships all styles STAT-IDENTICAL —
  -- styles differ only in clipset/anim feel (§8), so rep stays cash-neutral (§9).
  Config.Moves = {
      jab      = { moveId = 'jab',      kind = 'light', damage = 6,  staminaCost = 4,  cooldownMs = 450,  activeWindowMs = 350, reach = 1.6, chipPct = 0.15, blockStamCost = 8  },
      cross    = { moveId = 'cross',    kind = 'light', damage = 9,  staminaCost = 7,  cooldownMs = 650,  activeWindowMs = 400, reach = 1.6, chipPct = 0.15, blockStamCost = 10 },
      hook     = { moveId = 'hook',     kind = 'heavy', damage = 15, staminaCost = 14, cooldownMs = 1100, activeWindowMs = 450, reach = 1.4, chipPct = 0.20, blockStamCost = 16 },
      uppercut = { moveId = 'uppercut', kind = 'heavy', damage = 18, staminaCost = 18, cooldownMs = 1300, activeWindowMs = 450, reach = 1.3, chipPct = 0.20, blockStamCost = 20 },
      body     = { moveId = 'body',     kind = 'heavy', damage = 13, staminaCost = 12, cooldownMs = 1000, activeWindowMs = 450, reach = 1.4, chipPct = 0.10, blockStamCost = 14 },
  }

  -- Lifecycle timers (§6a). Seconds unless the name says Ms.
  Config.Timers = {
      ChallengeTTL = 20,
      BetWindowSec = 60,
      RoundSec     = 180,
      DrawBand     = 5,     -- HP% band → timeout draw
      RingPollSec  = 0.5,   -- ring-confinement poll cadence
      CountdownSec = 3,
  }

  -- Rep anchor (§6a) — single source of truth; §19.5 PvE fracs are RELATIVE to this.
  Config.RepPerPvpWin = 100

  -- Anti-farm knobs (§9).
  Config.Rep = {
      RepCooldownSec           = 3600,  -- 1h per pairing (applies to win AND consolation)
      DailyRepCap              = 5,     -- wins' worth of rep / rolling 24h (shared with PvE)
      DailyDistinctOpponentCap = 4,
      LoserConsolation         = 0,     -- MVP off
  }

  -- Blazin finisher (§7).
  Config.Blazin = {
      FullThreshold      = 100,
      HeavyQualifies     = true,
      MashReducePerHit   = 0.06,
      SceneDurationMs    = 3000,
      BaseFinisherDamage = 60,
  }

  -- Fallbacks when a player never opens SELECT. MUST reference real rows in
  -- data.lua (asserted at boot in exports.lua).
  Config.DefaultFighter = 'house_ace'
  Config.DefaultStyle   = 'brawler'

  Config.MaxCrowd = 12

  -- CLIENT-DISPLAY MONEY MIRROR (§10b). These two values MUST equal the money
  -- authority (palm6_fightclub Config.Fight.WinnerPursePct / Config.Betting.RakePct).
  -- fc_core cannot read fightclub's isolated state, so the equality is cross-
  -- asserted at FIGHTCLUB boot (T3), NOT here. HUD (T9) computes
  -- takeout = RakePct + WinnerPursePct = 0.25 from these.
  Config.WinnerPursePct = 0.15
  Config.Betting = {
      RakePct          = 0.10,
      OddsBroadcastSec = 2,
      MinBet           = 50,
      MaxBet           = 5000,
  }

  -- §19.3 PvE block — SHIPS DARK (present, Enabled=false). Money-inert by
  -- construction (is_pve=1 row, entry_pot=0, /fcbet rejects it). Difficulty is
  -- policy-only (never HP/damage inflation). PveTierRepFrac = fraction of
  -- RepPerPvpWin (asserted "full day < one PvP win" at boot in exports.lua).
  Config.Pve = {
      Enabled                 = false,
      MaxPop                  = 6,
      RequireNoHumanAtRing    = true,
      PreemptOnHumanChallenge = true,
      GrantsCash              = false,
      EntryFee                = 0,      -- PINNED 0 (§19.2)
      AiTickMs                = 250,
      CpuStepSpeed            = 2.2,    -- m/s, leashed to Ring.radius
      PveMinMatchSec          = 20,
      PveRepCooldownSec       = 3600,
      PveDailyRepGrantCap     = 3,
      DimFactor               = 0.5,
      PveCpuFinishers         = false,
      PveTierRepFrac = { T1 = 0.08, T2 = 0.14, T3 = 0.22, T4 = 0.32, T5 = 0.45 },
      Tiers = {
          { tier = 1, name = 'Rookie',    reactionMs = 800, blockChance = 0.10, aggression = 0.40, comboDepth = 1 },
          { tier = 2, name = 'Amateur',   reactionMs = 600, blockChance = 0.20, aggression = 0.60, comboDepth = 2 },
          { tier = 3, name = 'Contender', reactionMs = 450, blockChance = 0.35, aggression = 0.80, comboDepth = 2 },
          { tier = 4, name = 'Veteran',   reactionMs = 320, blockChance = 0.50, aggression = 1.00, comboDepth = 3 },
          { tier = 5, name = 'Legend',    reactionMs = 220, blockChance = 0.65, aggression = 1.00, comboDepth = 3 },
      },
      -- Original house-fighter CPUs, one per tier, on existing base ped models
      -- (zero custom assets). styleId must resolve to a Config.Styles id (asserted).
      CpuFighters = {
          { id = 'cpu_rook',    name = 'Freddy Fists', model = 'a_m_y_genstreet_01', styleId = 'brawler',   tier = 1 },
          { id = 'cpu_amateur', name = 'Lil Combo',    model = 'g_m_y_lost_01',      styleId = 'kickboxer', tier = 2 },
          { id = 'cpu_cont',    name = 'Marcus Steel', model = 'a_m_m_og_boss_01',   styleId = 'wrestler',  tier = 3 },
          { id = 'cpu_vet',     name = 'Old Snap',     model = 'g_m_m_armboss_01',   styleId = 'brawler',   tier = 4 },
          { id = 'cpu_legend',  name = 'The Warden',   model = 'a_m_m_bevhills_02',  styleId = 'wrestler',  tier = 5 },
      },
  }
  ```

- [ ] **Step 3: Write `data.lua` (roster + styles + statebag key constants — attaches to the shared `Config` table).**
  Create `resources/[custom]/palm6_fc_core/data.lua` (loads immediately after config.lua in the same VM, so `Config` already exists):
  ```lua
  -- ============================================================================
  -- palm6_fc_core/data.lua — roster + style data + statebag key constants.
  -- DATA ONLY. Attaches to the shared Config table from config.lua. BOTH realms.
  -- ============================================================================

  -- Original "house" fighters (§8): {id,name,model,styleId,unlockId?} mapped to
  -- existing base/MP ped models (zero custom assets). unlockId omitted = always
  -- selectable. GetFighter(id) resolves these (O(1) index built in exports.lua).
  Config.Fighters = {
      { id = 'house_ace',    name = 'Ace Malone',  model = 'mp_m_freemode_01',   styleId = 'brawler'   },
      { id = 'house_dozer',  name = 'Big Dozer',   model = 'a_m_m_hillbilly_01', styleId = 'wrestler'  },
      { id = 'house_switch', name = 'Switchblade', model = 'a_m_y_downtown_01',  styleId = 'kickboxer' },
      { id = 'house_reign',  name = 'Queen Reign', model = 'mp_f_freemode_01',   styleId = 'brawler'   },
      { id = 'house_kobra',  name = 'Kobra King',  model = 'g_m_y_lost_01',      styleId = 'kickboxer' },
      { id = 'house_titan',  name = 'Iron Titan',  model = 'a_m_m_og_boss_01',   styleId = 'wrestler'  },
  }

  -- 3 STAT-IDENTICAL styles (§8): differ ONLY in movementClipset + anim feel,
  -- NEVER power (so rep is genuinely cash-neutral, §9). Keyed by styleId.
  Config.Styles = {
      brawler = {
          id = 'brawler', name = 'Brawler', movementClipset = 'move_m@brave',
          animDicts = { strike = 'melee@unarmed@streamed_core', block = 'anim@mp_player_intmenu@key_fob@', hitreact = 'melee@unarmed@streamed_core', finisher = 'mini@takedowns@front' },
      },
      kickboxer = {
          id = 'kickboxer', name = 'Kickboxer', movementClipset = 'move_m@confident',
          animDicts = { strike = 'melee@unarmed@streamed_core', block = 'anim@mp_player_intmenu@key_fob@', hitreact = 'melee@unarmed@streamed_core', finisher = 'mini@takedowns@front' },
      },
      wrestler = {
          id = 'wrestler', name = 'Wrestler', movementClipset = 'move_m@tough_guy@',
          animDicts = { strike = 'melee@unarmed@streamed_core', block = 'anim@mp_player_intmenu@key_fob@', hitreact = 'melee@unarmed@streamed_core', finisher = 'mini@takedowns@front' },
      },
  }

  -- Statebag key constants (T1 DOCUMENTS the shape; T7 writes, T9 reads).
  -- Exposed via exports.palm6_fc_core:StateKeys().
  FcStateKeys = {
      MATCH_PREFIX  = 'fc:match:',
      PLAYER_ACTIVE = 'fc:active',
      PLAYER_SLOT   = 'fc:slot',
      matchKey = function(matchId) return 'fc:match:' .. matchId end,
  }
  ```

- [ ] **Step 4: luaparse the manifest + config + data (repo gate #1).**
  Run from repo root `C:/Users/Mgtda/Projects/Active/gtarp` (quote the bracketed path so Git Bash does not glob it):
  ```bash
  for f in fxmanifest config data; do npx luaparse "resources/[custom]/palm6_fc_core/$f.lua" >/dev/null && echo "PARSE_OK $f"; done
  ```
  Expected output (three lines, no `SyntaxError`):
  ```
  PARSE_OK fxmanifest
  PARSE_OK config
  PARSE_OK data
  ```
  If any file errors, luaparse prints `SyntaxError: <msg> near line N` and the `echo` is skipped — fix and rerun before proceeding.

- [ ] **Step 5: Commit the scaffold (explicit paths — golden rule: never `git add -A` in this shared tree).**
  ```bash
  git add "resources/[custom]/palm6_fc_core/fxmanifest.lua" \
          "resources/[custom]/palm6_fc_core/config.lua" \
          "resources/[custom]/palm6_fc_core/data.lua"
  git commit -m "palm6_fc_core: scaffold shared data resource (config + roster + styles)

  New shared_scripts-only resource: §6a move table + vitals/momentum/timers,
  §10b betting/purse client-display mirror, §19.3 PvE block (ships dark),
  6 house fighters + 3 stat-identical styles, statebag key constants. Data
  only, no behavior. luaparse-clean.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```
  Expected: one commit created (do NOT push — push only when David asks). If on `main`, first `git checkout -b feat/defjam-fc-core` (or the existing Phase-0 branch) — `main` auto-deploys on `resources/**` changes.

- [ ] **Step 6: Write `exports.lua` (lookups + O(1) index + boot data-integrity asserts + export registrations + boot self-test).** This is the only "logic" in the resource — pure load-time lookups/validation, no events/threads/gameplay.
  Create `resources/[custom]/palm6_fc_core/exports.lua`:
  ```lua
  -- ============================================================================
  -- palm6_fc_core/exports.lua — export surface + boot data-integrity asserts.
  -- The ONLY logic in this resource: pure lookups + load-time validation. No
  -- events, threads, or gameplay behavior. Loads in BOTH realms.
  -- ============================================================================

  -- O(1) fighter index (Config.Fighters is an array; GetFighter looks up by id).
  local FighterById = {}
  for _, f in ipairs(Config.Fighters) do
      FighterById[f.id] = f
  end

  local function getFighter(fighterId) return FighterById[fighterId] end
  local function getStyle(styleId)      return Config.Styles[styleId] end
  local function getMove(moveId)        return Config.Moves[moveId] end

  -- ---- boot data-integrity asserts (load-time; a bad row fails LOUD at boot,
  -- ---- never silently ships a half-valid roster) ----
  local MOVE_KEYS = { 'moveId', 'kind', 'damage', 'staminaCost', 'cooldownMs', 'activeWindowMs', 'reach', 'chipPct', 'blockStamCost' }

  local function fcAssert(cond, msg)
      if not cond then error('[palm6_fc_core] CONFIG INVALID: ' .. msg, 0) end
  end

  -- 1) defaults resolve to real rows
  fcAssert(getFighter(Config.DefaultFighter) ~= nil, 'DefaultFighter "' .. tostring(Config.DefaultFighter) .. '" is not a Config.Fighters id')
  fcAssert(getStyle(Config.DefaultStyle) ~= nil,      'DefaultStyle "' .. tostring(Config.DefaultStyle) .. '" is not a Config.Styles id')

  -- 2) every fighter references a real style
  for _, f in ipairs(Config.Fighters) do
      fcAssert(getStyle(f.styleId) ~= nil, 'fighter "' .. tostring(f.id) .. '" has unknown styleId "' .. tostring(f.styleId) .. '"')
  end

  -- 3) every move row is complete + self-consistent
  for id, m in pairs(Config.Moves) do
      fcAssert(m.moveId == id, 'move "' .. tostring(id) .. '" moveId mismatch (' .. tostring(m.moveId) .. ')')
      for _, k in ipairs(MOVE_KEYS) do
          fcAssert(m[k] ~= nil, 'move "' .. tostring(id) .. '" missing field "' .. k .. '"')
      end
  end

  -- 4) every dark-PvE CPU fighter references a real style
  for _, c in ipairs(Config.Pve.CpuFighters) do
      fcAssert(getStyle(c.styleId) ~= nil, 'PvE CpuFighter "' .. tostring(c.id) .. '" has unknown styleId "' .. tostring(c.styleId) .. '"')
  end

  -- 5) §19.5 guarantee: a full rolling-day of TOP-tier PvE wins < one PvP win.
  --    sum_{n=1..cap} PveTierRepFrac.T5 * DimFactor^(n-1) < 1.0  (fraction of RepPerPvpWin)
  do
      local frac, dim, cap = Config.Pve.PveTierRepFrac.T5, Config.Pve.DimFactor, Config.Pve.PveDailyRepGrantCap
      local sum, term = 0.0, frac
      for _ = 1, cap do
          sum  = sum + term
          term = term * dim
      end
      fcAssert(sum < 1.0, string.format('PvE top-tier daily rep sum %.4f >= 1.0 (a full PvE day must be worth < one PvP win)', sum))
  end

  -- ---- exports (callable from every fc resource, BOTH realms) ----
  exports('Config',     function() return Config end)
  exports('GetFighter', function(fighterId) return getFighter(fighterId) end)
  exports('GetStyle',   function(styleId)   return getStyle(styleId) end)
  exports('GetMove',    function(moveId)    return getMove(moveId) end)
  exports('StateKeys',  function() return FcStateKeys end)

  -- ---- boot self-test: the visible boot-verify signal; smokes every resolver
  -- ---- path + the statebag key builder. Printed server-side only (IsDuplicity-
  -- ---- Version), but the asserts above run in BOTH realms. ----
  do
      local nF = #Config.Fighters
      local nS, nM = 0, 0
      for _ in pairs(Config.Styles) do nS = nS + 1 end
      for _ in pairs(Config.Moves)  do nM = nM + 1 end
      assert(getMove('jab').damage == 6)
      assert(getFighter(Config.DefaultFighter).styleId ~= nil)
      assert(getStyle(Config.DefaultStyle).movementClipset ~= nil)
      assert(FcStateKeys.matchKey(7) == 'fc:match:7')
      if IsDuplicityVersion() then
          print(('[palm6_fc_core] data OK: %d fighters, %d styles, %d moves (Enabled=%s)'):format(nF, nS, nM, tostring(Config.Enabled)))
      end
  end
  ```

- [ ] **Step 7: luaparse `exports.lua` (repo gate #1).**
  ```bash
  npx luaparse "resources/[custom]/palm6_fc_core/exports.lua" >/dev/null && echo "PARSE_OK exports"
  ```
  Expected: `PARSE_OK exports` (no `SyntaxError`). Fix and rerun on any error before proceeding.

- [ ] **Step 8: Offline data/exports exercise under standalone Lua (recommended pre-boot check — proves the asserts pass and the resolvers return the right rows without a full FXServer).** Skip only if no `lua`/`lua54` binary is present (Step 9 is the required runtime gate either way).
  Create throwaway `scratch/fc_core_stub.lua` (do NOT commit it):
  ```lua
  -- throwaway FiveM-global stub so config/data/exports can run under plain Lua
  _G.__fc = {}
  _G.exports = setmetatable({}, { __call = function(_, name, fn) _G.__fc[name] = fn end })
  function IsDuplicityVersion() return true end
  dofile('resources/[custom]/palm6_fc_core/config.lua')
  dofile('resources/[custom]/palm6_fc_core/data.lua')
  dofile('resources/[custom]/palm6_fc_core/exports.lua')
  -- exercise the produced export surface exactly as downstream tasks will
  local C = _G.__fc.Config()
  assert(C.Enabled == false, 'Enabled must ship false')
  assert(C.WinnerPursePct == 0.15 and C.Betting.RakePct == 0.10, 'money mirror drifted')
  assert(_G.__fc.GetMove('uppercut').damage == 18)
  assert(_G.__fc.GetMove('nope') == nil, 'unknown move must be nil')
  assert(_G.__fc.GetFighter('house_ace').name == 'Ace Malone')
  assert(_G.__fc.GetStyle('wrestler').movementClipset == 'move_m@tough_guy@')
  assert(_G.__fc.StateKeys().matchKey(42) == 'fc:match:42')
  print('STUB OK')
  ```
  Run from repo root:
  ```bash
  lua54 scratch/fc_core_stub.lua || lua scratch/fc_core_stub.lua
  ```
  Expected output (both lines):
  ```
  [palm6_fc_core] data OK: 6 fighters, 3 styles, 5 moves (Enabled=false)
  STUB OK
  ```
  A bad row instead aborts with `[palm6_fc_core] CONFIG INVALID: <reason>` (that is the assert firing correctly). Delete `scratch/fc_core_stub.lua` after — it is not part of the resource.

- [ ] **Step 9: Boot-verify on a local FXServer (repo gate #2 — the canonical runtime gate).** Do NOT edit `custom.cfg` (T11 owns the ensure order); ensure the resource manually in the server console instead. In the FXServer console:
  ```
  refresh
  ensure palm6_fc_core
  ```
  Expected: the resource starts with **0 SCRIPT ERROR** and the server console prints exactly:
  ```
  [palm6_fc_core] data OK: 6 fighters, 3 styles, 5 moves (Enabled=false)
  ```
  Then clean up so the manual ensure does not linger:
  ```
  stop palm6_fc_core
  ```
  If a `CONFIG INVALID` error or any SCRIPT ERROR appears, the resource will not have started — fix the offending file, re-luaparse, and repeat Steps 8-9. (No `/fcdebug` exercise here: that command is created in T4 and there is no runtime surface yet — fc_core is pure data.)

- [ ] **Step 10: Final commit (exports + verified data resource).**
  ```bash
  git add "resources/[custom]/palm6_fc_core/exports.lua"
  git commit -m "palm6_fc_core: export surface + boot data-integrity asserts

  Adds Config/GetFighter/GetStyle/GetMove/StateKeys exports (both realms),
  O(1) fighter index, and load-time asserts: defaults resolve, every fighter/
  CPU styleId resolves, every move row complete, and the §19.5 top-tier PvE
  daily-rep sum < one PvP win. Boot self-test prints a data-OK line.
  luaparse-clean; boot-verified (0 SCRIPT ERROR, data-OK line on ensure).

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```
  Expected: one commit created (do NOT push). Confirm the scratch stub is not staged: `git status --short` shows nothing under `scratch/`.

**David feel-test items (in-game verification — the standing rule):** Task 1 ships **no in-game surface** (pure data behind `Config.Enabled=false`), so there is **no Task-1 feel-test gate**. It only seeds the tunable defaults that David will feel-test once combat exists downstream. Flag these carried-forward items so later tasks surface them:
- **Ring.coords / radius** (`Config.Ring`): must be verified in-game as on-ground and reachable, and the 15m radius sized so two fighters can reach each other's `move.reach` — the feel-test gate lands in T6/T10 (arena + fight-mark squaring), not here.
- **§6a combat numbers** (move `damage`/`staminaCost`/`cooldownMs`/`activeWindowMs`/`reach`, `Config.Vitals`, `Config.Momentum`, `Config.Blazin`): these are David's tuning surface once the move clock runs (T6-T8) — a KO should feel like ~7-12 connects and `body` should read as stamina-pressure, not damage. Task 1 only sets the starting values.
- **6 fighter ped models + 3 style movement clipsets**: need a visual pass at the T6 SELECT screen to confirm they load and read as distinct silhouettes/feels (all use base/MP models, zero custom assets).

---

### Task 2: DB migrations registered in palm6_dbmigrate (additive, idempotent, prod-safe)

**Files:**
- MODIFY `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_dbmigrate/server.lua` (append entries to the `STATEMENTS` array, inserted BEFORE the existing `0054` fightclub block)
- CREATE `C:/Users/Mgtda/Projects/Active/gtarp/sql/0066_fightclub_defjam.sql` (canonical source-of-truth mirror — repo convention: every dbmigrate entry references a `sql/00XX` file, e.g. `-- 0054: ... (see sql/0054)`. dbmigrate applies its own inline copy; this file is the human-readable authority.)

**Interfaces:**
- Consumes: nothing (pure schema task; no Lua exports imported).
- Produces (DB schema, consumed by later tasks — do NOT rename a column):
  - Base `palm6_fightclub_matches` + `palm6_fightclub_bets` (mirror of `sql/0028_fightclub.sql`, currently NOT registered in dbmigrate — a fresh-DB rebuild has no fightclub tables, and the existing `0054` ALTERs at server.lua:280-288 silently FAIL against a missing table).
  - New columns on `palm6_fightclub_matches`: `style1/style2 VARCHAR(24)`, `fighter1_model/fighter2_model VARCHAR(48)`, `method VARCHAR(16)`, `entry_pot INT NOT NULL DEFAULT 0`, `entry_paid1/entry_paid2 TINYINT NOT NULL DEFAULT 0`, `rep_awarded TINYINT NOT NULL DEFAULT 1`, `is_pve TINYINT NOT NULL DEFAULT 0`, `cpu_tier TINYINT NULL`, `cpu_fighter VARCHAR(48) NULL`. (T3 `settleMatch`/`OpenMatch`/`ResolveMatch` consume `entry_pot`/`entry_paid1`/`entry_paid2`/`method`/`style*`/`fighter*_model`; T5 progression consumes `rep_awarded`/`is_pve`; PvE cols ship dark.)
  - New tables: `palm6_fc_progression` (T5 exports `GetRep`/`GetRank`), `palm6_fc_unlocks` (T5 `HasUnlock`), `palm6_fc_daily` (T5 anti-farm caps), `palm6_fc_pve_cooldowns` (dark PvE).

**Money/rep-safety rationale (load-bearing, do not weaken):**
- `rep_awarded TINYINT NOT NULL DEFAULT 1` — DEFAULT **1** (not 0) is the same first-boot-safety pattern as `0054`'s `settled DEFAULT 1`. Existing `status='resolved'` matches are backfilled as already-rep-awarded, so T5's boot reconcile (`WHERE rep_awarded=0 AND is_pve=0`) never re-grants rep on historical matches (a rep printer). T3's `ResolveMatch` resets `rep_awarded=0` at the live→resolved flip, so matches resolving AFTER deploy stay claimable exactly once.
- `entry_pot DEFAULT 0` + `entry_paid1/2 DEFAULT 0` — existing matches have `entry_pot=0`, so T3's entry-pot settle block is a no-op on all historical rows (charge-before-grant is preserved; no mint on legacy data).
- Every statement is `CREATE TABLE IF NOT EXISTS` / `ALTER ... ADD COLUMN IF NOT EXISTS` — the `STATEMENTS` array re-runs top-to-bottom every boot (dbmigrate is ledger-less; header line 7: "Every statement is IF NOT EXISTS, so re-running is a harmless no-op"). MariaDB-only `IF NOT EXISTS` on ADD COLUMN/CREATE INDEX is already the repo idiom (see 0043/0050/0057).

**Ordering constraint (critical):** the `STATEMENTS` array runs top-to-bottom; an ALTER before its base CREATE fails on a fresh DB. Insert the new block IMMEDIATELY BEFORE the existing `-- 0054: recoverable fightclub settlement` comment (server.lua:275). Resulting order: `...0053 pumpcoin_billboards → [fc base matches → fc base bets → fc matches defjam columns → 4 new tables] → 0054 bets.paid/purse_paid/settled → 0057...`. Base tables now exist before BOTH the new ALTER and the pre-existing `0054` ALTERs. Do NOT duplicate the `0054` `paid`/`purse_paid`/`settled` ALTERs — they already register T3's money flags.

- [ ] **Step 1: Read the anchor region of server.lua.** Confirm the insertion point is still the `0054` comment block. Run:
  ```
  npx --version
  ```
  Expected: a version string (confirms npx/luaparse toolchain is present; if `luaparse` isn't installed, `npx luaparse` auto-fetches it). Then open `resources/[custom]/palm6_dbmigrate/server.lua` and confirm lines 275-288 read exactly:
  ```lua
      -- 0054: recoverable fightclub settlement (see sql/0054). Idempotent ALTERs.
      -- `paid` (per-bet) + `purse_paid` (per-match) are claim-before-credit
  ```
  This is the Edit anchor for Step 3. Do NOT proceed if the text differs (someone renumbered).

- [ ] **Step 2: Create the canonical SQL mirror `sql/0066_fightclub_defjam.sql`.** Write this exact file (repo convention: canonical `.sql` per migration; dbmigrate re-inlines it). Real content:
  ```sql
  -- ============================================================================
  -- 0066_fightclub_defjam.sql — Def Jam Fight Club (Phase 0) schema.
  --
  -- Registers the BASE fightclub tables (mirror of 0028 — never added to
  -- palm6_dbmigrate, so a fresh-DB rebuild had no fightclub layer and the 0054
  -- settlement ALTERs FAILed against a missing table) PLUS the Phase-0 additive
  -- columns and progression/unlock/daily/pve-cooldown tables.
  --
  -- All statements IF NOT EXISTS — dbmigrate re-runs them every boot (ledger-less).
  -- rep_awarded DEFAULT 1 backfills existing resolved matches as already-awarded
  -- so the T5 progression boot reconcile never re-grants rep on payment history.
  -- entry_pot/entry_paid* DEFAULT 0 keep the entry-pot settle a no-op on legacy rows.
  -- ============================================================================

  -- Base tables (mirror of 0028_fightclub.sql).
  CREATE TABLE IF NOT EXISTS `palm6_fightclub_matches` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      fighter1_citizenid VARCHAR(64) NOT NULL,
      fighter1_name VARCHAR(100) NOT NULL DEFAULT '',
      fighter2_citizenid VARCHAR(64) NOT NULL,
      fighter2_name VARCHAR(100) NOT NULL DEFAULT '',
      status ENUM('betting','live','resolved') NOT NULL DEFAULT 'betting',
      winner_citizenid VARCHAR(64) DEFAULT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      betting_ends_at TIMESTAMP NULL DEFAULT NULL,
      live_started_at TIMESTAMP NULL DEFAULT NULL,
      resolved_at TIMESTAMP NULL DEFAULT NULL,
      INDEX idx_palm6_fightclub_matches_status (status),
      INDEX idx_palm6_fightclub_matches_f1 (fighter1_citizenid),
      INDEX idx_palm6_fightclub_matches_f2 (fighter2_citizenid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

  CREATE TABLE IF NOT EXISTS `palm6_fightclub_bets` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      match_id INT UNSIGNED NOT NULL,
      citizenid VARCHAR(64) NOT NULL,
      fighter TINYINT UNSIGNED NOT NULL,
      amount INT UNSIGNED NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uniq_palm6_fightclub_bet (match_id, citizenid),
      INDEX idx_palm6_fightclub_bets_match (match_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

  -- Phase-0 additive columns on matches (each ADD COLUMN IF NOT EXISTS).
  ALTER TABLE `palm6_fightclub_matches`
      ADD COLUMN IF NOT EXISTS `style1`         VARCHAR(24) NULL,
      ADD COLUMN IF NOT EXISTS `style2`         VARCHAR(24) NULL,
      ADD COLUMN IF NOT EXISTS `fighter1_model` VARCHAR(48) NULL,
      ADD COLUMN IF NOT EXISTS `fighter2_model` VARCHAR(48) NULL,
      ADD COLUMN IF NOT EXISTS `method`         VARCHAR(16) NULL,
      ADD COLUMN IF NOT EXISTS `entry_pot`      INT     NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `entry_paid1`    TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `entry_paid2`    TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `rep_awarded`    TINYINT NOT NULL DEFAULT 1,
      ADD COLUMN IF NOT EXISTS `is_pve`         TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `cpu_tier`       TINYINT NULL,
      ADD COLUMN IF NOT EXISTS `cpu_fighter`    VARCHAR(48) NULL;

  -- Progression / unlocks / daily caps / dark PvE cooldowns.
  CREATE TABLE IF NOT EXISTS `palm6_fc_progression` (
      citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
      rep INT NOT NULL DEFAULT 0,
      wins INT NOT NULL DEFAULT 0,
      losses INT NOT NULL DEFAULT 0,
      rank_tier INT NOT NULL DEFAULT 0,
      pve_wins INT NOT NULL DEFAULT 0,
      pve_losses INT NOT NULL DEFAULT 0,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

  CREATE TABLE IF NOT EXISTS `palm6_fc_unlocks` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      citizenid VARCHAR(64) NOT NULL,
      unlock_id VARCHAR(48) NOT NULL,
      unlocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uniq_fc_unlock (citizenid, unlock_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

  CREATE TABLE IF NOT EXISTS `palm6_fc_daily` (
      citizenid VARCHAR(64) NOT NULL,
      day_bucket VARCHAR(10) NOT NULL,
      pvp_rep_wins INT NOT NULL DEFAULT 0,
      pve_rep_wins INT NOT NULL DEFAULT 0,
      distinct_opponents INT NOT NULL DEFAULT 0,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY (citizenid, day_bucket)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

  CREATE TABLE IF NOT EXISTS `palm6_fc_pve_cooldowns` (
      citizenid VARCHAR(64) NOT NULL,
      cpu_tier TINYINT NOT NULL,
      beaten_at BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (citizenid, cpu_tier)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ```
  (No verify command for a `.sql` file — it is applied via dbmigrate, verified at Step 5. This file is documentation + prod-panel manual-apply fallback.)

- [ ] **Step 3: Insert the 7 STATEMENTS entries into server.lua, before the 0054 block.** Use an Edit whose `old_string` is the `0054` comment header and whose `new_string` prepends the fc block. Note the dbmigrate inline SQL carries NO trailing `;` (single-statement `MySQL.query.await`; every existing entry omits it — the `.sql` file above keeps `;` for multi-statement panel paste, dbmigrate does not). Edit:
  - `old_string`:
    ```lua
      -- 0054: recoverable fightclub settlement (see sql/0054). Idempotent ALTERs.
    ```
  - `new_string`:
    ```lua
      -- 0066: Def Jam Fight Club (Phase 0). Registers the BASE fightclub tables
      -- (0028 was never added here — a fresh-DB rebuild had no fightclub layer and
      -- the 0054 ALTERs below FAILed on a missing table) BEFORE the additive
      -- columns + progression/unlock/daily/pve tables. All IF NOT EXISTS -> no-op
      -- on prod where 0028/0054 already ran. See sql/0066_fightclub_defjam.sql.
      -- rep_awarded DEFAULT 1 backfills existing resolved matches as already-awarded
      -- so the progression boot reconcile never re-grants rep on payment history.
      { name = '0066 fc base matches', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fightclub_matches` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      fighter1_citizenid VARCHAR(64) NOT NULL,
      fighter1_name VARCHAR(100) NOT NULL DEFAULT '',
      fighter2_citizenid VARCHAR(64) NOT NULL,
      fighter2_name VARCHAR(100) NOT NULL DEFAULT '',
      status ENUM('betting','live','resolved') NOT NULL DEFAULT 'betting',
      winner_citizenid VARCHAR(64) DEFAULT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      betting_ends_at TIMESTAMP NULL DEFAULT NULL,
      live_started_at TIMESTAMP NULL DEFAULT NULL,
      resolved_at TIMESTAMP NULL DEFAULT NULL,
      INDEX idx_palm6_fightclub_matches_status (status),
      INDEX idx_palm6_fightclub_matches_f1 (fighter1_citizenid),
      INDEX idx_palm6_fightclub_matches_f2 (fighter2_citizenid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      { name = '0066 fc base bets', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fightclub_bets` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      match_id INT UNSIGNED NOT NULL,
      citizenid VARCHAR(64) NOT NULL,
      fighter TINYINT UNSIGNED NOT NULL,
      amount INT UNSIGNED NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uniq_palm6_fightclub_bet (match_id, citizenid),
      INDEX idx_palm6_fightclub_bets_match (match_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      { name = '0066 fc matches defjam columns', sql = [[
  ALTER TABLE `palm6_fightclub_matches`
      ADD COLUMN IF NOT EXISTS `style1`         VARCHAR(24) NULL,
      ADD COLUMN IF NOT EXISTS `style2`         VARCHAR(24) NULL,
      ADD COLUMN IF NOT EXISTS `fighter1_model` VARCHAR(48) NULL,
      ADD COLUMN IF NOT EXISTS `fighter2_model` VARCHAR(48) NULL,
      ADD COLUMN IF NOT EXISTS `method`         VARCHAR(16) NULL,
      ADD COLUMN IF NOT EXISTS `entry_pot`      INT     NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `entry_paid1`    TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `entry_paid2`    TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `rep_awarded`    TINYINT NOT NULL DEFAULT 1,
      ADD COLUMN IF NOT EXISTS `is_pve`         TINYINT NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS `cpu_tier`       TINYINT NULL,
      ADD COLUMN IF NOT EXISTS `cpu_fighter`    VARCHAR(48) NULL]] },
      { name = '0066 fc progression', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fc_progression` (
      citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
      rep INT NOT NULL DEFAULT 0,
      wins INT NOT NULL DEFAULT 0,
      losses INT NOT NULL DEFAULT 0,
      rank_tier INT NOT NULL DEFAULT 0,
      pve_wins INT NOT NULL DEFAULT 0,
      pve_losses INT NOT NULL DEFAULT 0,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      { name = '0066 fc unlocks', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fc_unlocks` (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
      citizenid VARCHAR(64) NOT NULL,
      unlock_id VARCHAR(48) NOT NULL,
      unlocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uniq_fc_unlock (citizenid, unlock_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      { name = '0066 fc daily', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fc_daily` (
      citizenid VARCHAR(64) NOT NULL,
      day_bucket VARCHAR(10) NOT NULL,
      pvp_rep_wins INT NOT NULL DEFAULT 0,
      pve_rep_wins INT NOT NULL DEFAULT 0,
      distinct_opponents INT NOT NULL DEFAULT 0,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      PRIMARY KEY (citizenid, day_bucket)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      { name = '0066 fc pve cooldowns', sql = [[
  CREATE TABLE IF NOT EXISTS `palm6_fc_pve_cooldowns` (
      citizenid VARCHAR(64) NOT NULL,
      cpu_tier TINYINT NOT NULL,
      beaten_at BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (citizenid, cpu_tier)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
      -- 0054: recoverable fightclub settlement (see sql/0054). Idempotent ALTERs.
    ```
  (The last line of `new_string` re-supplies the original `0054` comment so the Edit is a clean insertion — the 8 fc entries land immediately before the untouched `0054` block.)

- [ ] **Step 4: luaparse the modified resource file.** The only `.lua` touched. Run:
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && npx luaparse "resources/[custom]/palm6_dbmigrate/server.lua"
  ```
  Expected: clean exit (no stderr, exit code 0). A JSON AST dump or silence both = pass; any `SyntaxError:` line = fail (most likely a `[[ ]]` long-bracket mismatch or a missing `},` between entries) — fix and re-run before Step 5. Cross-check bracket balance: the file must still end with the single `}` closing `STATEMENTS` on the line before `CreateThread(function()`.

- [ ] **Step 5: Boot-verify against a local FXServer + local MariaDB (real dbmigrate gate).** dbmigrate has no external DB reach, so its own boot console is the authority. Start the local server (per repo's local-boot doc) with `palm6_dbmigrate` ensured, and watch console for the `[palm6_dbmigrate]` block. Expected lines (order matters — base tables print before the defjam ALTER, which prints before 0054):
  ```
  [palm6_dbmigrate]   OK   0066 fc base matches
  [palm6_dbmigrate]   OK   0066 fc base bets
  [palm6_dbmigrate]   OK   0066 fc matches defjam columns
  [palm6_dbmigrate]   OK   0066 fc progression
  [palm6_dbmigrate]   OK   0066 fc unlocks
  [palm6_dbmigrate]   OK   0066 fc daily
  [palm6_dbmigrate]   OK   0066 fc pve cooldowns
  [palm6_dbmigrate]   OK   0054 fightclub bets.paid
  [palm6_dbmigrate]   OK   0054 fightclub matches.purse_paid
  [palm6_dbmigrate]   OK   0054 fightclub matches.settled
  ```
  Then the summary must show `0 failed` (no `FAIL 0066` or `FAIL 0054` lines — a FAIL on a `0054` line would prove the base-table ordering is wrong). Confirm column shape with the local DB client:
  ```
  mysql -u root palm6 -e "DESCRIBE palm6_fightclub_matches" | grep -E "rep_awarded|entry_pot|entry_paid1|entry_paid2|is_pve|cpu_tier|cpu_fighter|method|style1|fighter1_model"
  ```
  Expected: `rep_awarded  tinyint ... 1` (DEFAULT **1**, not 0 — the load-bearing backfill guard), `entry_pot int ... 0`, `is_pve tinyint ... 0`, `method varchar(16)`, `style1 varchar(24)`, `fighter1_model varchar(48)`. And:
  ```
  mysql -u root palm6 -e "SHOW TABLES LIKE 'palm6_fc_%'"
  ```
  Expected 4 rows: `palm6_fc_daily`, `palm6_fc_progression`, `palm6_fc_pve_cooldowns`, `palm6_fc_unlocks`.

- [ ] **Step 6: Idempotency re-run (ledger-less every-boot safety).** Restart the local FXServer once more WITHOUT dropping the DB. Expected: the SAME 10 `OK` lines and `0 failed` — every statement is a no-op the second time (`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` on already-present objects return success on MariaDB). Any `FAIL` on the second boot means a non-idempotent statement slipped in — fix before commit. Verify no data churn: `rep_awarded` DEFAULT stays `1`, and a manually-inserted `status='resolved'` test row keeps `rep_awarded=1` across the reboot (proves the backfill runs exactly once, never re-defaulting live rows).

- [ ] **Step 7: Commit.** Conventional-commit, explicit paths, AI co-author trailer (per CONTRIBUTING.md:51). Run:
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && git add "resources/[custom]/palm6_dbmigrate/server.lua" "sql/0066_fightclub_defjam.sql" && git commit -m "$(cat <<'EOF'
  feat(fightclub): register defjam Phase-0 schema in dbmigrate (0066)

  Register base fightclub tables (0028 was never in dbmigrate) + additive
  matches columns (style/model/method/entry_pot/entry_paid/rep_awarded/pve)
  + progression/unlocks/daily/pve_cooldown tables. Inserted BEFORE the 0054
  block so base CREATEs precede the settlement ALTERs on a fresh DB. All
  IF NOT EXISTS (idempotent every-boot). rep_awarded DEFAULT 1 backfills
  historical resolved matches so the T5 reconcile never re-grants rep.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected: one commit touching exactly the two files. Do NOT push (repo push policy is a separate gated step; pushes don't auto-deploy per CONTRIBUTING.md:24).

**David feel-test (the only prod gate — prod DB `db-dtx-06` is unreachable externally, so in-game/panel boot is the sole verification):** After the change lands and the server is deployed, David must (1) confirm the prod `[palm6_dbmigrate]` boot console shows all 10 `0066`/`0054` fightclub lines `OK` with `0 failed` on the real prod DB, and (2) on the prod DB panel run `DESCRIBE palm6_fightclub_matches` and eyeball that `rep_awarded` reads DEFAULT `1` and the 4 `palm6_fc_*` tables exist — because a silent `FAIL` here (e.g. MariaDB vs MySQL `ADD COLUMN IF NOT EXISTS` support, or a pre-existing incompatible column type) is invisible until T3/T5 later read a missing column and strand money/rep. No in-game combat feel-test applies to this task (schema only).

---

### Task 3: palm6_fightclub rewire — OpenMatch/GoLive/ResolveMatch/VoidMatch + entry-pot settle (HIGHEST RISK, live money)

Rewire `palm6_fightclub` from a self-swept queue-and-combat resource into the **pure money authority**: guarded server exports that open/advance/resolve/void a match row, plus the recoverable, idempotent settlement extended to pay the two-fighter entry pot. The queue, `/fcjoin`, `/fcleave`, `checkFighter`, `sweepLiveMatches`, `sweepBettingToLive`, `sweepQueueTimeouts`, the sweep thread, and `playerDropped` match-resolution are DELETED (lifecycle moves to `palm6_fc_combat`, T6). Preserve the charge-before-grant / claim-before-credit / guarded-UPDATE / boot-reconcile discipline exactly. The winner's entry cut is the RESIDUAL so no config combo can mint.

**Files:**
- MODIFY `resources/[custom]/palm6_fightclub/shared/config.lua` (add money knobs, drop dead ratelimits)
- MODIFY `resources/[custom]/palm6_fightclub/server/main.lua` (full rewrite of logic; keep settle/reconcile/claim discipline)
- (NO change to `bridge/sv_framework.lua` or `fxmanifest.lua` — still server-only, same file list. `/fcdebug` and its ace/ratelimit are T4; eventguard/ensure-order/`Config.Enabled` cutover are T11.)

**Interfaces:**
- **Consumes** (from T1 `palm6_fc_core`, both exports optional-guarded so this resource still parses/boots if T1 lands later):
  - `exports.palm6_fc_core:Config()` → table with `.Enabled` (bool) — the HARD prod gate.
  - `exports.palm6_fc_core:GetFighter(fighterId)` → `{ id, name, model, styleId, ... }` or nil — model lookup for a row.
- **Consumes** (real `Bridge.*` from `bridge/sv_framework.lua`, unchanged signatures): `Bridge.GetCitizenId(src)`, `Bridge.GetPlayerName(src)`, `Bridge.GetSourceByCitizenId(cid)`, `Bridge.ChargeBank(src, amount, reason)`→bool, `Bridge.CreditBankByCitizenId(cid, amount, reason)`→bool, `Bridge.Notify(src,title,msg,type)`, `Bridge.Reply(src, lines)`, `Bridge.RegisterCommand(name, handler)`.
- **Produces** (server-only exports on `palm6_fightclub`, consumed by T4 `/fcdebug` + T6 combat):
  - `exports('OpenMatch', function(aCid, bCid, styleA, styleB, fighterA, fighterB, entryStake))` → `matchId:int` | `nil` (INSERTs a `status='betting'` row; does NOT charge antes; `nil` on gate/INSERT-fail so caller refunds both).
  - `exports('GoLive', function(matchId))` → `bool` (guarded `betting→live`).
  - `exports('ResolveMatch', function(matchId, winnerCid, method))` → `bool` (atomic `live→resolved` + settle + seam; `winnerCid=nil`⇒draw).
  - `exports('VoidMatch', function(matchId))` → `bool` (guarded `betting→resolved,void` for betting-state aborts).
  - `exports('LiveVoidMatch', function(matchId))` → `bool` (guarded `live→resolved,void` for boot-strand / cutover / preempt of a LIVE row).
  - `exports('BroadcastOdds', function(matchId))` → nil.
  - `exports('GetSummary', function())` → `{ openMatches:int }` (kept, `queued` field dropped).
- **Produces** (net event, consumed by T9/T10 client): `palm6_fightclub:oddsUpdate` = `{ matchId:int, sideA:int, sideB:int, betCount:int, secsLeft:int }`.
- **Produces** (server-internal seam, `TriggerEvent` NEVER `RegisterNetEvent`, consumed by T5 progression / T10 arena): `fc:match:resolved` = `{ matchId, winnerCid, loserCid, method, startedAt, endedAt, isPve, cpuTier }` (`winnerCid=nil` on draw/void).

---

- [ ] **Step 1: Add the §10b money knobs + drop dead ratelimits in `shared/config.lua`.** Three exact `Edit`s.

  Edit A — extend `Config.Betting` (replace the whole block):
  ```lua
  Config.Betting = {
      WindowSec = 60,
      MinBet    = 50,
      MaxBet    = 5000,
      RakePct   = 0.10,   -- house cut of the total pool — an economy sink
  }
  ```
  with:
  ```lua
  Config.Betting = {
      WindowSec        = 60,
      MinBet           = 50,
      MaxBet           = 5000,
      RakePct          = 0.10,    -- house cut of the betting pool — an economy sink
      OddsBroadcastSec = 2,       -- tote-board throttle (T6 per-match timer cadence)
      MaxPoolPerMatch  = 50000,   -- aggregate match-fix cap; folded into the atomic
                                  -- /fcbet insert (no TOCTOU); 0 disables the cap
  }
  ```

  Edit B — extend `Config.Fight` (replace the whole block; KOHealth/MaxDurationSec/PollSec/RequireUnarmed are now unused by main.lua but left in place to avoid churn — harmless data):
  ```lua
  Config.Fight = {
      KOHealth        = 110,
      MaxDurationSec  = 180,   -- no KO by then = timeout draw, full refund
      WinnerPursePct  = 0.15,  -- cut of the pool paid straight to the winner
      PollSec         = 2,     -- sweep cadence for betting->live transitions + fight monitoring
      RequireUnarmed  = true,  -- drawing any weapon is an instant forfeit
  }
  ```
  with:
  ```lua
  Config.Fight = {
      -- §10b two-layer paid fighter (self-funded ante on top of the betting pool).
      EntryStake       = 500,   -- ante per fighter; 0 = for-rep-only (charge skipped, layer no-ops)
      EntryRakePct     = 0.10,  -- sink on the entry pot (anti-collusion); 0 = zero-sum wash (still no mint)
      EntryPotLoserPct = 0.0,   -- MVP off; boot-assert EntryRakePct+this<=1 AND this<0.5
      WinnerPursePct   = 0.15,  -- UNCHANGED: winner's cut of the betting pool
      -- Legacy combat knobs (lifecycle now owned by palm6_fc_combat / fc_core):
      KOHealth         = 110,
      MaxDurationSec   = 180,
      PollSec          = 2,
      RequireUnarmed   = true,
  }
  ```

  Edit C — drop the removed commands' ratelimits (replace the whole block):
  ```lua
  Config.RateLimits = {
      fcjoin    = 3,
      fcleave   = 2,
      fcbet     = 2,
      fcmatches = 2,
  }
  ```
  with:
  ```lua
  Config.RateLimits = {
      fcbet     = 2,
      fcmatches = 2,
      -- fcjoin/fcleave removed (queue deleted); fcdebug added by T4.
  }
  ```

- [ ] **Step 2: Parse-gate config.lua.**
  ```bash
  npx luaparse "resources/[custom]/palm6_fightclub/shared/config.lua" > /dev/null && echo PARSE_OK
  ```
  Expected stdout: `PARSE_OK` (exit 0, no `SyntaxError`).

- [ ] **Step 3: Full rewrite of `server/main.lua`.** Use `Write` to replace the entire file with the exact content below. This deletes the queue and every sweep/queue/`playerDropped`-resolution function, keeps `now/dbg/rl/claimBet/markSettled/settleMatch/reconcileUnsettled` (settle extended for the entry pot), and adds `fcEnabled`, name/model resolution, `claimEntry`, `fireResolved`, `resolveLive`, `broadcastOdds`, and the six lifecycle exports. Local functions are declared before use (`resolveLive` before `ResolveMatch`; `broadcastOdds` before `cmdFcBet`).

  ```lua
  -- ============================================================================
  -- palm6_fightclub/server/main.lua
  --
  -- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
  -- native access. No direct framework / native calls here (§6 gate).
  --
  -- Def Jam Fight Club rewire (Phase 0). The queue + server-swept combat are
  -- GONE — the match lifecycle (challenge -> select -> betting -> live ->
  -- resolved) is owned by palm6_fc_combat. This resource is now the MONEY
  -- AUTHORITY only: it exposes guarded server exports that open/advance/resolve/
  -- void a match row and runs the recoverable, idempotent settlement (spectator
  -- parimutuel pool + the two-fighter entry-stake pot). Every money move is
  -- charge-before-grant / claim-before-credit, every state flip is a guarded
  -- UPDATE ... WHERE status='<expected>', and a crash mid-payout is re-driven by
  -- the boot reconcile with NO double-pay. NEVER a mint: the winner's entry cut
  -- is the RESIDUAL (entry_pot - entryRake - loserCut) so no config combo can
  -- create money (spec 10b).
  -- ============================================================================

  local lastAction = {}    -- [src] = { [key] = ts } — chat-command spam guard

  local function now() return os.time() end

  local function dbg(msg)
      if Config.Debug then print('[palm6_fightclub] ' .. msg) end
  end

  local function rl(src, key)
      local window = Config.RateLimits[key] or 1
      lastAction[src] = lastAction[src] or {}
      local t = now()
      if (lastAction[src][key] or 0) + window > t then return false end
      lastAction[src][key] = t
      return true
  end

  -- HARD prod gate. fc_core owns Config.Enabled (isolated Lua state -> reached
  -- via export). Missing/erroring fc_core => inert (false) so the feature never
  -- opens new matches or takes bets before it is proven. Settlement/reconcile/
  -- void are deliberately NOT gated so in-flight matches always finish paying
  -- out even after a mid-session cutover (spec 15).
  local function fcEnabled()
      local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
      return ok and cfg ~= nil and cfg.Enabled == true
  end

  -- Money-safety boot asserts (spec 10b). A failed assert stops the script — the
  -- intended fail-closed gate: never boot a config that could mint on the entry
  -- pot. entryRake + loserCut can never exceed the pot (winnerCut is the
  -- residual), and a loss must always sting.
  assert(Config.Fight.EntryRakePct + Config.Fight.EntryPotLoserPct <= 1,
      '[palm6_fightclub] money-safety: Config.Fight.EntryRakePct + EntryPotLoserPct must be <= 1')
  assert(Config.Fight.EntryPotLoserPct < 0.5,
      '[palm6_fightclub] money-safety: Config.Fight.EntryPotLoserPct must be < 0.5 (a loss must sting)')

  -- ---------------------------------------------------------------------------
  -- Server-side name / model resolution for a match row (never client-trusted).
  -- ---------------------------------------------------------------------------
  local function nameForCid(cid)
      local s = Bridge.GetSourceByCitizenId(cid)
      if s then return Bridge.GetPlayerName(s) end
      return tostring(cid)
  end

  -- fighterId -> ped model, resolved through fc_core's data table; falls back to
  -- treating the passed value as a raw model string (display-only, never money).
  local function fighterModel(fighterId)
      local ok, f = pcall(function() return exports.palm6_fc_core:GetFighter(fighterId) end)
      if ok and f and f.model then return f.model end
      return tostring(fighterId)
  end

  -- ---------------------------------------------------------------------------
  -- Idempotency claim helpers (claim-before-credit: WE flipped 0->1 iff true).
  -- ---------------------------------------------------------------------------
  local function claimBet(betId)
      local claimed = false
      pcall(function()
          claimed = MySQL.update.await(
              "UPDATE palm6_fightclub_bets SET paid = 1 WHERE id = ? AND paid = 0", { betId }) == 1
      end)
      return claimed
  end

  -- Claim one fighter's entry-pot payout flag. slot is a fixed 1|2 -> whitelisted
  -- column name (never client input), so the interpolation is injection-safe.
  local function claimEntry(matchId, slot)
      local col = (slot == 1) and 'entry_paid1' or 'entry_paid2'
      local claimed = false
      pcall(function()
          claimed = MySQL.update.await(
              ("UPDATE palm6_fightclub_matches SET %s = 1 WHERE id = ? AND %s = 0"):format(col, col),
              { matchId }) == 1
      end)
      return claimed
  end

  local function paidSnap(match, slot)
      return tonumber((slot == 1) and match.entry_paid1 or match.entry_paid2) == 1
  end

  local function markSettled(matchId)
      pcall(function()
          MySQL.update.await(
              "UPDATE palm6_fightclub_matches SET settled = 1 WHERE id = ? AND settled = 0", { matchId })
      end)
  end

  -- ---------------------------------------------------------------------------
  -- Recoverable, idempotent settlement. Every credit is claimed BEFORE the money
  -- moves; the entry-pot block runs BEFORE markSettled in BOTH branches so a
  -- crash mid-credit leaves status='resolved' AND settled=0 -> re-driven by
  -- reconcileUnsettled with no double-pay. entry_pot / entry_paid1 / entry_paid2
  -- are in the SELECT so a replay can skip already-credited antes.
  -- ---------------------------------------------------------------------------
  local function settleMatch(matchId, reasonLabel)
      local match
      pcall(function()
          match = MySQL.single.await([[
              SELECT winner_citizenid, purse_paid, entry_pot, entry_paid1, entry_paid2,
                     fighter1_citizenid, fighter1_name,
                     fighter2_citizenid, fighter2_name
                FROM palm6_fightclub_matches WHERE id = ? AND status = 'resolved']],
              { matchId })
      end)
      if not match then
          dbg(('settle #%d skipped — resolved-row fetch failed; will retry on boot'):format(matchId))
          return
      end

      local bets = {}
      pcall(function()
          bets = MySQL.query.await(
              "SELECT id, citizenid, fighter, amount, paid FROM palm6_fightclub_bets WHERE match_id = ?", { matchId }) or {}
      end)

      local winnerCid = match.winner_citizenid  -- nil/NULL == draw / void
      local entryPot  = tonumber(match.entry_pot) or 0

      if not winnerCid then
          -- Draw / void: full refund of every unpaid bet + unwind the entry pot.
          for _, b in ipairs(bets) do
              if tonumber(b.paid) ~= 1 and claimBet(b.id) then
                  Bridge.CreditBankByCitizenId(b.citizenid, tonumber(b.amount) or 0, 'fightclub-draw-refund')
                  local s = Bridge.GetSourceByCitizenId(b.citizenid)
                  if s then Bridge.Notify(s, 'Fight Club', ('Match #%d no contest — $%d refunded.'):format(matchId, b.amount), 'inform') end
              end
          end
          -- Entry-pot unwind: refund each ante half (2*EntryStake is even -> no
          -- dust). Claim-before-credit via entry_paid1/2; no-op when entry_pot==0.
          if entryPot > 0 then
              local half = math.floor(entryPot / 2)
              if not paidSnap(match, 1) and claimEntry(matchId, 1) then
                  Bridge.CreditBankByCitizenId(match.fighter1_citizenid, half, 'fightclub-entry-refund')
                  local s1 = Bridge.GetSourceByCitizenId(match.fighter1_citizenid)
                  if s1 then Bridge.Notify(s1, 'Fight Club', ('Match #%d no contest — $%d entry refunded.'):format(matchId, half), 'inform') end
              end
              if not paidSnap(match, 2) and claimEntry(matchId, 2) then
                  Bridge.CreditBankByCitizenId(match.fighter2_citizenid, entryPot - half, 'fightclub-entry-refund')
                  local s2 = Bridge.GetSourceByCitizenId(match.fighter2_citizenid)
                  if s2 then Bridge.Notify(s2, 'Fight Club', ('Match #%d no contest — $%d entry refunded.'):format(matchId, entryPot - half), 'inform') end
              end
          end
          markSettled(matchId)
          dbg(('match #%d settled DRAW/VOID (%s) — %d bet(s), entry_pot=%d'):format(matchId, reasonLabel or '?', #bets, entryPot))
          return
      end

      local winnerSlot = (match.fighter1_citizenid == winnerCid) and 1 or 2
      local winnerName = (winnerSlot == 1 and match.fighter1_name) or match.fighter2_name or 'the winner'
      local loserCid   = (winnerSlot == 1) and match.fighter2_citizenid or match.fighter1_citizenid

      -- Parimutuel pool math from the FULL bet set (deterministic on replay).
      local totalPool, winningSideTotal = 0, 0
      for _, b in ipairs(bets) do
          local amt = tonumber(b.amount) or 0
          totalPool = totalPool + amt
          if tonumber(b.fighter) == winnerSlot then winningSideTotal = winningSideTotal + amt end
      end

      local rake       = math.floor(totalPool * Config.Betting.RakePct)
      local purse      = math.floor(totalPool * Config.Fight.WinnerPursePct)
      local forBettors = math.max(0, totalPool - rake - purse)

      -- Winner betting-purse — claimed once via matches.purse_paid.
      if purse > 0 then
          local claimedPurse = false
          pcall(function()
              claimedPurse = MySQL.update.await(
                  "UPDATE palm6_fightclub_matches SET purse_paid = 1 WHERE id = ? AND purse_paid = 0", { matchId }) == 1
          end)
          if claimedPurse then
              Bridge.CreditBankByCitizenId(winnerCid, purse, 'fightclub-purse')
              local ws = Bridge.GetSourceByCitizenId(winnerCid)
              if ws then Bridge.Notify(ws, 'Fight Club', ('You won match #%d (%s) — $%d purse.'):format(matchId, reasonLabel or 'knockout', purse), 'success') end
          end
      end

      if loserCid then
          local ls = Bridge.GetSourceByCitizenId(loserCid)
          if ls then Bridge.Notify(ls, 'Fight Club', ('You lost match #%d (%s vs %s) — %s.'):format(matchId, match.fighter1_name, match.fighter2_name, reasonLabel or 'knockout'), 'error') end
      end

      -- Parimutuel split: each bet claimed exactly once. Losing stakes + rounding
      -- remainder are the sink ("buys round up, payouts round down").
      for _, b in ipairs(bets) do
          if tonumber(b.paid) ~= 1 and claimBet(b.id) then
              if tonumber(b.fighter) == winnerSlot and winningSideTotal > 0 and forBettors > 0 then
                  local share = math.floor(forBettors * (tonumber(b.amount) or 0) / winningSideTotal)
                  if share > 0 then
                      Bridge.CreditBankByCitizenId(b.citizenid, share, 'fightclub-bet-win')
                      local s = Bridge.GetSourceByCitizenId(b.citizenid)
                      if s then Bridge.Notify(s, 'Fight Club', ('Match #%d: %s won — you collected $%d.'):format(matchId, winnerName, share), 'success') end
                  end
              end
          end
      end

      -- Entry-pot payout (winner RESIDUAL — never a mint). winnerCut absorbs the
      -- remainder so entryRake + loserCut + winnerCut == entry_pot exactly for ANY
      -- config combo. Claim-before-credit via entry_paid<slot>. BEFORE markSettled
      -- so a crash mid-credit is re-driven by the boot reconcile. No-op when
      -- entry_pot == 0 (historical / for-rep-only / is_pve rows).
      if entryPot > 0 then
          local entryRake = math.floor(entryPot * Config.Fight.EntryRakePct)
          local loserCut  = math.floor(entryPot * Config.Fight.EntryPotLoserPct)
          local winnerCut = entryPot - entryRake - loserCut          -- residual
          local loserSlot = (winnerSlot == 1) and 2 or 1
          if not paidSnap(match, winnerSlot) and claimEntry(matchId, winnerSlot) then
              Bridge.CreditBankByCitizenId(winnerCid, winnerCut, 'fightclub-entry')
              local ws = Bridge.GetSourceByCitizenId(winnerCid)
              if ws then Bridge.Notify(ws, 'Fight Club', ('Match #%d — $%d entry purse.'):format(matchId, winnerCut), 'success') end
          end
          if loserCut > 0 and loserCid then
              if not paidSnap(match, loserSlot) and claimEntry(matchId, loserSlot) then
                  Bridge.CreditBankByCitizenId(loserCid, loserCut, 'fightclub-entry-consolation')
                  local ls2 = Bridge.GetSourceByCitizenId(loserCid)
                  if ls2 then Bridge.Notify(ls2, 'Fight Club', ('Match #%d — $%d consolation.'):format(matchId, loserCut), 'inform') end
              end
          end
      end

      markSettled(matchId)
      dbg(('match #%d settled: winner=%s (%s), pool=%d rake=%d purse=%d forBettors=%d entry_pot=%d')
          :format(matchId, winnerCid, reasonLabel or '?', totalPool, rake, purse, forBettors, entryPot))
  end

  -- Boot reconcile — re-drive any match flipped 'resolved' whose payout never
  -- finished (server died mid-settlement). Idempotent: settleMatch skips every
  -- already-claimed step. Delayed so palm6_dbmigrate's ALTERs (settled/paid/
  -- purse_paid/entry_paid1/2 columns) have landed first.
  local function reconcileUnsettled()
      local pending = {}
      pcall(function()
          pending = MySQL.query.await(
              "SELECT id FROM palm6_fightclub_matches WHERE status = 'resolved' AND settled = 0") or {}
      end)
      for _, row in ipairs(pending) do
          settleMatch(row.id, 'recovered')
      end
      if #pending > 0 then
          print(('[palm6_fightclub] boot reconcile settled %d interrupted payout(s)'):format(#pending))
      end
  end

  -- Server-internal seam — fired AFTER settle so downstream (T5 rep, T10 arena)
  -- sees a fully-paid terminal row. TriggerEvent (NEVER a net event): unspoofable.
  local function fireResolved(matchId, winnerCid, method)
      local row
      pcall(function()
          row = MySQL.single.await([[
              SELECT fighter1_citizenid, fighter2_citizenid,
                     UNIX_TIMESTAMP(live_started_at) AS started_at,
                     UNIX_TIMESTAMP(resolved_at)     AS ended_at,
                     is_pve, cpu_tier
                FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
      end)
      local loserCid = nil
      if row and winnerCid then
          loserCid = (row.fighter1_citizenid == winnerCid) and row.fighter2_citizenid or row.fighter1_citizenid
      end
      TriggerEvent('fc:match:resolved', {
          matchId   = matchId,
          winnerCid = winnerCid,
          loserCid  = loserCid,
          method    = method,
          startedAt = row and tonumber(row.started_at) or nil,
          endedAt   = row and tonumber(row.ended_at) or nil,
          isPve     = row and tonumber(row.is_pve) == 1 or false,
          cpuTier   = row and row.cpu_tier or nil,
      })
  end

  -- Atomic live->resolved flip (winnerCid=nil => draw). settled=0 + rep_awarded=0
  -- mark the row for settlement (this boot) and rep (T5). Reused by ResolveMatch.
  local function resolveLive(matchId, winnerCid, method)
      local marked = false
      pcall(function()
          marked = MySQL.update.await([[
              UPDATE palm6_fightclub_matches
                 SET status = 'resolved', winner_citizenid = ?, method = ?,
                     resolved_at = NOW(), settled = 0, rep_awarded = 0
               WHERE id = ? AND status = 'live']], { winnerCid, method, matchId }) == 1
      end)
      if not marked then return false end
      settleMatch(matchId, method)
      fireResolved(matchId, winnerCid, method)
      return true
  end

  -- Parimutuel tote board broadcast (display-only; settlement is the pool truth).
  local function broadcastOdds(matchId)
      local m
      pcall(function()
          m = MySQL.single.await([[
              SELECT status, GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), betting_ends_at)) AS secs_left
                FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
      end)
      if not m then return end
      local rows = {}
      pcall(function()
          rows = MySQL.query.await([[
              SELECT fighter, COALESCE(SUM(amount),0) AS total, COUNT(*) AS n
                FROM palm6_fightclub_bets WHERE match_id = ? GROUP BY fighter]], { matchId }) or {}
      end)
      local sideA, sideB, betCount = 0, 0, 0
      for _, r in ipairs(rows) do
          betCount = betCount + (tonumber(r.n) or 0)
          if tonumber(r.fighter) == 1 then sideA = tonumber(r.total) or 0
          elseif tonumber(r.fighter) == 2 then sideB = tonumber(r.total) or 0 end
      end
      local secsLeft = (m.status == 'betting') and (tonumber(m.secs_left) or 0) or 0
      TriggerClientEvent('palm6_fightclub:oddsUpdate', -1, {
          matchId = matchId, sideA = sideA, sideB = sideB, betCount = betCount, secsLeft = secsLeft,
      })
  end

  -- ---------------------------------------------------------------------------
  -- Server-only money / lifecycle exports (consumed by T4 debug + T6 combat).
  -- ---------------------------------------------------------------------------

  -- Open a betting-window match row. Does NOT charge antes (caller charges per
  -- spec 10b then unwinds on nil). Returns matchId on success, nil on gate/fail.
  exports('OpenMatch', function(aCid, bCid, styleA, styleB, fighterA, fighterB, entryStake)
      if not fcEnabled() then return nil end
      if not aCid or not bCid then return nil end
      entryStake = math.floor(tonumber(entryStake) or 0)
      if entryStake < 0 then return nil end
      local entryPot     = 2 * entryStake
      local aName, bName = nameForCid(aCid), nameForCid(bCid)
      local mdlA, mdlB   = fighterModel(fighterA), fighterModel(fighterB)
      local ok, matchId = pcall(function()
          return MySQL.insert.await([[
              INSERT INTO palm6_fightclub_matches
                  (fighter1_citizenid, fighter1_name, fighter2_citizenid, fighter2_name,
                   style1, style2, fighter1_model, fighter2_model,
                   status, entry_pot, is_pve, betting_ends_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'betting', ?, 0, NOW() + INTERVAL ? SECOND)
          ]], { aCid, aName, bCid, bName, styleA, styleB, mdlA, mdlB, entryPot, Config.Betting.WindowSec })
      end)
      if not ok or not matchId or matchId == 0 then
          dbg('OpenMatch INSERT failed — caller must refund both antes')
          return nil
      end
      dbg(('OpenMatch #%d: %s vs %s (entry_pot=%d)'):format(matchId, aCid, bCid, entryPot))
      return matchId
  end)

  -- betting -> live (guarded). Closes /fcbet by leaving the 'betting' state.
  exports('GoLive', function(matchId)
      local moved = false
      pcall(function()
          moved = MySQL.update.await(
              "UPDATE palm6_fightclub_matches SET status = 'live', live_started_at = NOW() WHERE id = ? AND status = 'betting'",
              { matchId }) == 1
      end)
      if moved then dbg(('match #%d betting closed — fight is live'):format(matchId)) end
      return moved
  end)

  -- live -> resolved (atomic) + settle + seam. winnerCid=nil => draw.
  exports('ResolveMatch', function(matchId, winnerCid, method)
      return resolveLive(matchId, winnerCid, method or 'ko')
  end)

  -- betting -> resolved(void): abort a match that never went live. Refunds bets +
  -- both antes via settleMatch's draw branch.
  exports('VoidMatch', function(matchId)
      local marked = false
      pcall(function()
          marked = MySQL.update.await([[
              UPDATE palm6_fightclub_matches
                 SET status = 'resolved', winner_citizenid = NULL, method = 'void',
                     resolved_at = NOW(), settled = 0, rep_awarded = 0
               WHERE id = ? AND status = 'betting']], { matchId }) == 1
      end)
      if not marked then return false end
      settleMatch(matchId, 'void')
      fireResolved(matchId, nil, 'void')
      return true
  end)

  -- live -> resolved(void): no-contest a LIVE row (boot strand / mid-match cutover
  -- / preempt). Refunds bets + both antes via the draw branch.
  exports('LiveVoidMatch', function(matchId)
      local marked = false
      pcall(function()
          marked = MySQL.update.await([[
              UPDATE palm6_fightclub_matches
                 SET status = 'resolved', winner_citizenid = NULL, method = 'void',
                     resolved_at = NOW(), settled = 0, rep_awarded = 0
               WHERE id = ? AND status = 'live']], { matchId }) == 1
      end)
      if not marked then return false end
      settleMatch(matchId, 'void')
      fireResolved(matchId, nil, 'void')
      return true
  end)

  exports('BroadcastOdds', function(matchId)
      broadcastOdds(matchId)
  end)

  -- ---------------------------------------------------------------------------
  -- /fcbet <matchid> <1|2> <amount> — spectator wager, guarded atomic claim.
  -- ---------------------------------------------------------------------------
  local function cmdFcBet(src, args)
      if src == 0 then return end
      if not rl(src, 'fcbet') then return end
      if not fcEnabled() then
          Bridge.Notify(src, 'Fight Club', 'Betting is closed.', 'error')
          return
      end
      local cid = Bridge.GetCitizenId(src)
      if not cid then return end

      local matchId = tonumber(args[1])
      local slot    = tonumber(args[2])
      local amount  = math.floor(tonumber(args[3]) or 0)

      if not matchId or (slot ~= 1 and slot ~= 2)
          or amount < Config.Betting.MinBet or amount > Config.Betting.MaxBet then
          Bridge.Notify(src, 'Fight Club',
              ('Usage: /fcbet [match #] [1 or 2] [$%d-%d]')
              :format(Config.Betting.MinBet, Config.Betting.MaxBet), 'error')
          return
      end

      local m
      pcall(function()
          m = MySQL.single.await(
              "SELECT fighter1_citizenid, fighter2_citizenid FROM palm6_fightclub_matches WHERE id = ? AND status = 'betting' AND is_pve = 0",
              { matchId })
      end)
      if not m then
          Bridge.Notify(src, 'Fight Club', 'No open betting window with that match number.', 'error')
          return
      end
      if cid == m.fighter1_citizenid or cid == m.fighter2_citizenid then
          Bridge.Notify(src, 'Fight Club', 'Fighters cannot bet on their own match.', 'error')
          return
      end

      -- Consume-before-grant: take the stake FIRST; refunded on any insert failure.
      if not Bridge.ChargeBank(src, amount, 'fightclub-bet') then
          Bridge.Notify(src, 'Fight Club', ('You need $%d in the bank.'):format(amount), 'error')
          return
      end

      -- Atomic claim: inserts only if the match is STILL betting, is_pve=0, AND the
      -- aggregate pool + this stake stays <= MaxPoolPerMatch — all folded into ONE
      -- statement (no read-then-write TOCTOU). The pool sum reads the bets table
      -- through a DERIVED table (materialized) so MySQL/MariaDB accepts the target
      -- table inside an INSERT...SELECT subquery (a raw self-reference throws error
      -- 1093). 0 disables the cap. UNIQUE(match_id,citizenid) rejects a double bet.
      local maxPool = Config.Betting.MaxPoolPerMatch or 0
      local insOk, insId = pcall(function()
          return MySQL.insert.await([[
              INSERT INTO palm6_fightclub_bets (match_id, citizenid, fighter, amount)
              SELECT ?, ?, ?, ? FROM palm6_fightclub_matches
              WHERE id = ? AND status = 'betting' AND is_pve = 0
                AND (? = 0 OR (
                      SELECT COALESCE(SUM(b.amount), 0)
                      FROM (SELECT amount FROM palm6_fightclub_bets WHERE match_id = ?) AS b
                    ) + ? <= ?)
          ]], { matchId, cid, slot, amount, matchId, maxPool, matchId, amount, maxPool })
      end)
      if not insOk then
          Bridge.CreditBankByCitizenId(cid, amount, 'fightclub-bet-refund')
          Bridge.Notify(src, 'Fight Club', 'You already have a bet on this match.', 'error')
          return
      end
      if not insId or insId == 0 then
          Bridge.CreditBankByCitizenId(cid, amount, 'fightclub-bet-refund')
          Bridge.Notify(src, 'Fight Club', 'Betting just closed, or the match pool cap is full.', 'error')
          return
      end

      Bridge.Notify(src, 'Fight Club',
          ('Bet placed: $%d on fighter %d in match #%d.'):format(amount, slot, matchId), 'success')
      dbg(('bet %d on match #%d fighter %d by %s'):format(amount, matchId, slot, cid))
      broadcastOdds(matchId)
  end

  -- ---------------------------------------------------------------------------
  -- /fcmatches — open board (betting + live), read-only.
  -- ---------------------------------------------------------------------------
  local function cmdFcMatches(src)
      if src == 0 then return end
      if not rl(src, 'fcmatches') then return end
      local rows = {}
      pcall(function()
          rows = MySQL.query.await([[
              SELECT id, status, fighter1_name, fighter2_name,
                     TIMESTAMPDIFF(SECOND, NOW(), betting_ends_at) AS secs_left
              FROM palm6_fightclub_matches
              WHERE status IN ('betting', 'live')
              ORDER BY id DESC LIMIT 20
          ]]) or {}
      end)
      if #rows == 0 then
          Bridge.Reply(src, { 'no open matches — challenge someone at the ring to start one' })
          return
      end
      local lines = {}
      for _, r in ipairs(rows) do
          if r.status == 'betting' then
              local secs = math.max(0, tonumber(r.secs_left) or 0)
              lines[#lines + 1] = ('#%d [BETTING %ds left] 1) %s vs 2) %s — /fcbet %d [1|2] [$]')
                  :format(r.id, secs, r.fighter1_name, r.fighter2_name, r.id)
          else
              lines[#lines + 1] = ('#%d [LIVE] %s vs %s'):format(r.id, r.fighter1_name, r.fighter2_name)
          end
      end
      Bridge.Reply(src, lines)
  end

  -- ---------------------------------------------------------------------------
  -- Commands + boot. /fcjoin, /fcleave, the sweep thread, and the playerDropped
  -- match-resolution are GONE — the lifecycle is owned by palm6_fc_combat (T6).
  -- ---------------------------------------------------------------------------
  Bridge.RegisterCommand('fcbet', function(source, args) cmdFcBet(source, args) end)
  Bridge.RegisterCommand('fcmatches', function(source) cmdFcMatches(source) end)

  AddEventHandler('onResourceStart', function(resource)
      if resource ~= GetCurrentResourceName() then return end
      local openN = 0
      pcall(function()
          local r = MySQL.single.await(
              "SELECT COUNT(*) AS n FROM palm6_fightclub_matches WHERE status IN ('betting', 'live')")
          openN = r and tonumber(r.n) or 0
      end)
      -- Open betting/live rows are NOT auto-resolved here; T6 owns the live-strand
      -- no-contest (LiveVoidMatch) at its own boot. This only reports + recovers
      -- interrupted payouts.
      print(('[palm6_fightclub] money authority up — %d match(es) still open'):format(openN))
      CreateThread(function()
          Wait(8000)
          reconcileUnsettled()
      end)
  end)

  ---Open-match count for devtest and future consumers.
  exports('GetSummary', function()
      local out = { openMatches = 0 }
      pcall(function()
          local r = MySQL.single.await(
              "SELECT COUNT(*) AS n FROM palm6_fightclub_matches WHERE status IN ('betting', 'live')")
          out.openMatches = r and tonumber(r.n) or 0
      end)
      return out
  end)
  ```

- [ ] **Step 4: Parse-gate main.lua.**
  ```bash
  npx luaparse "resources/[custom]/palm6_fightclub/server/main.lua" > /dev/null && echo PARSE_OK
  ```
  Expected stdout: `PARSE_OK` (exit 0, no `SyntaxError`). If it errors, fix the reported line before proceeding — do NOT boot a syntactically broken money resource.

- [ ] **Step 5: Commit the rewire (money change isolated in one commit).** Stage only the two touched files (never `git add -A` in a multi-terminal repo).
  ```bash
  cd C:/Users/Mgtda/Projects/Active/gtarp && \
  git add "resources/[custom]/palm6_fightclub/shared/config.lua" "resources/[custom]/palm6_fightclub/server/main.lua" && \
  git commit -m "$(printf 'palm6_fightclub: rewire to money authority (OpenMatch/GoLive/ResolveMatch/VoidMatch/LiveVoidMatch + entry-pot settle)\n\nDelete queue/sweep/playerDropped-resolution; add guarded lifecycle exports\nand the residual entry-pot payout (no-mint). /fcbet gains is_pve + MaxPool\ncap folded into the atomic insert. Ships gated behind fc_core Config.Enabled.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
  ```
  Expected: commit succeeds, 2 files changed.

- [ ] **Step 6: Boot-verify on the local FXServer (0 SCRIPT ERROR, asserts pass).** Prerequisites on this local boot: (a) `palm6_dbmigrate` (T2) present so `palm6_fightclub_matches`/`_bets` + the new columns (`style1/2`, `fighter1/2_model`, `entry_pot`, `entry_paid1/2`, `method`, `is_pve`, `cpu_tier`, `rep_awarded`, `settled`, `purse_paid`, `paid`) exist; (b) `palm6_fc_core` (T1) present with `Config.Enabled = true` set in `resources/[custom]/palm6_fc_core/config.lua` for this test boot (OpenMatch/`/fcbet` are inert while `Enabled=false`). Start the server and watch the console.
  - Expected: no line containing `SCRIPT ERROR` or `attempt to` for `palm6_fightclub`.
  - Expected: `[palm6_fightclub] money authority up — 0 match(es) still open`.
  - Expected: after ~8s, no reconcile line on a clean DB (or `boot reconcile settled N` if strays existed) — no error either way.
  - The money-safety asserts pass silently (they only halt on a bad config; the negative test is Step 8).

- [ ] **Step 7: Exercise the money path via a TEMP console-only harness, then inspect the DB.** `/fcdebug` is built in T4; for T3 self-verification append a throwaway harness (console `src==0` only) at the END of `server/main.lua` — it can call the in-scope locals. Add via `Edit` (append before the final newline):
  ```lua

  -- ==== TEMP T3 VERIFY — REMOVE before final commit (Step 9) ====
  local function _t3open()
      return exports.palm6_fightclub:OpenMatch('T3_A', 'T3_B', 'brawler', 'brawler', 'house_ace', 'house_ace', 500)
  end
  RegisterCommand('fct3win', function(src)
      if src ~= 0 then return end
      local id = _t3open(); print('[fct3] win OpenMatch ->', tostring(id)); if not id then return end
      print('[fct3] win GoLive ->', tostring(exports.palm6_fightclub:GoLive(id)))
      print('[fct3] win ResolveMatch(ko,A) ->', tostring(exports.palm6_fightclub:ResolveMatch(id, 'T3_A', 'ko')))
  end, true)
  RegisterCommand('fct3void', function(src)
      if src ~= 0 then return end
      local id = _t3open(); print('[fct3] void OpenMatch ->', tostring(id)); if not id then return end
      print('[fct3] void VoidMatch ->', tostring(exports.palm6_fightclub:VoidMatch(id)))
  end, true)
  RegisterCommand('fct3draw', function(src)
      if src ~= 0 then return end
      local id = _t3open(); if not id then print('[fct3] draw open failed'); return end
      exports.palm6_fightclub:GoLive(id)
      print('[fct3] draw ResolveMatch(nil,draw) ->', tostring(exports.palm6_fightclub:ResolveMatch(id, nil, 'draw')))
  end, true)
  RegisterCommand('fct3reconcile', function(src)
      if src ~= 0 then return end
      reconcileUnsettled()   -- in-scope local: verifies idempotent re-drive
  end, true)
  -- ==== END TEMP T3 VERIFY ====
  ```
  Parse it, restart the resource, run the console commands, then inspect the DB:
  ```bash
  npx luaparse "resources/[custom]/palm6_fightclub/server/main.lua" > /dev/null && echo PARSE_OK
  ```
  In the server console: `ensure palm6_fightclub` (or `restart palm6_fightclub`), then run `fct3win`, `fct3void`, `fct3draw`. Then query the local DB:
  ```sql
  SELECT id, status, method, settled, rep_awarded, entry_pot, entry_paid1, entry_paid2, purse_paid
  FROM palm6_fightclub_matches ORDER BY id DESC LIMIT 3;
  ```
  Expected rows (newest first — draw, void, win):
  - **draw:** `status=resolved, method=draw, settled=1, rep_awarded=0, entry_pot=1000, entry_paid1=1, entry_paid2=1, purse_paid=0` (both antes unwound: 500/500).
  - **void:** `status=resolved, method=void, settled=1, entry_pot=1000, entry_paid1=1, entry_paid2=1` (both antes refunded).
  - **win:** `status=resolved, method=ko, settled=1, entry_pot=1000, entry_paid1=1, entry_paid2=0, purse_paid=0` (winner residual = 1000 - 100 rake - 0 loser = 900 credited; loser ante is the rake+residual sink, so `entry_paid2` stays 0). `rep_awarded=0` on all (T5 claims it later) — this is correct, not a bug.
  (Balances go to `T3_A`/`T3_B`, which don't exist in `players`, so the credit UPDATE matches 0 rows without error — this test verifies FLAGS + idempotency + no double-resolve, NOT real balances; real balance credit is David's in-game feel-test.)

- [ ] **Step 8: Prove no-double-resolve + no-mint idempotency, and the fail-closed assert.**
  - **Idempotent re-drive:** note the `win` row's `id`, then in the DB: `UPDATE palm6_fightclub_matches SET settled = 0 WHERE id = <winId>;` and in the console run `fct3reconcile`. Re-query the row — expected UNCHANGED: `settled=1, entry_paid1=1, entry_paid2=0`, no error in console. Confirms `claimEntry`/`claimBet` skip already-claimed steps (a crash-replay never double-pays).
  - **Double-resolve guard:** in the console run `fct3win` twice against the SAME id is not possible (ids differ); instead confirm the guard directly — pick a resolved id and call the export again via a one-off: it returns `false` because the `WHERE status='live'` flip affects 0 rows. (Observe: `ResolveMatch` on an already-resolved row prints/returns `false`.)
  - **Fail-closed assert (negative test):** temporarily set `Config.Fight.EntryPotLoserPct = 0.6` in `shared/config.lua`, `restart palm6_fightclub`. Expected: the script FAILS to start with the console error `money-safety: Config.Fight.EntryPotLoserPct must be < 0.5 (a loss must sting)`. Revert `EntryPotLoserPct` back to `0.0` and confirm it boots clean again.

- [ ] **Step 9: Remove the TEMP harness, re-parse, and final commit.** Delete the entire `-- ==== TEMP T3 VERIFY ... END TEMP T3 VERIFY ====` block from `server/main.lua` (and revert the fc_core `Config.Enabled` back to `false` if this is not a dedicated staging boot — it must ship prod-inert).
  ```bash
  npx luaparse "resources/[custom]/palm6_fightclub/server/main.lua" > /dev/null && echo PARSE_OK
  cd C:/Users/Mgtda/Projects/Active/gtarp && \
  git add "resources/[custom]/palm6_fightclub/server/main.lua" && \
  git commit -m "$(printf 'palm6_fightclub: remove T3 verify harness (money path validated)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
  ```
  Expected: `PARSE_OK`, commit succeeds.

**David feel-test (in-game only — the standing rule; runs once T4 `/fcdebug` + T6 combat exist, on a staging boot with `Config.Enabled=true`):**
1. **Entry purse pays correctly:** two real characters ante $500 each (or via `/fcdebug open` in T4), a spectator places a real `/fcbet`, resolve to a winner — the WINNER's bank rises by the entry residual ($900 at $500 ante / 10% rake / 0% loser) PLUS the betting purse+winnings; the loser's ante is gone; a losing bettor loses their stake.
2. **Void/draw fully unwinds:** open a match, void it before it goes live (T6 abort) — BOTH fighters get their $500 back and every spectator bet is refunded; nobody nets a change.
3. **No double-pay on restart:** immediately after a resolve, `restart palm6_fightclub` — the winner is NOT paid twice and no bet is re-credited (boot reconcile is a no-op on the already-settled row).
4. **Cap + own-match guards:** a fighter cannot `/fcbet` on their own match; the pool stops accepting bets once `MaxPoolPerMatch` ($50k) would be exceeded; `/fcbet` is refused entirely while the feature is `Enabled=false`.

---

### Task 4: Ace-gated /fcdebug stub commands (open/live/resolve/void) — makes betting/progression/HUD testable before fc_combat exists

Adds a dev-only console/admin command that drives the match lifecycle by calling the Task-3 money exports directly. This is the stub OPEN/ADVANCE spec §14 requires so T5 (progression), T3 (betting/settlement), and T9 (HUD) are exercisable long before T6 combat exists. It ships as an isolated new file (`server/debug.lua`) so it does **not** collide with T3's rewrite of `server/main.lua`.

**Files:**
- CREATE `resources/[custom]/palm6_fightclub/server/debug.lua`
- MODIFY `resources/[custom]/palm6_fightclub/fxmanifest.lua` (load `server/debug.lua` AFTER `server/main.lua`)
- MODIFY `resources/[custom]/palm6_fightclub/shared/config.lua` (add `fcdebug` to `Config.RateLimits`)
- (NOT touched by this task) `custom.cfg` — the `add_ace group.admin palm6_fc.debug allow` grant is **T11's** job; console (src==0) bypasses the ace so T4 is fully self-testable without it.

**Interfaces:**
- **Consumes (T3 server-only exports, exact signatures — self-calls within the same resource via `exports.palm6_fightclub:*`):**
  - `exports.palm6_fightclub:OpenMatch(aCid, bCid, styleA, styleB, fighterA, fighterB, entryStake)` → `matchId:int` | `nil`
  - `exports.palm6_fightclub:GoLive(matchId)` → `bool`
  - `exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method)` → `bool`
  - `exports.palm6_fightclub:VoidMatch(matchId)` → `bool`
- **Consumes (T1 fc_core):** `exports.palm6_fc_core:Config()` → reads `.DefaultStyle` (`'brawler'`), `.DefaultFighter` (`'house_ace'`). Guarded by pcall with literal fallbacks so the stub still runs if fc_core is momentarily down.
- **Consumes (globals already in this resource's Lua state):** `Bridge.GetSourceByCitizenId(cid)`, `Bridge.ChargeBank(src, amt, reason)`, `Bridge.CreditBankByCitizenId(cid, amt, reason)`, `Bridge.Reply(src, lines)` (all from `bridge/sv_framework.lua`); `Config.Fight.EntryStake`, `Config.Betting.WindowSec`, `Config.RateLimits.fcdebug` (from `shared/config.lua`). Native `IsPlayerAceAllowed(src, ace)`.
- **Produces:** the command `fcdebug` (registered raw via `RegisterCommand('fcdebug', handler, false)`, ace-gated **inside** the handler — NOT `Bridge.RegisterCommand`, per §14); the ace name `palm6_fc.debug` (T11 wires the grant into `custom.cfg`); `Config.RateLimits.fcdebug`.

Money-safety note carried through every step: `/fcdebug open` is the ONLY subcommand that charges (charges BOTH antes before calling `OpenMatch`, §10b). If `OpenMatch` returns `nil` **or throws** (partial-rollout: export missing), BOTH antes are refunded. The export call is pcall-wrapped precisely so a throw after the charge can never strand the antes.

- [ ] **Step 1: Write `server/debug.lua` (complete file).**
  Create `resources/[custom]/palm6_fightclub/server/debug.lua` with exactly this content:
  ```lua
  -- ============================================================================
  -- palm6_fightclub/server/debug.lua
  --
  -- Ace-gated dev harness (spec §14). Drives the match lifecycle by calling the
  -- money exports from server/main.lua (OpenMatch/GoLive/ResolveMatch/VoidMatch)
  -- so betting (T3), progression (T5) and the HUD (T9) are exercisable BEFORE
  -- fc_combat (T6) exists. Isolated in its own file so it never conflicts with
  -- main.lua's rewrite.
  --
  -- Gating: NOT Bridge.RegisterCommand (which would leave restricted=false and
  -- rely on nothing) — registered raw and gated in-handler with IsPlayerAceAllowed
  -- against 'palm6_fc.debug'. Server console (src == 0) always passes the gate
  -- (it also has no ped, so it never charges antes — the two fighter cids do).
  --
  -- ONLY /fcdebug open moves money: it charges BOTH antes up front (§10b) and
  -- refunds BOTH if OpenMatch returns nil OR throws. The export call is pcall-
  -- wrapped so a throw after the charge can never strand the antes.
  -- ============================================================================

  local FC_ACE = 'palm6_fc.debug'

  -- Self-contained rate-limit (main.lua's rl() is a file-local, not visible here).
  local lastDebug = {}
  local function drl(src)
      local window = (Config.RateLimits and Config.RateLimits.fcdebug) or 1
      local t = os.time()
      if (lastDebug[src] or 0) + window > t then return false end
      lastDebug[src] = t
      return true
  end

  -- Default style/fighter live in fc_core (config authority). pcall-guarded with
  -- literal fallbacks so the stub still opens matches if fc_core is momentarily
  -- unstarted (boot-order race / isolated testing).
  local function debugDefaults()
      local styleDef, fighterDef = 'brawler', 'house_ace'
      local ok, core = pcall(function() return exports.palm6_fc_core:Config() end)
      if ok and type(core) == 'table' then
          styleDef   = core.DefaultStyle   or styleDef
          fighterDef = core.DefaultFighter or fighterDef
      end
      return styleDef, fighterDef
  end

  -- /fcdebug open <cidA> <cidB>
  local function subOpen(src, args)
      local cidA, cidB = args[2], args[3]
      if not cidA or not cidB then
          Bridge.Reply(src, { 'usage: /fcdebug open <cidA> <cidB>' })
          return
      end
      if cidA == cidB then
          Bridge.Reply(src, { 'fighters must be two different citizenids' })
          return
      end

      local stake = Config.Fight.EntryStake or 0

      -- Charge-before-grant (§10b). Antes come from the two fighter cids, never
      -- the invoker. Both must be online to be charged; refund A if B can't pay.
      if stake > 0 then
          local srcA = Bridge.GetSourceByCitizenId(cidA)
          local srcB = Bridge.GetSourceByCitizenId(cidB)
          if not srcA then
              Bridge.Reply(src, { ('cidA %s is offline — cannot charge the $%d ante'):format(cidA, stake) })
              return
          end
          if not srcB then
              Bridge.Reply(src, { ('cidB %s is offline — cannot charge the $%d ante'):format(cidB, stake) })
              return
          end
          if not Bridge.ChargeBank(srcA, stake, 'fightclub-entry') then
              Bridge.Reply(src, { ('cidA %s cannot cover the $%d ante'):format(cidA, stake) })
              return
          end
          if not Bridge.ChargeBank(srcB, stake, 'fightclub-entry') then
              Bridge.CreditBankByCitizenId(cidA, stake, 'fightclub-entry-refund')
              Bridge.Reply(src, { ('cidB %s cannot cover the $%d ante — refunded cidA'):format(cidB, stake) })
              return
          end
      end

      local styleDef, fighterDef = debugDefaults()
      local ok, matchId = pcall(function()
          return exports.palm6_fightclub:OpenMatch(cidA, cidB, styleDef, styleDef, fighterDef, fighterDef, stake)
      end)

      -- nil return (INSERT-fail) OR throw (export missing during rollout): refund
      -- BOTH antes — mirrors OpenMatch's own both-ante refund contract.
      if not ok or not matchId then
          if stake > 0 then
              Bridge.CreditBankByCitizenId(cidA, stake, 'fightclub-entry-refund')
              Bridge.CreditBankByCitizenId(cidB, stake, 'fightclub-entry-refund')
          end
          Bridge.Reply(src, { ('OpenMatch failed (%s) — both antes refunded')
              :format(ok and 'INSERT returned nil' or 'export threw') })
          return
      end

      Bridge.Reply(src, { ('opened match #%d: %s vs %s (style=%s fighter=%s stake $%d, betting %ds)')
          :format(matchId, cidA, cidB, styleDef, fighterDef, stake, Config.Betting.WindowSec) })
  end

  -- /fcdebug live <matchId>
  local function subLive(src, args)
      local matchId = tonumber(args[2])
      if not matchId then Bridge.Reply(src, { 'usage: /fcdebug live <matchId>' }); return end
      local ok, res = pcall(function() return exports.palm6_fightclub:GoLive(matchId) end)
      if not ok then Bridge.Reply(src, { 'GoLive threw (is T3 merged?)' }); return end
      Bridge.Reply(src, { res
          and ('match #%d -> LIVE (betting closed)'):format(matchId)
          or  ('match #%d not in betting state — no-op'):format(matchId) })
  end

  -- /fcdebug resolve <matchId> <winnerCid>
  local function subResolve(src, args)
      local matchId = tonumber(args[2])
      local winnerCid = args[3]
      if not matchId or not winnerCid then
          Bridge.Reply(src, { 'usage: /fcdebug resolve <matchId> <winnerCid>' })
          return
      end
      local ok, res = pcall(function() return exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, 'ko') end)
      if not ok then Bridge.Reply(src, { 'ResolveMatch threw (is T3 merged?)' }); return end
      Bridge.Reply(src, { res
          and ('match #%d -> RESOLVED, winner %s (method=ko), settled'):format(matchId, winnerCid)
          or  ('match #%d not live — no-op'):format(matchId) })
  end

  -- /fcdebug void <matchId>
  local function subVoid(src, args)
      local matchId = tonumber(args[2])
      if not matchId then Bridge.Reply(src, { 'usage: /fcdebug void <matchId>' }); return end
      local ok, res = pcall(function() return exports.palm6_fightclub:VoidMatch(matchId) end)
      if not ok then Bridge.Reply(src, { 'VoidMatch threw (is T3 merged?)' }); return end
      Bridge.Reply(src, { res
          and ('match #%d -> VOID (betting aborted, bets refunded)'):format(matchId)
          or  ('match #%d not in betting state — no-op'):format(matchId) })
  end

  RegisterCommand('fcdebug', function(src, args)
      -- Ace gate FIRST line (§14). Console (src == 0) bypasses the gate.
      if src ~= 0 and not IsPlayerAceAllowed(src, FC_ACE) then return end
      if src ~= 0 and not drl(src) then return end

      local sub = args[1]
      if sub == 'open' then
          subOpen(src, args)
      elseif sub == 'live' then
          subLive(src, args)
      elseif sub == 'resolve' then
          subResolve(src, args)
      elseif sub == 'void' then
          subVoid(src, args)
      else
          Bridge.Reply(src, {
              'fcdebug (ace: palm6_fc.debug) — dev lifecycle driver:',
              '  open <cidA> <cidB>        open a betting match (charges both antes)',
              '  live <matchId>            close betting -> LIVE',
              '  resolve <matchId> <cid>   resolve LIVE -> winner cid (method=ko)',
              '  void <matchId>            abort a BETTING match (refund bets)',
          })
      end
  end, false)
  ```

- [ ] **Step 2: Parse-gate `debug.lua`.**
  Run (Bash tool):
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && npx luaparse "resources/[custom]/palm6_fightclub/server/debug.lua" > /dev/null && echo PARSE_OK
  ```
  Expected output: `PARSE_OK` (exit 0, no `SyntaxError`). If luaparse errors, fix the reported line before continuing. No Lua 5.4-only syntax is used (no `//`, no bitwise ops), so default luaparse accepts it.

- [ ] **Step 3: Load `debug.lua` in the manifest AFTER `main.lua`.**
  In `resources/[custom]/palm6_fightclub/fxmanifest.lua`, change the `server_scripts` block so `server/debug.lua` is the last entry (the exports it calls are registered by `server/main.lua`, which must load first). Replace:
  ```lua
  server_scripts {
      '@oxmysql/lib/MySQL.lua',
      'shared/config.lua',
      'bridge/sv_framework.lua',  -- framework adapter — before server logic
      'server/main.lua',
  }
  ```
  with:
  ```lua
  server_scripts {
      '@oxmysql/lib/MySQL.lua',
      'shared/config.lua',
      'bridge/sv_framework.lua',  -- framework adapter — before server logic
      'server/main.lua',
      'server/debug.lua',         -- ace-gated /fcdebug harness — AFTER main (uses its exports)
  }
  ```
  Then parse-gate the manifest:
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && npx luaparse "resources/[custom]/palm6_fightclub/fxmanifest.lua" > /dev/null && echo PARSE_OK
  ```
  Expected: `PARSE_OK`.

- [ ] **Step 4: Add the `fcdebug` rate limit to `shared/config.lua`.**
  In `resources/[custom]/palm6_fightclub/shared/config.lua`, in the `Config.RateLimits` table, add the `fcdebug` key. Replace:
  ```lua
  Config.RateLimits = {
      fcjoin    = 3,
      fcleave   = 2,
      fcbet     = 2,
      fcmatches = 2,
  }
  ```
  with:
  ```lua
  Config.RateLimits = {
      fcjoin    = 3,
      fcleave   = 2,
      fcbet     = 2,
      fcmatches = 2,
      fcdebug   = 1,   -- dev harness throttle (per-src; console src==0 bypasses)
  }
  ```
  (Leave `fcjoin`/`fcleave`/`fcmatches` keys in place — T3 owns removing the dead ones; T4 must not touch them, to avoid a merge conflict.)
  Then parse-gate:
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && npx luaparse "resources/[custom]/palm6_fightclub/shared/config.lua" > /dev/null && echo PARSE_OK
  ```
  Expected: `PARSE_OK`.

- [ ] **Step 5: Boot-verify the resource still loads with 0 SCRIPT ERROR (standalone gate — does NOT need T3 merged).**
  Start the local FXServer that runs `custom.cfg` (the resource ensures at `custom.cfg:108`). In the server console watch the `palm6_fightclub` startup lines. Then, in the server console (src == 0, bypasses the ace), type:
  ```
  fcdebug
  ```
  Expected console output (the help, proving the command registered and the handler runs):
  ```
  [palm6_fightclub] fcdebug (ace: palm6_fc.debug) — dev lifecycle driver:
  [palm6_fightclub]   open <cidA> <cidB>        open a betting match (charges both antes)
  [palm6_fightclub]   live <matchId>            close betting -> LIVE
  [palm6_fightclub]   resolve <matchId> <cid>   resolve LIVE -> winner cid (method=ko)
  [palm6_fightclub]   void <matchId>            abort a BETTING match (refund bets)
  ```
  Gate: `palm6_fightclub` loads, no `SCRIPT ERROR` mentioning `debug.lua`, help prints. (If T3 is not yet merged, `open/live/resolve/void` will report `... threw (is T3 merged?)` — that is expected and still proves the pcall guards work; the lifecycle exercise is Steps 6-7.)

- [ ] **Step 6: Stub-exercise the LIFECYCLE with zero-stake matches (requires T3 exports; needs no online/funded chars).**
  Temporarily set `Config.Fight.EntryStake = 0` (T3's key) OR just accept the default and use the money path in Step 7 — the zero-stake path lets you drive the state machine with placeholder cids so T5/T9 can be built against real rows. With `EntryStake = 0`, in the server console:
  ```
  fcdebug open TESTCID_A TESTCID_B
  ```
  Expected: `[palm6_fightclub] opened match #<N> ... stake $0, betting 60s`. Note the `#N`.
  Then verify the row (via your DB client / oxmysql console — the same DB `custom.cfg` points at):
  ```sql
  SELECT id, status, entry_pot, entry_paid1, entry_paid2, settled, rep_awarded,
         method, winner_citizenid, is_pve, style1, fighter1_model
    FROM palm6_fightclub_matches ORDER BY id DESC LIMIT 1;
  ```
  Expected: `status='betting'`, `entry_pot=0`, `settled=1` (column default; protects pre-deploy history), `rep_awarded=1` (default), `method=NULL`, `winner_citizenid=NULL`, `is_pve=0`, `style1='brawler'`, `fighter1_model` non-null (proves OpenMatch set the new columns).
  Advance:
  ```
  fcdebug live <N>
  ```
  Expected reply `match #<N> -> LIVE`; DB now `status='live'`, `live_started_at` set.
  Resolve to a winner (use `TESTCID_A` so a valid winner slot is chosen):
  ```
  fcdebug resolve <N> TESTCID_A
  ```
  Expected reply `match #<N> -> RESOLVED, winner TESTCID_A (method=ko), settled`; DB now `status='resolved'`, `winner_citizenid='TESTCID_A'`, `method='ko'`, `settled=1` (settleMatch ran markSettled), `rep_awarded=0` (so T5 progression can claim it later).
  **Double-resolve safety:** run `fcdebug resolve <N> TESTCID_A` AGAIN. Expected reply `match #<N> not live — no-op` and the DB row is byte-for-byte unchanged (the guarded `WHERE status='live'` UPDATE affects 0 rows → no re-settle, no double-pay). Restore `Config.Fight.EntryStake` to its T3 value (500) afterward.

- [ ] **Step 7: Stub-exercise the MONEY path + void refund (requires T3 exports, two ONLINE funded characters).**
  With `Config.Fight.EntryStake = 500` (T3 default), connect two test characters and note their citizenids (cidA, cidB — from `players` table or txAdmin). In the server console:
  ```
  fcdebug open <cidA> <cidB>
  ```
  Expected: both characters' bank balances drop by $500 (charge-before-grant); reply `opened match #<N> ... stake $500`. DB: `entry_pot=1000`.
  **Ante-refund-on-abort:** immediately void the betting match:
  ```
  fcdebug void <N>
  ```
  Expected reply `match #<N> -> VOID (betting aborted, bets refunded)`; DB row `status='resolved'`, `method='void'`, `winner_citizenid=NULL`, `settled=1`, `entry_paid1=1`, `entry_paid2=1`; **both fighters' banks are back to their original balance** (draw-branch settle refunded each half of `entry_pot`). Net money delta across the whole open→void cycle = $0 (no mint, no stranded ante).
  **Offline-ante guard:** run `fcdebug open <cidA> OFFLINE_CID` — expected reply `cidB OFFLINE_CID is offline — cannot charge the $500 ante` and cidA's bank is unchanged (refused before any charge).
  **Full payout path:** open a fresh match, place a bettor's wager with the real (T3) command from a third character `/fcbet <N> 1 200`, `fcdebug live <N>`, then `fcdebug resolve <N> <cidA>`. Expected: winner cidA receives the entry-pot residual cut + the winner purse, the bettor on fighter 1 collects the parimutuel share, and DB shows `settled=1`, `purse_paid=1`, `entry_paid<winnerSlot>=1`. Confirm no negative/duplicate credits by re-running the SELECT and re-issuing the resolve (must be `not live — no-op`).

- [ ] **Step 8: David in-game feel-test (the standing rule — in-game is the only gate for these).**
  Note for David to verify once T11 has wired `add_ace group.admin palm6_fc.debug allow` into `custom.cfg`:
  1. As an admin character in-game, `/fcdebug` (no args) shows the help in chat; as a NON-admin character `/fcdebug` does nothing (silent return — the ace gate holds, no error, no leak).
  2. Drive a real `open → live → resolve` on two live characters and confirm the on-screen ox_lib notifications land correctly: both fighters see the match-open notify, the winner sees the purse/win notify, the loser sees the loss notify, and any bettor sees their collect/refund notify (this is the end-to-end money-UX path T3 produces, surfaced through the stub before combat exists).
  3. `void` a betting match with a live bettor and confirm the bettor visibly gets their stake back (draw-refund notify), and both fighters get their antes back.

- [ ] **Step 9: Commit.**
  ```
  cd "C:/Users/Mgtda/Projects/Active/gtarp" && git add "resources/[custom]/palm6_fightclub/server/debug.lua" "resources/[custom]/palm6_fightclub/fxmanifest.lua" "resources/[custom]/palm6_fightclub/shared/config.lua" && git commit -m "$(cat <<'EOF'
palm6_fightclub: ace-gated /fcdebug lifecycle harness (open/live/resolve/void)

Dev-only stub (spec §14) that drives the match state machine via the T3 money
exports so betting, progression, and the HUD are exercisable before fc_combat
exists. Registered raw + gated in-handler on IsPlayerAceAllowed('palm6_fc.debug');
console (src==0) bypasses. Only `open` moves money: charges both antes up front
and refunds both if OpenMatch returns nil or throws (pcall-guarded so a rollout
gap can never strand antes). Isolated in server/debug.lua to avoid conflicting
with main.lua's rewrite. Ace grant is wired by T11.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```
  Expected: one commit containing the three files. (Do not stage `custom.cfg` — the ace grant belongs to T11.)

---

### Task 5: palm6_fc_progression — rep award on the seam + anti-farm + boot reconcile

New **server-only** resource `resources/[custom]/palm6_fc_progression/`. It listens on the server-internal seam `fc:match:resolved` (fired by T3's `ResolveMatch`/`VoidMatch`/`LiveVoidMatch` after `settleMatch`), atomically claims `rep_awarded` on the match row (mirroring fightclub's `claimBet`/`purse_paid` claim-before-credit idiom), credits **display/rank rep only (never cash — no `Bridge.ChargeBank`/`CreditBank` here)**, and gates rep behind four stacked anti-farm bounds. All reads are DB-authoritative (the seam payload is never trusted for the money-adjacent gates). Testable NOW: `/fcdebug open → live → resolve` (T4) drives T3's `ResolveMatch`, which fires the seam this task consumes.

**Files:**
- create `resources/[custom]/palm6_fc_progression/fxmanifest.lua`
- create `resources/[custom]/palm6_fc_progression/bridge/sv_framework.lua`
- create `resources/[custom]/palm6_fc_progression/server/main.lua`

**Interfaces:**
- **Consumes** (server-internal event, `AddEventHandler` — NEVER `RegisterNetEvent`): `fc:match:resolved` = `{ matchId, winnerCid, loserCid, method, startedAt, endedAt, isPve, cpuTier }` (T3/T6). Payload used only to trigger; winner/loser/method/is_pve re-read from `palm6_fightclub_matches` for authority.
- **Consumes** (export, both realms): `exports.palm6_fc_core:Config()` → reads `.RepPerPvpWin` (=100), `.Rep.RepCooldownSec` (=3600), `.Rep.DailyRepCap` (=5), `.Rep.DailyDistinctOpponentCap` (=4), `.Rep.LoserConsolation` (=0) (T1).
- **Consumes** (DB tables, created by T2 in `palm6_dbmigrate`): `palm6_fightclub_matches` (with `rep_awarded TINYINT DEFAULT 1`, `is_pve TINYINT DEFAULT 0`, `method VARCHAR(16)`, `winner_citizenid`, `resolved_at`), `palm6_fc_progression (citizenid PK, rep, wins, losses, rank_tier, updated_at)`, `palm6_fc_unlocks (citizenid, unlock_id, UNIQUE)`, `palm6_fc_daily (citizenid, day_bucket, pvp_rep_wins, pve_rep_wins, distinct_opponents, PK(citizenid,day_bucket))`.
- **Produces** (server-only exports, consumed by T9 HUD career panel + future): `exports('GetRep', function(citizenid) → int end)`, `exports('GetRank', function(citizenid) → int end)`, `exports('HasUnlock', function(citizenid, unlockId) → bool end)`.

**PRECONDITION (parallel-author note):** T2's `STATEMENTS` (base fc tables + the `rep_awarded`/`is_pve`/`method` ALTERs + `palm6_fc_progression`/`palm6_fc_unlocks`/`palm6_fc_daily` CREATEs) must be present in `palm6_dbmigrate/server.lua`, and `palm6_dbmigrate` must boot before this resource's 8s reconcile fires (it always does: dbmigrate applies at boot+3s, this reconcile runs at boot+8s). If T2 is not yet merged when you boot-verify, the `rep_awarded` claim UPDATE errors (pcall-swallowed) → no rep, silent. Confirm the columns exist first (Step 4 does this).

---

- [ ] **Step 1: create the fxmanifest (server-only, deps declare load order)**
  Write `resources/[custom]/palm6_fc_progression/fxmanifest.lua`. Server-only like `palm6_fightclub` — no `shared_scripts`/`client_scripts` block, nothing ships to clients. `dependencies` forces `palm6_fc_core` (for `exports.palm6_fc_core:Config()`) and `palm6_fightclub` (for the seam + tables) to be started first.
  ```lua
  fx_version 'cerulean'
  game 'gta5'
  lua54 'yes'

  author 'EvThatGuy'
  version '0.1.0'
  description 'palm6 fc_progression — rep/rank/unlock ledger for the fight club (claim-before-credit, anti-farm, cash-neutral)'

  -- Server-only on purpose: rep is a server-authoritative ledger with no client
  -- surface (palm6_fightclub / palm6_bounty precedent). Nothing here ships to
  -- clients, so nothing a modified client can abuse.
  server_scripts {
      '@oxmysql/lib/MySQL.lua',
      'bridge/sv_framework.lua',  -- framework adapter — before server logic
      'server/main.lua',
  }

  dependencies {
      'ox_lib',
      'oxmysql',
      'qbx_core',
      'palm6_fc_core',
      'palm6_fightclub',
  }
  ```
  Verify: `npx --yes luaparse "resources/[custom]/palm6_fc_progression/fxmanifest.lua"` — expected: prints the AST JSON and exits 0 (fxmanifest is valid Lua). A `SyntaxError: [line:col]` means fix it.

- [ ] **Step 2: create the bridge clone (minimal — only what rep needs)**
  Write `resources/[custom]/palm6_fc_progression/bridge/sv_framework.lua`. Trimmed clone of `palm6_fightclub/bridge/sv_framework.lua` — rep pays no cash, so it needs only citizenid→source resolution and the ox_lib toast. Keep the same `getPlayer` pcall guard so a bad `src` never throws.
  ```lua
  -- ============================================================================
  -- palm6_fc_progression/bridge/sv_framework.lua
  -- Framework adapter (server). The ONLY file here that calls qbx_core / natives.
  -- server/main.lua calls Bridge.* only (§6 gate) — ports to VI by rewriting this.
  -- Rep is a cash-neutral ledger, so NO money functions are bridged here.
  -- ============================================================================
  Bridge = {}

  local function getPlayer(src)
      local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
      return ok and p or nil
  end

  -- Server source for an online character, or nil (offline winner just gets no toast).
  function Bridge.GetSourceByCitizenId(citizenid)
      for _, src in ipairs(GetPlayers()) do
          src = tonumber(src)
          local p = getPlayer(src)
          if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
              return src
          end
      end
      return nil
  end

  -- Notify a player (ox_lib toast).
  function Bridge.Notify(src, title, msg, t)
      TriggerClientEvent('ox_lib:notify', src, {
          title = title, description = msg, type = t or 'inform',
      })
  end
  ```
  Verify: `npx --yes luaparse "resources/[custom]/palm6_fc_progression/bridge/sv_framework.lua"` — expected: AST JSON, exit 0.

- [ ] **Step 3: write the complete server logic (config load, ledger, anti-farm, seam handler, boot reconcile, exports)**
  Write `resources/[custom]/palm6_fc_progression/server/main.lua` with the full file below. Key money-safety properties preserved: (1) atomic `rep_awarded 0→1` claim BEFORE any credit, guarded by `is_pve=0` (§9 CRITICAL — the PvE §19.5 path owns `is_pve=1` rows and must never be claimed here); (2) reserved `'__'`-prefix winner cids hard-rejected (defense-in-depth vs a mis-plumbed CPU seam); (3) no rep on `forfeit`/`draw`/`void`; (4) same-opponent 1h cooldown + rolling-24h daily rep cap + rolling-24h distinct-opponent cap, all read straight off `palm6_fightclub_matches.resolved_at` (true rolling window — no UTC-midnight straddle exploit, per spec §9); (5) shared `palm6_fc_daily` counter incremented BEFORE the rep credit (crash biases against the grinder, never past the cap); (6) rep is never cash.
  ```lua
  -- ============================================================================
  -- palm6_fc_progression/server/main.lua
  --
  -- Rep / rank / unlock ledger for the fight club. Consumes the server-internal
  -- seam fc:match:resolved (fired by palm6_fightclub after settleMatch). Rep is
  -- DISPLAY/RANK ONLY — it pays no cash and unlocks only cosmetic/name variants
  -- (styles are stat-identical, §8/§9), so farm->money is severed at the source.
  --
  -- Money-safety idioms mirror palm6_fightclub's settleMatch:
  --   * atomic claim-before-credit: UPDATE ... SET rep_awarded=1 WHERE
  --     rep_awarded=0 AND is_pve=0 (affected==1 gates) — exactly one award ever.
  --   * a crash in the claim->credit window strands ONE award (never double-pays).
  --   * boot reconcile re-drives status='resolved' AND rep_awarded=0 rows.
  -- The is_pve=0 gate is load-bearing: PvP (this file) and the PvE §19.5 path
  -- share ONE seam + ONE rep_awarded column; without it a CPU win would mint the
  -- full RepPerPvpWin past every cap and try to credit the '__CPU__' sentinel.
  -- ============================================================================

  -- Rank bands (rep -> rank_tier). Resource-internal + tunable in feel-test; rep
  -- is cash-neutral so these bands only drive the HUD career badge (T9).
  local RANK_THRESHOLDS = { 300, 800, 1600, 3000, 5000 }

  -- Config (from fc_core, isolated Lua state -> read via export). Cached on first
  -- award; loadConf is idempotent and cheap.
  local RepPerPvpWin, RepCooldownSec, DailyRepCap, DailyDistinctOpponentCap, LoserConsolation

  local function loadConf()
      local ok, FC = pcall(function() return exports.palm6_fc_core:Config() end)
      if not ok or type(FC) ~= 'table' then
          -- fc_core not up yet: fall back to the spec anchors so a claim never
          -- silently no-ops on missing config (still cash-neutral).
          RepPerPvpWin, RepCooldownSec = 100, 3600
          DailyRepCap, DailyDistinctOpponentCap, LoserConsolation = 5, 4, 0
          return
      end
      local R = FC.Rep or {}
      RepPerPvpWin             = tonumber(FC.RepPerPvpWin) or 100
      RepCooldownSec           = tonumber(R.RepCooldownSec) or 3600
      DailyRepCap              = tonumber(R.DailyRepCap) or 5
      DailyDistinctOpponentCap = tonumber(R.DailyDistinctOpponentCap) or 4
      LoserConsolation         = tonumber(R.LoserConsolation) or 0
  end

  local function dbg(msg)
      print('[palm6_fc_progression] ' .. msg)
  end

  -- Reserved sentinel guard: reject any non-string cid or a '__'-prefixed cid
  -- (e.g. '__CPU__') so a mis-plumbed seam can never create a phantom row.
  local function isReserved(cid)
      return type(cid) ~= 'string' or cid == '' or cid:sub(1, 2) == '__'
  end

  local function rankForRep(rep)
      rep = tonumber(rep) or 0
      local tier = 0
      for i = 1, #RANK_THRESHOLDS do
          if rep >= RANK_THRESHOLDS[i] then tier = i else break end
      end
      return tier
  end

  local function scalarCount(sql, params)
      local n = 0
      pcall(function()
          local r = MySQL.single.await(sql, params)
          if r then n = tonumber(r.n) or 0 end
      end)
      return n
  end

  -- ---------------------------------------------------------------------------
  -- Ledger writers (upsert; row may not exist yet)
  -- ---------------------------------------------------------------------------
  local function bumpWin(cid)
      pcall(function()
          MySQL.insert.await([[
              INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
              VALUES (?, 0, 1, 0, 0)
              ON DUPLICATE KEY UPDATE wins = wins + 1
          ]], { cid })
      end)
  end

  local function bumpLoss(cid)
      pcall(function()
          MySQL.insert.await([[
              INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
              VALUES (?, 0, 0, 1, 0)
              ON DUPLICATE KEY UPDATE losses = losses + 1
          ]], { cid })
      end)
  end

  -- rep += amount, then recompute rank_tier off the new total.
  local function addRep(cid, amount)
      if not amount or amount <= 0 then return end
      pcall(function()
          MySQL.insert.await([[
              INSERT INTO palm6_fc_progression (citizenid, rep, wins, losses, rank_tier)
              VALUES (?, ?, 0, 0, 0)
              ON DUPLICATE KEY UPDATE rep = rep + VALUES(rep)
          ]], { cid, amount })
      end)
      local newRep = amount
      pcall(function()
          local r = MySQL.single.await("SELECT rep FROM palm6_fc_progression WHERE citizenid = ?", { cid })
          if r then newRep = tonumber(r.rep) or amount end
      end)
      pcall(function()
          MySQL.update.await("UPDATE palm6_fc_progression SET rank_tier = ? WHERE citizenid = ?",
              { rankForRep(newRep), cid })
      end)
  end

  -- Shared cross-mode daily counter (contract-mandated for the future PvE path).
  -- Incremented BEFORE the rep credit so a crash biases against the grinder.
  local function bumpDaily(winnerCid)
      pcall(function()
          MySQL.insert.await([[
              INSERT INTO palm6_fc_daily (citizenid, day_bucket, pvp_rep_wins, pve_rep_wins, distinct_opponents)
              VALUES (?, ?, 1, 0, 0)
              ON DUPLICATE KEY UPDATE pvp_rep_wins = pvp_rep_wins + 1
          ]], { winnerCid, os.date('!%Y-%m-%d') })
      end)
  end

  -- ---------------------------------------------------------------------------
  -- Anti-farm reads — all off palm6_fightclub_matches.resolved_at (true rolling
  -- window; the current match is excluded by id, since we already claimed it
  -- rep_awarded=1 before these run).
  -- ---------------------------------------------------------------------------
  local function wonAgainstWithin(matchId, winnerCid, loserCid, seconds)
      local row
      pcall(function()
          row = MySQL.single.await([[
              SELECT id FROM palm6_fightclub_matches
               WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
                 AND winner_citizenid = ?
                 AND (fighter1_citizenid = ? OR fighter2_citizenid = ?)
                 AND resolved_at >= (NOW() - INTERVAL ? SECOND)
               LIMIT 1
          ]], { matchId, winnerCid, loserCid, loserCid, seconds })
      end)
      return row ~= nil
  end

  -- Returns (repAmount, reason). repAmount==0 => capped (reason logged/notified).
  local function repToAward(matchId, winnerCid, loserCid)
      -- (b) same-opponent 1h cooldown
      if wonAgainstWithin(matchId, winnerCid, loserCid, RepCooldownSec) then
          return 0, 'cooldown'
      end
      -- (d) daily rep cap — rolling 24h count of this winner's rep-granted PvP wins
      local wins24 = scalarCount([[
          SELECT COUNT(*) AS n FROM palm6_fightclub_matches
           WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
             AND winner_citizenid = ?
             AND resolved_at >= (NOW() - INTERVAL 24 HOUR)
      ]], { matchId, winnerCid })
      if wins24 >= DailyRepCap then return 0, 'daily-cap' end
      -- (d) distinct-opponent cap — only blocks a NEW opponent (a re-beat inside
      -- 24h is already governed by wins24 above).
      if not wonAgainstWithin(matchId, winnerCid, loserCid, 86400) then
          local distinctOpp = scalarCount([[
              SELECT COUNT(DISTINCT CASE WHEN fighter1_citizenid = ?
                          THEN fighter2_citizenid ELSE fighter1_citizenid END) AS n
                FROM palm6_fightclub_matches
               WHERE id <> ? AND status = 'resolved' AND is_pve = 0 AND rep_awarded = 1
                 AND winner_citizenid = ?
                 AND resolved_at >= (NOW() - INTERVAL 24 HOUR)
          ]], { winnerCid, matchId, winnerCid })
          if distinctOpp >= DailyDistinctOpponentCap then return 0, 'distinct-cap' end
      end
      return RepPerPvpWin, 'ok'
  end

  -- ---------------------------------------------------------------------------
  -- Award driver — atomic claim, authoritative re-read, ledger, gated rep.
  -- Called by the seam handler AND boot reconcile (seam payload ignored for
  -- everything money-adjacent; DB row is authority).
  -- ---------------------------------------------------------------------------
  local function awardRep(matchId)
      loadConf()

      -- 1. atomic claim: PvP only, exactly once. Gates re-fire + PvE rows.
      local claimed = false
      pcall(function()
          claimed = MySQL.update.await(
              "UPDATE palm6_fightclub_matches SET rep_awarded = 1 WHERE id = ? AND rep_awarded = 0 AND is_pve = 0",
              { matchId }) == 1
      end)
      if not claimed then return end

      -- 2. authoritative resolved row
      local m
      pcall(function()
          m = MySQL.single.await([[
              SELECT winner_citizenid, method, fighter1_citizenid, fighter2_citizenid
                FROM palm6_fightclub_matches WHERE id = ? AND status = 'resolved'
          ]], { matchId })
      end)
      if not m then return end

      local winnerCid = m.winner_citizenid
      local method    = m.method or ''
      -- (c) decisive-only: draw/void produce no winner; forfeit has a winner but
      -- pays NO rep (spec §9c). Ledger win/loss is recorded for ko/finisher/forfeit.
      local decisive = winnerCid and (method == 'ko' or method == 'finisher' or method == 'forfeit')
      if not decisive then return end
      if isReserved(winnerCid) then
          dbg(('match #%d: winner cid reserved (%s) — no rep'):format(matchId, tostring(winnerCid)))
          return
      end

      local loserCid = (m.fighter1_citizenid == winnerCid) and m.fighter2_citizenid or m.fighter1_citizenid

      -- ledger (rank is rep-derived, so a forfeit win never inflates rank)
      bumpWin(winnerCid)
      if loserCid and not isReserved(loserCid) then bumpLoss(loserCid) end

      -- rep only on a clean decisive result (never forfeit/draw/void)
      if method == 'forfeit' or not loserCid or isReserved(loserCid) then return end

      local repAmount, reason = repToAward(matchId, winnerCid, loserCid)
      if repAmount > 0 then
          bumpDaily(winnerCid)          -- increment-before-credit
          addRep(winnerCid, repAmount)
          local ws = Bridge.GetSourceByCitizenId(winnerCid)
          if ws then
              Bridge.Notify(ws, 'Fight Club',
                  ('+%d rep for the win.'):format(repAmount), 'success')
          end
          dbg(('match #%d: %s +%d rep (win over %s)'):format(matchId, winnerCid, repAmount, loserCid))
      else
          local ws = Bridge.GetSourceByCitizenId(winnerCid)
          if ws then
              Bridge.Notify(ws, 'Fight Club',
                  'Win recorded — no rep (' .. reason .. ').', 'inform')
          end
          dbg(('match #%d: %s win recorded, rep skipped (%s)'):format(matchId, winnerCid, reason))
      end

      -- optional loser consolation (0 in MVP; same-opponent gated per spec §9b)
      if LoserConsolation > 0 and not wonAgainstWithin(matchId, winnerCid, loserCid, RepCooldownSec) then
          addRep(loserCid, LoserConsolation)
      end
  end

  -- ---------------------------------------------------------------------------
  -- Seam consumer — server-internal event, NEVER RegisterNetEvent.
  -- ---------------------------------------------------------------------------
  AddEventHandler('fc:match:resolved', function(d)
      if type(d) ~= 'table' then return end
      local matchId = tonumber(d.matchId)
      if not matchId then return end
      awardRep(matchId)
  end)

  -- ---------------------------------------------------------------------------
  -- Boot reconcile — re-drive post-deploy matches whose rep award never landed
  -- (crash between the seam fire and the credit). Idempotent via the claim gate.
  -- Delayed so palm6_dbmigrate has created the tables + columns (mirror
  -- fightclub's Wait(8000)); DEFAULT 1 on rep_awarded backfills history as done.
  -- ---------------------------------------------------------------------------
  AddEventHandler('onResourceStart', function(resource)
      if resource ~= GetCurrentResourceName() then return end
      CreateThread(function()
          Wait(8000)
          local pending = {}
          pcall(function()
              pending = MySQL.query.await(
                  "SELECT id FROM palm6_fightclub_matches WHERE status = 'resolved' AND rep_awarded = 0 AND is_pve = 0") or {}
          end)
          for _, row in ipairs(pending) do
              awardRep(row.id)
          end
          if #pending > 0 then
              print(('[palm6_fc_progression] boot reconcile awarded rep for %d match(es)'):format(#pending))
          end
      end)
  end)

  -- ---------------------------------------------------------------------------
  -- Exports (server-only) — consumed by T9 HUD career panel + future unlock UI.
  -- ---------------------------------------------------------------------------
  exports('GetRep', function(citizenid)
      local r
      pcall(function()
          r = MySQL.single.await("SELECT rep FROM palm6_fc_progression WHERE citizenid = ?", { citizenid })
      end)
      return r and tonumber(r.rep) or 0
  end)

  exports('GetRank', function(citizenid)
      local r
      pcall(function()
          r = MySQL.single.await("SELECT rank_tier FROM palm6_fc_progression WHERE citizenid = ?", { citizenid })
      end)
      return r and tonumber(r.rank_tier) or 0
  end)

  exports('HasUnlock', function(citizenid, unlockId)
      local r
      pcall(function()
          r = MySQL.single.await(
              "SELECT 1 AS ok FROM palm6_fc_unlocks WHERE citizenid = ? AND unlock_id = ? LIMIT 1",
              { citizenid, unlockId })
      end)
      return r ~= nil
  end)
  ```
  Verify: `npx --yes luaparse "resources/[custom]/palm6_fc_progression/server/main.lua"` — expected: AST JSON, exit 0. Fix any `SyntaxError: [line:col]` before moving on.

- [ ] **Step 4: confirm the DB shape T5 depends on exists (T2 precondition gate)**
  Against the server DB (HeidiSQL / phpMyAdmin / the panel's SQL console), run:
  ```sql
  SHOW COLUMNS FROM palm6_fightclub_matches LIKE 'rep_awarded';
  SHOW COLUMNS FROM palm6_fightclub_matches LIKE 'is_pve';
  SHOW COLUMNS FROM palm6_fightclub_matches LIKE 'method';
  SHOW TABLES LIKE 'palm6_fc_progression';
  SHOW TABLES LIKE 'palm6_fc_unlocks';
  SHOW TABLES LIKE 'palm6_fc_daily';
  ```
  Expected: `rep_awarded` = `tinyint … DEFAULT 1`, `is_pve` = `tinyint … DEFAULT 0`, `method` = `varchar(16)`, and all three `palm6_fc_*` tables present. If any is missing, T2 (`palm6_dbmigrate` STATEMENTS) has not landed — stop and coordinate; T5 cannot award rep without them. (Do NOT add the migrations here — that is T2's file.)

- [ ] **Step 5: boot-verify on the local FXServer (resource loads, 0 SCRIPT ERROR, exports resolve)**
  If T11's ensure order is not yet merged, temporarily add to `custom.cfg` (after the existing `ensure palm6_fightclub` at :108, and ensure `palm6_fc_core` + `palm6_dbmigrate` start too):
  ```
  ensure palm6_fc_core
  ensure palm6_fc_progression
  ```
  Boot the server. Expected console: `[palm6_fc_progression]` reconcile line only if there were pending rows (silent otherwise), and NO `SCRIPT ERROR` / `Failed to load` for `palm6_fc_progression`. In the server console confirm the resource is up and exports resolve:
  ```
  txAdmin/console> ensure palm6_fc_progression
  ```
  Expect `Started resource palm6_fc_progression`. (Export resolution is exercised for real in Step 6 via the HUD read path / DB.)

- [ ] **Step 6: stub-exercise the full rep path via /fcdebug (T4) → T3 seam → T5**
  With `palm6_fc.debug` ace granted to your admin (T4/T11) and two known citizenids on hand (call them `CIDA`, `CIDB` — use `SELECT citizenid FROM players LIMIT 2;` or two logged-in test chars):
  1. `/fcdebug open CIDA CIDB` → note the printed `matchId` (call it `M`). Charges both antes, INSERTs a `betting` row.
  2. `/fcdebug live M` → flips to `live`.
  3. `/fcdebug resolve M CIDA` → T3 `ResolveMatch(M, CIDA, 'ko')` → `settleMatch` → fires `fc:match:resolved`. Watch console for `[palm6_fc_progression] match #M: CIDA +100 rep (win over CIDB)`. CIDA (if online) sees a `+100 rep` toast.
  4. Verify the ledger:
     ```sql
     SELECT citizenid, rep, wins, losses, rank_tier FROM palm6_fc_progression WHERE citizenid IN ('CIDA','CIDB');
     SELECT id, rep_awarded, method, winner_citizenid FROM palm6_fightclub_matches WHERE id = M;
     ```
     Expected: `CIDA` row `rep=100, wins=1, rank_tier=0`; `CIDB` row `wins=0, losses=1, rep=0`; match `rep_awarded=1, method='ko'`.
  5. **Cash-neutrality (money-safety):** confirm neither CIDA nor CIDB bank balance changed from the rep award (only the ante charge from Step 6.1 moved money — that is T3/betting, not rep): `SELECT citizenid, JSON_EXTRACT(money,'$.bank') AS bank FROM players WHERE citizenid IN ('CIDA','CIDB');` — rep never touches `money`.
  6. **Same-opponent cooldown:** run 1→3 again (open M2, live, `resolve M2 CIDA`). Console: `win recorded, rep skipped (cooldown)`. Verify `rep` on CIDA is still `100` (not 200), `wins=2`, and `palm6_fc_progression` unchanged in rep.
  7. **No rep on draw/void/forfeit:** `/fcdebug open CIDA CIDB` → `/fcdebug void <id>` (VoidMatch fires the seam with `winnerCid=nil,method='void'`). Console: no rep line (returns early); `SELECT` confirms no rep/wins delta. Then open+live+`ResolveMatch` a forfeit (drive via T6/T7 ring-out, or a scratch `exports.palm6_fightclub:ResolveMatch(id, CIDB, 'forfeit')`): expect `wins`+1 for the winner but rep unchanged, console `rep skipped (forfeit)` path (method=='forfeit' returns before repToAward).
  8. **Idempotency / no double-pay on reboot:** restart the server. The boot reconcile runs; since every resolved match is `rep_awarded=1`, expect `boot reconcile awarded rep for 0 match(es)` (or no line) and CIDA's `rep` unchanged. Re-run the Step 6.4 SELECT to confirm no double-award.
  9. **(Optional, fast daily-cap check):** temporarily set `Config.Rep.DailyRepCap = 1` in `palm6_fc_core/config.lua` (T1), reboot, then resolve two wins by CIDA over two DIFFERENT opponents within an hour — the second must log `rep skipped (daily-cap)`. Revert the config after.

- [ ] **Step 7: David feel-test (in-game — the only gate for the live experience)**
  Note for David to verify in a real session (rep is display/rank only, never cash):
  - After a real PvP **KO**, the winner sees a `+100 rep` toast and the HUD career panel (T9, reads `GetRep`/`GetRank`) reflects the new rep/rank.
  - Beating the **same opponent twice within an hour** grants rep only the first time (second win toasts "no rep (cooldown)").
  - **Losing, forfeiting (walking out of the ring), or a draw grants no rep** to either side; a forfeit still records the win in the ledger but no rep/rank gain.
  - **Bank balance never moves** from a rep award — confirm the economy stays cash-neutral (only bets/antes move money, and those are the betting path).

- [ ] **Step 8: commit**
  ```
  git -C "C:/Users/Mgtda/Projects/Active/gtarp" add "resources/[custom]/palm6_fc_progression/fxmanifest.lua" "resources/[custom]/palm6_fc_progression/bridge/sv_framework.lua" "resources/[custom]/palm6_fc_progression/server/main.lua"
  git -C "C:/Users/Mgtda/Projects/Active/gtarp" commit -m "$(cat <<'EOF'
  feat(fightclub): palm6_fc_progression — rep/rank ledger on fc:match:resolved seam

  New server-only resource. Consumes the server-internal fc:match:resolved seam;
  atomic rep_awarded 0->1 claim (is_pve=0 gate, claim-before-credit, boot
  reconcile) credits cash-neutral RepPerPvpWin, updates wins/losses/rank_tier.
  Anti-farm: reserved '__' winner reject, no rep on forfeit/draw/void, 1h
  same-opponent cooldown, rolling-24h daily rep + distinct-opponent caps (off
  matches.resolved_at), shared palm6_fc_daily counter incremented before credit.
  Exports GetRep/GetRank/HasUnlock. Ships behind fightclub's existing gates.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected: one commit created with the three new files. (Do not push unless David asks — push policy.)

---

### Task 6: palm6_fc_combat — lifecycle state machine (challenge→select→accepted→betting→GoLive→countdown→live→resolve) + DC handling

Creates the new resource `palm6_fc_combat` and builds the **seam-gated match loop** that drives the money-owning `palm6_fightclub` exports. Combat *strikes/HP* are Task 7 and the *finisher* is Task 8 — both **add to this same resource**, so this task lays the in-memory match-state table, the net-event surface, the client bridge, and the teardown they hook into. Ships prod-inert (every entry point gated on `exports.palm6_fc_core:Config().Enabled`, default `false`).

**Files:**
- create `resources/[custom]/palm6_fc_combat/fxmanifest.lua`
- create `resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua`
- create `resources/[custom]/palm6_fc_combat/bridge/cl_game.lua`
- create `resources/[custom]/palm6_fc_combat/server/main.lua`
- create `resources/[custom]/palm6_fc_combat/client/main.lua`
- modify `resources/[custom]/palm6_fightclub/server/main.lua` (append one read-only `GetEntryStake` export — coordinate region-wise with T3; append at EOF after `GetSummary`)
- modify `custom.cfg` (add a temporary `ensure palm6_fc_combat` for boot-verify; T11 finalizes the whole fc ensure order)

**Interfaces:**
- **Consumes (server, via exports — do NOT reimplement):**
  - `exports.palm6_fc_core:Config()` → `{ Enabled, Ring={coords,radius,label}, Vitals={StartHP,MaxStamina,...}, Timers={ChallengeTTL,BetWindowSec,RoundSec,DrawBand,RingPollSec,CountdownSec}, DefaultFighter, DefaultStyle, Fighters, Styles }`
  - `exports.palm6_fc_core:GetFighter(id)` → `{ id,name,model,styleId }|nil`; `exports.palm6_fc_core:GetStyle(id)` → `{ id,name,movementClipset,animDicts }|nil`; `exports.palm6_fc_core:StateKeys()` → `{ MATCH_PREFIX,PLAYER_ACTIVE,PLAYER_SLOT,matchKey=fn }`
  - `exports.palm6_fightclub:OpenMatch(aCid,bCid,styleA,styleB,fighterA,fighterB,entryStake)` → `matchId:int|nil`
  - `exports.palm6_fightclub:GoLive(matchId)` → `bool`; `:ResolveMatch(matchId,winnerCid,method)` → `bool`; `:VoidMatch(matchId)` → `bool`; `:LiveVoidMatch(matchId)` → `bool`
  - `exports.palm6_fightclub:GetEntryStake()` → `int` (this task adds it to fightclub; money authority stays in `fightclub/shared/config.lua Config.Fight.EntryStake` — fc_combat NEVER hardcodes the stake)
  - `exports.palm6_fc_arena:GetFightMarks(matchId)` → `{ a={x,y,z,heading}, b={x,y,z,heading} }` (T10; **defensive fallback** built here so T6 boot-verifies standalone)
  - `Bridge.*` (own sv_framework clone): `GetCitizenId`, `GetPlayerName`, `GetCoords`, `Distance`, `ChargeBank`, `CreditBankByCitizenId`, `GetSourceByCitizenId`, `Notify`
- **Produces (net events, client→server; T11 eventguard-budgets):** `palm6_fc_combat:challenge{targetServerId}`, `palm6_fc_combat:accept{}`, `palm6_fc_combat:decline{}`, `palm6_fc_combat:select{fighterId,styleId}`. (`:strike/:connect/:block` T7, `:break` T8 register into THIS resource later.)
- **Produces (net events, server→client):** `palm6_fc_combat:challengePrompt{fromName,fromServerId,ttl}`, `palm6_fc_combat:openSelect{matchId}` (matchId = pre-OpenMatch **staging token**), `palm6_fc_combat:countdown{matchId,seconds}` (`seconds>0` = 3-2-1, `seconds==0` = GO), `palm6_fc_combat:teardown{matchId}` (`matchId==0` = boot "abort any fight" broadcast). Emits `palm6_fc_arena:squareUp{matchId,coords,heading}` (shape owned by T10) to each fighter using `GetFightMarks`.
- **Produces (server-internal `TriggerEvent`, consumed by T10 arena):** `fc:match:opened{matchId,f1name,f2name,betWindowSec}`, `fc:match:countdown{matchId,cidA,cidB}`, `fc:match:teardown{matchId}`.
- **Produces (server export, consumed by T7/T8 in-resource):** `exports('MatchState', function(matchId) return matches[matchId] end)` → `{ cidA,cidB,srcA,srcB,roundStarted,resolving,inFinisher={},startedAt,wentLive }`.
- **Produces (server-internal seam for T7):** `TriggerEvent('fc:combat:live', {matchId})` at LIVE entry (T7 attaches HP/hardening/strike handlers here).

---

- [ ] **Step 1: Scaffold the resource dir + fxmanifest (mirror palm6_lottery split).** Write `resources/[custom]/palm6_fc_combat/fxmanifest.lua`:
```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 fc_combat — Def Jam fight lifecycle (challenge/select/betting/countdown/live/resolve + DC)'

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'bridge/cl_game.lua',       -- native / ox UI adapter, before client logic
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',  -- framework adapter, before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
    'ox_target',
    'palm6_fc_core',
    'palm6_fightclub',
}
```

- [ ] **Step 2: Verify manifest + create the server Bridge (clone of fightclub's, verbatim API).** Write `resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua` as an exact copy of `palm6_fightclub/bridge/sv_framework.lua` lines 1-141 (same `Bridge` table, same `getPlayer`/`GetCitizenId`/`GetPlayerName`/`Notify`/`Reply`/`ChargeBank`/`CreditBankByCitizenId`/`GetSourceByCitizenId`/`GetCoords`/`Distance`/`GetHealth`/`GetCurrentWeaponHash`/`UnarmedHash`/`ResourceStarted`/`RegisterCommand`). Do not alter signatures — fc_combat calls `Bridge.*` exactly as fightclub does. Then: `npx luaparse "resources/[custom]/palm6_fc_combat/fxmanifest.lua"` and `npx luaparse "resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua"`. Expected: both exit 0, no `SyntaxError`.

- [ ] **Step 3: Add the `GetEntryStake` getter to fightclub (money authority stays there).** In `resources/[custom]/palm6_fightclub/server/main.lua`, append at EOF (after the `exports('GetSummary', ...)` block, ~line 594):
```lua
---Read-only money-authority getter: the entry ante fc_combat charges + passes to OpenMatch.
---Lives here so shared/config.lua Config.Fight.EntryStake stays the single source of truth (no drift).
exports('GetEntryStake', function()
    return math.floor(tonumber(Config.Fight and Config.Fight.EntryStake) or 0)
end)
```
Then `npx luaparse "resources/[custom]/palm6_fightclub/server/main.lua"` → exit 0. (Note: T3 also edits this file; this addition is append-only at EOF to minimize merge conflict. If T3 already added an identical `GetEntryStake`, skip this step.)

- [ ] **Step 4: Write server/main.lua — Section A: header, state tables, config/gate helpers, ring + DB guards.** Create `resources/[custom]/palm6_fc_combat/server/main.lua` starting with:
```lua
-- ============================================================================
-- palm6_fc_combat/server/main.lua
--
-- The fight LIFECYCLE + single resolver seam. Owns the in-memory match state,
-- CHALLENGE→SELECT→ACCEPTED→BETTING→COUNTDOWN→LIVE→RESOLVED transitions, and
-- the playerDropped DC handler. Money lives in palm6_fightclub (called via
-- OpenMatch/GoLive/ResolveMatch/VoidMatch/LiveVoidMatch). Combat strikes/HP are
-- added by Task 7, the finisher by Task 8 — both hook fc:combat:live + MatchState.
--
-- Ships prod-inert: every entry point gates on exports.palm6_fc_core:Config().Enabled.
-- ============================================================================

local SELECT_WINDOW_SEC = 15   -- client-UX select window (not money); defaults applied if a side never picks
local RATE = { fcchallenge = 3, fcaccept = 1, fcdecline = 1, fcselect = 1 }

local matches        = {}   -- [matchId] = { cidA,cidB,srcA,srcB, selA,selB, nameA,nameB, modelA,modelB, roundStarted,resolving,inFinisher,startedAt,wentLive,bettingEndsAt }
local activeByCid    = {}   -- [cid]  = matchId (in-memory quick lookup; DB is the authority)
local activeBySrc    = {}   -- [src]  = matchId (playerDropped routing)
local pendingChallenges = {} -- [targetCid] = { fromCid, fromSrc, targetSrc, expiresAt }
local staging        = {}   -- [stgId] = { aCid,bCid,aSrc,bSrc, selA,selB, submittedA,submittedB, done }
local stagingBySrc   = {}   -- [src] = stgId
local stagingSeq     = 0
local lastAction     = {}   -- [src][key] = ts — command/event spam guard
local entryStakeCache = nil
local bootDone       = false -- boot no-contest must finish before any challenge is accepted (§11)

local function now() return os.time() end

local function fcCore()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and cfg or nil
end

local function enabled()
    local cfg = fcCore()
    return cfg ~= nil and cfg.Enabled == true
end

local function dbg(msg)
    local cfg = fcCore()
    if cfg and cfg.Debug then print('[palm6_fc_combat] ' .. msg) end
end

local function rl(src, key)
    local window = RATE[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function stateKeys()
    local ok, sk = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    return ok and sk or nil
end

local function atRing(src)
    local c = Bridge.GetCoords(src)
    local cfg = fcCore()
    if not c or not cfg then return false end
    return Bridge.Distance(c, cfg.Ring.coords) <= cfg.Ring.radius
end

-- DB is the single source of truth for occupancy (survives restart; the
-- in-memory maps are cleared by a crash) — mirrors fightclub activeMatchForCitizen.
local function activeMatchForCitizen(cid)
    local row
    pcall(function()
        row = MySQL.single.await(
            [[SELECT id FROM palm6_fightclub_matches
              WHERE (fighter1_citizenid = ? OR fighter2_citizenid = ?)
                AND status IN ('betting','live') LIMIT 1]], { cid, cid })
    end)
    return row ~= nil
end

local function ringBusy()
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id FROM palm6_fightclub_matches WHERE status IN ('betting','live') LIMIT 1")
    end)
    return row ~= nil
end

local function getEntryStake()
    if entryStakeCache ~= nil then return entryStakeCache end
    local ok, v = pcall(function() return exports.palm6_fightclub:GetEntryStake() end)
    entryStakeCache = (ok and tonumber(v)) or 0
    return entryStakeCache
end

local function validPick(fighterId, styleId)
    local cfg = fcCore()
    local f = exports.palm6_fc_core:GetFighter(fighterId)
    local s = exports.palm6_fc_core:GetStyle(styleId)
    if f and s then return fighterId, styleId end
    return cfg.DefaultFighter, cfg.DefaultStyle
end

-- Opposing marks around the ring center; used only if arena isn't loaded (T6 solo
-- boot-verify) — T10's GetFightMarks is authoritative in the full stack.
local function getFightMarks(matchId)
    local ok, marks = pcall(function() return exports.palm6_fc_arena:GetFightMarks(matchId) end)
    if ok and type(marks) == 'table' and marks.a and marks.b then return marks end
    local c = fcCore().Ring.coords
    return {
        a = { x = c.x - 1.0, y = c.y, z = c.z, heading = 90.0 },
        b = { x = c.x + 1.0, y = c.y, z = c.z, heading = 270.0 },
    }
end
```
Then `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0 (file is still incomplete but must parse as far as written; if luaparse errors on a truncated file, defer this check to Step 9 after the file is whole). Continue appending in Steps 5-8 before the next parse gate.

- [ ] **Step 5: Append server/main.lua — Section B: teardown + resolveFight (the single resolver hub T7/T8/DC/timeout all route through).**
```lua
-- Canonical teardown: clears statebag + player state, tells both clients to
-- unwind (drop model/appearance), fires the arena cleanup seam, frees the ring.
-- Called on RESOLVE, void, DC, and the boot broadcast.
local function teardownMatch(matchId)
    local m = matches[matchId]
    if not m then return end
    local sk = stateKeys()
    if sk then
        GlobalState[sk.matchKey(matchId)] = nil
        for _, src in ipairs({ m.srcA, m.srcB }) do
            if src then
                Player(src).state:set(sk.PLAYER_ACTIVE, false, true)
                Player(src).state:set(sk.PLAYER_SLOT, false, true)
            end
        end
    end
    for _, src in ipairs({ m.srcA, m.srcB }) do
        if src then TriggerClientEvent('palm6_fc_combat:teardown', src, { matchId = matchId }) end
    end
    TriggerEvent('fc:match:teardown', { matchId = matchId })
    if m.cidA then activeByCid[m.cidA] = nil end
    if m.cidB then activeByCid[m.cidB] = nil end
    if m.srcA then activeBySrc[m.srcA] = nil end
    if m.srcB then activeBySrc[m.srcB] = nil end
    matches[matchId] = nil
    dbg(('match #%d torn down'):format(matchId))
end

-- The ONE resolve entry. winnerCid=nil => draw/void. method: ko/finisher/forfeit/draw/void.
-- Idempotent via the resolving flag + fightclub's own atomic status-guarded UPDATEs.
--   roundStarted           -> ResolveMatch (live row pays a winner)
--   wentLive & !roundStarted (COUNTDOWN) -> LiveVoidMatch (no-contest, never pays — §5 pre-LIVE)
--   !wentLive (BETTING)    -> VoidMatch (betting-row draw refund)
function resolveFight(matchId, winnerCid, method)
    local m = matches[matchId]
    if not m or m.resolving then return end
    m.resolving = true
    if m.roundStarted then
        exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method or 'ko')
    elseif m.wentLive then
        exports.palm6_fightclub:LiveVoidMatch(matchId)
    else
        exports.palm6_fightclub:VoidMatch(matchId)
    end
    teardownMatch(matchId)
end

-- Round-cap timeout. Task 7 REPLACES this body with an HP%-comparison winner
-- (DrawBand). Until T7 lands (no HP), a timeout is an honest draw.
function onRoundTimeout(matchId)
    local m = matches[matchId]
    if not m or m.resolving or not m.roundStarted then return end
    resolveFight(matchId, nil, 'draw')
end

local function startRoundTimer(matchId)
    local cap = fcCore().Timers.RoundSec
    CreateThread(function()
        Wait(cap * 1000)
        onRoundTimeout(matchId)
    end)
end
```

- [ ] **Step 6: Append server/main.lua — Section C: enterLive + GoLive/countdown.**
```lua
local function enterLive(matchId)
    local m = matches[matchId]
    if not m or m.resolving then return end
    m.roundStarted = true
    m.startedAt = now()
    local cfg = fcCore()
    local sk = stateKeys()
    if sk then
        GlobalState[sk.matchKey(matchId)] = {
            status = 'live', roundStarted = true,
            slot = {
                [1] = { hp = cfg.Vitals.StartHP, stam = cfg.Vitals.MaxStamina, blazin = 0, name = m.nameA, model = m.modelA },
                [2] = { hp = cfg.Vitals.StartHP, stam = cfg.Vitals.MaxStamina, blazin = 0, name = m.nameB, model = m.modelB },
            },
        }
        if m.srcA then Player(m.srcA).state:set(sk.PLAYER_ACTIVE, matchId, true); Player(m.srcA).state:set(sk.PLAYER_SLOT, 1, true) end
        if m.srcB then Player(m.srcB).state:set(sk.PLAYER_ACTIVE, matchId, true); Player(m.srcB).state:set(sk.PLAYER_SLOT, 2, true) end
    end
    -- seconds=0 => GO
    if m.srcA then TriggerClientEvent('palm6_fc_combat:countdown', m.srcA, { matchId = matchId, seconds = 0 }) end
    if m.srcB then TriggerClientEvent('palm6_fc_combat:countdown', m.srcB, { matchId = matchId, seconds = 0 }) end
    startRoundTimer(matchId)
    TriggerEvent('fc:combat:live', { matchId = matchId })   -- T7 attaches HP/hardening/strike handling here
    dbg(('match #%d LIVE'):format(matchId))
end

local function goLiveAndCountdown(matchId)
    local m = matches[matchId]
    if not m or m.resolving or m.roundStarted then return end
    if not exports.palm6_fightclub:GoLive(matchId) then
        -- betting->live flip lost the race (already voided/resolved): clean up local shell
        teardownMatch(matchId)
        return
    end
    m.wentLive = true
    -- refresh srcs (a fighter could have reconnected during the 60s window)
    m.srcA = Bridge.GetSourceByCitizenId(m.cidA)
    m.srcB = Bridge.GetSourceByCitizenId(m.cidB)
    if m.srcA then activeBySrc[m.srcA] = matchId end
    if m.srcB then activeBySrc[m.srcB] = matchId end
    TriggerEvent('fc:match:countdown', { matchId = matchId, cidA = m.cidA, cidB = m.cidB })  -- arena crowd/cam
    local marks = getFightMarks(matchId)
    if m.srcA then TriggerClientEvent('palm6_fc_arena:squareUp', m.srcA, { matchId = matchId, coords = marks.a, heading = marks.a.heading }) end
    if m.srcB then TriggerClientEvent('palm6_fc_arena:squareUp', m.srcB, { matchId = matchId, coords = marks.b, heading = marks.b.heading }) end
    local cd = fcCore().Timers.CountdownSec
    if m.srcA then TriggerClientEvent('palm6_fc_combat:countdown', m.srcA, { matchId = matchId, seconds = cd }) end
    if m.srcB then TriggerClientEvent('palm6_fc_combat:countdown', m.srcB, { matchId = matchId, seconds = cd }) end
    dbg(('match #%d COUNTDOWN (%ds)'):format(matchId, cd))
    CreateThread(function()
        Wait(cd * 1000)
        enterLive(matchId)
    end)
end

local function startBettingTimer(matchId)
    local waitSec = fcCore().Timers.BetWindowSec
    CreateThread(function()
        Wait(waitSec * 1000)
        goLiveAndCountdown(matchId)
    end)
end
```

- [ ] **Step 7: Append server/main.lua — Section D: ACCEPTED (charge antes → OpenMatch → refund both on nil).**
```lua
local function beginAccepted(s)
    local cfg = fcCore()
    local aSrc = Bridge.GetSourceByCitizenId(s.aCid)
    local bSrc = Bridge.GetSourceByCitizenId(s.bCid)
    if not aSrc or not bSrc then
        if aSrc then Bridge.Notify(aSrc, 'Fight Club', 'Opponent left before the fight opened.', 'error') end
        if bSrc then Bridge.Notify(bSrc, 'Fight Club', 'Opponent left before the fight opened.', 'error') end
        return
    end
    if activeMatchForCitizen(s.aCid) or activeMatchForCitizen(s.bCid) or ringBusy() then
        Bridge.Notify(aSrc, 'Fight Club', 'The ring is no longer free.', 'error')
        Bridge.Notify(bSrc, 'Fight Club', 'The ring is no longer free.', 'error')
        return
    end

    -- ACCEPTED charge + OpenMatch INSERT are ONE recoverable unit (§10b):
    -- charge A, then B; B fails -> refund A. Both land but INSERT fails -> refund BOTH.
    local stake = getEntryStake()
    if stake > 0 then
        if not Bridge.ChargeBank(aSrc, stake, 'fightclub-entry') then
            Bridge.Notify(aSrc, 'Fight Club', ('You need $%d to ante in.'):format(stake), 'error')
            Bridge.Notify(bSrc, 'Fight Club', 'Opponent could not cover the ante.', 'inform')
            return
        end
        if not Bridge.ChargeBank(bSrc, stake, 'fightclub-entry') then
            Bridge.CreditBankByCitizenId(s.aCid, stake, 'fightclub-entry-refund')  -- unwind A
            Bridge.Notify(bSrc, 'Fight Club', ('You need $%d to ante in.'):format(stake), 'error')
            Bridge.Notify(aSrc, 'Fight Club', 'Opponent could not cover the ante — ante refunded.', 'inform')
            return
        end
    end

    local styleA = s.selA.styleId
    local styleB = s.selB.styleId
    local fighterA = s.selA.fighterId
    local fighterB = s.selB.fighterId
    local matchId = exports.palm6_fightclub:OpenMatch(s.aCid, s.bCid, styleA, styleB, fighterA, fighterB, stake)
    if not matchId or matchId == 0 then
        if stake > 0 then   -- INSERT failed after both charges landed -> refund BOTH antes
            Bridge.CreditBankByCitizenId(s.aCid, stake, 'fightclub-entry-refund')
            Bridge.CreditBankByCitizenId(s.bCid, stake, 'fightclub-entry-refund')
        end
        Bridge.Notify(aSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        Bridge.Notify(bSrc, 'Fight Club', 'Could not open the match — antes refunded.', 'error')
        return
    end

    local fA = exports.palm6_fc_core:GetFighter(fighterA) or exports.palm6_fc_core:GetFighter(cfg.DefaultFighter)
    local fB = exports.palm6_fc_core:GetFighter(fighterB) or exports.palm6_fc_core:GetFighter(cfg.DefaultFighter)
    matches[matchId] = {
        cidA = s.aCid, cidB = s.bCid, srcA = aSrc, srcB = bSrc,
        selA = s.selA, selB = s.selB,
        nameA = Bridge.GetPlayerName(aSrc), nameB = Bridge.GetPlayerName(bSrc),
        modelA = fA and fA.model or 'mp_m_freemode_01',
        modelB = fB and fB.model or 'mp_m_freemode_01',
        roundStarted = false, resolving = false, inFinisher = {}, startedAt = 0,
        wentLive = false, bettingEndsAt = now() + cfg.Timers.BetWindowSec,
    }
    activeByCid[s.aCid] = matchId; activeByCid[s.bCid] = matchId
    activeBySrc[aSrc] = matchId; activeBySrc[bSrc] = matchId
    TriggerEvent('fc:match:opened', { matchId = matchId, f1name = matches[matchId].nameA, f2name = matches[matchId].nameB, betWindowSec = cfg.Timers.BetWindowSec })
    Bridge.Notify(aSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, matches[matchId].nameB, cfg.Timers.BetWindowSec), 'success')
    Bridge.Notify(bSrc, 'Fight Club', ('Match #%d opened vs %s — betting is live for %ds.'):format(matchId, matches[matchId].nameA, cfg.Timers.BetWindowSec), 'success')
    startBettingTimer(matchId)
    dbg(('match #%d BETTING opened'):format(matchId))
end

local function finalizeStaging(stgId)
    local s = staging[stgId]
    if not s or s.done then return end
    s.done = true
    if s.aSrc then stagingBySrc[s.aSrc] = nil end
    if s.bSrc then stagingBySrc[s.bSrc] = nil end
    staging[stgId] = nil
    beginAccepted(s)
end
```

- [ ] **Step 8: Append server/main.lua — Section E: net-event handlers (challenge/accept/decline/select), playerDropped, boot no-contest, MatchState export.**
```lua
local function cleanupPendingForSrc(src)
    for tCid, pc in pairs(pendingChallenges) do
        if pc.fromSrc == src or pc.targetSrc == src then pendingChallenges[tCid] = nil end
    end
    local stgId = stagingBySrc[src]
    if stgId then finalizeStaging(stgId) end  -- resolves with defaults; harmless if empty
end

RegisterNetEvent('palm6_fc_combat:challenge', function(payload)
    local src = source
    if not enabled() or not bootDone then return end
    if type(payload) ~= 'table' or not rl(src, 'fcchallenge') then return end
    local targetSrc = tonumber(payload.targetServerId)
    if not targetSrc or targetSrc == src then return end
    local aCid = Bridge.GetCitizenId(src)
    local bCid = Bridge.GetCitizenId(targetSrc)
    if not aCid or not bCid then Bridge.Notify(src, 'Fight Club', 'Invalid opponent.', 'error') return end
    if not atRing(src) then Bridge.Notify(src, 'Fight Club', ('You must be at %s.'):format(fcCore().Ring.label), 'error') return end
    if not atRing(targetSrc) then Bridge.Notify(src, 'Fight Club', 'They are not at the ring.', 'error') return end
    if activeMatchForCitizen(aCid) or activeMatchForCitizen(bCid) then Bridge.Notify(src, 'Fight Club', 'One of you already has a match.', 'error') return end
    if ringBusy() then Bridge.Notify(src, 'Fight Club', 'The ring is in use.', 'error') return end
    if pendingChallenges[bCid] then Bridge.Notify(src, 'Fight Club', 'They already have a pending challenge.', 'error') return end
    local ttl = fcCore().Timers.ChallengeTTL
    pendingChallenges[bCid] = { fromCid = aCid, fromSrc = src, targetSrc = targetSrc, expiresAt = now() + ttl }
    TriggerClientEvent('palm6_fc_combat:challengePrompt', targetSrc, { fromName = Bridge.GetPlayerName(src), fromServerId = src, ttl = ttl })
    Bridge.Notify(src, 'Fight Club', ('Challenge sent — %ds to respond.'):format(ttl), 'inform')
    CreateThread(function()
        Wait(ttl * 1000)
        local pc = pendingChallenges[bCid]
        if pc and pc.fromCid == aCid then
            pendingChallenges[bCid] = nil
            local s2 = Bridge.GetSourceByCitizenId(aCid)
            if s2 then Bridge.Notify(s2, 'Fight Club', 'Challenge expired — no answer.', 'inform') end
        end
    end)
end)

RegisterNetEvent('palm6_fc_combat:decline', function()
    local src = source
    if not rl(src, 'fcdecline') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local pc = pendingChallenges[cid]
    if not pc then return end
    pendingChallenges[cid] = nil
    if pc.fromSrc then Bridge.Notify(pc.fromSrc, 'Fight Club', 'Your challenge was declined.', 'inform') end
end)

RegisterNetEvent('palm6_fc_combat:accept', function()
    local src = source
    if not enabled() or not bootDone then return end
    if not rl(src, 'fcaccept') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local pc = pendingChallenges[cid]
    if not pc then return end
    pendingChallenges[cid] = nil
    local aSrc, aCid, bSrc, bCid = pc.fromSrc, pc.fromCid, src, cid
    if Bridge.GetSourceByCitizenId(aCid) ~= aSrc then Bridge.Notify(bSrc, 'Fight Club', 'The challenger left.', 'error') return end
    if not atRing(aSrc) or not atRing(bSrc) then Bridge.Notify(bSrc, 'Fight Club', 'Both fighters must be at the ring.', 'error') return end
    if activeMatchForCitizen(aCid) or activeMatchForCitizen(bCid) or ringBusy() then Bridge.Notify(bSrc, 'Fight Club', 'The ring is in use.', 'error') return end
    local cfg = fcCore()
    stagingSeq = stagingSeq + 1
    local stgId = stagingSeq
    staging[stgId] = {
        aCid = aCid, bCid = bCid, aSrc = aSrc, bSrc = bSrc,
        selA = { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle },
        selB = { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle },
        submittedA = false, submittedB = false, done = false,
    }
    stagingBySrc[aSrc] = stgId; stagingBySrc[bSrc] = stgId
    TriggerClientEvent('palm6_fc_combat:openSelect', aSrc, { matchId = stgId })
    TriggerClientEvent('palm6_fc_combat:openSelect', bSrc, { matchId = stgId })
    CreateThread(function()
        Wait(SELECT_WINDOW_SEC * 1000)
        finalizeStaging(stgId)   -- proceed with whatever was picked (defaults otherwise)
    end)
end)

RegisterNetEvent('palm6_fc_combat:select', function(payload)
    local src = source
    if type(payload) ~= 'table' or not rl(src, 'fcselect') then return end
    local stgId = stagingBySrc[src]
    local s = stgId and staging[stgId]
    if not s or s.done then return end
    local fid, sid = validPick(payload.fighterId, payload.styleId)
    if src == s.aSrc then s.selA = { fighterId = fid, styleId = sid }; s.submittedA = true
    elseif src == s.bSrc then s.selB = { fighterId = fid, styleId = sid }; s.submittedB = true
    else return end
    if s.submittedA and s.submittedB then finalizeStaging(stgId) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local matchId = activeBySrc[src]
    if not matchId then cleanupPendingForSrc(src); return end
    local m = matches[matchId]
    if not m then activeBySrc[src] = nil; return end
    local droppedCid = (src == m.srcA) and m.cidA or m.cidB
    if not m.roundStarted then
        -- BETTING or COUNTDOWN: a fight that never started must not pay a winner (§5) -> void/no-contest
        resolveFight(matchId, nil, 'void')
    else
        -- LIVE: the disconnecting fighter forfeits, opponent is paid (§5)
        local opponentCid = (droppedCid == m.cidA) and m.cidB or m.cidA
        resolveFight(matchId, opponentCid, 'forfeit')
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(8000)  -- let palm6_dbmigrate land the fc columns first (mirror fightclub's boot delay)
        TriggerClientEvent('palm6_fc_combat:teardown', -1, { matchId = 0 })  -- abort any client stuck mid-fight
        local rows = {}
        pcall(function()
            rows = MySQL.query.await("SELECT id, status FROM palm6_fightclub_matches WHERE status IN ('betting','live')") or {}
        end)
        for _, r in ipairs(rows) do
            if r.status == 'betting' then exports.palm6_fightclub:VoidMatch(r.id)
            else exports.palm6_fightclub:LiveVoidMatch(r.id) end
        end
        if #rows > 0 then print(('[palm6_fc_combat] boot no-contested %d stranded match(es)'):format(#rows)) end
        bootDone = true
        print('[palm6_fc_combat] ready — Enabled=' .. tostring(enabled()))
    end)
end)

AddEventHandler('playerDropped', function() end)  -- (no-op; real handler above)

exports('MatchState', function(matchId) return matches[matchId] end)
```
(Delete the trailing no-op `playerDropped` line if the linter flags a duplicate handler — it is only a reminder that T7/T8 must NOT register a second `playerDropped`; combat DC is owned here.)

- [ ] **Step 9: Parse the whole server file.** `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0, no `SyntaxError`. Fix any parse error before proceeding (common: an unbalanced `end`, or `resolveFight`/`onRoundTimeout` declared without `local` — they are intentionally globals-in-file so forward references from Section C/E resolve; keep them as shown).

- [ ] **Step 10: Write client Bridge cl_game.lua — Section A: player-target + dialogs + menu (mirror lottery/clout).** Create `resources/[custom]/palm6_fc_combat/bridge/cl_game.lua`:
```lua
-- ============================================================================
-- palm6_fc_combat/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file here that calls GTA natives / ox_target /
-- ox_lib UI. client/main.lua calls Game.* only. Presentation + local ped only;
-- server owns all authority.
-- ============================================================================

Game = {}

local hasTarget = GetResourceState('ox_target') == 'started'
local saved = { model = nil, appearance = nil, active = false }

function Game.MyServerId()
    return GetPlayerServerId(PlayerId())
end

-- Server id of the remote player this ped belongs to, or nil.
function Game.ServerIdFromPed(ped)
    if not ped or ped == 0 then return nil end
    local p = NetworkGetPlayerIndexFromPed(ped)
    if p == -1 then return nil end
    return GetPlayerServerId(p)
end

function Game.PedIsRemotePlayer(ped)
    return ped and ped ~= 0 and IsPedAPlayer(ped) and ped ~= PlayerPedId()
end

-- ox_target eye on any nearby player: "Challenge to a fight".
function Game.AddChallengeTarget(onSelectServerId)
    if not hasTarget then return end
    exports.ox_target:addGlobalPlayer({
        {
            name = 'palm6_fc_challenge',
            icon = 'fa-solid fa-hand-fist',
            label = 'Challenge to a fight',
            distance = 2.5,
            canInteract = function(entity) return Game.PedIsRemotePlayer(entity) end,
            onSelect = function(data)
                local sid = Game.ServerIdFromPed(data.entity)
                if sid then onSelectServerId(sid) end
            end,
        },
    })
end

function Game.Notify(opts)
    lib.notify(opts)
end

-- Accept/decline modal. Returns true on accept.
function Game.ConfirmDialog(title, msg, ttlSec)
    local res = lib.alertDialog({
        header = title,
        content = msg,
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })
    return res == 'confirm'
end

-- ox_lib context menu. options = { { title, description, onSelect=fn }, ... }.
function Game.OpenMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

-- 3-2-1 client countdown (visual only; server owns the real clock).
function Game.RunCountdown(sec)
    CreateThread(function()
        for i = sec, 1, -1 do
            lib.notify({ title = 'Fight Club', description = tostring(i), type = 'inform', duration = 900 })
            Wait(1000)
        end
    end)
end
```

- [ ] **Step 11: Append cl_game.lua — Section B: fighter preload + model swap + appearance restore + teleport.**
```lua
-- Preload every anim dict + the movement clipset for a style (COUNTDOWN gate, §8).
function Game.PreloadStyle(styleId)
    local st = exports.palm6_fc_core:GetStyle(styleId)
    if not st then return end
    for _, d in pairs(st.animDicts or {}) do
        if type(d) == 'string' then
            RequestAnimDict(d)
            local dl = GetGameTimer() + 3000
            while not HasAnimDictLoaded(d) and GetGameTimer() < dl do Wait(25) end
        end
    end
    local cs = st.movementClipset
    if cs then
        RequestClipSet(cs)
        local dl = GetGameTimer() + 3000
        while not HasClipSetLoaded(cs) and GetGameTimer() < dl do Wait(25) end
    end
end

-- Snapshot real appearance (illenium) + hash, then swap to the fighter model.
-- Non-persisting: a DC self-heals on reconnect. Defensive: falls back to the
-- model hash if illenium isn't present.
function Game.SwapToFighter(model, styleId)
    local ped = PlayerPedId()
    local ok, ap = pcall(function() return exports['illenium-appearance']:getPedAppearance(ped) end)
    saved.appearance = ok and ap or nil
    saved.model = GetEntityModel(ped)
    saved.active = true
    Game.PreloadStyle(styleId)
    local hash = joaat(model)
    if not IsModelValid(hash) then return end
    RequestModel(hash)
    local dl = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(50) end
    if HasModelLoaded(hash) then
        SetPlayerModel(PlayerId(), hash)
        SetModelAsNoLongerNeeded(hash)
    end
end

-- Canonical client unwind — restore the real ped + saved appearance.
function Game.RestoreAppearance()
    if not saved.active then return end
    saved.active = false
    if saved.model and saved.model ~= 0 then
        RequestModel(saved.model)
        local dl = GetGameTimer() + 5000
        while not HasModelLoaded(saved.model) and GetGameTimer() < dl do Wait(50) end
        if HasModelLoaded(saved.model) then
            SetPlayerModel(PlayerId(), saved.model)
            SetModelAsNoLongerNeeded(saved.model)
        end
    end
    if saved.appearance then
        pcall(function() exports['illenium-appearance']:setPedAppearance(PlayerPedId(), saved.appearance) end)
    end
    saved.appearance = nil
    saved.model = nil
end

-- Place the fighter on its fight-mark facing the opponent (§K).
function Game.SquareUp(coords, heading)
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
end
```
Then `npx luaparse "resources/[custom]/palm6_fc_combat/bridge/cl_game.lua"` → exit 0.

- [ ] **Step 12: Write client/main.lua — challenge input, prompt, select, countdown, squareUp, teardown.** Create `resources/[custom]/palm6_fc_combat/client/main.lua`:
```lua
-- ============================================================================
-- palm6_fc_combat/client/main.lua
--
-- Pure presentation: fires the CHALLENGE, answers the prompt, picks a fighter,
-- runs the client 3-2-1 + model swap, squares up, and unwinds on teardown.
-- Every action is server-validated; a modified client only picks what to REQUEST.
-- Combat input (strike/block) is added by Task 7.
-- ============================================================================

local myPick = nil  -- { fighterId, styleId } — remembered so the model swap matches the pick

local function enabledClient()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and cfg and cfg.Enabled == true
end

-- CHALLENGE: ox_target eye on a nearby player.
CreateThread(function()
    Game.AddChallengeTarget(function(serverId)
        TriggerServerEvent('palm6_fc_combat:challenge', { targetServerId = serverId })
    end)
end)

-- CHALLENGE fallback: /fcchallenge <serverid>
RegisterCommand('fcchallenge', function(_, args)
    local sid = tonumber(args[1])
    if not sid then
        Game.Notify({ title = 'Fight Club', description = 'Usage: /fcchallenge [server id]', type = 'error' })
        return
    end
    TriggerServerEvent('palm6_fc_combat:challenge', { targetServerId = sid })
end, false)

RegisterNetEvent('palm6_fc_combat:challengePrompt', function(d)
    if type(d) ~= 'table' then return end
    local ok = Game.ConfirmDialog('Fight Challenge',
        ('**%s** wants to fight you at the ring. Accept?'):format(d.fromName or 'Someone'), d.ttl or 20)
    TriggerServerEvent(ok and 'palm6_fc_combat:accept' or 'palm6_fc_combat:decline')
end)

RegisterNetEvent('palm6_fc_combat:openSelect', function(d)
    if type(d) ~= 'table' then return end
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    if not ok or not cfg then return end
    local opts = {}
    for _, f in ipairs(cfg.Fighters or {}) do
        opts[#opts + 1] = {
            title = f.name,
            description = ('Style: %s'):format(f.styleId or '?'),
            icon = 'fa-solid fa-user-ninja',
            onSelect = function()
                myPick = { fighterId = f.id, styleId = f.styleId }
                TriggerServerEvent('palm6_fc_combat:select', { fighterId = f.id, styleId = f.styleId })
            end,
        }
    end
    Game.OpenMenu('palm6_fc_select', 'Choose your fighter', opts)
end)

RegisterNetEvent('palm6_fc_combat:countdown', function(d)
    if type(d) ~= 'table' then return end
    local sec = tonumber(d.seconds) or 0
    if sec > 0 then
        -- COUNTDOWN: preload + model swap (uses the remembered pick, else the default the server also used)
        local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
        local pick = myPick or (ok and cfg and { fighterId = cfg.DefaultFighter, styleId = cfg.DefaultStyle }) or nil
        if pick then
            local f = exports.palm6_fc_core:GetFighter(pick.fighterId)
            if f and f.model then Game.SwapToFighter(f.model, pick.styleId) end
        end
        Game.RunCountdown(sec)
    else
        Game.Notify({ title = 'Fight Club', description = 'FIGHT!', type = 'inform', duration = 1500 })
    end
end)

RegisterNetEvent('palm6_fc_arena:squareUp', function(d)
    if type(d) ~= 'table' or type(d.coords) ~= 'table' then return end
    Game.SquareUp(d.coords, d.heading)
end)

RegisterNetEvent('palm6_fc_combat:teardown', function(d)
    -- matchId==0 is the boot "abort any fight" broadcast — always unwind.
    Game.RestoreAppearance()
    myPick = nil
    pcall(function() lib.hideContext(false) end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Game.RestoreAppearance()
end)
```
Then `npx luaparse "resources/[custom]/palm6_fc_combat/client/main.lua"` → exit 0.

- [ ] **Step 13: Wire the ensure into custom.cfg (boot-verify placement; T11 finalizes order).** In `custom.cfg`, add immediately after line 108 `ensure palm6_fightclub`:
```cfg
ensure palm6_fc_combat
```
(Requires `palm6_fc_core` [T1], `palm6_fightclub` [T3], and ideally `palm6_fc_arena` [T10] to be ensured before it. For a standalone T6 boot-verify without T10, the `getFightMarks` fallback covers the missing arena export. T11 relocates this into the canonical `eventguard → dbmigrate → fc_core → fightclub → fc_combat → fc_hud/fc_arena → fc_progression` block.)

- [ ] **Step 14: Boot-verify on a local FXServer (0 SCRIPT ERROR).** Start the local FXServer with `palm6_fc_core`, `palm6_dbmigrate`, `palm6_fightclub`, and `palm6_fc_combat` ensured. Confirm console shows: `[palm6_dbmigrate] done: N ok, 0 failed`, `[palm6_fightclub] ring open — 0 match(es)`, and after ~8s `[palm6_fc_combat] ready — Enabled=false`. Expected: **zero** `SCRIPT ERROR`, `palm6_fc_combat` state `started` (`ensure palm6_fc_combat` → check `resmon`/`GetResourceState`). In the server console (txAdmin/live console) run: `exports.palm6_fc_combat:MatchState(1)` returns nil (no crash) — confirms the export is registered. (If FXServer isn't available locally, gate on luaparse-clean across all 5 files + the fightclub edit, and note boot-verify as required before merge.)

- [ ] **Step 15: Stub-exercise the money seam the lifecycle drives (via T4 /fcdebug, no combat needed).** With `Enabled=false` still fine for /fcdebug (ace-gated, T4). As an admin: `/fcdebug open <cidA> <cidB>` → a `betting` row appears; `/fcbet <id> 1 100` from a third cid succeeds; `/fcdebug live <id>` → row `live`, `/fcbet` now rejected; `/fcdebug resolve <id> <cidA> ko` → winner paid, bets settle; then `/fcdebug open` again + `/fcdebug void <id>` → both antes + bets refunded. This proves `OpenMatch/GoLive/ResolveMatch/VoidMatch` (the exact exports fc_combat calls) behave, before real combat exists. Confirm `entry_pot`, `entry_paid1/2`, `settled` move correctly (money-safety: no double-pay, no strand). Note in the run log the exact balances before/after.

- [ ] **Step 16: Commit.** `git add resources/[custom]/palm6_fc_combat resources/[custom]/palm6_fightclub/server/main.lua custom.cfg` then commit:
```
feat(fc_combat): match lifecycle state machine + DC handling (Task 6)

New palm6_fc_combat resource: CHALLENGE (ox_target + /fcchallenge, server
atRing + DB active-match + ring-occupancy guards) -> accept/decline ->
SELECT (server-snapshotted fighter/style, defaults on no-pick) -> ACCEPTED
(charge both antes -> OpenMatch -> refund BOTH on nil) -> per-match betting
timer off BetWindowSec -> GoLive -> COUNTDOWN (arena square-up + client
preload/model-swap + 3-2-1) -> LIVE (statebag + player state + roundStarted)
-> single resolveFight() hub (ResolveMatch / LiveVoidMatch / VoidMatch by
state) + canonical teardown. playerDropped DC: void pre-LIVE, forfeit in-LIVE.
Boot no-contests stranded rows before accepting challenges. Ships behind
Config.Enabled=false. Combat strikes (T7) + finisher (T8) hook fc:combat:live
+ exports MatchState. Adds fightclub GetEntryStake getter (money authority
stays in fightclub config). luaparse-clean; boot-verified 0 SCRIPT ERROR.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**David feel-test items (in-game only — the standing rule; this is the sole gate for the interactive half):**
1. Flip `palm6_fc_core Config.Enabled=true`. Two players stand at the Vanilla Unicorn back lot ring: player A ox_target-eyes player B → "Challenge to a fight"; B gets the accept/decline modal; on Accept both get the fighter-select menu; a pick (or letting the 15s window lapse → defaults) opens match #N with a 60s betting window and the `/fcbet` broadcast. Confirm the ante ($500 each) is charged at ACCEPTED and both are refunded if either can't cover it or the match fails to open.
2. During the 60s window a **spectator** `/fcbet`s; at window end both fighters are square-upped on opposing marks, see 3-2-1 then "FIGHT!", and have swapped to their fighter model (verify the model swap and that on teardown the **real appearance/outfit is restored**, not stripped).
3. **DC pre-LIVE:** one fighter disconnects during betting or countdown → the match VOIDs/no-contests, antes + bets fully refunded, opponent freed (never paid a winner for a fight that never happened).
4. **DC in-LIVE:** once "FIGHT!" has fired, a fighter disconnects → opponent wins by forfeit, purse (entry pot + any pool) settles to them, both clients tear down (no one left invincible/frozen/stuck as a fighter model).
5. **Restart mid-fight:** open a match, then restart `palm6_fc_combat` (or the server) mid-betting and mid-live → on boot the stranded row is no-contested (antes/bets refunded) and any connected client stuck mid-fight receives the abort-teardown; a new challenge cannot be accepted until the boot no-contest completes.
6. Confirm the round-cap safety timeout (`RoundSec`, 180s) resolves a stalled match to a draw (Task 7 will upgrade this to an HP%-based winner).

---

### Task 7: palm6_fc_combat — server move clock + ped hardening + KO + ring confinement

Adds the real striking layer to the `palm6_fc_combat` resource created in T6: server-owned HP/stamina/momentum keyed by `matchId..':'..cid`, the `strike`→`connect`/`block` move clock, per-LIVE-frame ped hardening, the `RingPollSec` confinement poll, and KO. Server owns ALL fight state (never ped health); §6a numbers come from `palm6_fc_core`. This task writes the T1 statebag shape (`GlobalState['fc:match:'..matchId]` + `Player(src).state['fc:active']/['fc:slot']`) that T9 HUD reads.

**Files:**
- MODIFY `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua` (append 3 server-side native helpers)
- MODIFY `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/server/main.lua` (append the whole T7 move clock)
- MODIFY `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/bridge/cl_game.lua` (append client hardening/clip/ragdoll natives)
- MODIFY `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/client/main.lua` (append the hardening loop + strike/KO/teardown reactions)

**Interfaces:**
- Consumes (T1 `palm6_fc_core`, both realms via export): `exports.palm6_fc_core:Config()` → `.Moves` (§6a table), `.Vitals` (`StartHP/MaxStamina/StaminaRegenPerSec`), `.Momentum` (`PerLandedHit/PerTakenHit`), `.Timers.RingPollSec`, `.Blazin.FullThreshold`, `.Ring` (`.coords/.radius`); `exports.palm6_fc_core:GetStyle(styleId)` → `.animDicts.strike`; `exports.palm6_fc_core:StateKeys()` → `.matchKey(matchId)`.
- Consumes (T6, same resource): `exports.palm6_fc_combat:MatchState(matchId)` → the live per-match table `{ cidA, cidB, srcA, srcB, roundStarted, resolving, inFinisher, startedAt }` (read fields + set `.resolving=true`). `st.cidA`==fightclub fighter1==slot 1==`st.srcA`.
- Consumes (T3, live-money resolver): `exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method)` → bool. Consumes server-internal `fc:match:resolved` (fired by T3 after settle) for cleanup.
- Consumes net (client-registered by T6): `palm6_fc_combat:teardown = { matchId }` (add a second AddEventHandler).
- Produces (server handlers for T6-produced net events): `palm6_fc_combat:strike = { matchId, moveId }`, `palm6_fc_combat:connect = { matchId, targetCid }`, `palm6_fc_combat:block = { matchId, on }`.
- Produces net server→client (consumed by T7/T8 client): `palm6_fc_combat:playClip = { matchId, cid, moveId, animDict }` (targeted to attacker src), `palm6_fc_combat:koRagdoll = { matchId }` (targeted to victim src).
- Produces statebags: `GlobalState['fc:match:'..matchId] = { status='live', roundStarted=true, slot={[1]={hp,stam,blazin,name,model},[2]=…} }` (throttled ≤4/s); `Player(src).state['fc:active'] = matchId|false`, `Player(src).state['fc:slot'] = 1|2`.
- Produces Bridge helpers (server): `Bridge.Reach(aSrc,bSrc)→m|nil`, `Bridge.DistToRing(src,ring)→m|nil`, `Bridge.Facing(targetSrc,attackerSrc)→bool`. Game helpers (client): `Game.HardenFighterPed()`, `Game.PlayStrikeClip(dict,clip)`, `Game.RagdollSelf()`, `Game.RestoreFighterPed()`.

---

- [ ] **Step 1: Orient — confirm the exact T6 seams this task binds to.** T7 is code appended to files T6 already created, so the identifiers below MUST exist before writing a line. Run:
  ```bash
  cd "C:/Users/Mgtda/Projects/Active/gtarp"
  grep -n "MatchState\|roundStarted\|resolving\|srcA\|cidA" "resources/[custom]/palm6_fc_combat/server/main.lua"
  grep -n "RegisterNetEvent('palm6_fc_combat:teardown'" "resources/[custom]/palm6_fc_combat/client/main.lua"
  grep -n "function Bridge\." "resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua"
  ```
  Expected: `exports('MatchState', …)` present and the state table exposes `cidA/cidB/srcA/srcB/roundStarted/resolving`; teardown is `RegisterNetEvent`'d client-side. If `MatchState` is absent or the state fields are named differently, STOP — T6 is incomplete; do not proceed (this task's entire read path is `ms(matchId)`). No file change; no commit.

- [ ] **Step 2: Append the 3 server native helpers to the fc_combat server bridge.** All server-side natives stay in the bridge (the §6 gate). Add to the END of `resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua`:
  ```lua

  -- ============================================================================
  -- T7 combat-native helpers (server-authoritative reach / confinement / facing).
  -- GetEntityCoords/GetEntityHeading are valid server-side on a synced player ped.
  -- ============================================================================

  -- Distance (m) between two online fighters' peds; nil if either isn't readable.
  function Bridge.Reach(aSrc, bSrc)
      local pa, pb = GetPlayerPed(aSrc), GetPlayerPed(bSrc)
      if not pa or pa == 0 or not pb or pb == 0 then return nil end
      return #(GetEntityCoords(pa) - GetEntityCoords(pb))
  end

  -- Distance (m) from an online player's ped to a ring-center {x,y,z}; nil if the
  -- ped isn't readable (unsynced / gone) — caller treats nil as "skip", never a ring-out.
  function Bridge.DistToRing(src, ring)
      local ped = GetPlayerPed(src)
      if not ped or ped == 0 then return nil end
      return #(GetEntityCoords(ped) - vec3(ring.x, ring.y, ring.z))
  end

  -- Is targetSrc's ped facing attackerSrc? Forward-dot toward the attacker > 0.25
  -- (~75 deg frontal arc) = a valid guard direction. False if unreadable.
  function Bridge.Facing(targetSrc, attackerSrc)
      local tp, ap = GetPlayerPed(targetSrc), GetPlayerPed(attackerSrc)
      if not tp or tp == 0 or not ap or ap == 0 then return false end
      local dir = GetEntityCoords(ap) - GetEntityCoords(tp)
      local len = #dir
      if len < 0.01 then return true end
      dir = dir / len
      local h = math.rad(GetEntityHeading(tp))    -- GTA heading 0 = +Y; forward = (-sin, cos)
      local fwd = vec3(-math.sin(h), math.cos(h), 0.0)
      return (fwd.x * dir.x + fwd.y * dir.y) > 0.25
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua"` → prints AST JSON, no `SyntaxError`, exit 0.

- [ ] **Step 3: Append the server state core + caches + startRound + flush to server/main.lua.** Add to the END of `resources/[custom]/palm6_fc_combat/server/main.lua`:
  ```lua

  -- ============================================================================
  -- T7: server move clock. HP/stamina/momentum are server script vars keyed by
  -- matchId..':'..cid (never ped health). Combat numbers come from palm6_fc_core
  -- (§6a). Per-match live state comes from T6 via MatchState(matchId).
  -- ============================================================================

  local DBG = false
  local Combat = {}   -- [matchId..':'..cid] = { slot, cid, src, hp, stam, blazin, blocking, cd={}, active, name, model, animStrike }
  local Active = {}    -- [matchId] = true   (T7-managed: LIVE + roundStarted)
  local Dirty  = {}    -- [matchId] = true   (statebag needs a throttled flush)

  -- fc_core caches (populated once the export is up; pcall-retry survives load order).
  local MOVES, VIT, MOM, TIM, BLZ, RING, SK
  CreateThread(function()
      while not MOVES do
          local ok, c = pcall(function() return exports.palm6_fc_core:Config() end)
          if ok and c and c.Moves then
              MOVES, VIT, MOM, TIM, BLZ, RING = c.Moves, c.Vitals, c.Momentum, c.Timers, c.Blazin, c.Ring
          end
          if not SK then
              local ok2, k = pcall(function() return exports.palm6_fc_core:StateKeys() end)
              if ok2 and k then SK = k end
          end
          if not MOVES then Wait(250) end
      end
      if DBG then print('[palm6_fc_combat] T7 combat config cached') end
  end)

  local function ckey(matchId, cid) return matchId .. ':' .. cid end
  local function mkey(matchId) return (SK and SK.matchKey(matchId)) or ('fc:match:' .. matchId) end
  local function ms(matchId) return exports.palm6_fc_combat:MatchState(matchId) end

  -- Throttled statebag write (§6/§12: send-on-change, not per-frame). Only the
  -- client-display fields (T1 slot shape) go on the wire — never cd/active/src.
  local function flush(matchId)
      local st = ms(matchId)
      if not st then return end
      local a = Combat[ckey(matchId, st.cidA)]
      local b = Combat[ckey(matchId, st.cidB)]
      if not a or not b then return end
      local function view(f) return { hp = f.hp, stam = f.stam, blazin = f.blazin, name = f.name, model = f.model } end
      GlobalState[mkey(matchId)] = {
          status = 'live', roundStarted = true,
          slot = { [1] = view(a), [2] = view(b) },
      }
  end

  -- Build the server-owned fight state for a match that just went LIVE. One DB
  -- read maps slot -> cid/name/model/style; everything else lives in memory only.
  local function startRound(matchId)
      local st = ms(matchId)
      if not st or not st.roundStarted or Active[matchId] then return end
      if not VIT then return end          -- fc_core not cached yet; discovery retries
      Active[matchId] = true              -- claim BEFORE the await so discovery can't double-init

      local row
      pcall(function()
          row = MySQL.single.await([[
              SELECT fighter1_citizenid, fighter2_citizenid,
                     fighter1_name, fighter2_name,
                     fighter1_model, fighter2_model,
                     style1, style2
                FROM palm6_fightclub_matches WHERE id = ?]], { matchId })
      end)
      if not row then Active[matchId] = nil; return end   -- transient DB fail; retry next pass

      local function strikeDictFor(styleId)
          local okS, style = pcall(function() return exports.palm6_fc_core:GetStyle(styleId) end)
          if okS and style and style.animDicts and style.animDicts.strike then
              return style.animDicts.strike
          end
          return 'melee@unarmed@streamed_core'
      end

      local seats = {
          { slot = 1, cid = row.fighter1_citizenid, src = st.srcA, name = row.fighter1_name, model = row.fighter1_model, dict = strikeDictFor(row.style1) },
          { slot = 2, cid = row.fighter2_citizenid, src = st.srcB, name = row.fighter2_name, model = row.fighter2_model, dict = strikeDictFor(row.style2) },
      }
      for _, s in ipairs(seats) do
          Combat[ckey(matchId, s.cid)] = {
              slot = s.slot, cid = s.cid, src = s.src,
              hp = VIT.StartHP, stam = VIT.MaxStamina, blazin = 0,
              blocking = false, cd = {}, active = nil,
              name = s.name or ('fighter %d'):format(s.slot),
              model = s.model or 'mp_m_freemode_01',
              animStrike = s.dict,
          }
          if s.src then
              Player(s.src).state:set('fc:active', matchId, true)
              Player(s.src).state:set('fc:slot', s.slot, true)
          end
      end
      Dirty[matchId] = true
      if DBG then print(('[palm6_fc_combat] round started #%d'):format(matchId)) end
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → AST JSON, no `SyntaxError`.

- [ ] **Step 4: Append the strike + block handlers to server/main.lua.** Strike = the move-clock gate (§6 step 2): validate live+roundStarted+cooldown+stamina, open a server active window, order the attacker's own client to play the swing. Block = held stance (§blocking). Add after the Step 3 block:
  ```lua

  -- Strike (§6 step 2): validate -> deduct stamina -> open active window -> order
  -- the attacker's OWN client to play the swing (replication shows it to everyone).
  RegisterNetEvent('palm6_fc_combat:strike', function(data)
      local src = source
      if not MOVES or type(data) ~= 'table' then return end
      local matchId = tonumber(data.matchId)
      local moveId  = data.moveId
      if not matchId or type(moveId) ~= 'string' then return end
      local move = MOVES[moveId]
      if not move then return end

      local st = ms(matchId)
      if not st or not st.roundStarted or st.resolving then return end
      local cid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
      if not cid then return end
      local f = Combat[ckey(matchId, cid)]
      if not f then return end

      local nowMs = GetGameTimer()
      if nowMs < (f.cd[moveId] or 0) then return end                          -- cooldown not elapsed
      if move.kind == 'heavy' and f.stam < move.staminaCost then return end    -- 0-stam = light only

      f.stam = math.max(0, f.stam - move.staminaCost)
      f.cd[moveId] = nowMs + move.cooldownMs
      f.active = { moveId = moveId, expiresAt = nowMs + move.activeWindowMs }
      Dirty[matchId] = true

      TriggerClientEvent('palm6_fc_combat:playClip', src,
          { matchId = matchId, cid = cid, moveId = moveId, animDict = f.animStrike })
  end)

  -- Block: held stance (server records on/off). Cost is drained per absorbed hit
  -- in the connect handler; while blocking, stamina does not regenerate (§6a).
  RegisterNetEvent('palm6_fc_combat:block', function(data)
      local src = source
      if type(data) ~= 'table' then return end
      local matchId = tonumber(data.matchId)
      if not matchId then return end
      local st = ms(matchId)
      if not st or not st.roundStarted or st.resolving then return end
      local cid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
      if not cid then return end
      local f = Combat[ckey(matchId, cid)]
      if not f then return end
      f.blocking = data.on and true or false
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → no `SyntaxError`.

- [ ] **Step 5: Append the connect handler (damage + momentum + block-chip + KO) to server/main.lua.** Connect = §6 step 4: must arrive inside the attacker's active window, target within server `move.reach`, block resolved server-side; then apply damage/momentum and detect KO. Add after Step 4:
  ```lua

  -- Connect (§6 step 4): the attacker client claims a visual hit; the SERVER
  -- validates window + reach + block and applies authoritative damage/momentum.
  RegisterNetEvent('palm6_fc_combat:connect', function(data)
      local src = source
      if not MOVES or type(data) ~= 'table' then return end
      local matchId = tonumber(data.matchId)
      if not matchId then return end
      local st = ms(matchId)
      if not st or not st.roundStarted or st.resolving then return end

      local attCid = (src == st.srcA and st.cidA) or (src == st.srcB and st.cidB) or nil
      if not attCid then return end
      local att = Combat[ckey(matchId, attCid)]
      if not att or not att.active then return end                     -- no live swing
      if GetGameTimer() > att.active.expiresAt then att.active = nil; return end  -- window closed

      local move = MOVES[att.active.moveId]
      if not move then att.active = nil; return end

      local tgtCid = (attCid == st.cidA) and st.cidB or st.cidA
      local tgt = Combat[ckey(matchId, tgtCid)]
      if not tgt or not tgt.src then att.active = nil; return end

      local reach = Bridge.Reach(att.src, tgt.src)                      -- server distance, never client
      if not reach or reach > move.reach then att.active = nil; return end

      att.active = nil                                                  -- one connect per swing

      local dmg = move.damage
      if tgt.blocking and Bridge.Facing(tgt.src, att.src) then
          dmg = math.floor(move.damage * (move.chipPct or 0))           -- chip through the guard
          tgt.stam = math.max(0, tgt.stam - (move.blockStamCost or 0))
          if tgt.stam <= 0 then tgt.blocking = false end                -- block breaks at 0 stamina
      end

      tgt.hp = tgt.hp - dmg
      local cap = (BLZ and BLZ.FullThreshold) or 100
      att.blazin = math.min(cap, att.blazin + (MOM.PerLandedHit or 0))  -- both gain (Def Jam feel)
      tgt.blazin = math.min(cap, tgt.blazin + (MOM.PerTakenHit or 0))
      Dirty[matchId] = true

      if tgt.hp <= 0 then
          st.resolving = true                                          -- DC/KO race guard (T6 flag)
          TriggerClientEvent('palm6_fc_combat:koRagdoll', tgt.src, { matchId = matchId })
          exports.palm6_fightclub:ResolveMatch(matchId, attCid, 'ko')  -- atomic live->resolved flip
      end
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → no `SyntaxError`.

- [ ] **Step 6: Append the 4 server threads/handler (discovery, combat tick, ring-poll, resolved cleanup) to server/main.lua.** These wire the state machine: discover LIVE+roundStarted matches, regen stamina + flush the throttled bag, enforce ring confinement, and tear down T7 state when the match resolves. Add after Step 5:
  ```lua

  -- Discovery: a DB-authoritative sweep that promotes any LIVE row whose T6 round
  -- has actually started into Active. Cheap 1s cadence; empty result set at idle.
  CreateThread(function()
      while true do
          Wait(1000)
          if MOVES then
              local live = {}
              pcall(function()
                  live = MySQL.query.await("SELECT id FROM palm6_fightclub_matches WHERE status = 'live'") or {}
              end)
              for _, r in ipairs(live) do
                  local id = tonumber(r.id)
                  if id and not Active[id] then
                      local st = ms(id)
                      if st and st.roundStarted then startRound(id) end
                  end
              end
          end
      end
  end)

  -- Combat tick: stamina regen (skip a fighter mid-swing or blocking) + throttled
  -- statebag flush. Runs only over Active matches -> no measurable cost at idle.
  CreateThread(function()
      while true do
          Wait(250)
          for matchId in pairs(Active) do
              local nowMs = GetGameTimer()
              local prefix = matchId .. ':'
              for k, f in pairs(Combat) do
                  if k:sub(1, #prefix) == prefix then
                      local attacking = f.active and nowMs <= f.active.expiresAt
                      if not f.blocking and not attacking and f.stam < VIT.MaxStamina then
                          f.stam = math.min(VIT.MaxStamina, f.stam + (VIT.StaminaRegenPerSec * 0.25))
                          Dirty[matchId] = true
                      end
                  end
              end
          end
          for matchId in pairs(Dirty) do
              flush(matchId)
              Dirty[matchId] = nil
          end
      end
  end)

  -- Ring confinement (§6, CONFIRMED gap): a fast server coords poll force-resolves
  -- a ring-out to a forfeit AND drops that fighter's invincibility this instant
  -- (teardown to their own client) — invincibility must not survive a ring-exit.
  CreateThread(function()
      while not TIM do Wait(250) end
      local pollMs = math.floor((TIM.RingPollSec or 0.5) * 1000)
      if pollMs < 250 then pollMs = 250 end
      while true do
          Wait(pollMs)
          for matchId in pairs(Active) do
              local st = ms(matchId)
              if st and st.roundStarted and not st.resolving then
                  local prefix = matchId .. ':'
                  for k, f in pairs(Combat) do
                      if k:sub(1, #prefix) == prefix and f.src then
                          local d = Bridge.DistToRing(f.src, RING.coords)
                          if d ~= nil and d > RING.radius then     -- real out-of-radius read (nil = skip; DC is T6)
                              st.resolving = true
                              local oppCid = (f.cid == st.cidA) and st.cidB or st.cidA
                              TriggerClientEvent('palm6_fc_combat:teardown', f.src, { matchId = matchId })
                              exports.palm6_fightclub:ResolveMatch(matchId, oppCid, 'forfeit')
                              break
                          end
                      end
                  end
              end
          end
      end
  end)

  -- Cleanup: when any match resolves (T3 fires this after settle, for KO / ring-out
  -- forfeit / DC / void), drop all T7 state so nothing is stranded. Safe for a
  -- match that never entered Active (a betting-row void has no Combat entries).
  AddEventHandler('fc:match:resolved', function(d)
      if type(d) ~= 'table' then return end
      local matchId = tonumber(d.matchId)
      if not matchId then return end
      Active[matchId] = nil
      Dirty[matchId]  = nil
      local prefix = matchId .. ':'
      for k, f in pairs(Combat) do
          if k:sub(1, #prefix) == prefix then
              if f.src then
                  Player(f.src).state:set('fc:active', false, true)
                  Player(f.src).state:set('fc:slot', nil, true)
              end
              Combat[k] = nil
          end
      end
      GlobalState[mkey(matchId)] = nil
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → no `SyntaxError`. Then commit the server half:
  ```bash
  cd "C:/Users/Mgtda/Projects/Active/gtarp"
  git add "resources/[custom]/palm6_fc_combat/bridge/sv_framework.lua" "resources/[custom]/palm6_fc_combat/server/main.lua"
  git commit -m "$(cat <<'EOF'
palm6_fc_combat (T7): server move clock — HP/stamina/momentum, strike/connect/block, ring confinement, KO

Server owns all fight state keyed by matchId:cid (never ped health). Strike opens a
server active window; connect validates window+reach+block then applies §6a damage/momentum;
KO (HP<=0) ragdolls the victim + ResolveMatch(ko). Ring-out poll (RingPollSec) forfeits and
drops invincibility instantly. Throttled fc:match statebag write for the HUD.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

- [ ] **Step 7: Append the client hardening/clip/ragdoll natives to the fc_combat client bridge.** All client natives stay in the Game adapter (the §6 gate; mirrors lottery's `cl_game.lua`). Add to the END of `resources/[custom]/palm6_fc_combat/bridge/cl_game.lua`:
  ```lua

  -- ============================================================================
  -- T7: LIVE fighter ped hardening / strike clip / KO ragdoll / restore.
  -- Every native re-fetches PlayerPedId() so a model swap (§8) never leaves us
  -- operating on a stale handle.
  -- ============================================================================

  local FC_MELEE_CONTROLS = { 24, 25, 140, 141, 142, 143, 257, 262, 263, 264 }  -- attack/aim/melee light+heavy+block+combo
  local FC_UNARMED = joaat('WEAPON_UNARMED')

  -- One frame of hardening on the LOCAL fighter's own ped (§6): invincible (blocks
  -- health loss only), ragdoll OFF (re-asserted each frame so a punch/blast can't
  -- interrupt a clip), pain/flinch off, own melee suppressed, empty-handed.
  function Game.HardenFighterPed()
      local pid = PlayerId()
      local ped = PlayerPedId()
      SetPlayerInvincible(pid, true)
      SetEntityInvincible(ped, true)
      SetPedCanRagdoll(ped, false)
      SetPedSuffersCriticalHits(ped, false)
      SetPedConfigFlag(ped, 187, true)          -- disable melee-hit reactions
      SetPedConfigFlag(ped, 281, true)
      SetCurrentPedWeapon(ped, FC_UNARMED, true)
      SetWeaponsNoAutoswap(true)
      for i = 1, #FC_MELEE_CONTROLS do
          DisableControlAction(0, FC_MELEE_CONTROLS[i], true)
      end
  end

  -- Play a strike clip on the LOCAL fighter's own ped, non-interruptibly (flag 2)
  -- so a stray reaction can't override the intended swing (§6).
  function Game.PlayStrikeClip(animDict, animName)
      if type(animDict) ~= 'string' or type(animName) ~= 'string' then return end
      RequestAnimDict(animDict)
      local deadline = GetGameTimer() + 1000
      while not HasAnimDictLoaded(animDict) and GetGameTimer() < deadline do Wait(0) end
      if not HasAnimDictLoaded(animDict) then return end
      TaskPlayAnim(PlayerPedId(), animDict, animName, 8.0, -8.0, -1, 2, 0.0, false, false, false)
  end

  -- KO: the victim's own client ragdolls its own ped. §6 ordering — the caller
  -- MUST have stopped the hardening loop first; here we enable ragdoll then apply.
  function Game.RagdollSelf()
      local ped = PlayerPedId()
      SetPlayerInvincible(PlayerId(), false)
      SetEntityInvincible(ped, false)
      SetPedCanRagdoll(ped, true)
      SetPedToRagdoll(ped, 3500, 3500, 0, false, false, false)
      ApplyForceToEntity(ped, 1, 0.0, -1.5, 0.4, 0.0, 0.0, 0.0, 0, false, true, true, false, true)
  end

  -- Teardown of hardening: reverse everything HardenFighterPed asserted (§11).
  function Game.RestoreFighterPed()
      local pid = PlayerId()
      local ped = PlayerPedId()
      SetPlayerInvincible(pid, false)
      SetEntityInvincible(ped, false)
      SetPedCanRagdoll(ped, true)
      SetPedSuffersCriticalHits(ped, true)
      SetPedConfigFlag(ped, 187, false)
      SetPedConfigFlag(ped, 281, false)
      SetWeaponsNoAutoswap(false)
      ClearPedTasks(ped)
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/bridge/cl_game.lua"` → AST JSON, no `SyntaxError`. Commit:
  ```bash
  cd "C:/Users/Mgtda/Projects/Active/gtarp"
  git add "resources/[custom]/palm6_fc_combat/bridge/cl_game.lua"
  git commit -m "$(cat <<'EOF'
palm6_fc_combat (T7): client ped-hardening / strike-clip / KO-ragdoll / restore natives

Game adapter (§6 gate): invincible + CanRagdoll(false) re-assert + pain flags off +
melee-control suppression + unarmed each frame; non-interruptible strike clip; victim-owned
KO ragdoll; full restore for the canonical teardown. Re-fetches PlayerPedId() every call.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

- [ ] **Step 8: Append the client hardening loop + strike/KO/teardown reactions to client/main.lua.** Hardening is driven purely off our OWN `fc:active` statebag (server-set at round start, cleared at resolve) so there is zero polling when we are not a fighter. Add to the END of `resources/[custom]/palm6_fc_combat/client/main.lua`:
  ```lua

  -- ============================================================================
  -- T7: LIVE fighter hardening loop + strike/KO/teardown reactions. Presentation
  -- only; the server owns every number and validates every event.
  -- ============================================================================

  local Fighter = { matchId = false, hardening = false }

  -- Clip name WITHIN the style's strike dict (server picks the dict; the clip is
  -- pure feel — tune/replace in David's feel-test, zero logic impact).
  local STRIKE_CLIP = {
      jab      = 'plyr_takedown_front_lefthook',
      cross    = 'plyr_takedown_front_lefthook',
      hook     = 'plyr_takedown_front_lefthook',
      uppercut = 'plyr_takedown_front_lefthook',
      body     = 'plyr_takedown_front_lefthook',
  }

  local function startHardening(matchId)
      if Fighter.hardening then return end
      Fighter.matchId = matchId
      Fighter.hardening = true
      CreateThread(function()
          while Fighter.hardening do
              Game.HardenFighterPed()
              Wait(0)                       -- re-assert every frame (§6)
          end
      end)
  end

  local function stopHardening()
      Fighter.hardening = false
      Fighter.matchId = false
      Game.RestoreFighterPed()
  end

  -- Drive hardening off our own player statebag. bagFilter nil + explicit own-bag
  -- check because GetPlayerServerId is unreliable at script-load.
  AddStateBagChangeHandler('fc:active', nil, function(bagName, _, value)
      if bagName ~= ('player:%d'):format(GetPlayerServerId(PlayerId())) then return end
      if value and value ~= false then
          startHardening(tonumber(value))
      else
          stopHardening()
      end
  end)

  -- Attacker's own swing (targeted to us; replication shows it to everyone else).
  RegisterNetEvent('palm6_fc_combat:playClip', function(data)
      if type(data) ~= 'table' then return end
      local clip = STRIKE_CLIP[data.moveId] or 'plyr_takedown_front_lefthook'
      Game.PlayStrikeClip(data.animDict, clip)
  end)

  -- KO: stop re-asserting CanRagdoll(false) BEFORE ragdolling (§6 ordering) or the
  -- next hardening frame no-ops SetPedToRagdoll.
  RegisterNetEvent('palm6_fc_combat:koRagdoll', function(data)
      if type(data) ~= 'table' then return end
      Fighter.hardening = false
      Wait(0)
      Game.RagdollSelf()
      Fighter.matchId = false
  end)

  -- Canonical teardown (net-registered by T6). A second AddEventHandler runs
  -- alongside T6's HUD/cam teardown to guarantee hardening is dropped + ped restored
  -- (ring-out drops invincibility the instant this arrives).
  AddEventHandler('palm6_fc_combat:teardown', function()
      stopHardening()
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/client/main.lua"` → AST JSON, no `SyntaxError`. Commit:
  ```bash
  cd "C:/Users/Mgtda/Projects/Active/gtarp"
  git add "resources/[custom]/palm6_fc_combat/client/main.lua"
  git commit -m "$(cat <<'EOF'
palm6_fc_combat (T7): client hardening loop + strike/KO/teardown reactions

Hardening driven off our own fc:active statebag (no idle polling). playClip plays the swing
on our own ped; koRagdoll stops hardening before ragdolling (§6 ordering); teardown restores
the ped alongside T6's HUD/cam teardown so ring-out drops invincibility immediately.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

- [ ] **Step 9: Boot-verify (0 SCRIPT ERROR) + stub sanity + record the feel-test gate.** The move clock needs two real clients, so runtime combat is David's feel-test; the automatable gate here is a clean boot and that the ace-stub path does not crash the new code.
  1. Start the local FXServer with the fc block ensured (custom.cfg order from T11: `palm6_eventguard` → `palm6_dbmigrate` → `palm6_fc_core` → `palm6_fightclub` → `palm6_fc_combat`). In the server console:
     ```
     ensure palm6_fc_combat
     ```
     Expected: `palm6_fc_combat` starts; console shows NO `SCRIPT ERROR` from `@palm6_fc_combat/*` and NO `Failed to load script`. (If `MatchState`/`palm6_fc_core:Config` aren't up yet the cache thread pcall-retries silently — that is expected, not an error.)
  2. Drive the stub to confirm the new server code coexists with a match row without erroring (combat state will NOT initialize — `/fcdebug` opens a DB row but no T6 in-memory MatchState, so `startRound` correctly no-ops on `ms(matchId)==nil`; this proves the discovery loop is null-safe):
     ```
     /fcdebug open <cidA> <cidB>
     /fcdebug live 1
     ```
     Wait ~2s, confirm console stays clean (no `attempt to index a nil value` from the discovery/tick/ring-poll threads). Then:
     ```
     /fcdebug resolve 1 <cidA>
     ```
     Expected: resolves cleanly; `fc:match:resolved` cleanup runs with no error (no Combat/statebag entries existed — the pairs loops are empty and safe).
  3. **David in-game feel-test (the only gate for real combat — note explicitly, do NOT claim done without it):**
     - **Strike/connect cadence:** jab/cross land quick; hook/uppercut/body feel heavy and gated by cooldown+stamina; body drains more stamina than it damages.
     - **Stamina floor:** at 0 stamina only light strikes throw; regen resumes when not swinging/blocking.
     - **Block:** held block chips (small damage) + drains guard; block breaks at 0 stamina; a hit from BEHIND a blocker deals full damage (facing check).
     - **KO:** a fighter driven to HP≤0 ragdolls (only their own ped) and the match resolves KO with the correct winner + purse/entry payout.
     - **Ring-out (anti-godmode):** an invincible fighter who walks past `Config.Ring.radius` is force-forfeited within ~0.5s AND loses invincibility the instant they cross (confirm they take damage/ragdoll normally right after).
     - **Third-party interference:** a non-participant punching a mid-clip fighter does nothing to HP (server ignores non-snapshotted attackers); the fighter's clip is not interrupted.
     - **Strike clip visuals:** the `STRIKE_CLIP` names are placeholders — verify/replace per move for feel (presentation only).
  4. Final commit (verification notes only if any tuning constants changed; otherwise the working tree is already committed from Steps 6-8 — run a no-op confirm):
     ```bash
     cd "C:/Users/Mgtda/Projects/Active/gtarp"
     git status --short
     git log --oneline -3
     ```
     Expected: clean tree, the three T7 commits present. If David's feel-test forced a constant tweak (e.g. a `STRIKE_CLIP` name or the `0.25` facing threshold), edit, re-`luaparse` the touched file, and commit with message `palm6_fc_combat (T7): feel-test tuning — <what changed>` + the Co-Authored-By trailer.

---

### Task 8: palm6_fc_combat — Blazin finisher (per-client own-ped scene, interruptible)

Adds the Blazin finisher to the **existing** `palm6_fc_combat` resource (created by T6, move-clock added by T7). Per §7 + §11 of the design spec. All code is **appended to the two files T6/T7 already ship** (`server/main.lua`, `client/main.lua`) so it shares their file-local fight state — no new files, no fxmanifest change (the finisher net event needs no manifest entry; its eventguard budget is T11's, its client→server mash `palm6_fc_combat:break` is T6-declared/T11-budgeted).

**Files:**
- Modify: `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/server/main.lua` (append the finisher server block; one insertion into the T7 connect handler)
- Modify: `C:/Users/Mgtda/Projects/Active/gtarp/resources/[custom]/palm6_fc_combat/client/main.lua` (append the finisher client block; one insertion at the top of the T6 `palm6_fc_combat:teardown` handler)

**Interfaces:**
- **Consumes** (fc_core, both realms): `exports.palm6_fc_core:Config()` → `.Blazin{FullThreshold,HeavyQualifies,MashReducePerHit,SceneDurationMs,BaseFinisherDamage}`, `.Vitals.StartHP`, `.Momentum`; `exports.palm6_fc_core:GetMove(moveId)` → `{ kind='light'|'heavy', ... }`.
- **Consumes** (T6/T7 file-locals in `server/main.lua`, same chunk scope): `matches[matchId]` = `{ cidA, cidB, srcA, srcB, roundStarted, resolving, inFinisher={}, startedAt }`; `fightHp[matchId..':'..cid]` (int); `fightMom[matchId..':'..cid]` (int momentum = Blazin meter); `writeMatchState(matchId)` (T7 throttled `GlobalState['fc:match:'..matchId]` writer); `resolveFight(matchId, winnerCid, method)` (T6 wrapper: sets `st.resolving`, calls `exports.palm6_fightclub:ResolveMatch`). **Before wiring, `grep` these five names in `server/main.lua` and adapt the references if T6/T7 spelled any differently.**
- **Consumes** (T7 net event): `palm6_fc_combat:koRagdoll` (server→victim) reused for the finisher KO.
- **Consumes** (T6 net event): `palm6_fc_combat:teardown` (server→client) — this task inserts `abortFinisherLocal()` at its top.
- **Produces**: net event `palm6_fc_combat:finisher` (server→each fighter individually) = `{ matchId:int, cid:string, startAt:int, origin={x,y,z}, heading:number, sceneDict:string, sceneAnim:string }`; the **server handler** for `palm6_fc_combat:break` = `{ matchId:int }`; global server table `Fin = { tryTrigger, start, applyDamage, cleanup }`; global client fn `abortFinisherLocal()`; ace-gated dev command `/fcfin <matchId> <attackerCid>`.

---

- [ ] **Step 1: Server — finisher scaffold, constants, heading helper.** Append to the END of `server/main.lua`:
  ```lua
  -- ==========================================================================
  -- Blazin finisher (T8) — server half.
  -- Per-client OWN-ped synchronized scene (§7). The SERVER owns: the trigger (a
  -- LANDED HEAVY connect at a full meter), the shared scene origin/heading + a
  -- start stamp, the mash-to-reduce tally (palm6_fc_combat:break), and the
  -- finisher damage applied on scene end -- a NO-OP if the row already resolved
  -- (DC / ring-out / KO beat the finisher via the T6 `resolving` flag, §5/§11).
  -- Builds on the T6/T7 file-locals declared ABOVE in this same chunk:
  --   matches[matchId], fightHp[k], fightMom[k], writeMatchState(), resolveFight()
  -- (grep to confirm spellings before wiring the trigger in Step 6).
  -- ==========================================================================
  local FinCfg = exports.palm6_fc_core:Config()

  -- Prototype takedown clip (§7: base-game takedown first). Dict mirrors the
  -- fc_core style finisher dict. David feel-tests the pose + swaps the clip /
  -- adds 180 to heading if it reads wrong (Step 12). The finisher MECHANIC
  -- (freeze / damage / mash / teardown) is clip-agnostic.
  local FINISHER_DICT          = 'mini@takedowns@front'
  local FINISHER_ANIM_ATTACKER = 'plyr_takedown_front'
  local FINISHER_ANIM_VICTIM   = 'victim_takedown_front'
  local FINISHER_WINDUP_MS     = 800    -- telegraph + mash window BEFORE impact (MUST match client Step 8)
  local FINISHER_MAX_REDUCE    = 0.85   -- mash shaves at most 85% off BaseFinisherDamage

  Fin = {}                     -- GLOBAL (Bridge/Game convention) so the T7 connect handler can reach Fin.tryTrigger
  local finishers = {}         -- [matchId] = { attCid, defCid, mash, done, startAt }

  local function finKey(matchId, cid) return matchId .. ':' .. cid end

  local function headingFromVec(dx, dy)
      -- GTA heading approximation; if fighters face away in feel-test, add 180.0.
      return (math.deg(math.atan(-dx, dy))) % 360.0
  end
  ```
  Verify: `cd "C:/Users/Mgtda/Projects/Active/gtarp" && npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0, no output.

- [ ] **Step 2: Server — `Fin.start` (spend meter, compute shared origin, broadcast own-half orders, schedule damage).** Append below Step 1's block:
  ```lua
  -- Begins the finisher. Re-guards everything so tryTrigger / the debug command
  -- can call it freely. Sends EACH fighter a "run your half on your OWN ped"
  -- order at a shared origin (§7 step 1-2); spectators/opponent view the scene
  -- via normal ped-anim replication, never tasked here.
  function Fin.start(matchId, attCid, defCid)
      local st = matches[matchId]
      if not st or not st.roundStarted or st.resolving then return end
      if finishers[matchId] then return end                     -- one finisher per match
      if st.inFinisher[attCid] or st.inFinisher[defCid] then return end

      local attSrc = (st.cidA == attCid) and st.srcA or st.srcB
      local defSrc = (st.cidA == defCid) and st.srcA or st.srcB
      if not attSrc or not defSrc then return end

      local ac = Bridge.GetCoords(attSrc)
      local dc = Bridge.GetCoords(defSrc)
      if not ac or not dc then return end

      fightMom[finKey(matchId, attCid)] = 0                     -- spend the meter (no instant re-chain)
      st.inFinisher[attCid] = true
      st.inFinisher[defCid] = true

      local startAt = GetGameTimer()
      finishers[matchId] = { attCid = attCid, defCid = defCid, mash = 0, done = false, startAt = startAt }

      local origin  = { x = (ac.x + dc.x) * 0.5, y = (ac.y + dc.y) * 0.5, z = ac.z }
      local heading = headingFromVec(dc.x - ac.x, dc.y - ac.y)

      TriggerClientEvent('palm6_fc_combat:finisher', attSrc, {
          matchId = matchId, cid = attCid, startAt = startAt,
          origin = origin, heading = heading,
          sceneDict = FINISHER_DICT, sceneAnim = FINISHER_ANIM_ATTACKER,
      })
      TriggerClientEvent('palm6_fc_combat:finisher', defSrc, {
          matchId = matchId, cid = defCid, startAt = startAt,
          origin = origin, heading = heading,
          sceneDict = FINISHER_DICT, sceneAnim = FINISHER_ANIM_VICTIM,
      })

      writeMatchState(matchId)   -- push the spent meter to the HUD (T9) immediately

      -- Server-authoritative damage lands at scene end (after windup + scene).
      SetTimeout(FINISHER_WINDUP_MS + FinCfg.Blazin.SceneDurationMs, function()
          Fin.applyDamage(matchId)
      end)
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0. (`Fin.applyDamage` is a runtime field access, defined in Step 4 — parses fine now.)

- [ ] **Step 3: Server — `Fin.tryTrigger` (heavy + full-meter gate).** Append below Step 2:
  ```lua
  -- Called from the T7 connect handler (Step 6) right after a LANDED connect
  -- adds momentum to the attacker. Fires only on a HEAVY move at a full meter.
  function Fin.tryTrigger(matchId, attCid, defCid, moveId)
      if not FinCfg.Blazin.HeavyQualifies then return end
      local move = exports.palm6_fc_core:GetMove(moveId)
      if not move or move.kind ~= 'heavy' then return end
      local mom = fightMom[finKey(matchId, attCid)] or 0
      if mom < FinCfg.Blazin.FullThreshold then return end
      Fin.start(matchId, attCid, defCid)
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0.

- [ ] **Step 4: Server — `Fin.cleanup` + `Fin.applyDamage` (damage on scene end; no-op if resolved; KO path).** Append below Step 3:
  ```lua
  function Fin.cleanup(matchId)
      local st = matches[matchId]
      local f  = finishers[matchId]
      if st and f then
          st.inFinisher[f.attCid] = nil
          st.inFinisher[f.defCid] = nil
      end
      finishers[matchId] = nil
  end

  -- Applies the finisher damage authoritatively (§7 step 4). No-op if the match
  -- already resolved (DC-beats-finisher precedence, §5) -- never a double flip,
  -- never HP mutation on a dead row.
  function Fin.applyDamage(matchId)
      local f = finishers[matchId]
      if not f or f.done then return end
      f.done = true

      local st = matches[matchId]
      if not st or st.resolving then
          Fin.cleanup(matchId)          -- clear record; teardown already dropped the clients
          return
      end

      local reduce = math.min(FINISHER_MAX_REDUCE, (f.mash or 0) * FinCfg.Blazin.MashReducePerHit)
      local dmg    = math.floor(FinCfg.Blazin.BaseFinisherDamage * (1.0 - reduce))

      local dk = finKey(matchId, f.defCid)
      local hp = math.max(0, (fightHp[dk] or FinCfg.Vitals.StartHP) - dmg)
      fightHp[dk] = hp

      local attCid, defCid = f.attCid, f.defCid
      Fin.cleanup(matchId)
      writeMatchState(matchId)

      if hp <= 0 then
          -- KO: victim's OWN client ragdolls (T7 pattern), then the single
          -- resolver flips the row atomically (method='finisher').
          local defSrc = (st.cidA == defCid) and st.srcA or st.srcB
          if defSrc then
              TriggerClientEvent('palm6_fc_combat:koRagdoll', defSrc, { matchId = matchId })
          end
          resolveFight(matchId, attCid, 'finisher')
      end
  end
  ```
  Note: the finisher-KO relies on **T7's `koRagdoll` handler unfreezing the victim ped** (the finisher froze it); confirm T7 does `FreezeEntityPosition(ped,false)` before `SetPedToRagdoll`. Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0.

- [ ] **Step 5: Server — victim mash handler (`palm6_fc_combat:break`).** Append below Step 4:
  ```lua
  -- Victim mash -> reduces the pending finisher damage (§7 fairness). Only the
  -- CURRENT finisher's victim can accrue mashes. Combat-class eventguard budget
  -- (T11: 80/10s, drop-not-kick) sits in front of this.
  RegisterNetEvent('palm6_fc_combat:break', function(d)
      local src = source
      if type(d) ~= 'table' then return end
      local matchId = tonumber(d.matchId)
      if not matchId then return end
      local f = finishers[matchId]
      if not f or f.done then return end
      if Bridge.GetCitizenId(src) ~= f.defCid then return end
      f.mash = (f.mash or 0) + 1
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0.

- [ ] **Step 6: Server — wire the trigger into the T7 connect handler.** Locate where T7 applies momentum to the attacker on a landed connect: `grep -n "fightMom\[" "resources/[custom]/palm6_fc_combat/server/main.lua"`. Immediately AFTER the line that increments the **attacker's** `fightMom[...]` and BEFORE that handler's `writeMatchState(...)` call, insert (matching T7's actual local names for match id / attacker cid / defender cid / move id — likely `matchId`, the attacker/defender cid locals, and the incoming `moveId`):
  ```lua
  Fin.tryTrigger(matchId, attCid, defCid, moveId)   -- Blazin finisher trigger (T8); rename locals to match T7
  ```
  `Fin` is a global set when this chunk loads; the call resolves at runtime, so definition order in-file does not matter. Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0.

- [ ] **Step 7: Server — ace-gated `/fcfin` finisher exerciser.** Append to the end of `server/main.lua`:
  ```lua
  -- Dev: force a finisher on an already-LIVE in-memory match (skips grinding a
  -- full meter during a 2-client feel-test). Ace-gated like /fcdebug (T4) --
  -- Bridge.RegisterCommand hardcodes restricted=false, so gate IN-handler.
  RegisterCommand('fcfin', function(src, args)
      if src ~= 0 and not IsPlayerAceAllowed(src, 'palm6_fc.debug') then return end
      local matchId = tonumber(args[1])
      local attCid  = args[2]
      if not matchId or not attCid then return end
      local st = matches[matchId]
      if not st then return end
      if attCid ~= st.cidA and attCid ~= st.cidB then return end
      local defCid = (st.cidA == attCid) and st.cidB or st.cidA
      Fin.start(matchId, attCid, defCid)
  end, false)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/server/main.lua"` → exit 0.

- [ ] **Step 8: Client — finisher constants, state, cam helpers, abort/end.** Append to the END of `client/main.lua`:
  ```lua
  -- ==========================================================================
  -- Blazin finisher (T8) -- client half. Runs the scene on THIS client's OWN
  -- ped ONLY (§7): never drives the other ped. Interruptible -- abortFinisherLocal()
  -- stops the scene task + clears the handle BEFORE unfreeze/timescale/cam
  -- (§11), and is called at the TOP of the palm6_fc_combat:teardown handler
  -- (Step 10). A per-client `finisherActive` flag stops a torn-down player from
  -- being re-frozen.
  -- ==========================================================================
  local FinCfg = exports.palm6_fc_core:Config()

  local FINISHER_DICT        = 'mini@takedowns@front'
  local FINISHER_ANIM_VICTIM = 'victim_takedown_front'   -- role tag: this recipient is the mash-side victim
  local FINISHER_WINDUP_MS   = 800     -- MUST match the server constant (Step 1)
  local FINISHER_TIMESCALE   = 0.4     -- participant slow-mo (feel-test)

  local finisherActive = false
  local finisherScene  = nil
  local finisherCam    = nil

  local function stopFinisherCam()
      if finisherCam then
          RenderScriptCams(false, true, 300, true, true)
          DestroyCam(finisherCam, false)
          finisherCam = nil
      end
  end

  local function startFinisherCam(origin)
      finisherCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
          origin.x + 1.6, origin.y + 1.6, origin.z + 0.7, 0.0, 0.0, 0.0, 42.0, false, 2)
      SetCamActive(finisherCam, true)
      RenderScriptCams(true, false, 0, true, true)
      -- slow dolly toward the action over the full lock
      SetCamParams(finisherCam,
          origin.x + 2.4, origin.y + 2.4, origin.z + 1.0, 0.0, 0.0, 0.0, 42.0,
          FINISHER_WINDUP_MS + FinCfg.Blazin.SceneDurationMs)
  end

  -- Hard abort (KO / DC / void / resource-stop). Stops the scene task + clears
  -- the handle FIRST, then drops timescale/cam and unfreezes (belt-and-suspenders
  -- against a stranded frozen ped). GLOBAL so the T6 teardown handler can call it.
  function abortFinisherLocal()
      if not finisherActive and not finisherScene then return end
      finisherActive = false
      finisherScene  = nil
      local ped = PlayerPedId()
      ClearPedTasksImmediately(ped)     -- kill the synced-scene task FIRST (§11 ordering)
      stopFinisherCam()
      SetTimeScale(1.0)
      ClearTimecycleModifier()
      FreezeEntityPosition(ped, false)
      -- invincibility / CanRagdoll are re-asserted by the T7 LIVE hardening loop
      -- (non-KO), or handled by the koRagdoll path (KO).
  end

  -- Soft end (non-KO scene finished): resume fighting, match still LIVE.
  local function endFinisherLocal()
      if not finisherActive then return end
      finisherActive = false
      finisherScene  = nil
      stopFinisherCam()
      SetTimeScale(1.0)
      ClearTimecycleModifier()
      local ped = PlayerPedId()
      ClearPedTasks(ped)
      FreezeEntityPosition(ped, false)
  end
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/client/main.lua"` → exit 0.

- [ ] **Step 9: Client — `palm6_fc_combat:finisher` handler (preload, telegraph+mash, own-ped scene, slow-mo, auto-end).** Append below Step 8:
  ```lua
  RegisterNetEvent('palm6_fc_combat:finisher', function(d)
      if type(d) ~= 'table' or type(d.origin) ~= 'table' then return end
      if finisherActive then return end

      RequestAnimDict(d.sceneDict)
      local dl = GetGameTimer() + 2000
      while not HasAnimDictLoaded(d.sceneDict) and GetGameTimer() < dl do Wait(10) end
      if not HasAnimDictLoaded(d.sceneDict) then return end

      finisherActive = true
      local isVictim = (d.sceneAnim == FINISHER_ANIM_VICTIM)   -- role from the tailored clip

      -- Telegraph + mash window (BEFORE impact). Victim mashes JUMP to shave damage.
      PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
      if isVictim then
          BeginTextCommandDisplayHelp('STRING')
          AddTextComponentSubstringPlayerName('~INPUT_JUMP~ mash to break the finisher!')
          EndTextCommandDisplayHelp(0, false, true, FINISHER_WINDUP_MS + FinCfg.Blazin.SceneDurationMs)
          CreateThread(function()
              while finisherActive do
                  if IsControlJustPressed(0, 22) then   -- 22 = JUMP
                      TriggerServerEvent('palm6_fc_combat:break', { matchId = d.matchId })
                  end
                  Wait(0)
              end
          end)
      end

      Wait(FINISHER_WINDUP_MS)
      if not finisherActive then return end     -- aborted mid-windup (Step 10 / KO)

      local ped = PlayerPedId()
      SetEntityCoordsNoOffset(ped, d.origin.x, d.origin.y, d.origin.z, false, false, false)
      SetEntityHeading(ped, d.heading)
      FreezeEntityPosition(ped, true)
      SetEntityInvincible(ped, true)
      SetPedCanRagdoll(ped, false)

      finisherScene = CreateSynchronizedScene(d.origin.x, d.origin.y, d.origin.z, 0.0, 0.0, d.heading, 2)
      SetSynchronizedSceneLooped(finisherScene, false)
      TaskSynchronizedScene(ped, finisherScene, d.sceneDict, d.sceneAnim, 8.0, -8.0, 0, 0, 0, 0)

      startFinisherCam(d.origin)
      SetTimeScale(FINISHER_TIMESCALE)                 -- participant-only (spectators never got this event)
      PlaySoundFrontend(-1, 'Bed', 'MP_LOBBY_SOUNDS', true)   -- finisher stinger (T11 finalizes the sound set)

      -- Non-KO end: server applies damage at the SAME total; if it wasn't a KO,
      -- no teardown arrives, so we self-restore and resume fighting.
      SetTimeout(FinCfg.Blazin.SceneDurationMs, function()
          if finisherActive then endFinisherLocal() end
      end)
  end)
  ```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/client/main.lua"` → exit 0.

- [ ] **Step 10: Client — abort the scene at the TOP of the teardown handler.** Locate the T6 canonical teardown: `grep -n "palm6_fc_combat:teardown" "resources/[custom]/palm6_fc_combat/client/main.lua"`. As the **first statement inside** that `RegisterNetEvent('palm6_fc_combat:teardown', function(...) ... end)` body (before any unfreeze / `SetTimeScale` / cam release T6 does), insert:
  ```lua
  abortFinisherLocal()   -- T8: stop the synced scene + clear the handle BEFORE T6 unfreeze/timescale/cam (§11)
  ```
  `abortFinisherLocal` is a global defined in Step 8; the call resolves at runtime regardless of in-file order. Verify: `npx luaparse "resources/[custom]/palm6_fc_combat/client/main.lua"` → exit 0.

- [ ] **Step 11: Boot-verify on a local FXServer.** Start the local server (per the repo's run script / `FXServer.exe +exec server.cfg`). In the console confirm: no `SCRIPT ERROR` mentioning `palm6_fc_combat`, and `palm6_fc_combat` reaches `started`. Then, with `Config.Enabled=false` still set in fc_core, confirm the resource is prod-inert (no finisher paths run without a live match). Deterministic scene smoke (needs a real T6 challenge to populate `matches[matchId]`): from the server console (`src==0` bypasses the ace check) after two test clients are LIVE, run `fcfin <matchId> <attackerCid>` and confirm both fighters lock into the scene, damage lands after ~`800 + SceneDurationMs` ms, and a non-KO resolve leaves both fighting again with `SetTimeScale` back to 1.0 (no stranded freeze). Expected: 0 script errors; the finisher plays and tears down cleanly.

- [ ] **Step 12: David feel-test (in-game — the only gate for feel/pose/money-safety-under-combat).** Two clients (or one + a spawned bot) at the ring, real challenge → LIVE:
  - Finisher fires ONLY on a landed **heavy** (`hook`/`uppercut`/`body`) at a **full** meter — never on lights, never partial.
  - The two peds square up and play the scene at the shared origin; the pose reads as a finish. **If they face away, add `180.0` in `headingFromVec` (Step 1); if the clip is wrong, swap `FINISHER_DICT`/`FINISHER_ANIM_*` (Steps 1/8) — §7 accepts small phase drift on the frozen, position-locked peds.**
  - Participant slow-mo + dolly cam feel right; a spectator sees the replicated scene at NORMAL speed (spectators never received the event).
  - Mashing JUMP visibly reduces damage: a low-HP victim is still KO'd; a healthy victim survives with a big HP swing (not a guaranteed instant KO).
  - **Interrupt/DC:** victim DCs mid-finisher → attacker unfreezes, no stranded freeze/slow-mo/cam, match forfeits to the attacker, and the finisher-end applies NOTHING (DC beats finisher-end; `applyDamage` no-ops on `resolving`) — no double resolve.
  - **KO-from-finisher:** victim ragdolls, row resolves `method='finisher'`, and the entry-pot + parimutuel purse settle exactly once (verify via bank + no duplicate payout).
  - **Ring-out during the windup:** the T7 ring-poll forfeit fires teardown → invincibility drops, scene aborts, no double resolve.
  - No lingering global `SetTimeScale`, timecycle modifier, or script cam after ANY exit path.

- [ ] **Step 13: Commit.** `cd "C:/Users/Mgtda/Projects/Active/gtarp" && git add "resources/[custom]/palm6_fc_combat/server/main.lua" "resources/[custom]/palm6_fc_combat/client/main.lua" && git commit -m "$(cat <<'EOF'
palm6_fc_combat: Blazin finisher (per-client own-ped scene, interruptible)

Heavy+full-meter trigger -> server shared origin/heading + start stamp ->
each fighter runs the synced scene on its OWN ped. Server owns the
mash-to-reduce tally (palm6_fc_combat:break) and applies finisher damage on
scene end, no-op if already resolved (DC beats finisher-end). Teardown aborts
the scene task + clears the handle before unfreeze/timescale/cam. Ace-gated
/fcfin exerciser. luaparse-clean, boot-verified.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"`. (If the repo branches off `main` per the palm6 push policy, create/checkout the feature branch first; do NOT push unless David asks.)

---

### Task 9: palm6_fc_hud — NUI HUD (two health bars, stamina, Blazin) + sportsbook odds board

New **display-only** NUI resource. Reads the server-owned fight statebags (T1/T7) → renders two HP bars + stamina + Blazin; listens for T3 `palm6_fightclub:oddsUpdate` → renders the §10b sportsbook board client-side (decimal / American / implied% / payout-preview computed from the broadcast pool totals). **Zero authority**: it never writes fight state, never sends a combat or bet event, and mints nothing. Ships prod-inert behind `exports.palm6_fc_core:Config().Enabled`.

**Files:**
- CREATE `resources/[custom]/palm6_fc_hud/fxmanifest.lua`
- CREATE `resources/[custom]/palm6_fc_hud/bridge/cl_game.lua`
- CREATE `resources/[custom]/palm6_fc_hud/html/index.html`
- CREATE `resources/[custom]/palm6_fc_hud/client/main.lua`
- CREATE `resources/[custom]/palm6_fc_hud/server/main.lua`

**Interfaces:**
- **Consumes (T1 fc_core, shared_scripts exports — both realms):** `exports.palm6_fc_core:Config()` → reads `.Enabled`, `.Vitals.StartHP`, `.Vitals.MaxStamina`, `.Blazin.FullThreshold`, `.Betting.RakePct`, `.WinnerPursePct`, `.Betting.MinBet`. `exports.palm6_fc_core:StateKeys()` → `{ MATCH_PREFIX='fc:match:', PLAYER_ACTIVE='fc:active', PLAYER_SLOT='fc:slot', matchKey=fn }`.
- **Consumes (T1/T7 statebags):** `GlobalState['fc:match:'..matchId]` = `{ status, roundStarted, slot={ [1]={hp,stam,blazin,name,model}, [2]={hp,stam,blazin,name,model} } }`; `LocalPlayer.state['fc:active']` = matchId|false; `LocalPlayer.state['fc:slot']` = 1|2.
- **Consumes (T3 net event):** `RegisterNetEvent('palm6_fightclub:oddsUpdate', fn)` payload `{ matchId:int, sideA:int, sideB:int, betCount:int, secsLeft:int }`.
- **Consumes (T5 server-only exports, lazily via this resource's OWN server callback):** `exports.palm6_fc_progression:GetRep(cid)` → int, `:GetRank(cid)` → int.
- **Produces:** `lib.callback.register('palm6_fc_hud:getCareer', ...)` (server, read-only, resolves cid server-side). NUI messages are internal to this resource only. **No net event any other resource consumes** (matches contract: "No events other resources consume").
- **Contract reconciliation (call out for the executor):** the SHARED-CONTRACT T9 manifest sketch lists only `shared_scripts{@ox_lib}` + `client_scripts{client/main.lua}`. This task ALSO ships `bridge/cl_game.lua` (mandatory per §13 "Bridge pattern + RFC-001 metadata + palm6_<domain> naming" and the palm6_clout mirror this task follows) and `server/main.lua` (the ONLY correct way to satisfy "consumes T5 exports GetRep/GetRank" from a client HUD — a read-only ox_lib callback). Neither adds authority; both are pure display plumbing. **Do NOT** add `palm6_fc_progression` to `dependencies` (T11 ensure order starts progression AFTER fc_hud — a hard dep would block boot; the callback pcall-guards a not-yet-started progression instead).

---

- [ ] **Step 1: Scaffold dirs + write `fxmanifest.lua`.** Create the resource. Write `resources/[custom]/palm6_fc_hud/fxmanifest.lua` exactly:
```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 fc_hud — Def Jam fight HUD: two health bars, stamina, Blazin meter + client-rendered sportsbook odds board. Display-only, zero authority (RFC-001, palm6_clout NUI mirror).'

ui_page 'html/index.html'

files {
    'html/index.html',
}

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game/NUI/statebag/export adapter — before client logic
    'client/main.lua',
}

server_scripts {
    'server/main.lua',      -- read-only career callback only
}

dependencies {
    'ox_lib',
    'palm6_fc_core',        -- shared_scripts Config()/StateKeys(); ensure-order guarantees it loads first
}
```
(Create the parent dirs with the Write tool as you author each file below — Write creates missing directories.)

- [ ] **Step 2: Write `bridge/cl_game.lua` (the ONLY file touching NUI / statebags / exports).** Write `resources/[custom]/palm6_fc_hud/bridge/cl_game.lua`:
```lua
-- ============================================================================
-- palm6_fc_hud/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls native
-- NUI messaging, reads statebags, or calls cross-resource exports. Pure logic
-- in client/main.lua calls Game.* only, so the HUD ports to GTA VI by
-- rewriting THIS FILE (palm6_clout bridge precedent, docs/GTA6-READINESS.md).
--
-- Display-only: nothing here writes fight state or sends a gameplay event.
-- ============================================================================

Game = {}

-- Push a display message to the NUI overlay. The HUD never takes input focus
-- (pure overlay), so no SetNuiFocus is ever called.
function Game.SendUIMessage(msg)
    SendNUIMessage(msg)
end

-- fc_core Config (shared_scripts export, present on the client realm). Returns
-- nil until fc_core has loaded so the caller can retry.
function Game.CoreConfig()
    local ok, cfg = pcall(function() return exports.palm6_fc_core:Config() end)
    if ok then return cfg end
    return nil
end

-- fc_core statebag key constants. Returns nil until fc_core has loaded.
function Game.StateKeys()
    local ok, keys = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    if ok then return keys end
    return nil
end

-- Local player's active match id (int) or false/nil when not fighting.
function Game.GetLocalActive(activeKey)
    return LocalPlayer.state[activeKey]
end

-- Local player's fight slot (1|2) or nil.
function Game.GetLocalSlot(slotKey)
    return LocalPlayer.state[slotKey]
end

-- Throttled global fight statebag for a match, or nil when unset.
function Game.GetMatchState(matchKey)
    return GlobalState[matchKey]
end

-- Read-only career fetch (rep/rank) via this resource's own server callback,
-- which lazily reads palm6_fc_progression. Returns { rep, rank } or nil.
function Game.FetchCareer()
    local ok, res = pcall(function() return lib.callback.await('palm6_fc_hud:getCareer', false) end)
    if ok then return res end
    return nil
end
```
Then verify: `npx luaparse "resources/[custom]/palm6_fc_hud/bridge/cl_game.lua"` → expected: prints the AST and exits 0 (no `SyntaxError`).

- [ ] **Step 3: Write the complete `html/index.html` (structure + CSS + JS, self-contained, no CDNs).** Write `resources/[custom]/palm6_fc_hud/html/index.html`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>fc.hud</title>
<style>
  /* palm6_fc_hud NUI — self-contained (no CDNs/fonts/network). Pure overlay:
     never takes focus, sends nothing back. All numbers come from the server
     (statebags + the parimutuel pool broadcast); the sportsbook math below is
     display-only — settlement IS the pool split, so a spoofed client only
     fools itself. */
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: 100%; height: 100%; background: transparent; overflow: hidden;
    font-family: 'Segoe UI', 'Arial', sans-serif; user-select: none; color: #eef; }

  /* ---- fight vitals (two HP bars + stamina + Blazin) ---- */
  #vitals { position: absolute; top: 3vh; left: 50%; transform: translateX(-50%);
    width: 640px; max-width: 92vw; display: none; }
  #vitals.show { display: block; }
  .fbar-row { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }
  .fname { width: 150px; font-weight: 800; font-size: 13px; letter-spacing: .5px;
    text-shadow: 0 1px 3px #000; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .fname.right { text-align: right; }
  .track { flex: 1; height: 16px; background: rgba(0,0,0,.55);
    border: 1px solid rgba(255,255,255,.14); border-radius: 4px; overflow: hidden; }
  .fill { height: 100%; width: 100%; transition: width .12s linear; }
  .hp .fill  { background: linear-gradient(90deg, #ff3b3b, #ff7a5c); }
  .opp .fill { background: linear-gradient(90deg, #ff7a5c, #ff3b3b); }
  /* opponent bar drains right-to-left (mirror), reads like Def Jam */
  .opp .track { transform: scaleX(-1); }
  .meta { margin-top: 4px; display: flex; gap: 8px; align-items: center; }
  .mini { flex: 1; height: 9px; background: rgba(0,0,0,.5);
    border: 1px solid rgba(255,255,255,.12); border-radius: 3px; overflow: hidden; }
  .mini .fill { transition: width .12s linear; }
  .stam .fill   { background: linear-gradient(90deg, #ffd23b, #7dff5c); }
  .blazin .fill { background: linear-gradient(90deg, #ff8a00, #ffd23b); }
  .lbl { font-size: 10px; font-weight: 700; letter-spacing: 1px; color: #b9c0cc; width: 54px; }
  #blazinWrap.ready .mini { box-shadow: 0 0 10px 2px #ffb23b; }
  #blazinWrap.ready .lbl { color: #ffb23b; animation: bpulse .8s ease-in-out infinite; }
  @keyframes bpulse { 0%,100% { opacity: 1; } 50% { opacity: .4; } }

  /* ---- sportsbook odds board ---- */
  #book { position: absolute; bottom: 4vh; right: 18px; width: 320px;
    background: rgba(9,10,16,.82); border: 1px solid rgba(255,255,255,.10);
    border-radius: 10px; padding: 12px 14px; display: none; backdrop-filter: blur(2px); }
  #book.show { display: block; }
  #book h2 { font-size: 12px; letter-spacing: 2px; color: #7ab8ff; margin-bottom: 2px; }
  #book.closed h2 { color: #ff5c5c; }
  #bookSub { font-size: 10px; color: #9aa0aa; margin-bottom: 8px; }
  .side { display: grid; grid-template-columns: 1fr auto; gap: 2px 8px;
    padding: 7px 0; border-top: 1px solid rgba(255,255,255,.07); }
  .side .who { font-weight: 800; font-size: 13px; }
  .side .price { font-weight: 800; font-size: 16px; text-align: right;
    font-variant-numeric: tabular-nums; }
  .side .row2 { grid-column: 1 / 3; display: flex; justify-content: space-between;
    font-size: 10px; color: #aab0bc; margin-top: 1px; }
  .side .row2 b { color: #dfe4ee; }
  #bookCap { margin-top: 8px; font-size: 10px; color: #ffc44d; }
  #bookCap .thin { color: #ff8a5c; display: none; }
  #bookCap .thin.show { display: inline; }

  /* ---- career panel (rep/rank, read-only) ---- */
  #career { position: absolute; top: 3vh; right: 18px; width: 200px;
    background: rgba(9,10,16,.86); border: 1px solid rgba(255,255,255,.10);
    border-radius: 10px; padding: 12px 14px; display: none; text-align: center; }
  #career.show { display: block; }
  #career h3 { font-size: 11px; letter-spacing: 2px; color: #7dff9e; }
  #career .rep { font-size: 26px; font-weight: 800; margin-top: 4px; }
  #career .rank { font-size: 11px; color: #aab0bc; margin-top: 2px; }
</style>
</head>
<body>

<div id="vitals">
  <div class="fbar-row hp opp">
    <div class="fname" id="oppName">Opponent</div>
    <div class="track"><div class="fill" id="oppHp"></div></div>
  </div>
  <div class="fbar-row hp me">
    <div class="fname" id="meName">You</div>
    <div class="track"><div class="fill" id="meHp"></div></div>
  </div>
  <div class="meta stam">
    <span class="lbl">STAMINA</span>
    <div class="mini"><div class="fill" id="meStam"></div></div>
  </div>
  <div class="meta blazin" id="blazinWrap">
    <span class="lbl">BLAZIN</span>
    <div class="mini"><div class="fill" id="meBlazin"></div></div>
  </div>
</div>

<div id="book">
  <h2 id="bookTitle">LIVE ODDS</h2>
  <div id="bookSub">indicative &mdash; locks at close</div>
  <div class="side" id="sideA">
    <div class="who">FIGHTER 1</div><div class="price" id="aPrice">&mdash;</div>
    <div class="row2"><span>impl <b id="aImpl">&mdash;</b></span><span>$<b id="aStake">0</b> in</span></div>
    <div class="row2"><span id="aPrev">&mdash;</span></div>
  </div>
  <div class="side" id="sideB">
    <div class="who">FIGHTER 2</div><div class="price" id="bPrice">&mdash;</div>
    <div class="row2"><span>impl <b id="bImpl">&mdash;</b></span><span>$<b id="bStake">0</b> in</span></div>
    <div class="row2"><span id="bPrev">&mdash;</span></div>
  </div>
  <div id="bookCap"><span id="capMain">indicative &mdash; locks at close</span> <span class="thin" id="capThin">&middot; thin pool</span></div>
</div>

<div id="career">
  <h3>FIGHT REP</h3>
  <div class="rep" id="repVal">0</div>
  <div class="rank" id="rankVal">Rank 0</div>
</div>

<script>
(function () {
  'use strict';

  var vitals = document.getElementById('vitals');
  var oppName = document.getElementById('oppName'), meName = document.getElementById('meName');
  var oppHp = document.getElementById('oppHp'), meHp = document.getElementById('meHp');
  var meStam = document.getElementById('meStam'), meBlazin = document.getElementById('meBlazin');
  var blazinWrap = document.getElementById('blazinWrap');

  var book = document.getElementById('book'), bookTitle = document.getElementById('bookTitle');
  var bookSub = document.getElementById('bookSub');
  var aPrice = document.getElementById('aPrice'), bPrice = document.getElementById('bPrice');
  var aImpl = document.getElementById('aImpl'), bImpl = document.getElementById('bImpl');
  var aStake = document.getElementById('aStake'), bStake = document.getElementById('bStake');
  var aPrev = document.getElementById('aPrev'), bPrev = document.getElementById('bPrev');
  var capThin = document.getElementById('capThin'), capMain = document.getElementById('capMain');

  var career = document.getElementById('career');
  var repVal = document.getElementById('repVal'), rankVal = document.getElementById('rankVal');

  var maxHp = 100, maxStam = 100, maxBlazin = 100;
  var bookHideTimer = null, careerHideTimer = null;

  function pct(v, max) {
    v = Number(v) || 0; max = Number(max) || 1;
    var p = (v / max) * 100;
    return p < 0 ? 0 : p > 100 ? 100 : p;
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // ---- sportsbook math (§10b) — display-only, mirrors the spec formulas ----
  function decimalFor(sideTotal, payoutPool) {
    if (sideTotal <= 0) return null;            // no action on this side
    return payoutPool / sideTotal;
  }
  function american(dec) {
    if (dec == null || dec <= 1) return null;   // below-stake chalk: no ML shown
    if (dec >= 2) return '+' + Math.round((dec - 1) * 100);
    return '-' + Math.round(100 / (dec - 1));
  }
  function preview(w, sideTotal, P, takeout) {   // your gross return incl own stake
    if (sideTotal + w <= 0) return 0;
    return w * (P + w) * (1 - takeout) / (sideTotal + w);
  }
  function money(n) { return '$' + Math.round(Number(n) || 0).toLocaleString(); }

  function renderBoard(d) {
    var A = Number(d.sideA) || 0, B = Number(d.sideB) || 0, P = A + B;
    var takeout = Number(d.takeout) || 0.25, minBet = Number(d.minBet) || 50;
    var closed = !!d.closed;
    var payoutPool = P * (1 - takeout);

    book.className = 'show' + (closed ? ' closed' : '');
    bookTitle.innerHTML = closed ? 'CLOSED &mdash; closing line' : 'LIVE ODDS';
    bookSub.innerHTML = closed
      ? 'final pool ' + money(P)
      : 'closes in ' + Math.max(0, Number(d.secsLeft) || 0) + 's';

    aStake.textContent = A.toLocaleString();
    bStake.textContent = B.toLocaleString();

    var dA = decimalFor(A, payoutPool), dB = decimalFor(B, payoutPool);
    aPrice.textContent = dA ? dA.toFixed(2) + 'x' : '—';
    bPrice.textContent = dB ? dB.toFixed(2) + 'x' : '—';
    var mlA = american(dA), mlB = american(dB);
    aImpl.textContent = P > 0 ? Math.round((A / P) * 100) + '%' + (mlA ? ' (' + mlA + ')' : '') : '—';
    bImpl.textContent = P > 0 ? Math.round((B / P) * 100) + '%' + (mlB ? ' (' + mlB + ')' : '') : '—';

    aPrev.innerHTML = money(minBet) + ' bet &rarr; ' + money(preview(minBet, A, P, takeout));
    bPrev.innerHTML = money(minBet) + ' bet &rarr; ' + money(preview(minBet, B, P, takeout));

    capMain.innerHTML = closed ? 'projections frozen at close' : 'indicative &mdash; locks at close';
    capThin.className = 'thin' + ((Number(d.betCount) || 0) < 3 ? ' show' : '');

    // Auto-retire a closed board so it doesn't linger; live boards persist.
    if (bookHideTimer) { clearTimeout(bookHideTimer); bookHideTimer = null; }
    if (closed) bookHideTimer = setTimeout(function () { book.className = ''; }, 8000);
  }

  window.addEventListener('message', function (e) {
    var d = e.data || {};
    if (d.action === 'hud:open') {
      maxHp = Number(d.maxHp) || 100;
      maxStam = Number(d.maxStam) || 100;
      maxBlazin = Number(d.maxBlazin) || 100;
      vitals.className = 'show';
    } else if (d.action === 'hud:vitals') {
      var mine = Number(d.mySlot) === 2 ? d.s2 : d.s1;
      var opp  = Number(d.mySlot) === 2 ? d.s1 : d.s2;
      mine = mine || {}; opp = opp || {};
      meName.textContent  = mine.name || 'You';
      oppName.textContent = opp.name || 'Opponent';
      meHp.style.width  = pct(mine.hp, maxHp) + '%';
      oppHp.style.width = pct(opp.hp, maxHp) + '%';
      meStam.style.width   = pct(mine.stam, maxStam) + '%';
      meBlazin.style.width = pct(mine.blazin, maxBlazin) + '%';
      blazinWrap.className = 'meta blazin' + ((Number(mine.blazin) || 0) >= maxBlazin ? ' ready' : '');
    } else if (d.action === 'hud:close') {
      vitals.className = '';
    } else if (d.action === 'odds:update') {
      renderBoard(d);
    } else if (d.action === 'odds:hide') {
      if (bookHideTimer) { clearTimeout(bookHideTimer); bookHideTimer = null; }
      book.className = '';
    } else if (d.action === 'career:show') {
      repVal.textContent = Number(d.rep || 0).toLocaleString();
      rankVal.textContent = 'Rank ' + (Number(d.rank || 0));
      career.className = 'show';
      if (careerHideTimer) clearTimeout(careerHideTimer);
      careerHideTimer = setTimeout(function () { career.className = ''; }, 6000);
    } else if (d.action === 'career:hide') {
      career.className = '';
    }
  });
})();
</script>
</body>
</html>
```

- [ ] **Step 4: Browser render-verify the NUI (no server needed — the fastest T9 gate).** Open the file directly and drive it with `postMessage` in DevTools (the standard self-contained NUI check). Run:
```bash
cmd //c start "" "C:\Users\Mgtda\Projects\Active\gtarp\resources\[custom]\palm6_fc_hud\html\index.html"
```
Then in the browser DevTools Console paste each and confirm the described result:
```js
// vitals open + a mid-fight snapshot (I am slot 1)
window.postMessage({action:'hud:open', mySlot:1, maxHp:100, maxStam:100, maxBlazin:100}, '*');
window.postMessage({action:'hud:vitals', mySlot:1,
  s1:{hp:64, stam:40, blazin:100, name:'Ace Malone'},
  s2:{hp:22, stam:70, blazin:30,  name:'Big Dozer'}}, '*');
// EXPECT: two bars visible; my (bottom) bar ~64%, opponent (top) mirror bar ~22%,
//         stamina ~40%, Blazin FULL with the orange READY glow/pulse.

// live odds board, lopsided pool, thin
window.postMessage({action:'odds:update', matchId:1, sideA:3000, sideB:1000,
  betCount:2, secsLeft:35, takeout:0.25, minBet:50, closed:false}, '*');
// EXPECT: board shows FIGHTER 1 ~0.75x (below-stake chalk, ML '—'), FIGHTER 2 ~2.25x (+125),
//         impl 75% / 25%, '$50 bet -> $…' previews, 'thin pool' caption on (betCount<3),
//         'indicative — locks at close'.

// close (GoLive)
window.postMessage({action:'odds:update', matchId:1, sideA:3000, sideB:1000,
  betCount:5, secsLeft:0, takeout:0.25, minBet:50, closed:true}, '*');
// EXPECT: title 'CLOSED — closing line' (red), 'projections frozen at close', auto-hides after 8s.

// career panel
window.postMessage({action:'career:show', rep:640, rank:3}, '*');
// EXPECT: rep 640, 'Rank 3', auto-hides after 6s.
```
If any bar/price is wrong, fix `html/index.html` and re-run before proceeding.

- [ ] **Step 5: Write `client/main.lua` (pure logic; Game.* only).** Write `resources/[custom]/palm6_fc_hud/client/main.lua`:
```lua
-- ============================================================================
-- palm6_fc_hud/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for NUI / statebags / exports.
-- DISPLAY-ONLY: reads the server-owned fight statebags (T1/T7) and the T3
-- betting-pool broadcast, renders the HUD, and has ZERO authority. It never
-- writes fight state, never sends a combat/bet event, and mints nothing.
-- Prod-inert until exports.palm6_fc_core:Config().Enabled is true.
-- ============================================================================

local CFG                       -- cached fc_core Config
local SK                        -- cached fc_core StateKeys
local takeout = 0.25            -- RakePct + WinnerPursePct (from CFG)
local minBet  = 50              -- CFG.Betting.MinBet
local maxHp, maxStam, maxBlazin = 100, 100, 100

local hudOpen = false
local lastSig = nil             -- coalesce: only push vitals on change

-- Wait for fc_core (shared_scripts export) to be ready, cache constants.
CreateThread(function()
    while not (CFG and SK) do
        CFG = Game.CoreConfig()
        SK  = Game.StateKeys()
        Wait(500)
    end
    takeout   = (CFG.Betting and CFG.Betting.RakePct or 0.10) + (CFG.WinnerPursePct or 0.15)
    minBet    = (CFG.Betting and CFG.Betting.MinBet) or 50
    maxHp     = (CFG.Vitals and CFG.Vitals.StartHP) or 100
    maxStam   = (CFG.Vitals and CFG.Vitals.MaxStamina) or 100
    maxBlazin = (CFG.Blazin and CFG.Blazin.FullThreshold) or 100
end)

local function snap(s)
    if type(s) ~= 'table' then return { hp = 0, stam = 0, blazin = 0, name = '' } end
    return {
        hp     = math.max(0, math.floor(tonumber(s.hp) or 0)),
        stam   = math.max(0, math.floor(tonumber(s.stam) or 0)),
        blazin = math.max(0, math.floor(tonumber(s.blazin) or 0)),
        name   = s.name or '',
    }
end

local function sig(mySlot, s1, s2)
    return table.concat({ mySlot,
        s1.hp, s1.stam, s1.blazin, s1.name,
        s2.hp, s2.stam, s2.blazin, s2.name }, '|')
end

local function closeHud()
    if hudOpen then
        Game.SendUIMessage({ action = 'hud:close' })
        hudOpen = false
        lastSig = nil
    end
end

-- Vitals poll: tight (100ms) only while I am a fighter with a live statebag;
-- otherwise idle (750ms) with zero NUI traffic. Mirrors palm6_clout's
-- idle-until-active loop — no per-frame work on a 48-slot server.
CreateThread(function()
    while true do
        local wait = 750
        if CFG and SK and CFG.Enabled then
            local matchId = Game.GetLocalActive(SK.PLAYER_ACTIVE)
            if type(matchId) == 'number' then
                local st = Game.GetMatchState(SK.MATCH_PREFIX .. matchId)
                if type(st) == 'table' and type(st.slot) == 'table' then
                    local mySlot = Game.GetLocalSlot(SK.PLAYER_SLOT) or 1
                    local s1, s2 = snap(st.slot[1]), snap(st.slot[2])
                    if not hudOpen then
                        Game.SendUIMessage({ action = 'hud:open', mySlot = mySlot,
                            maxHp = maxHp, maxStam = maxStam, maxBlazin = maxBlazin })
                        hudOpen = true
                        lastSig = nil
                    end
                    local s = sig(mySlot, s1, s2)
                    if s ~= lastSig then
                        Game.SendUIMessage({ action = 'hud:vitals', mySlot = mySlot, s1 = s1, s2 = s2 })
                        lastSig = s
                    end
                    wait = 100
                else
                    closeHud()
                end
            else
                closeHud()
            end
        else
            closeHud()
        end
        Wait(wait)
    end
end)

-- T3 tote-board broadcast (to all/arena). Display only; the server computes
-- nothing authoritative from this render.
RegisterNetEvent('palm6_fightclub:oddsUpdate', function(d)
    if not CFG or not CFG.Enabled then return end
    d = d or {}
    local secsLeft = tonumber(d.secsLeft) or 0
    Game.SendUIMessage({
        action   = 'odds:update',
        matchId  = tonumber(d.matchId) or 0,
        sideA    = tonumber(d.sideA) or 0,
        sideB    = tonumber(d.sideB) or 0,
        betCount = tonumber(d.betCount) or 0,
        secsLeft = secsLeft,
        takeout  = takeout,
        minBet   = minBet,
        closed   = secsLeft <= 0,   -- GoLive leaves secsLeft<=0 → CLOSED closing line
    })
end)

-- Read-only career panel. /fccareer pops rep/rank for a few seconds. No
-- authority, no rate-limit needed (a read-only callback), inert when disabled.
RegisterCommand('fccareer', function()
    if not CFG or not CFG.Enabled then return end
    local res = Game.FetchCareer()
    if res then
        Game.SendUIMessage({ action = 'career:show', rep = res.rep or 0, rank = res.rank or 0 })
    end
end, false)

-- On resource stop (dev restart), make sure the overlay is fully cleared so no
-- stale HUD lingers on the client.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        Game.SendUIMessage({ action = 'hud:close' })
        Game.SendUIMessage({ action = 'odds:hide' })
        Game.SendUIMessage({ action = 'career:hide' })
    end
end)
```
Then verify: `npx luaparse "resources/[custom]/palm6_fc_hud/client/main.lua"` → exits 0, no `SyntaxError`.

- [ ] **Step 6: Write `server/main.lua` (the ONE read-only career callback).** Write `resources/[custom]/palm6_fc_hud/server/main.lua`:
```lua
-- ============================================================================
-- palm6_fc_hud/server/main.lua
--
-- The HUD is display-only. Its SOLE server surface is one read-only ox_lib
-- callback returning the caller's own rep/rank for the career panel. It:
--   * resolves the citizenid SERVER-SIDE (ignores any client-supplied args),
--   * reads palm6_fc_progression LAZILY (it may be down / starting — the T11
--     ensure order starts progression AFTER this resource, so a hard dependency
--     would block boot; pcall + GetResourceState guard it instead),
--   * writes nothing and mints nothing.
-- ============================================================================

local function getCitizenId(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and p and p.PlayerData then return p.PlayerData.citizenid end
    return nil
end

lib.callback.register('palm6_fc_hud:getCareer', function(src)
    local cid = getCitizenId(src)
    if not cid then return { rep = 0, rank = 0 } end
    local rep, rank = 0, 0
    pcall(function()
        if GetResourceState('palm6_fc_progression') == 'started' then
            rep  = exports.palm6_fc_progression:GetRep(cid) or 0
            rank = exports.palm6_fc_progression:GetRank(cid) or 0
        end
    end)
    return { rep = rep, rank = rank }
end)
```
Then verify: `npx luaparse "resources/[custom]/palm6_fc_hud/server/main.lua"` → exits 0, no `SyntaxError`.

- [ ] **Step 7: Full luaparse sweep + boot-verify (prod-inert).** Run every touched `.lua` through luaparse in one shot:
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp" && for f in bridge/cl_game.lua client/main.lua server/main.lua; do echo "== $f =="; npx luaparse "resources/[custom]/palm6_fc_hud/$f" >/dev/null && echo OK || echo FAIL; done
```
Expected: three `OK` lines. Then boot-verify on the local FXServer (fc_core from T1 must be started first per the ensure order; if T11's custom.cfg ensure block isn't wired yet, temporarily `ensure palm6_fc_core` then `ensure palm6_fc_hud` in your local cfg). In the server console confirm:
  - `ensure palm6_fc_hud` reports the resource `started` with **0 SCRIPT ERROR**.
  - With `Config.Enabled=false` (default), `/fccareer` does nothing and no HUD appears — **prod-inert** confirmed (the poll loop's `CFG.Enabled` gate and the command's early return both hold).
  - Flip fc_core `Config.Enabled=true` locally (do NOT commit this), restart, run `/fccareer` in-game → the career panel appears showing `0` / `Rank 0` (progression not yet started or empty → the pcall default). Confirms the callback wiring. Flip `Enabled` back to false before committing.

- [ ] **Step 8: Integration exercise + record David's feel-test items (no code).** Document these gates in the commit body; they run once the sibling resources exist (do NOT block T9's commit on them):
  - **Odds board end-to-end (needs T3+T4):** ace `/fcdebug open <cidA> <cidB>` → a `betting` row → `/fcbet <id> 1 200` and `/fcbet <id> 2 600` from two spectators → T3 `BroadcastOdds` fires `palm6_fightclub:oddsUpdate` every 2s → **the board renders live decimals/American/implied and the payout preview, `thin pool` clears once betCount≥3**. `/fcdebug live <id>` (GoLive) → the next broadcast carries `secsLeft<=0` → **board flips to `CLOSED — closing line` and freezes**.
  - **Vitals HUD end-to-end (needs T7):** once T7 writes `GlobalState['fc:match:'..id]` and `Player(src).state['fc:active']/['fc:slot']`, a fighter sees **two HP bars draining from the server HP, stamina, and the Blazin meter filling to the READY glow** — with NO client authority (kill the client script mid-fight and the server result is unchanged).
  - **David in-game feel-test (the standing rule — the only gate for these):** (1) HP-bar drain reads legible and Def-Jam-punchy at real combat cadence (opponent bar mirrors correctly); (2) the Blazin READY glow is unmissable when the meter caps; (3) the sportsbook board reads like a real book (prices/ML believable) and the `indicative — locks at close` / `CLOSED — closing line` honesty captions are clear; (4) `/fccareer` rep/rank feels right; (5) confirm NO horizontal scroll / overlay never steals focus / never blocks other UI at 1080p and ultrawide.

- [ ] **Step 9: Commit.** Stage the new resource (use `git add` on the explicit paths — never `git add -A` on this multi-terminal repo, per the standing rule) and commit:
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp" && git add "resources/[custom]/palm6_fc_hud/fxmanifest.lua" "resources/[custom]/palm6_fc_hud/bridge/cl_game.lua" "resources/[custom]/palm6_fc_hud/html/index.html" "resources/[custom]/palm6_fc_hud/client/main.lua" "resources/[custom]/palm6_fc_hud/server/main.lua" && git commit -m "$(cat <<'EOF'
feat(fc_hud): Def Jam fight HUD + sportsbook odds board (display-only)

New palm6_fc_hud NUI resource (palm6_clout mirror, bridge pattern):
- two HP bars + stamina + Blazin meter from the T1/T7 fight statebags
- client-rendered §10b sportsbook board (decimal/American/implied%/payout
  preview) off the T3 palm6_fightclub:oddsUpdate pool broadcast, with the
  honest 'indicative — locks at close' / 'thin pool' / 'CLOSED — closing line'
  captions; freezes at GoLive (secsLeft<=0)
- read-only /fccareer panel via a lazy pcall to palm6_fc_progression exports
- ZERO authority (no fight-state writes, no combat/bet events, no mint);
  prod-inert behind exports.palm6_fc_core:Config().Enabled
- luaparse-clean; boot-verified 0 SCRIPT ERROR; NUI render-verified in-browser

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: one commit created touching the five new files. (Do not push — the standing push gate applies.)

---

### Task 10: palm6_fc_arena — zone + crowd + spectator cam + fight-marks + BETTING broadcast

New **client + server + bridge** resource `resources/[custom]/palm6_fc_arena/`, mirroring `palm6_lottery`'s bridge layout (`bridge/cl_game.lua` owns every native/ox_lib call, `client/main.lua` is pure logic; `bridge/sv_framework.lua` + `server/main.lua` on the server). Presentation + client-UX only — **no money, no DB, no authority over HP/winner/rep**. Everything gates on `exports.palm6_fc_core:Config().Enabled` so it ships prod-inert. All coords/radius/crowd-count come from **fc_core** (`exports.palm6_fc_core:Config().Ring` / `.MaxCrowd`); arena's own `shared/config.lua` holds only presentation knobs.

**Files:**
- Create `resources/[custom]/palm6_fc_arena/fxmanifest.lua`
- Create `resources/[custom]/palm6_fc_arena/shared/config.lua`
- Create `resources/[custom]/palm6_fc_arena/bridge/sv_framework.lua`
- Create `resources/[custom]/palm6_fc_arena/bridge/cl_game.lua`
- Create `resources/[custom]/palm6_fc_arena/server/main.lua`
- Create `resources/[custom]/palm6_fc_arena/client/main.lua`
- Modify `custom.cfg` (add `ensure palm6_fc_arena` after line 108 `ensure palm6_fightclub`; T11 later moves it into canonical order)

**Interfaces:**
- **Produces (server export):** `exports('GetFightMarks', function(matchId) end)` → `{ a={ x,y,z,heading }, b={ x,y,z,heading } }` — opposing marks around `Config.Ring.coords`, server-authoritative (consumed by T6 at COUNTDOWN for finisher origin).
- **Produces (net, server→client):** `palm6_fc_arena:bettingOpen` = `{ matchId:int, f1name:string, f2name:string, betCmd:string }` (broadcast -1); `palm6_fc_arena:squareUp` = `{ matchId:int, coords={x,y,z}, heading:number }` (to each fighter's OWN client).
- **Consumes (server-internal `AddEventHandler`, fired by T6):** `fc:match:opened` = `{ matchId, f1name, f2name, betWindowSec }` → BETTING broadcast; `fc:match:countdown` = `{ matchId, cidA, cidB }` → compute marks + squareUp; `fc:match:teardown` = `{ matchId }` → server-side no-op cleanup hook.
- **Consumes (net, client, broadcast by T6):** `palm6_fc_combat:teardown` = `{ matchId }` → stop crowd/cam/repel.
- **Consumes (T1):** `exports.palm6_fc_core:Config()` (`.Enabled/.Ring/.MaxCrowd/.Betting`), `exports.palm6_fc_core:StateKeys()` (`.matchKey`); `GlobalState['fc:match:'..matchId]` (LIVE flag, written by T7).
- **Consumes (server framework):** `Bridge.GetSourceByCitizenId(cid)` for squareUp targeting.
- **Produces (ace-gated dev command):** `/fcarenatest <cidA> <cidB>` gated by `IsPlayerAceAllowed(src,'palm6_fc.debug')` (the ace T4 produces / T11 grants) — drives the full arena visual path before T6 combat exists.

---

- [ ] **Step 1: Scaffold dir + fxmanifest.lua.** Create `resources/[custom]/palm6_fc_arena/fxmanifest.lua`. Client+server+bridge, mirroring lottery; depends on fc_core. No oxmysql (arena touches no DB).
```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 fc arena — ring zone, crowd, spectator cam, fight-mark placement, betting broadcast (presentation only, no authority)'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',        -- FightMarkOffset read on BOTH realms (server computeMarks + client)
}

client_scripts {
    'bridge/cl_game.lua',       -- native / ox_lib adapter, before client logic
    'client/main.lua',
}

server_scripts {
    'bridge/sv_framework.lua',  -- framework adapter, before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'qbx_core',
    'palm6_fc_core',
}
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/fxmanifest.lua"` → prints AST JSON, exits 0. (First `npx luaparse` run auto-installs the package; no local copy exists — expect a one-time download.)

- [ ] **Step 2: shared/config.lua (presentation knobs only).** Create `resources/[custom]/palm6_fc_arena/shared/config.lua`. Arena's own isolated `Config` global (fc_core's Config is reached via exports, never this one). `FightMarkOffset` MUST be small enough that squared-up fighters can step into `move.reach` (max reach 1.6m in fc_core) — 1.25m each side = 2.5m apart, one step to close.
```lua
-- ============================================================================
-- palm6_fc_arena/shared/config.lua — presentation tunables ONLY.
-- Ring coords/radius, MaxCrowd, and Betting min/max come from palm6_fc_core
-- (exports.palm6_fc_core:Config()); this file never duplicates a money knob.
-- ============================================================================
Config = {}

Config.Debug = false

Config.GalleryRadius   = 7.0     -- crowd peds ring the center at this radius (m)
Config.RepelRadius     = 3.5     -- non-participants pushed out to this radius during LIVE
Config.CullDistance    = 60.0    -- despawn crowd when the local player is beyond this from ring center
Config.FightMarkOffset = 1.25    -- each fighter squared up this far from center on OPPOSING marks (2.5m apart)
Config.RepelNotifySec  = 5       -- throttle the "step back" spectator notify

-- Local, non-networked crowd ped models (cheap ambient peds — no custom assets).
Config.CrowdModels = {
    'a_m_y_hipster_01', 'a_f_y_vinewood_01', 'a_m_m_business_01', 'a_f_m_business_02',
    'a_m_y_downtown_01', 'a_m_y_beach_01', 'a_f_y_beach_01', 'a_m_y_soucent_01',
}

Config.Blip = { sprite = 491, color = 1, scale = 0.9, label = 'Fight Club Ring' }

Config.RateLimits = { fcspectate = 1 }

Config.CrowdTestSec = 10         -- DEBUG ONLY: how long /fcarenatest holds the fake LIVE statebag
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/shared/config.lua"` → exits 0.

- [ ] **Step 3: bridge/sv_framework.lua (server framework adapter).** Create `resources/[custom]/palm6_fc_arena/bridge/sv_framework.lua`. Minimal clone of the palm6 server bridge — only what squareUp needs. No money helpers (arena moves no money), no MySQL.
```lua
-- ============================================================================
-- palm6_fc_arena/bridge/sv_framework.lua
-- Framework adapter (server). The ONLY server file calling qbx_core. Arena
-- moves NO money and touches NO DB — this exposes only cid<->src resolution.
-- ============================================================================
Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Server source for an online character, or nil (palm6_bounty precedent).
function Bridge.GetSourceByCitizenId(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, { title = title, description = msg, type = t or 'inform' })
end
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/bridge/sv_framework.lua"` → exits 0.

- [ ] **Step 4: bridge/cl_game.lua (client native / ox_lib adapter).** Create `resources/[custom]/palm6_fc_arena/bridge/cl_game.lua`. Every GTA native + ox_lib call lives here (client/main.lua stays native-free, GTA-VI-portable — the palm6 §6 gate). Owns blip, ring zone, crowd peds, square-up teleport, spectator cam, soft-repel, coords helpers.
```lua
-- ============================================================================
-- palm6_fc_arena/bridge/cl_game.lua
-- Game adapter (client). The ONLY client file calling GTA natives / ox_lib.
-- Presentation only — every fight authority (HP, winner, rep, proximity) is
-- server-owned elsewhere; nothing here is security-sensitive.
-- ============================================================================
Game = {}

function Game.Dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Game.LocalCoords()
    local ped = PlayerPedId()
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

-- Am I an active fighter? (statebag written by T7's combat server.)
function Game.IsFighter()
    return LocalPlayer.state['fc:active'] and true or false
end

function Game.Notify(opts) lib.notify(opts) end

function Game.AddBlip(coords, opts)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, opts.sprite)
    SetBlipColour(b, opts.color)
    SetBlipScale(b, opts.scale)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(opts.label)
    EndTextCommandSetBlipName(b)
    return b
end

function Game.RemoveBlip(h)
    if h and DoesBlipExist(h) then RemoveBlip(h) end
end

-- ox_lib sphere zone around the ring for the spectator-gallery hint.
function Game.AddRingZone(coords, radius, onEnter, onExit)
    return lib.zones.sphere({
        coords = vector3(coords.x, coords.y, coords.z),
        radius = radius,
        onEnter = onEnter,
        onExit = onExit,
        debug = false,
    })
end

function Game.RemoveZone(z)
    if z and z.remove then z:remove() end
end

-- Square the local fighter up on their server-authored mark (own ped only).
function Game.SquareUp(coords, heading)
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, heading + 0.0)
end

-- Spawn N local, non-networked, frozen crowd peds cheering around the ring.
function Game.SpawnCrowd(center, n, galleryRadius)
    local peds = {}
    for i = 1, n do
        local ang = (i / n) * 2.0 * math.pi
        local x = center.x + math.cos(ang) * galleryRadius
        local y = center.y + math.sin(ang) * galleryRadius
        local z = center.z
        local found, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
        if found then z = gz end
        local model = Config.CrowdModels[math.random(#Config.CrowdModels)]
        local hash = joaat(model)
        if IsModelValid(hash) then
            RequestModel(hash)
            local deadline = GetGameTimer() + 3000
            while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(10) end
            if HasModelLoaded(hash) then
                -- isNetwork=false, thisScriptCheck=false => local, non-networked
                local ped = CreatePed(4, hash, x, y, z, (math.deg(ang) + 180.0) % 360.0, false, false)
                SetEntityInvincible(ped, true)
                FreezeEntityPosition(ped, true)
                SetBlockingOfNonTemporaryEvents(ped, true)
                SetPedCanRagdoll(ped, false)
                TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CHEERING', 0, true)
                SetModelAsNoLongerNeeded(hash)
                peds[#peds + 1] = ped
            end
        end
    end
    return peds
end

function Game.DeleteCrowd(peds)
    for _, ped in ipairs(peds or {}) do
        if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
    end
end

-- Soft-repel: if the local ped is inside `inner`, snap it back to the boundary.
-- Returns true if it repelled (caller throttles the notify).
function Game.RepelFromRing(center, inner)
    local ped = PlayerPedId()
    if not ped or ped == 0 then return false end
    local pc = GetEntityCoords(ped)
    local dx, dy = pc.x - center.x, pc.y - center.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < inner then
        local nx, ny = 1.0, 0.0
        if dist > 0.01 then nx, ny = dx / dist, dy / dist end
        SetEntityCoords(ped, center.x + nx * inner, center.y + ny * inner, pc.z, false, false, false, false)
        return true
    end
    return false
end

local specCam
function Game.SpectateOn(center)
    if specCam then return end
    specCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(specCam, center.x + 6.0, center.y + 6.0, center.z + 4.0)
    PointCamAtCoord(specCam, center.x, center.y, center.z + 0.5)
    SetCamActive(specCam, true)
    RenderScriptCams(true, true, 500, true, true)
end

function Game.SpectateOff()
    if not specCam then return end
    RenderScriptCams(false, true, 500, true, true)
    DestroyCam(specCam, true)
    specCam = nil
end
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/bridge/cl_game.lua"` → exits 0.

- [ ] **Step 5: Commit the scaffold.**
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp"
git add "resources/[custom]/palm6_fc_arena/fxmanifest.lua" \
        "resources/[custom]/palm6_fc_arena/shared/config.lua" \
        "resources/[custom]/palm6_fc_arena/bridge/sv_framework.lua" \
        "resources/[custom]/palm6_fc_arena/bridge/cl_game.lua"
git commit -m "$(cat <<'EOF'
palm6_fc_arena: scaffold resource (manifest, config, bridges)

Presentation-only arena resource for the fight club: ring zone, crowd,
spectator cam, fight-mark placement, betting broadcast. No money/DB/authority.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
  Expected: `git status` clean for those 4 paths; commit created. (Stage explicit paths only — never `git add -A` in this multi-terminal repo.)

- [ ] **Step 6: server/main.lua — fight-marks export, squareUp on countdown, BETTING broadcast, ace-gated dev driver.** Create `resources/[custom]/palm6_fc_arena/server/main.lua`. `computeMarks` is the single geometry source (both the `GetFightMarks` export and the `fc:match:countdown` handler call it). Marks are on the ±X axis, headings so each faces the other (GTA heading: 90 faces −X, 270 faces +X). Everything gates on `Config().Enabled` except the pure-geometry export and the ace-gated driver.
```lua
-- ============================================================================
-- palm6_fc_arena/server/main.lua
-- Pure logic. Calls Bridge.* for framework access. Presentation + fight-mark
-- geometry only — no money, no DB, no HP/winner/rep authority.
--
-- Consumes T6 server-internal seams: fc:match:opened / :countdown / :teardown.
-- Produces: GetFightMarks export, palm6_fc_arena:bettingOpen / :squareUp.
-- ============================================================================

local function dbg(msg) if Config.Debug then print('[palm6_fc_arena] ' .. msg) end end

local function coreConfig()
    local ok, c = pcall(function() return exports.palm6_fc_core:Config() end)
    return ok and c or nil
end

local function coreStateKeys()
    local ok, k = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    return ok and k or nil
end

local function enabled()
    local c = coreConfig()
    return c and c.Enabled and true or false
end

-- Two opposing marks around the ring center on the X axis, each facing the
-- other. mark A at +X faces west (heading 90 => -X); mark B at -X faces east
-- (heading 270 => +X). Stateless: safe to call from the export or a handler.
local function computeMarks()
    local c = coreConfig()
    local ring = c and c.Ring
    if not ring or not ring.coords then return nil end
    local o = Config.FightMarkOffset or 1.25
    local ctr = ring.coords
    return {
        a = { x = ctr.x + o, y = ctr.y, z = ctr.z, heading = 90.0 },
        b = { x = ctr.x - o, y = ctr.y, z = ctr.z, heading = 270.0 },
    }
end

-- Server-authoritative fight marks — T6 reads these at COUNTDOWN for the
-- finisher origin. Pure geometry, so it answers even when disabled.
exports('GetFightMarks', function(_matchId)
    return computeMarks()
end)

-- A match entered BETTING (T6 fired the seam after OpenMatch): tell the server
-- (arena-wide reach = -1) so spectators discover it and can /fcbet.
AddEventHandler('fc:match:opened', function(d)
    if not enabled() then return end
    if type(d) ~= 'table' or not d.matchId then return end
    local c = coreConfig()
    local minb = (c and c.Betting and c.Betting.MinBet) or 50
    local maxb = (c and c.Betting and c.Betting.MaxBet) or 5000
    local betCmd = ('/fcbet %d [1|2] [$%d-%d]'):format(d.matchId, minb, maxb)
    TriggerClientEvent('palm6_fc_arena:bettingOpen', -1, {
        matchId = d.matchId,
        f1name = d.f1name or 'Fighter 1',
        f2name = d.f2name or 'Fighter 2',
        betCmd = betCmd,
    })
    dbg(('bettingOpen broadcast for match #%d'):format(d.matchId))
end)

-- COUNTDOWN: square both fighters up on opposing marks (each on their OWN ped).
AddEventHandler('fc:match:countdown', function(d)
    if not enabled() then return end
    if type(d) ~= 'table' or not d.matchId then return end
    local marks = computeMarks()
    if not marks then return end
    local srcA = d.cidA and Bridge.GetSourceByCitizenId(d.cidA)
    local srcB = d.cidB and Bridge.GetSourceByCitizenId(d.cidB)
    if srcA then
        TriggerClientEvent('palm6_fc_arena:squareUp', srcA, {
            matchId = d.matchId,
            coords = { x = marks.a.x, y = marks.a.y, z = marks.a.z },
            heading = marks.a.heading,
        })
    end
    if srcB then
        TriggerClientEvent('palm6_fc_arena:squareUp', srcB, {
            matchId = d.matchId,
            coords = { x = marks.b.x, y = marks.b.y, z = marks.b.z },
            heading = marks.b.heading,
        })
    end
    dbg(('squareUp sent for match #%d (A=%s B=%s)'):format(d.matchId, tostring(srcA), tostring(srcB)))
end)

-- Teardown seam: arena holds NO per-match server state (computeMarks is
-- stateless), so this is a defensive no-op hook kept for the seam contract.
AddEventHandler('fc:match:teardown', function(d)
    if type(d) ~= 'table' then return end
    dbg(('teardown seam observed for match #%s'):format(tostring(d.matchId)))
end)

-- ---------------------------------------------------------------------------
-- Ace-gated dev driver — exercises the FULL arena visual path before T6 combat
-- exists (§14 stub philosophy). Fires the three seams + a fake LIVE statebag +
-- the client teardown, so crowd/repel/cam/squareUp/betting-hint are all
-- testable with only fc_core present. NOT a production path.
-- ---------------------------------------------------------------------------
RegisterCommand('fcarenatest', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'palm6_fc.debug') then return end
    local cidA, cidB = args[1], args[2]
    local matchId = 0  -- sentinel id; never collides with a real match row
    TriggerEvent('fc:match:opened', { matchId = matchId, f1name = 'Test A', f2name = 'Test B', betWindowSec = 60 })
    CreateThread(function()
        Wait(2000)
        TriggerEvent('fc:match:countdown', { matchId = matchId, cidA = cidA, cidB = cidB })
        Wait(1000)
        local keys = coreStateKeys()
        local key = (keys and keys.matchKey and keys.matchKey(matchId)) or ('fc:match:%d'):format(matchId)
        GlobalState:set(key, {
            status = 'live', roundStarted = true,
            slot = {
                [1] = { hp = 100, stam = 100, blazin = 0, name = 'Test A', model = 'mp_m_freemode_01' },
                [2] = { hp = 100, stam = 100, blazin = 0, name = 'Test B', model = 'mp_m_freemode_01' },
            },
        }, true)
        Wait((Config.CrowdTestSec or 10) * 1000)
        GlobalState:set(key, nil, true)
        TriggerClientEvent('palm6_fc_combat:teardown', -1, { matchId = matchId })
        print('[palm6_fc_arena] fcarenatest complete for match #0')
    end)
end, false)
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/server/main.lua"` → exits 0.

- [ ] **Step 7: Commit the server.**
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp"
git add "resources/[custom]/palm6_fc_arena/server/main.lua"
git commit -m "$(cat <<'EOF'
palm6_fc_arena: server — GetFightMarks, squareUp, betting broadcast, dev driver

computeMarks() is the single geometry source for the export and the COUNTDOWN
seam. Ace-gated /fcarenatest drives crowd/repel/cam/squareUp before T6 combat.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8: client/main.lua — zone/blip, BETTING notify, squareUp, LIVE-only crowd + soft-repel, spectate cam.** Create `resources/[custom]/palm6_fc_arena/client/main.lua`. Pure logic (Game.* only). LIVE is detected by reading `GlobalState['fc:match:'..currentMatchId]` (written by T7); `currentMatchId` is set on `bettingOpen`, cleared on `palm6_fc_combat:teardown`. Crowd spawns only while LIVE + near; repel runs only vs non-participants during LIVE.
```lua
-- ============================================================================
-- palm6_fc_arena/client/main.lua
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all natives / ox_lib.
-- Presentation only: ring blip + gallery zone, crowd peds (LIVE-only, culled),
-- spectator cam, soft-repel, fight-mark square-up. No authority.
-- ============================================================================

local ringBlip, ringZone
local crowd = {}
local currentMatchId
local spectating = false
local lastRepelNotify = 0

local function core() return exports.palm6_fc_core:Config() end

local function coreSafe()
    local ok, c = pcall(core)
    return ok and c or nil
end

local function enabled()
    local c = coreSafe(); return c and c.Enabled and true or false
end

local function ring()
    local c = coreSafe(); return c and c.Ring or nil
end

local function stateKey(id)
    local ok, k = pcall(function() return exports.palm6_fc_core:StateKeys() end)
    if ok and k and k.matchKey then return k.matchKey(id) end
    return ('fc:match:%d'):format(id)
end

local function isLive()
    if not currentMatchId then return false end
    local st = GlobalState[stateKey(currentMatchId)]
    return type(st) == 'table' and st.status == 'live'
end

-- BETTING open → discoverability notify for spectators.
RegisterNetEvent('palm6_fc_arena:bettingOpen', function(d)
    if type(d) ~= 'table' then return end
    currentMatchId = d.matchId
    Game.Notify({
        title = 'Fight Club',
        description = ('Match #%d open: %s vs %s\nBet: %s'):format(
            d.matchId or 0, d.f1name or '?', d.f2name or '?', d.betCmd or '/fcbet'),
        type = 'inform',
    })
end)

-- Square the local fighter up on their own mark (own ped only).
RegisterNetEvent('palm6_fc_arena:squareUp', function(d)
    if type(d) ~= 'table' or not d.coords then return end
    Game.SquareUp(d.coords, d.heading or 0.0)
end)

-- Canonical teardown (also the boot "abort any fight" broadcast) → tear down
-- all local presentation regardless of matchId (single ring in MVP).
RegisterNetEvent('palm6_fc_combat:teardown', function(d)
    if type(d) ~= 'table' then return end
    currentMatchId = nil
    if #crowd > 0 then Game.DeleteCrowd(crowd); crowd = {} end
    if spectating then Game.SpectateOff(); spectating = false end
end)

-- Presentation manager: crowd (LIVE + near) and soft-repel (LIVE + not a fighter).
CreateThread(function()
    while true do
        local sleep = 1000
        local r = ring()
        local live = enabled() and isLive()

        if live and r then
            local pc = Game.LocalCoords()
            local near = pc and Game.Dist(pc, r.coords) <= (Config.CullDistance or 60.0)
            if near and #crowd == 0 then
                local c = coreSafe()
                crowd = Game.SpawnCrowd(r.coords, (c and c.MaxCrowd) or 12, Config.GalleryRadius or 7.0)
            elseif (not near) and #crowd > 0 then
                Game.DeleteCrowd(crowd); crowd = {}
            end

            if near and not Game.IsFighter() then
                if Game.RepelFromRing(r.coords, Config.RepelRadius or 3.5) then
                    local t = GetGameTimer()
                    if t - lastRepelNotify > (Config.RepelNotifySec or 5) * 1000 then
                        lastRepelNotify = t
                        Game.Notify({ title = 'Fight Club', description = 'Stay clear of the ring during the fight.', type = 'error' })
                    end
                end
                sleep = 50    -- responsive repel while a non-fighter is at the ring
            else
                sleep = near and 250 or 1000
            end
        else
            if #crowd > 0 then Game.DeleteCrowd(crowd); crowd = {} end
            if spectating then Game.SpectateOff(); spectating = false end
            sleep = 1000
        end

        Wait(sleep)
    end
end)

-- Optional spectator cam toggle (non-participants, live fight only).
RegisterCommand('fcspectate', function()
    local r = ring()
    if not enabled() or not r then return end
    if Game.IsFighter() then return end
    if not isLive() then
        Game.Notify({ title = 'Fight Club', description = 'No live fight to spectate.', type = 'error' })
        return
    end
    spectating = not spectating
    if spectating then Game.SpectateOn(r.coords) else Game.SpectateOff() end
end, false)

-- Ring blip + gallery zone (only when enabled — prod-inert otherwise).
CreateThread(function()
    Wait(1500)  -- let fc_core exports come up
    if not enabled() then return end
    local r = ring()
    if not r then return end
    ringBlip = Game.AddBlip(r.coords, Config.Blip)
    ringZone = Game.AddRingZone(r.coords, r.radius or 15.0, function()
        Game.Notify({ title = 'Fight Club', description = 'You are at the fight ring. /fcspectate to watch, /fcbet during betting.', type = 'inform' })
    end, nil)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if #crowd > 0 then Game.DeleteCrowd(crowd) end
    if spectating then Game.SpectateOff() end
    Game.RemoveBlip(ringBlip)
    Game.RemoveZone(ringZone)
end)
```
  Verify: `npx luaparse "resources/[custom]/palm6_fc_arena/client/main.lua"` → exits 0.

- [ ] **Step 9: Commit the client.**
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp"
git add "resources/[custom]/palm6_fc_arena/client/main.lua"
git commit -m "$(cat <<'EOF'
palm6_fc_arena: client — zone/blip, betting notify, squareUp, crowd, cam, repel

LIVE detected via GlobalState fc:match:<id> (T7). Crowd is LIVE+near only and
culled; soft-repel targets non-participants; /fcspectate toggles the cam. All
gated on fc_core Config().Enabled (prod-inert).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 10: Add the ensure line to custom.cfg.** Arena must load AFTER `palm6_fc_core` (exports) — add its ensure line right after `ensure palm6_fightclub` (line 108). T11 owns the canonical order and will move it into `…fc_combat → fc_hud/fc_arena → fc_progression`; this provisional line just makes arena boot for its own verify. Use Edit to insert after the fightclub line:
```
ensure palm6_fightclub
ensure palm6_fc_arena        # provisional — T11 reorders into the fc block
```
  Note for the executor: `palm6_fc_core` (T1) and `ox_lib` must be ensured before this line. If T1 has not yet added `ensure palm6_fc_core`, temporarily add it above this line for standalone boot-verify (T11 will consolidate). Verify: `grep -n "palm6_fc_arena\|palm6_fc_core" custom.cfg` shows the arena line present and after any fc_core line.

- [ ] **Step 11: Boot-verify + exercise the stub.** Start the local FXServer.
  - Console must show `palm6_fc_arena` started with **0 SCRIPT ERROR** and no red `luaparse`/manifest errors.
  - With `Config.Enabled` still `false` in fc_core (prod default): confirm arena is inert — no blip, no crowd, `/fcarenatest` fires the seams but the `enabled()`-gated handlers no-op (only the LIVE statebag path + client teardown run; acceptable). Expected console line: `[palm6_fc_arena] fcarenatest complete for match #0`.
  - Flip fc_core `Config.Enabled = true` locally and restart. Join with a dev character holding the `palm6_fc.debug` ace (grant once locally: server console `add_ace group.admin palm6_fc.debug allow`, or run `/fcarenatest` from the **server console** as src 0). Run `/fcarenatest <yourCid> <yourCid>`:
    - Within ~2s you get the BETTING notify (`Match #0 open: Test A vs Test B / Bet: /fcbet 0 [1|2] [$50-5000]`).
    - Within ~3s your ped is teleported/heading-set onto a fight mark (squareUp — both marks target your cid in this test).
    - For `Config.CrowdTestSec` seconds the statebag is LIVE → crowd peds cheer around the ring; walking a non-fighter into the ring center snaps you back to `RepelRadius`; `/fcspectate` toggles the orbit cam.
    - On expiry: crowd despawns, cam releases, no orphan peds (`onResourceStop` also cleans up on `restart palm6_fc_arena`).
  - Confirm `exports.palm6_fc_core` nil-safety: if fc_core is stopped, arena logs nothing and throws no error (pcall guards).

- [ ] **Step 12: Commit custom.cfg + close the task. David feel-test items.**
```bash
cd "C:/Users/Mgtda/Projects/Active/gtarp"
git add custom.cfg
git commit -m "$(cat <<'EOF'
palm6_fc_arena: ensure in custom.cfg (provisional; T11 finalizes fc order)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
  **David must feel-test in-game (the only gate for these — the plan does not automate them):**
  1. Fight marks: two fighters who accepted from opposite edges of the 15m ring are squared up ~2.5m apart facing each other and can close to strike range in one step (tune `Config.FightMarkOffset` if too far/too close).
  2. Crowd: reads as a live audience (not clipping into geometry / floating); spawns only during LIVE; despawns cleanly at fight end; culls when he walks away and re-forms on return — no perf hit.
  3. Soft-repel: non-participant spectators can't stand in the fight but the two fighters are never repelled (verify `LocalPlayer.state['fc:active']` exemption holds); the nudge feels like a boundary, not a stutter.
  4. Spectator cam (`/fcspectate`): frames the ring well and releases cleanly; can't be toggled by a participant.
  5. Betting broadcast: the `/fcbet` hint is readable and arrives when a match opens; drives spectators to wager in the 60s window.
  6. Ring blip: correct place at the Vanilla Unicorn back lot, only visible once Enabled.
  7. No orphan crowd peds after a `restart palm6_fc_arena` or a mid-fight resource stop (boot `palm6_fc_combat:teardown` broadcast + `onResourceStop` both clear them).

---

### Task 11: eventguard combat budget + minimum audio + custom.cfg ensure order + Config.Enabled rollout

**Files:**
- Modify `resources/[custom]/palm6_eventguard/server/main.lua` (add the drop-only combat-class path to `guard()`)
- Modify `resources/[custom]/palm6_eventguard/config.lua` (register the 8 `palm6_fc_combat:*` net events)
- Create `resources/[custom]/palm6_fc_audio/fxmanifest.lua`
- Create `resources/[custom]/palm6_fc_audio/client/main.lua`
- Modify `custom.cfg` (reorder the fc ensure block + add the `palm6_fc.debug` ace)

**Interfaces:**
- **Consumes (server→client net events, produced by T6/T8, handled by the new audio client):** `palm6_fc_combat:playClip = { matchId:int, cid:string, moveId:string, animDict:string }`, `palm6_fc_combat:finisher = { matchId:int, cid:string, startAt:int, origin, heading, sceneDict, sceneAnim }`, `palm6_fc_combat:koRagdoll = { matchId:int }`, `palm6_fc_combat:countdown = { matchId:int, seconds:int }`.
- **Consumes (T1 exports + statebag shape):** `exports.palm6_fc_core:Config()` (reads `.Enabled`, `.Blazin.FullThreshold`), `exports.palm6_fc_core:StateKeys()` → `{ PLAYER_ACTIVE='fc:active', PLAYER_SLOT='fc:slot', matchKey=function(id) end }`; `GlobalState[matchKey(matchId)] = { status='live', roundStarted=true, slot={ [1]={hp,stam,blazin,name,model}, [2]={...} } }`; `LocalPlayer.state['fc:active']` = matchId|false, `LocalPlayer.state['fc:slot']` = 1|2.
- **Consumes (client→server combat net events to budget, produced by T6/T8):** `palm6_fc_combat:challenge/accept/decline/select/strike/connect/block/break`.
- **Produces:** the definitive `Config.Events` budget registry (8 entries) + the combat-class drop-only handler path in eventguard; the `custom.cfg` ensure order (`eventguard → dbmigrate → fc_core → fightclub → fc_combat → fc_hud → fc_arena → fc_audio → fc_progression`); the `add_ace group.admin palm6_fc.debug allow` grant (consumed by T4's `IsPlayerAceAllowed(src,'palm6_fc.debug')`); minimum arena audio; the rollout/prod-verify checklist.

> Ground rule for this task: eventguard, `custom.cfg`, and the new `palm6_fc_audio` resource are owned solely by T11 — no other task touches them, so there are no merge conflicts. This task is the LAST to run; T1/T3/T6/T7/T8/T9/T10 resources already exist on disk when you start. Audio is a **standalone** client-only resource (not folded into T10's arena) precisely so T11 edits zero files owned by another author.

- [ ] **Step 1: Add the combat-class drop-only path to eventguard's `guard()`.** Open `resources/[custom]/palm6_eventguard/server/main.lua`. The current over-budget branch (lines 60-65) unconditionally calls `record()` (which increments `Violations[src]` and kicks at `KickThreshold`). Replace that inner branch so a `class='combat'` budget drops the event but never touches the session kick counter. Change:
```lua
        if #b.calls >= budget.calls then
            record(src, eventName, ('over budget %d/%ds'):format(
                budget.calls, budget.window_seconds))
            CancelEvent()
            return
        end
```
to:
```lua
        if #b.calls >= budget.calls then
            -- Combat-class budget (fc striking/finisher mash): DROP the
            -- over-budget event but NEVER call record() — no violation row,
            -- no Violations[src]++ , no 3-strike kick. A legit flurry of
            -- palm6_fc_combat:strike/connect/block/break can burst past the
            -- budget; the server move-clock (palm6_fc_combat) — not eventguard
            -- — is the combat authority, and the §7 finisher :break mash would
            -- trip the kick model instantly. Money/menu events keep the
            -- strike-and-kick model via record() below.
            if budget.class == 'combat' then
                CancelEvent()
                return
            end
            record(src, eventName, ('over budget %d/%ds'):format(
                budget.calls, budget.window_seconds))
            CancelEvent()
            return
        end
```
This is the only handler change; the budget map itself is data (Step 2). Non-combat events (no `class` key) behave exactly as before.

- [ ] **Step 2: Register the 8 fc net events in eventguard config.** Open `resources/[custom]/palm6_eventguard/config.lua`. Append this block to the `Config.Events` table, immediately before the closing `}` on line 242 (right after the `palm6_gunrunning:dealer:buy` entry):
```lua

    -- palm6_fc_combat — Def Jam fight-club engine (Phase 0). challenge/accept/
    -- decline/select are low-frequency MENU events → the normal kick model.
    -- The LIVE-combat events (strike/connect/block/break) fire many times a
    -- second per fighter and carry class='combat' so the guard DROPS an
    -- over-budget event WITHOUT the 3-strike session kick (see server/main.lua
    -- guard()): the server move-clock is the authority, and the §7 finisher
    -- :break mash would trip a kick model instantly. custom.cfg ensures
    -- palm6_eventguard BEFORE palm6_fc_combat so these register first in the
    -- handler chain (same requirement as palm6_robbery/turf/drugs/gangs above).
    ['palm6_fc_combat:challenge'] = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:accept']    = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:decline']   = { calls = 10, window_seconds = 60 },
    ['palm6_fc_combat:select']    = { calls = 15, window_seconds = 60 },
    ['palm6_fc_combat:strike']    = { calls = 60, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:connect']   = { calls = 60, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:block']     = { calls = 40, window_seconds = 10, class = 'combat' },
    ['palm6_fc_combat:break']     = { calls = 80, window_seconds = 10, class = 'combat' },
```
Names/limits/`class` values are the exact contract set — do not rename or retune.

- [ ] **Step 3: luaparse both eventguard files.** Run:
```
npx luaparse "resources/[custom]/palm6_eventguard/server/main.lua"
npx luaparse "resources/[custom]/palm6_eventguard/config.lua"
```
Expected: each prints the parsed AST JSON and exits 0, with **no** `SyntaxError:` line. If either errors, fix the exact reported line before continuing.

- [ ] **Step 4: Commit the eventguard changes.** Run:
```
git add "resources/[custom]/palm6_eventguard/config.lua" "resources/[custom]/palm6_eventguard/server/main.lua"
git commit -m "$(cat <<'EOF'
palm6_eventguard: combat-class drop-only budget + register fc_combat net events

Adds a class='combat' branch to guard(): over-budget fc strike/connect/block/
break events are dropped, not counted toward the 3-strike session kick (the
server move-clock is the combat authority; the finisher mash would trip a kick
model instantly). Registers the 8 palm6_fc_combat:* net events (menu-class for
challenge/accept/decline/select; combat-class for strike/connect/block/break).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Create the audio resource manifest.** Write `resources/[custom]/palm6_fc_audio/fxmanifest.lua`:
```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'MGT'
version '0.1.0'
description 'palm6 fc audio - minimum Def Jam arena audio bed via native PlaySoundFrontend (zero shipped assets, provenance-clean by construction)'

-- Client-only, presentation-only, ZERO authority: no money, no net-event
-- production, no statebag writes. Reads exports.palm6_fc_core:Config()/
-- StateKeys() and reacts to the palm6_fc_combat server->client broadcasts +
-- the fc match statebag. Standalone (not folded into palm6_fc_arena) so this
-- resource is owned entirely by the rollout task with no cross-author edits.
client_scripts {
    'client/main.lua',
}

dependencies {
    'palm6_fc_core',
}
```

- [ ] **Step 6: Write the audio client.** Write `resources/[custom]/palm6_fc_audio/client/main.lua`:
```lua
-- ============================================================================
-- palm6_fc_audio/client/main.lua
--
-- Minimum Def Jam arena audio (spec §12): crowd bed, per-hit SFX, a Blazin
-- ready cue, a finisher stinger, a KO crowd roar, a countdown beep. Native
-- PlaySoundFrontend ONLY -> zero shipped assets, provenance-clean (GTA's own
-- frontend sound sets). No authority, no money, no net events produced.
--
-- The sound set/name pairs below are PLACEHOLDERS. PlaySoundFrontend silently
-- no-ops on an unknown name/set (it never raises a Lua error), so a wrong pick
-- is a missing sound, never a SCRIPT ERROR -- boot-safe regardless. David swaps
-- and tunes the exact sets in the in-game feel-test (§14).
-- ============================================================================

local Config    = nil
local StateKeys = nil

local function cfg()
    if Config == nil then Config = exports.palm6_fc_core:Config() end
    return Config
end

local function keys()
    if StateKeys == nil then StateKeys = exports.palm6_fc_core:StateKeys() end
    return StateKeys
end

local function play(name, set)
    PlaySoundFrontend(-1, name, set, true)
end

-- Per-hit swing/impact SFX: the server told this client to play a strike clip
-- (palm6_fc_combat:playClip, §6 move clock; broadcast to in-range clients).
RegisterNetEvent('palm6_fc_combat:playClip', function(data)
    if not data or not data.moveId then return end
    play('MELEE_Fist_Takedown', 'CELEBRATION_SOUNDSET')  -- placeholder swing/impact
end)

-- Finisher stinger: the Blazin cinematic starts (palm6_fc_combat:finisher, §7).
RegisterNetEvent('palm6_fc_combat:finisher', function(data)
    if not data then return end
    play('Bed', 'DLC_LOWRIDER_RELAY_RACE_SOUNDS')  -- placeholder stinger bed
end)

-- KO crowd roar: the victim is dropped (palm6_fc_combat:koRagdoll, §6 KO).
RegisterNetEvent('palm6_fc_combat:koRagdoll', function(data)
    play('CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET')  -- placeholder crowd roar
end)

-- Countdown beep: 3-2-1 into LIVE (palm6_fc_combat:countdown, §5 COUNTDOWN).
RegisterNetEvent('palm6_fc_combat:countdown', function(data)
    play('Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS')  -- placeholder beep
end)

-- Crowd bed + Blazin ready cue. Runs only while the LOCAL player is IN a LIVE
-- fc match (LocalPlayer.state['fc:active']); reads the throttled match statebag
-- (fc_core StateKeys shape, written by palm6_fc_combat §6/§7). PlaySoundFrontend
-- is one-shot, so the "bed" is a low-cadence re-trigger, not a true loop. Gated
-- on Config.Enabled so it is fully inert when the feature ships dark (§15).
CreateThread(function()
    local k = keys()
    local lastBed = 0
    local blazinFired = false
    while true do
        local wait = 1000
        if cfg().Enabled then
            local matchId = LocalPlayer.state[k.PLAYER_ACTIVE]
            local slot    = LocalPlayer.state[k.PLAYER_SLOT]
            if matchId and matchId ~= false then
                local st = GlobalState[k.matchKey(matchId)]
                if st and st.status == 'live' and st.roundStarted then
                    local t = GetGameTimer()
                    if t - lastBed > 4000 then
                        play('Crowd_Cheer', 'HUD_MINI_GAME_SOUNDSET')  -- placeholder crowd bed
                        lastBed = t
                    end
                    -- Blazin ready cue: edge-trigger ONCE when this fighter's
                    -- momentum fills to FullThreshold (§7 telegraph). Re-arms
                    -- when it drops back below (e.g. after a finisher fires).
                    local me = slot and st.slot and st.slot[slot]
                    if me and me.blazin and me.blazin >= cfg().Blazin.FullThreshold then
                        if not blazinFired then
                            play('Rank_Up', 'HUD_AWARDS')  -- placeholder Blazin cue
                            blazinFired = true
                        end
                    else
                        blazinFired = false
                    end
                    wait = 250
                else
                    blazinFired = false
                end
            end
        end
        Wait(wait)
    end
end)
```
Note: `LocalPlayer.state` (not `Player(src).state`) is the client-side statebag accessor; `GlobalState[key]` is client-readable. The lazy `cfg()`/`keys()` getters defer the fc_core export calls to the first thread tick, after fc_core has started (guaranteed by the ensure order in Step 8).

- [ ] **Step 7: luaparse the audio resource.** Run:
```
npx luaparse "resources/[custom]/palm6_fc_audio/fxmanifest.lua"
npx luaparse "resources/[custom]/palm6_fc_audio/client/main.lua"
```
Expected: both print AST JSON, exit 0, no `SyntaxError:`. Fix any reported line before continuing.

- [ ] **Step 8: Reorder the fc ensure block in `custom.cfg` + add the debug ace.** Three edits to `custom.cfg`:

  (a) Insert the contiguous fc block **after** the `ensure palm6_eventguard` line (line 87). Change:
```
ensure palm6_eventguard
ensure palm6_allowlist
```
to:
```
ensure palm6_eventguard

# ---------------------------------------------------------------------------
# Def Jam fight club (Phase 0) - ordered for the real dependency graph:
#   palm6_eventguard (above) registers its net-event guards FIRST;
#   palm6_dbmigrate creates/patches the fc tables BEFORE any fc resource reads
#   them (moved up from its old spot near the bottom; still one ensure, still
#   all IF NOT EXISTS -> harmless to run earlier); palm6_fc_core (shared data)
#   before every consumer; palm6_fightclub (money/match record; moved up from
#   its old mid-list spot) before combat; combat before the presentation +
#   progression layers. Enabled=false by default (fc_core) -> prod-inert.
# ---------------------------------------------------------------------------
ensure palm6_dbmigrate
ensure palm6_fc_core
ensure palm6_fightclub
ensure palm6_fc_combat
ensure palm6_fc_hud
ensure palm6_fc_arena
ensure palm6_fc_audio
ensure palm6_fc_progression

ensure palm6_allowlist
```

  (b) Remove the OLD `ensure palm6_fightclub` at line 108 (it moved into the block above). Change:
```
ensure palm6_tips
ensure palm6_fightclub
ensure palm6_ransom
```
to:
```
ensure palm6_tips
ensure palm6_ransom
```

  (c) Remove the OLD `ensure palm6_dbmigrate` at line 208 (it moved up). Change:
```
# ONE-SHOT migration applier — creates pending tables (0040/0042/0043/0044) via
# the server DB connection since the prod DB isn't externally reachable. All
# statements are IF NOT EXISTS. Remove this line + the resource once confirmed.
ensure palm6_dbmigrate
```
to:
```
# ONE-SHOT migration applier — creates/patches pending tables (drugs 0040/0042,
# fightclub base + fc ALTERs) via the server DB connection since the prod DB
# isn't externally reachable. All statements are IF NOT EXISTS. MOVED into the
# Def Jam fight-club ensure block above so it runs BEFORE palm6_fc_core /
# palm6_fc_progression read the fc tables. Remove once confirmed applied.
```

  (d) Add the debug ace in the ACE section. After the `add_ace group.mod command.priors allow` line (line 266), insert:
```
add_ace group.mod   command.priors     allow

# palm6_fightclub /fcdebug — ace-gated dev stub (open/live/resolve/void) that
# drives betting/progression/HUD/audio before real combat exists. The command
# is RegisterCommand(restricted=false) and self-checks
# IsPlayerAceAllowed(src,'palm6_fc.debug'), so admins need this explicit grant
# (console src 0 is always allowed by the handler). NOTE: this is a bare ace
# object name, NOT a command.<name> ACE.
add_ace group.admin palm6_fc.debug allow
```

- [ ] **Step 9: Boot-verify on a local FXServer (0 SCRIPT ERROR).** Start the local FXServer with `custom.cfg`. In the server console confirm:
  - `[palm6_eventguard] guarding N events; kick threshold=3` — **N is 8 higher** than before this task (the 8 new fc events registered).
  - Each of `palm6_dbmigrate`, `palm6_fc_core`, `palm6_fightclub`, `palm6_fc_combat`, `palm6_fc_hud`, `palm6_fc_arena`, `palm6_fc_audio`, `palm6_fc_progression` prints its start line **in that order** with **zero** `SCRIPT ERROR`.
  - No `Failed to load` / `Couldn't find resource` for `palm6_fc_audio`.
  If a resource errors, read the traceback and fix before continuing. (Reminder from §14: the fc base tables must already be registered in `palm6_dbmigrate` by T2, or the fresh-DB boot fails on the ALTERs — verify T2 landed if you see a missing-table error.)

- [ ] **Step 10: Stub-exercise eventguard order + audio inertness (dark) + the Enabled cutover.** With the server booted:
  - **Dark inertness:** with `Config.Enabled=false` (the fc_core default), confirm `palm6_fc_audio`'s poll loop does nothing (no matches open) and no fc events fire — the feature is inert in prod exactly as shipped.
  - **Drive the lifecycle via the T4 stub** (ace `palm6_fc.debug` now granted): from the server console run `fcdebug open <cidA> <cidB>`, then `fcdebug live <matchId>`, then `fcdebug resolve <matchId> <winnerCid>`. Confirm the row walks `betting -> live -> resolved`, `settleMatch` runs, and the eventguard console shows **no** VIOLATION lines for this flow (the stub calls exports directly, not net events).
  - **Config.Enabled cutover (§15 mid-match flip):** set `Config.Enabled=true` in `palm6_fc_core/config.lua`, `restart palm6_fc_core palm6_fightclub palm6_fc_combat palm6_fc_audio`, `fcdebug open`+`fcdebug live` to get a `live` row, then flip `Config.Enabled=false` and `restart palm6_fc_combat`. Confirm (T6-owned behavior this task verifies): the `palm6_fc_combat` `onResourceStop`/boot path fires the `palm6_fc_combat:teardown` no-contest broadcast to `-1` AND `LiveVoidMatch` flips the open `live` row to `resolved, winner=NULL, method='void', settled=0` -> `settleMatch` draw refunds bets + returns both entry stakes. No player left invincible/frozen; no stranded bet or ante. This is the definition of `Enabled=false` = "no new matches, betting frozen, settlement still reconciles."
  - **Combat-class drop path** (needs a test client, folds into David's feel-test in Step 12): confirm that spamming `palm6_fc_combat:strike`/`break` past the budget drops the events with **no kick** and no `event_violations` rows, while a menu-class event (e.g. `palm6_fc_combat:challenge`) over its budget still records a violation.

- [ ] **Step 11: Commit the audio resource + cfg rollout wiring.** Run:
```
git add "resources/[custom]/palm6_fc_audio/fxmanifest.lua" "resources/[custom]/palm6_fc_audio/client/main.lua" custom.cfg
git commit -m "$(cat <<'EOF'
palm6_fc_audio + custom.cfg rollout: fc ensure order, dbmigrate/fightclub moved, /fcdebug ace

Adds the minimum Def Jam arena audio (client-only, native PlaySoundFrontend:
crowd bed, per-hit SFX, Blazin cue, finisher stinger, KO roar, countdown beep;
Config.Enabled-gated so it ships dark). Reorders custom.cfg into the contiguous
fight-club ensure block (eventguard -> dbmigrate -> fc_core -> fightclub ->
fc_combat -> fc_hud/fc_arena/fc_audio -> fc_progression), moving palm6_dbmigrate
up so the fc tables exist before any fc resource reads them and palm6_fightclub
up ahead of combat. Grants add_ace group.admin palm6_fc.debug for the T4 stub.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 12: David in-game feel-test + prod-verify checklist (the standing gate — in-game verification is the ONLY gate for these).** Automation stops here; hand David this checklist:
  - **Audio feel (§12):** during a real LIVE match — crowd bed is present, per-hit SFX lands with each punch clip, the Blazin cue fires the instant a fighter's meter fills, the finisher stinger plays over the cinematic, the KO roar hits on the drop, the 3-2-1 beep plays into LIVE. Swap the placeholder `PlaySoundFrontend` set/name pairs in `palm6_fc_audio/client/main.lua` to taste (they no-op if wrong, so this is pure tuning).
  - **Eventguard combat class:** in a real fight, mash strikes and spam the finisher `:break` window hard — confirm you are **NOT kicked** and no `event_violations` rows accrue, while normal (menu) event abuse still trips the kick model.
  - **Rollout (deploy during low pop, §15):** push -> CI -> prod. On prod verify: the boot log shows the fc block loading in order with 0 SCRIPT ERROR; run one **live test match** end to end; place and confirm a **settled bet**; confirm the **entry-stake payout** to the winner. Only after all four does this ship.
  - **Announce `/fcjoin` is gone** (removed in T3): post the player-facing notice that the queue/`/fcjoin`/`/fcleave` flow is replaced by challenge-at-the-ring, so no one waits on a dead command.
  - Do not mark shipped until David confirms the feel-test AND the four prod-verify items pass.
