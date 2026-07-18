# Def Jam-Style Fight Club — Design Spec (MVP / "bigger Phase 0") — v2

**Date:** 2026-07-18 (v2 after adversarial spec review: 63 findings applied)
**Status:** Design — pending final spec review before implementation planning.
**Repo:** BlacklineDevs/gtarp (Palm6 FiveM/Qbox server). **Owner:** David Olverson.

> v2 changelog: unified match ownership with the existing `palm6_fightclub` (integer
> match id + its recoverable payout), gutted the old self-resolver, added the betting
> window back into the state machine, made the seam server-internal, corrected the
> ragdoll/flinch and animation-preload technical claims, replaced "validate mid-move"
> with a server-driven move clock, populated match format + move table + all starting
> numbers, and added disconnect/teardown/restart, anti-farm, audio, performance,
> testing, and rollout sections.

---

## 1. Goal & fidelity target

Rebuild the fight club into a **Def Jam: Fight for NY-flavored** brawler: pick a fighter,
strike/combo with stamina, build a **Blazin momentum meter**, land a **cinematic finish**,
KO your opponent in a hyped arena with a crowd and live **betting**, and climb a **rep career**.

**Fidelity target: convincing homage, not arcade-faithful port.** Deferred/simplified: frame-precise
reversals and flawless two-body grapple sync.

**Hard IP line (enforced in the asset pipeline):** original-branded; no real rappers/celebrities/
copyrighted characters; no ripped Def Jam/Sifu/Sleeping Dogs/Yakuza assets. Roster = original
archetype "house" fighters + (later phase) player-created fighters. Every shipped asset carries a
provenance note (original / CC0 / CC-BY / licensed). Rationale: Take-Two owns Cfx.re and can pull the
server key **and** Tebex store; monetization strips any fan-use framing.

## 2. Scope

### In (MVP)
Server-authoritative match lifecycle **built on the existing `palm6_fightclub` match record + recoverable
payout**; real striking combat (server-driven move clock, server-owned HP/stamina/momentum); Blazin meter
+ **one** cinematic finisher (local-synced-scene pattern); fighter select with original house fighters +
styles; NUI HUD; arena (zone + crowd + spectator cam); rep/rank career; betting kept and driven by the new
resolver.

### Out (deferred — not MVP)
Grapple/throw + environmental finishers (custom synced scenes + mocap); build-your-own-fighter creator;
deep reversals/counters; full unlock tree / gear / seasons; multi-round / best-of formats.

## 3. Architecture — modules

palm6 bridge pattern (`bridge/sv_framework.lua` + `bridge/cl_game.lua`) + RFC-001 metadata + `palm6_<domain>`
naming throughout. Load order via custom.cfg: `palm6_eventguard` → `palm6_fc_core` → `palm6_fightclub`
(rewired) → `palm6_fc_combat` → `palm6_fc_hud` / `palm6_fc_arena` → `palm6_fc_progression`.

| Resource | Responsibility | Interface |
|---|---|---|
| `palm6_fc_core` | Shared data + constants only (no behavior): config; fighter/style/move data tables; statebag key constants; the seam's shape; **documents** which net events need eventguard budgets (the budgets themselves live in `palm6_eventguard/config.lua`). | exports `GetFighter/GetStyle/GetMove/StateKeys/Config`. |
| `palm6_fightclub` (rewired) | **Owns the match record + money.** Keeps `palm6_fightclub_matches`/`_bets`, `/fcbet`, the betting window, and the crash-recoverable `settleMatch`/`reconcileUnsettled`/`claimBet`/`purse_paid`/`settled` payout. **Removes** the queue, `/fcjoin`/`/fcleave`, and the native-melee health-monitor self-resolver. Exposes `OpenMatch`/`ResolveMatch` **server exports** for combat to drive. | exports (server-only) `OpenMatch(aCid,bCid)→matchId:int`, `ResolveMatch(matchId,winnerCid,method)`. Fires server-internal `fc:match:resolved`. |
| `palm6_fc_combat` | The fight engine (client+server): challenge/accept handshake, server-driven move clock, server-owned HP/stamina/momentum, KO, drives the finisher. On fight end calls `palm6_fightclub:ResolveMatch`. **Sole resolver.** | in: challenge/accept/strike/connect/block net events (all eventguard-budgeted). out: `ResolveMatch` call; fight statebags. |
| `palm6_fc_hud` | NUI HUD only (two health bars, stamina, Blazin meter). Reads fight statebags. No authority. | in: statebags/`fc:hud:*`. |
| `palm6_fc_arena` | Zone + ring bounds + crowd (local, non-networked peds) + spectator cam. **Presentation + client UX only** — NOT the source of proximity truth. | client zone prompts; server has its own coords check. |
| `palm6_fc_progression` | Rep/rank/unlock ledger; atomic claim-before-credit + boot reconcile; anti-farm gating. | in: consumes server-internal `fc:match:resolved`. out: `GetRep/GetRank/HasUnlock`. |

### The seam — server-internal, unforgeable
`fc:match:resolved` is a **server-side `TriggerEvent`** (or direct call), **never** a `RegisterNetEvent`.
Producers/consumers are all server code; a modified client cannot fire it. Flow: `fc_combat` decides the
winner from its own server state → calls `exports.palm6_fightclub:ResolveMatch(matchId, winnerCid, method)`
→ fightclub settles the purse/bets via its existing recoverable path and emits server-internal
`fc:match:resolved{matchId,winnerCid,loserCid,method,startedAt,endedAt}` → `fc_progression` awards rep.
`matchId` is the **integer** `palm6_fightclub_matches.id` (one match record; no second namespace).

## 4. Data model

Reuse the existing `palm6_fightclub_matches` (id INT, fighter1/2_citizenid, status, winner_citizenid,
purse_paid, settled, …) and `palm6_fightclub_bets` (paid) — the money path is unchanged. New columns on
`matches` (idempotent ALTERs): `style1`, `style2`, `method` (ko/finisher/forfeit/draw), `rep_awarded TINYINT
NOT NULL DEFAULT 0`. New tables:
- `palm6_fc_progression(citizenid PK, rep INT DEFAULT 0, wins INT, losses INT, rank_tier INT, updated_at)`
- `palm6_fc_unlocks(citizenid, unlock_id, unlocked_at, UNIQUE(citizenid,unlock_id))` (INSERT IGNORE).

**Migration registration:** every new ALTER/CREATE is added to `palm6_dbmigrate`'s inline list (no ledger,
re-runs every boot → must be idempotent). Confirm the base `palm6_fightclub` tables are registered there too;
if only applied via the raw `sql/` set, add guarded CREATEs so a dbmigrate-only rebuild has them.
**`rep_awarded` DEFAULT 1** (this is the correct application of the first-boot-mass-repay lesson). Because
`rep_awarded` is a NEW column on the **existing** `palm6_fightclub_matches` table — which already holds
historical `resolved` rows — `DEFAULT 0` would make the boot reconcile (`WHERE status='resolved' AND
rep_awarded=0`) award rep for **every historical match at once** on the first boot (a mass rep grant). So the
`ADD COLUMN ... DEFAULT 1` backfills all pre-existing rows as already-awarded (skipped by the reconcile), and
the resolver **sets `rep_awarded=0` at the moment of resolution** so only post-deploy matches are reconcilable.
(This differs from a brand-new table, where the DEFAULT is moot because the resolver controls every inserted
row — here the DEFAULT is load-bearing because history exists.)

## 5. Match lifecycle (state machine — server-owned, single resolver)

```
IDLE
 → CHALLENGE  A targets B at the ring (server verifies BOTH at ring via server coords) and sends a request;
              B gets an accept/decline prompt. TTL = Config.ChallengeTTL (20s) → auto-expire.
 → ACCEPTED   server calls palm6_fightclub:OpenMatch(A,B) → integer matchId; snapshots fighter+style per side.
 → BETTING    match row status='betting'; betting window Config.BetWindowSec (30s); /fcbet open ONLY here.
 → COUNTDOWN  3-2-1; both clients enter fight mode (see §6 teardown-safe setup); betting closed.
 → LIVE       the round (§6). Round cap Config.RoundSec (180s).
 → FINISH     KO (server HP≤0), finisher KO, ring-out forfeit, DC forfeit, or round-timer expiry.
 → RESOLVED   fc_combat computes winner+method, calls ResolveMatch(matchId,winner,method); teardown both clients.
 → IDLE
```

**Round resolution (MVP = single round):** first fighter to server-HP ≤ 0 loses (method=ko/finisher). If
`RoundSec` expires: higher HP% wins (method=ko); equal within Config.DrawBand → **draw** (method=draw, no rep,
bets fully refunded via the existing draw path). Multi-round/best-of deferred.

**Ring occupancy:** one active match per ring. A second challenge while a ring is busy is rejected ("ring in
use") — no queue in MVP (challenge-driven, not queue-driven; the old queue is removed).

**Concurrency/races:** a player already in CHALLENGE/ACCEPTED/BETTING/COUNTDOWN/LIVE cannot be challenged or
challenge again (server per-cid state guard). Mutual simultaneous challenges: first to reach the server wins,
the second is auto-declined. All challenge/accept events eventguard-budgeted + rate-limited.

**Disconnect / exit — handled at EVERY state:**
- CHALLENGE/ACCEPTED/BETTING (pre-fight): match voided; any `betting` bets refunded via the existing bet-refund
  path; no result row resolved.
- COUNTDOWN/LIVE: the disconnecting player forfeits → `ResolveMatch(matchId, opponentCid, 'forfeit')` (settles
  purse to opponent, bets via existing path); opponent client runs teardown.
- Simultaneous KO+DC or double-trigger: resolution is idempotent — `ResolveMatch` is gated by the existing
  atomic `UPDATE matches SET status='resolved' WHERE id=? AND status='live'` (affected==1); only the first
  caller resolves, later callers no-op. fc_combat also holds a per-match in-process `resolving` flag.

## 6. Combat model (`palm6_fc_combat`) — server-driven move clock

**Server owns all fight state.** HP, stamina, momentum are **server script vars** keyed by matchId+cid — never
ped health. Fighter peds are decoupled and hardened each LIVE tick:
- `SetPlayerInvincible(playerId,true)` + `SetEntityInvincible(ped,true)` — blocks health loss only.
- **`SetPedCanRagdoll(ped,false)`** — the call that actually stops a punch/vehicle/explosion from knocking the
  fighter into ragdoll and interrupting a clip (invincibility does NOT do this).
- Pain/flinch suppression: `SetPedSuffersCriticalHits(ped,false)` + relevant `SetPedConfigFlag` pain flags.
- Native melee input suppression: `DisableControlAction` on 24,25,140,141,142,143,257,262,263,264 each frame
  (blocks the *local* fighter's own melee inputs); `SetCurrentPedWeapon(ped,WEAPON_UNARMED)` +
  `SetWeaponsNoAutoswap` only guarantee empty-handed (they do NOT block being hit).
- **Third-party interference (handled):** a non-participant who hasn't disabled melee can still swing at a
  fighter, but `SetPedCanRagdoll(false)`+invincibility neutralize the physics, and the server **ignores any hit
  whose attacker is not a snapshotted participant of that matchId**. Arena may also soft-repel non-participants.
- **Ordering:** before any intended KO/finisher ragdoll, flip `SetPedCanRagdoll(ped,true)` first or
  `SetPedToRagdoll` no-ops.

**Move clock (replaces "validate mid-move" — the server can't read client anim state):**
1. Client presses input → emits `fc:combat:strike{matchId,moveId}`.
2. Server validates: correct match+state (LIVE), move exists, per-move cooldown elapsed (server timer),
   stamina ≥ cost. On pass: deduct stamina, start a server-side **active window** timer for that move, tell BOTH
   clients to play the clip. (Server now owns move cadence, so it *can* time-validate the connect.)
3. Attacker client, on visual connect, emits `fc:combat:connect{matchId,targetCid}`.
4. Server validates: connect arrived within that move's active window, target is a LIVE participant, within
   `move.reach` (server coords distance), target not currently in a valid block (§ blocking). On pass: apply
   `move.damage` to server HP, add momentum to both (landed→attacker, taken→target — the Def Jam feel),
   broadcast HP/stamina/momentum via statebags. Reject (rate-limit/log) otherwise.

**Blocking:** `block` is a held stance (client sets a block flag → `fc:combat:block{on/off}`, server records it).
A connect against a blocking target that is facing the attacker deals `move.chipPct` chip damage + drains the
blocker's stamina by `move.blockStamCost`; block breaks if stamina hits 0 (server-owned, so unforgeable).

**Stamina:** heavy moves + blocking cost stamina; regenerates `StaminaRegenPerSec` when not attacking/blocking;
at 0 you can only throw light strikes (server-gated).

**KO:** server HP ≤ 0 → server orders **the victim's own client** to ragdoll itself (`SetPedCanRagdoll(true)` →
`SetPedToRagdoll` type 0/1/3 + `ApplyForceToEntity`) — each client only ragdolls the ped it owns, avoiding the
remote-owner problem → FINISH.

**Anti-cheat posture (documented limits):** no true server hit-detection exists in FiveM; the server owns
HP/stamina/momentum + the move clock and validates every event, so a cheater cannot mint rep/money (gated on
the server result + atomic claim) though they may desync visuals. Accepted, not hidden.

## 7. Blazin finisher (local-synced-scene, per-client)

Trigger: a fighter whose momentum is full lands a **heavy** connect (the "qualifying hit") → server starts the
finisher. Fairness (MVP): the finisher is **telegraphed** (a wind-up beat + audio cue) and the victim gets a
short **mash-to-reduce** window (`fc:combat:break` spam) that scales the finisher damage down — so a full meter
is a big momentum swing, not a guaranteed instant KO unless the victim is already low. It only KOs if it drops
HP ≤ 0.

Execution (never `NetworkCreateSynchronisedScene`):
1. Server computes finisher **origin+rotation** from the two peds and picks the clip pair; broadcasts params to
   all clients in range **and re-broadcasts to late-arrivers for the duration** (§ late-join).
2. Every client runs an **identical local** `CreateSynchronizedScene`/`TaskSynchronizedScene` with both peds
   `SetEntityCoordsNoOffset`+`FreezeEntityPosition(true)`+`SetEntityInvincible(true)`+`SetPedCanRagdoll(false)`
   for the 2–4s duration (freeze prevents interpolation drift; both peds are driven locally, sidestepping
   network ownership). Preload the clip dict first (§ preload).
3. Participants get a scripted dolly cam (`SetCamActive`/`RenderScriptCams`) + participant-only slow-mo
   (`SetTimeScale`) + brief screen FX. Spectators see the scene (both peds animate locally) but keep normal cam.
4. On scene end: server applies finisher damage authoritatively → teardown → KO/RESOLVED. All temporary states
   (freeze, invincible, CanRagdoll, cam, timescale) reset in the canonical teardown (§ teardown).

## 8. Roster & styles (`palm6_fc_core` data)

- **Fighters** = data `{id,name,model,styleId,unlockId?}`. MVP ships ~4-6 **original house fighters** (original
  names/silhouettes) mapped to **existing base/MP ped models** (zero custom assets to ship). A fighter is just
  data+model, so custom original models swap in later.
- **Styles** = data `{id,name,movementClipset,moveTable}`; ~3 styles (Brawler/Kickboxer/Wrestler-lite).
  `SetPedMovementClipset` **requires `RequestClipSet` + wait-until-`HasClipSetLoaded` first** (it silently
  no-ops otherwise). Styles are decoupled from models.
- **Appearance safety:** applying a house-fighter model swaps the player ped. Snapshot and **restore the
  player's real appearance + inventory-visible model on teardown/exit** (store before SetPlayerModel; restore
  after). Never leave a player stuck as a fighter model.
- **Select UX:** NUI list + stance-preview cam at the arena. Client only *requests* fighter/style; server
  resolves + snapshots into the match at ACCEPTED.

## 9. Progression (`palm6_fc_progression`) + anti-farm

- On server-internal `fc:match:resolved`: atomically claim `UPDATE matches SET rep_awarded=1 WHERE id=? AND
  rep_awarded=0` (affected==1 gates) → credit winner rep (+ small loser consolation), update wins/losses/rank.
- Boot reconcile: `status='resolved' AND rep_awarded=0` matches created post-deploy are re-driven idempotently.
- **Anti-farm (the server has a farmable-stat→cash history, so this is mandatory):** (a) rep is **display/rank
  only in MVP — it pays NO cash and unlocks only cosmetic/style items**, severing farm→money; (b) no rep for a
  win vs an opponent you already beat within `Config.RepCooldownSec`; (c) no rep on `forfeit`/`draw`; (d) daily
  rep cap. Match-fixing for BETS is bounded by the existing bet caps + the fact that both fighters consent and
  bets are parimutuel; document that player-chosen opponents allow collusion and cap exposure via MaxBet.
- Exports: `GetRep/GetRank/HasUnlock`.

## 10. Betting (`palm6_fightclub`, rewired — money path unchanged)

Betting keeps its battle-tested recoverable payout (`settleMatch`/`reconcileUnsettled`/`claimBet`/`purse_paid`/
`settled`). Changes: (1) matches are opened by combat's `OpenMatch` (challenge-driven), not the queue; (2) the
BETTING window is a lifecycle state (§5) — `/fcbet` is open only during it; (3) resolution comes only from
combat's `ResolveMatch(matchId,winnerCid,method)` — `settleMatch` already maps winnerCid→slot via
fighter1/2_citizenid, so no slot is transmitted; (4) the old `sweepLiveMatches`/`checkFighter` self-resolver
(health≤KOHealth, weapon-draw, left-ring, MaxDuration) is **removed** so combat is the sole resolver (no
double-resolve). Bet refunds on pre-fight void / draw / forfeit all use the existing paths.

## 11. Restart-safety & teardown

- **Canonical teardown** (one function, called on KO, finisher-end, forfeit, DC, error, resource-stop): unfreeze
  peds, `SetPedCanRagdoll` restore, invincibility off, pain flags restore, re-enable melee, release script cam,
  reset `SetTimeScale(1.0)`, close NUI HUD, **restore real appearance/model**, clear per-match client state.
- **fc_combat restart mid-match:** HP/momentum are in-memory and lost. On boot, any `palm6_fightclub_matches`
  row still `betting`/`live` is resolved as **no-contest** → bets refunded via the existing bet-refund path,
  match marked resolved(method=draw), and connected clients receive a teardown broadcast (a boot "abort any
  fight" event) so no one is stranded invincible/frozen. No money stranded (bets refunded; no purse on
  no-contest). This is the honest restart story (the v1 "restart-safe" claim is only true with this abort path).

## 12. Arena, spectators, audio, performance

- **Arena:** ox_lib zone for ring bounds + spectator gallery; server owns the authoritative at-ring coords
  check; crowd = cheap **local non-networked** peds (`CREATE_PED` client-side, `WORLD_HUMAN_CHEERING` scenarios,
  culled by distance). Spectator cam = optional client toggle at the gallery.
- **Spectators:** anyone in the arena zone; they see the fight + the finisher (peds animate locally for
  everyone) and can `/fcbet` during the BETTING window. Non-participants are soft-repelled from the ring
  interior during LIVE.
- **Audio (the #1 driver of Def Jam feel — MVP includes a minimum):** crowd bed + reaction stings, per-hit SFX,
  a Blazin charge/ready cue, and a finisher hit-stinger, via a sound lib (xsound/interact-sound or native
  `PlaySoundFrontend`). Announcer/licensed-music deferred; all audio original/CC/licensed per the IP line.
- **Performance budget:** the LIVE combat tick runs only for the ≤2 active fighters (not all players); crowd
  peds are local, count-capped (`Config.MaxCrowd`), distance-culled, and spawned only while a match is LIVE;
  statebag HUD updates are **coalesced/throttled** (send on change, ≤ N/sec) not per-frame; spectator clients
  run render-only. Target: no measurable server tick cost when idle, bounded during a fight.

## 13. Cross-cutting rules (palm6 discipline)

Money-safety (charge-before-grant; atomic claim-before-credit; boot reconcile); eventguard budgets for every new
net event — **combat events (strike/connect/block) are higher-frequency than money events, so they get
combat-rate budgets and a client-side emit cap tied to the server move cooldown**, not money-sized budgets that
would kick a legit fighter; eventguard ensures before the fc resources. Server-authoritative throughout (HP,
winner, price, rep, proximity all server-owned). Statebag HUD sync documented (targeted replication to the two
fighters + spectators, throttled). Bridge pattern + RFC-001 metadata + `palm6_<domain>` naming.

## 14. Testing / verification

- Per-resource `luaparse` on every `.lua`; boot-verify on a local FXServer (0 SCRIPT ERROR).
- A **stub mode**: an **ace-gated** dev command (`/fcdebug resolve <matchId> <winner>`) fires the resolver so
  progression/betting/arena/HUD are testable before real combat — **must be ace-gated** (an open command is a
  rep/purse mint). Combat itself validated by two test clients (or one + a spawned bot) exercising strike/
  connect/block/KO/finisher/DC at each state.
- Money-safety regression: verify no double-resolve, no stranded bets on DC/restart, rep gated + anti-farm caps.
- David feel-tests in-game before "done" (the standing rule).

## 15. Deploy / rollout (cutting over a LIVE resource)

`palm6_fightclub` is live in prod. Cutover plan: (1) land the new resources + the fightclub rewrite behind a
`Config.Enabled`/convar so the new challenge/combat path can be toggled; (2) migrations are additive/idempotent
(new columns/tables) — the old rows stay valid; (3) deploy during low pop; (4) the removed queue/self-resolver
means old `/fcjoin` stops — announce it; (5) verify prod boot + a live test match + a settled bet before calling
it shipped. Follow the palm6 deploy path (push → CI → prod-verify info.json + DB).

## 16. Risks & mitigations
1. **IP/legal (existential)** → original brand + house/player-created roster + provenance manifest. (Decided.)
2. **Synced-scene desync** → local-synced-scene-per-client + freeze; prototype on base-game takedown clips first.
3. **No true server hit-detection** → server move clock + owned HP/stamina/momentum + validated events; rep/money
   gated on the atomic claim, never fight telemetry.
4. **Double-resolve / two resolvers** → old self-resolver removed; single atomic `live→resolved` claim.
5. **Restart strands fights / money** → boot abort-and-refund no-contest path (§11).
6. **Scope (XL)** → seam-gated loop + stub first, then striking, defer grapples/mocap/creator.

## 17. MVP acceptance criteria

Two players challenge at the ring (server-verified proximity) → betting window → real striking (light/heavy/
block, server move clock, server-owned HP/stamina) → a Blazin meter that fills and triggers **one** cinematic
finisher identical on all clients (with a fair mash-to-reduce window) → server-side KO/resolution → purse settles
off the resolver, winner gains **cash-neutral** rep (anti-farm capped) and can rank up. ≥4 original house fighters
across ≥3 styles. Crowd + spectator cam + HUD + minimum audio present. DC/restart never strand a player or money.
Zero custom/copyrighted assets shipped. luaparse-clean; boot-verified; David feel-tests before ship.

## 18. Phasing beyond MVP (context)
Next: build-your-own-fighter + custom original models. Then: grapple/throw + environmental finishers (custom
synced scenes + mocap). Then: reversals/counters, full unlock tree, gear, seasons/ladder.
