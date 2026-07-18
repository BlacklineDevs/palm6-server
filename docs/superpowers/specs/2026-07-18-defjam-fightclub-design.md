# Def Jam-Style Fight Club — Design Spec (MVP / "bigger Phase 0")

**Date:** 2026-07-18
**Status:** Design — approved for spec, pending final spec review before implementation planning.
**Repo:** BlacklineDevs/gtarp (Palm6 FiveM/Qbox server).
**Owner:** David Olverson.

---

## 1. Goal & fidelity target

Rebuild the fight club into a **Def Jam: Fight for NY-flavored** brawler: pick a fighter,
strike/combo with stamina, build a **Blazin momentum meter**, land a **cinematic finish**,
KO your opponent in a hyped arena with a crowd and live **betting**, and climb a **rep
career**.

**Fidelity target: convincing homage, not arcade-faithful port.** FiveM/GTA5 can deliver
the loop and the spectacle; it genuinely fights us on (a) frame-precise reversal timing and
(b) flawless two-body grapple sync. Those are deliberately deferred / simplified. The MVP
nails the *feel* using the well-supported primitives.

**Hard IP line (non-negotiable, enforced in the asset pipeline):** no real rappers,
celebrities, or copyrighted/iconic characters; no ripped Def Jam / Sifu / Sleeping Dogs /
Yakuza assets; the product is **original-branded**. Roster = original archetype "house"
fighters + (later phase) player-created fighters. Rationale: Take-Two owns Cfx.re and can
pull the server key **and** Tebex store; monetization strips any fan-use framing. Every
shipped model/animation carries a provenance note (original / CC0 / CC-BY / licensed).

## 2. Scope

### In (MVP / bigger Phase 0)
- Server-authoritative **match state machine** + the `fc:match:resolved` seam + DB.
- **Real striking combat**: native melee disabled, combo state machine off **base-game
  `melee@unarmed`** anims, server-owned HP/stamina/momentum, hybrid hit-reg, KO ragdoll.
- **Blazin momentum meter** (fills on hits landed *and* taken) → one **cinematic finisher**
  via the local-synced-scene pattern (server broadcasts params, every client runs an
  identical local scene + scripted cam + slow-mo).
- **Fighter select** with a few **original house fighters** + **styles** (movement clipset +
  per-style move table).
- **NUI HUD** (two health bars, stamina, glowing Blazin meter).
- **Arena**: zone + ring bounds + crowd of cheap local peds + spectator cam.
- **Rep/rank career** (progression ledger, unlocks) behind it.
- **Betting** rewired: settle purse off `fc:match:resolved`, not native-melee death.

### Out (deferred to later phases — explicitly not in MVP)
- Cinematic **grapple/throw** finishers + **environmental slams** (custom synced scenes + mocap).
- **Build-your-own-fighter** creator (player-created appearance persistence) — next phase.
- Deep **reversals/counters** with tight timing.
- Full **unlock tree** / gear / seasons.

## 3. Architecture — modules

Small, single-purpose resources, each using the palm6 bridge pattern
(`bridge/sv_framework.lua` + `bridge/cl_game.lua`) so framework/native calls stay isolated
(GTA6-portable). Load order: `palm6_fc_core` before the rest; `palm6_eventguard` before all.

| Resource | Responsibility | Interface (in → out) |
|---|---|---|
| `palm6_fc_core` | Shared data + the contract. Config; fighter/style/move data tables; statebag key constants; DB schema + migrations; the `fc:match:resolved` seam definition; eventguard budgets. No behavior. | exports: `GetFighter`, `GetStyle`, `GetMove`, `StateKeys`. Everything else `require`s/reads these. |
| `palm6_fc_combat` | The fight engine (client + server). Disables native melee; combo state machine; **server-owned HP/stamina/momentum**; hybrid hit validation; KO ragdoll; Blazin fill; drives the finisher. Owns match lifecycle. | in: challenge/accept/hit net events. out: **fires `fc:match:resolved`**; writes fight statebags the HUD reads. |
| `palm6_fc_hud` | NUI HUD only. Renders two health bars + stamina + Blazin meter from statebags/events. No authority. | in: fight statebags / `fc:hud:*` events. out: none. |
| `palm6_fc_arena` | Zone + ring bounds + crowd (cheap **local, non-networked** peds) + spectator cam. Presentation. | in: zone enter/exit. out: `fc:arena:atRing(src)` truth for combat's proximity checks. |
| `palm6_fc_progression` | Rep/rank/unlock ledger. Atomic **claim-before-credit** + boot reconcile. | in: **consumes `fc:match:resolved`**. out: exports `GetRep`, `GetRank`, `HasUnlock`. |
| `palm6_fightclub` (existing, rewired) | Betting/purse. Settle off the seam event instead of native-melee death. | in: **consumes `fc:match:resolved`**. out: purse payouts (existing money-safe path). |

**The seam is the spine.** Combat is the *only* producer of `fc:match:resolved`; progression
and betting are pure consumers. This lets us ship + feel-test progression/betting/arena/HUD
**before real combat exists** (combat stubbed behind a dev command that fires the seam), then
drop the real fight engine in behind the same contract.

### `fc:match:resolved` contract
Server-emitted (combat → server-side handlers in progression + fightclub), never client-trusted:
```
fc:match:resolved = {
  matchId   : string   -- server-generated match id
  winnerCid : string   -- citizenid (server-resolved)
  loserCid  : string   -- citizenid
  method    : 'ko' | 'finisher' | 'forfeit' | 'draw'
  startedAt : int       -- os.time at match open
  endedAt   : int
}
```
Rep/purse award is gated on the server's own match-state record + an atomic
`rep_awarded 0→1` flip — never on a client-reported outcome.

## 4. Data model (`palm6_fc_core` migrations, idempotent, registered in palm6_dbmigrate)

- `palm6_fc_match_results(id, match_id UNIQUE, winner_cid, loser_cid, method, started_at,
  ended_at, rep_awarded TINYINT NOT NULL DEFAULT 1, created_at)`
  - `rep_awarded` **DEFAULT 1** (first-boot safety: existing rows read as already-settled so
    the boot reconcile never re-pays history — the payout-recoverability lesson); the
    resolving INSERT sets it 0 so only post-deploy matches are reconcilable.
- `palm6_fc_progression(citizenid PRIMARY KEY, rep INT NOT NULL DEFAULT 0, wins INT, losses
  INT, rank_tier INT, updated_at)`
- `palm6_fc_unlocks(citizenid, unlock_id, unlocked_at, UNIQUE(citizenid, unlock_id))`
  — atomic INSERT IGNORE per unlock; no double-grant.

## 5. The fight loop (state machine, server-owned)

```
IDLE
 → CHALLENGE   (A challenges B at the ring; both must be atRing per fc_arena)
 → ACCEPTED    (B accepts; server opens a match, assigns matchId, snapshots fighters/styles)
 → COUNTDOWN   (3-2-1; clients lock into fight mode: native melee disabled, HUD up)
 → LIVE        (round; see §6)
 → FINISH      (KO or Blazin finisher; see §7)
 → RESOLVED    (server writes match_results (rep_awarded=0), fires fc:match:resolved)
 → IDLE
```
Forfeit (leaving ring bounds / disconnect) → RESOLVED with method='forfeit', opponent wins.
One match per participant at a time; server rejects concurrent challenges.

## 6. Combat model (`palm6_fc_combat`)

**Server owns all fight state.** HP, stamina, momentum are **server script variables** keyed
by matchId+cid — never ped health (peds are pinned invincible during a match so native
death/flinch/auto-ragdoll can't pre-empt our logic; a clean fight-state gate prevents
conflict with EMS/cops/other combat scripts).

- **Disable native melee** every frame in fight mode: `DisableControlAction` on
  24,25,140-143,263,264,257,262 + force `WEAPON_UNARMED` + `SetWeaponsNoAutoswap`.
- **Strikes**: read input via `IsDisabledControlJustPressed` → combo state machine → play a
  base-game `melee@unarmed@*` / `reaction@` / `get_up@` clip via `TaskPlayAnim`. Active-frame
  window gated by polling `GetEntityAnimCurrentTime` (0.0–1.0).
- **Hybrid hit-reg** (there is no true server-side hit detection in FiveM): client detects a
  landed strike (own anim in active-frame window + target within arc/range) → sends
  `fc:combat:hit{matchId, targetCid, moveId}` → **server validates plausibility** (same
  match, per-move cooldown/rate-limit, max reach, attacker actually mid-move) → server
  applies damage to its own HP var → broadcasts new HP/stamina/momentum to both clients' HUD.
- **Stamina** gates heavy moves/blocks (server math). **Momentum/Blazin** fills on hits
  landed *and* taken (the classic Def Jam feel), capped, server-owned.
- **KO**: when server HP ≤ 0 → server orders **the victim's own client** to ragdoll
  (`SetPedToRagdoll` type 0/1/3 + `ApplyForceToEntity`) — each client only ever ragdolls
  itself, avoiding the remote-ragdoll network-owner problem — → FINISH.

**Anti-cheat posture (accepted limits):** client is a dumb renderer + input source; every
inbound event validated + rate-limited server-side; rep/purse gated only on server match
state. A determined cheater can forge/suppress hit events (engine limitation) but cannot
mint rep/money because the payout is gated on the server's atomic claim, not the fight
telemetry. Documented, not hidden.

## 7. Blazin finisher (the signature moment)

When a fighter's momentum meter is full and they land a qualifying hit, the server triggers a
finisher. **We never use `NetworkCreateSynchronisedScene`** (documented desync/ped-drop). Instead:

1. Server computes the finisher **origin + rotation** (from the two peds' positions) and the
   clip pair, and **broadcasts the parameters** to all clients in range.
2. Every client runs an **identical local** `CreateSynchronizedScene` / `TaskSynchronizedScene`
   with both peds **frozen + invincible** for the 2–4s duration (freeze prevents interpolation
   drift), so the result is identical on every screen.
3. Participants get a scripted dolly cam (`SET_CAM_*` / `RenderScriptCams`) + slow-mo
   (`SetTimeScale`, participant-only) + brief screen FX.
4. Server applies the finishing damage authoritatively → KO → RESOLVED (method='finisher').

MVP ships **one** finisher clip pair (base-game takedown-style) to prove the pattern; custom
signature finishers per fighter come in a later phase (custom `.ycd` mocap).

## 8. Roster & styles (`palm6_fc_core` data)

- **Fighters** are pure data: `{ id, name, model, styleId, unlockId? }`. MVP ships ~4-6
  **original house fighters** (distinct silhouettes/vibes, original names). Model = an existing
  MP/base ped for MVP (no custom model needed to ship); custom original models can be swapped
  in later since a fighter is just data + a model hash.
- **Styles** are data: `{ id, name, movementClipset, moveTable }`. MVP ships ~3 styles
  (e.g. Brawler / Kickboxer / Wrestler-lite) applied via `SetPedMovementClipset` + a per-style
  move table (which base-game clips map to light/heavy/etc.). Styles are decoupled from models.
- **Fighter select**: NUI list + a stance-preview cam at the arena. Server records the chosen
  fighter/style into the match snapshot at ACCEPTED (client only *requests*; server resolves).
- Player-created fighters (fork of an appearance system) = **next phase**, not MVP.

## 9. Progression (`palm6_fc_progression`)

- On `fc:match:resolved`: atomically claim `rep_awarded 0→1` on the match row
  (`UPDATE ... SET rep_awarded=1 WHERE match_id=? AND rep_awarded=0`, affected==1 gates the
  award) → credit winner rep (+ small loser consolation), update wins/losses/rank_tier.
- Boot reconcile: any `rep_awarded=0` result rows (crash between resolve and award) are
  re-driven idempotently on start (same claim flip). DEFAULT-1 keeps history untouched.
- Rank tiers derived from rep thresholds (config). Unlocks: INSERT IGNORE per `(cid, unlock_id)`.
- Exports for HUD/other resources: `GetRep(cid)`, `GetRank(cid)`, `HasUnlock(cid, id)`.

## 10. Betting integration (`palm6_fightclub`, rewired)

Keep the existing money-safe betting (`/fcbet`, purse, atomic claim-before-credit,
charge-before-record). Change only the **trigger**: settle the purse on the server's
`fc:match:resolved` (winner known authoritatively) instead of the old native-melee
health-monitor KO. No change to the money-safety path.

## 11. Cross-cutting rules (palm6 discipline)

- **Money-safety:** charge-before-grant; atomic claim-before-credit; DEFAULT-1 recoverable
  flags + reset-at-transition; boot reconcile. Rep/purse gated on server match state only.
- **eventguard:** every new money/DB net event (challenge/accept/hit/finisher/select) gets a
  budget; eventguard ensures before the fc resources.
- **Server-authoritative:** clients never assert HP, winner, fighter price, rep, or proximity
  the server doesn't recompute.
- **Restart-safe:** an in-flight match on restart resolves to a no-contest (both refunded via
  the betting refund path); no orphaned money.
- **Verify:** boot-verify + luaparse each `.lua`; feel-test in-game (David) before "done".

## 12. Risks & mitigations

1. **IP/legal (existential).** → Original brand + original/house + player-created roster;
   provenance manifest; hard line enforced in the asset pipeline. (Decided: safe path.)
2. **Synced-scene desync.** → Local-synced-scene-per-client pattern (§7); prototype on
   base-game takedown clips before any custom mocap.
3. **No true server hit-detection → exploit risk.** → Server-owned HP/stamina/momentum; every
   event validated + rate-limited; rep/purse gated on the atomic claim, never fight telemetry.
4. **Remote ragdoll no-ops.** → KO routes each client to ragdoll *itself* on server order.
5. **Scope creep (XL).** → Ship the seam-gated loop first (progression/betting/arena/HUD with
   stubbed combat), then striking, then defer grapples/mocap/creator to later phases.

## 13. MVP acceptance criteria

- Two players challenge at the ring, fight with real striking (light/heavy/block/hit-react),
  server-owned HP/stamina, a Blazin meter that fills and triggers **one** cinematic finisher
  that looks identical on all clients, and a KO that resolves the match server-side.
- Pick from ≥4 original house fighters across ≥3 styles.
- Spectators bet; purse settles off the seam; winner gains rep and can rank up; all money-safe
  and restart-safe.
- Crowd + spectator cam + HUD present. Zero custom/copyrighted assets shipped.
- luaparse-clean; boot-verified; David feel-tests before ship.

---

## Phasing beyond MVP (for context, not this spec)
- **Next:** build-your-own-fighter (appearance persistence) + custom original fighter models.
- **Then:** grapple/throw + environmental finishers (custom synced scenes + mocap `.ycd`).
- **Then:** reversals/counters, full unlock tree, gear, seasons/ladder.
