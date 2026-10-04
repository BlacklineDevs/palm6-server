# Palm6 Beta RC1 Status

**Version:** RC1 candidate assessment
**Date:** 2026-10-04
**Branch:** `beta/rc1-hardening` (PR #24)
**Baseline:** `main` @ `b33ddf6` (2026-08-04)

This is the source of truth for RC1 readiness. It replaces any estimate in a
handoff package. Where a claim is inherited rather than re-verified, it says so.

---

## Summary

**Verdict: READY FOR INTERNAL QA. Not ready for a closed founding beta.**

The gap is not features and it is not code quality. Every automated gate this
repo owns passes, and the self-test proves those gates can still fail. The gap
is that **roughly 33 world coordinates have never been stood on**, and the ones
that matter most are the ones that strand a player: the prison yard, the
smuggling nodes, the market exchange and refinery. None of that can be closed
from a keyboard.

### What was actually wrong, in order of how close it came to costing real damage

1. **Ten thousand lines of finished work existed only as untracked files.** Three
   resources (`palm6_charselect`, `palm6_appearance`, `palm6_radialmenu`), four
   test suites, their `custom.cfg` wiring and their eventguard budgets were on no
   branch and no remote, two months after they were written, on a workstation with
   a recorded BSOD and freeze history. Four of those test suites were not even
   visible in `git status` until 33 MB of loadscreen source art was ignored. Now
   committed and pushed.
2. **The starter vehicle could be granted, permanently, into a garage that does
   not exist.** Fixed. Detail below.
3. **`palm6_racing` was live while three separate places said it ships dark.**
   Re-darked.
4. **A turf zone center is about 2,017 units from the business that claims it.**
   Latent today. Now detected loudly at boot.

### What the assessment inherited and could not confirm

The "75-80% ready / server 85-90% / website 85% / bot 85%" figures predate this
sweep by two months and are not reproducible from anything in the repositories.
Treat them as discarded. The percentage below is scoped to the RC1 gate only.

**RC1 gate completion: about 70%.** Automated and structural work is done. The
runtime, world-position and multiplayer legs are untouched because they require a
running server and a human in the city.

---

## Automated gates

| Gate | Command | Result |
|---|---|---|
| Repo invariants (8) | `node tools/audit/run.js` | **PASS 8/8** |
| Invariant self-test | `node tools/audit/run.js --self-test` | **PASS** (19 planted violations, all detected; 8 checks silent on a clean tree) |
| Lua unit tests | `cd tests && node run.js` | **PASS** 1499/1499 assertions, 17 suites |
| Lua syntax, edited files | fengari Lua 5.3 VM | **PASS** (validated against a deliberately broken control) |
| Website typecheck | `npx tsc --noEmit` | **PASS** exit 0, zero diagnostics |
| Website unit tests | `npx vitest run` | **PASS** 50 files / 402 tests |
| Website build | `npx next build` | **PASS** exit 0 |
| Website lint | `npx eslint .` | **FAIL** 6 errors / 4 warnings, all pre-existing and all in untracked, un-gitignored `.handoff/` prototype `.cjs` files. No tracked source file errors. |
| Bot typecheck / tests / lint | n/a | **NOT RUN.** `node_modules` absent. `npm run lint` has never been runnable: `eslint` is not a dependency, not in the lockfile, and there is no eslint config. |

The self-test line is the one that matters. An 8/8 from a suite that cannot fail
is not evidence, and this suite demonstrably can.

The eight invariants are worth naming, because they already encode failures this
project paid for once: a table a query names with no `CREATE TABLE` anywhere; an
export call to a function the target does not register; an event raised with no
handler; a MySQL `.await` reachable from `onResourceStop`; a `RegisterCommand(...,
true)` with no matching `add_ace`; an eventguard budget whose resource is ensured
*before* the guard (which makes the budget a no-op while still counting in the
boot banner); an `ensure` for a deleted directory; and migration numbering across
*both* authorities, since `palm6_dbmigrate` owns numbers that have no `sql/` file.

---

## Runtime and staging gates

| Gate | State |
|---|---|
| Clean resource boot | **HUMAN REQUIRED.** All 87 ensures resolve to real resources and there are no duplicates (verified statically), but nothing here has booted an FXServer. |
| Migrations, fresh database | **HUMAN REQUIRED.** Numbering is consistent across both authorities and the next free number is 0078. Not applied to a clean DB in this session. |
| Migrations, production upgrade | **HUMAN REQUIRED.** Same. |
| `/diag` clean | **HUMAN REQUIRED.** |
| `palm6_devtest` clean | **HUMAN REQUIRED.** |
| Critical world anchors verified | **FAIL.** About 33 live `VERIFY IN-GAME` markers. See the walk list. |
| Website to game DB contract | **PARTIAL.** See cross-repo contracts. |
| Bot integrations | **PARTIAL.** See cross-repo contracts. |

---

## Open P0

**1. The `palm6-bot` local checkout is 3 commits BEHIND production, and pushing it
would silently delete a shipped feature.**

`DEPLOY.md` documents the ship ritual as `git push deploy HEAD:main`. Doing that
from the current checkout is a production rollback that removes the entire
founding-grant webhook and the durable role reconcile (`5ec620e`, `87c390e`,
`8e8e4a3`). There is **no `.github/` directory in that repo at all**: no CI, no
test gate, no lint gate in front of a one-command deploy to Railway.

Not fixable from here without touching the deployed branch. The action is
operational: do not push that checkout to `main`, and add a CI gate before the
next bot deploy.

---

## Open P1

| # | Finding | Where | State |
|---|---|---|---|
| 1 | ~33 unverified world coordinates, including every prison yard node, all 7 smuggling nodes, and the market exchange and refinery | `palm6_yard`, `palm6_smuggling`, `palm6_market`, `palm6_drugs` | **HUMAN REQUIRED** |
| 2 | `vinewood` turf zone center is ~2,017 units from `vw_pawn`, which declares that zone, against `OwnedZoneRadius = 200` | `palm6_protection/shared/config.lua` | **Detected at boot.** Correction is a design decision: `palm6_turf` owns zone centers and moving one relocates a capture point. |
| 3 | `/p6tp` covers 7 of ~102 anchors, so most of the walk list has to be reached by raw coordinate or `/anchors` | `server_base/server/main.lua` | Open |
| 4 | PS execute `queued` status is a black hole: no drainer exists anywhere, and the idempotency short-circuit returns `duplicate: true` without re-dispatching | `palm6-bot src/ps/execute.ts` | Uncommitted WIP in that repo |
| 5 | Game city-feed accepts a plain bearer secret as an alternative to HMAC, reducing the channel to a static password that crosses the wire on every request | `palm6-bot src/events/verify.ts` | Open |
| 6 | `GTARP_DB_*` is read by the bot but documented in no `.env.example`, so the whole PS feature deploys inert while reporting "queued" | `palm6-bot src/lib/gtarp-db.ts` | Open |
| 7 | The website `(site)` route-group restructure is 40 commits stale; merging as-is leaves `/business` outside the shared layout, shipping with no nav or footer | `palm6-web`, snapshotted on `rescue/uncommitted-2026-10-04` | Must be rebased, not merged |
| 8 | `LAUNCH-CONFIG.md` documents ~8 of 37 env vars in use. The omission that matters is `FIVEM_STATUS_URL`: without it the site shows "Pre-Launch" forever, even after the server opens, and nothing in the launch checklist says so | `palm6-web` | Open |

---

## Closed this pass

| Finding | Severity | Resolution |
|---|---|---|
| Starter vehicle granted permanently into an unverified garage, with a success message, unrepeatable | P1 | `900b186`. Garage resolved three-state before granting; flag claimed before the car is created; claim released on failure; deferred grants retried on later load; `palm6:onboarding_garage` convar; boot banner reports state and backlog |
| 34 files of finished, audited work untracked and unbacked | P0 (data loss) | `196b766`, `7b84d3b`, `8a4db6d`, `6f1b4d6`, pushed |
| 404 untracked website files including an entire `/ops` product | P0 (data loss) | `palm6-web` `22d57fb`, pushed to `rescue/uncommitted-2026-10-04` |
| `palm6_racing` live against three statements of intent | P2 | `d03beca`, re-darked |
| No zone/business coherence check | P1 (latent) | `d03beca`, boot-time check |
| `*.pem` dropped from the website `.gitignore`, making private keys committable | P2 | Restored in `22d57fb` |
| Website Phase 3 task 3.8 FAIL open 7 weeks (DEC-004) | P2 (governance) | Remediated and re-run to PASS as DEC-005, PR #11 |

---

## Dark and disabled features, explicitly

Verified by reading the live values, not the comments. The comments were wrong
twice.

| Resource / flag | State | Correct for RC1? |
|---|---|---|
| `palm6_threads` | `stop` in `custom.cfg`, directory present, allowlisted in the audit | **Yes, keep dark.** It overwrites a base GTA freemode clothing drawable and needs an addon-DLC conversion first. |
| `prop_spawn` | `stop` in `custom.cfg` | Yes, superseded by `palm6_props` |
| `palm6_racing` | `Config.Enabled = false` as of `d03beca` | Yes. Meet point still unverified. |
| `palm6_brain` | `Config.Enabled = true`, Director `Enabled = true`, `DryRun = false` | **LIVE.** Highest-risk live resource. |
| `palm6_brain` Director `MoneyEnabled` | `false`, marked "HELD: real money faucet" | **Yes, keep off.** Double-gated: also needs `palm6_business Config.NpcPassiveIncome`, which is `false`. Both would have to flip. Gate intact. |
| `palm6_brain` Director `CrimeEnabled` | `true`, throttled 911s gated by `MinOnDutyPolice` | Live and audited. Leave. |
| `palm6_brain` `PoliceBus.Enabled` | `false` | Yes, keep off. The witness-incident half is an unrequested gameplay change. |
| `palm6_brain` networked peds | `Enabled = true` but nothing spawns until `/netpedtest` | Armed, inert. Acceptable. |
| `palm6_business` Phase 1 flags | Not individually audited this pass | **Unknown. Do not flip anything.** |
| `palm6_mapeditor`, `object_gizmo`, `palm6_devtest` | Ensured in what deploys to production | **Open question.** ACE-gated per the `command-aces` invariant, but a dev tool reaching prod deserves a deliberate decision. Not changed. |

---

## Human test route

The full walk list with file:line and exact coordinates is in
`docs/BETA-RC1-WALK-LIST.md`. Priority order:

1. **`palm6_yard`, 3 nodes.** `/p6tp jail_labor`, `/p6tp jail_shop`,
   `/p6tp jail_bail`. All three are round to the nearest 10 and the tool's own
   note says "round placeholder, verify!". A jailed player who cannot reach
   commissary or labour is stuck in a cell with no loop.
2. **`palm6_smuggling`, 7 nodes.** All placeholder, all hand-round, two at
   `z = 1.0` (sea drops). An air drop at `z = 41` over the wrong ground is a
   crash, not a bad marker.
3. **`palm6_market`, 2 nodes.** Exchange and refinery, both explicitly
   "Tier-3 placeholder, VERIFY IN-GAME".
4. **The starter garage.** The single highest-value check in the list, because
   the fix is designed around it. Detail below.
5. **The Legion Square cluster.** One coordinate appears at 9 sites across 7
   resources: spawn, turf center, danger zone, payphone and an NPC scene are all
   the same square metre. Decide once whether that is intended.

---

## Deployment checklist

Exact order. Steps 1 and 2 are not optional.

1. **Confirm the real public garage name in-game** against the deployed
   `qbx_garages`. If it is `motelgarage`, nothing further. If not, set
   `palm6:onboarding_garage "<real name>"` in `server.cfg`. No deploy needed for
   the name itself.
2. **Apply `sql/0045_onboarding_starter_grants.sql` if it was never applied.** CI
   never touches the DB. On MySQL 8 the additive `ADD COLUMN IF NOT EXISTS`
   throws even when the column exists, so `palm6_onboarding` carries it as a
   best-effort ALTER. The starter-vehicle claim depends on that column: without
   it, no car is ever granted. The boot banner now says so explicitly.
3. Merge PR #24. **This deploys production and restarts the live FXServer**, so
   pick a quiet hour.
4. Watch the boot banner for the new `palm6_onboarding` lines: resolved garage
   state, owed-vehicle backlog, and the column check.
5. Watch for the `palm6_protection` zone-coherence line. It will report the
   `vinewood` mismatch until that is decided.
6. Run `/diag` and `palm6_devtest`.
7. Walk the P0 coordinate list.

## Rollback checklist

1. `git revert 900b186` restores the previous starter-vehicle behaviour, and the
   defect with it.
2. `git revert d03beca` re-enables `palm6_racing` and drops the zone check.
3. Reverting the whole branch removes three resources that `custom.cfg` ensures.
   Revert `196b766` and the `custom.cfg` change **together**, or the boot log
   fills with missing-resource errors.
4. No migrations are introduced by this branch. `sql/0045` is pre-existing and
   unchanged; the fix only detects whether it was applied, so no DB rollback is
   implied.

---

## Cross-repo contracts

| Contract | State |
|---|---|
| Website founding ledger to game founder tag | **Works, and a bot-only audit got this wrong.** `palm6_founder` is the authoritative in-game reader of `palm6_founding_grants` and exposes `GetTag` / `IsFounder` / `Refresh`, cache-backed and fail-open. An audit scoped to the bot repo concluded the founder DM promises a game-side mark "no code delivers"; that conclusion is false across repos. |
| `palm6_founding_grants` table ownership | **Real dependency, worth watching.** It is the single allowlisted exception in the `tables` invariant: the game queries it, the **website** creates it. If the website has not created it, `palm6_founder` silently does nothing, by design (fail-open). Nothing in the game repo can detect that. |
| Tebex webhook to Discord roles | Strong. Correct two-step signature verification, constant-time compare, raw-body capture, idempotency on envelope id with release-on-failure so a 502 lets Tebex retry, and refund logic that uses bundle marker roles rather than inferring from the "everything" bundle. |
| Tebex replay protection | Depends on `DATA_DIR` being a mounted Railway volume. Without one, `processed` empties on redeploy and a captured webhook can be replayed. Unverified from the repo. |
| Game city feed to Discord | Signature or bearer. Tightly constrained output (strict 7-type discriminated union, forbidden-field sanitizer that rejects nested `citizenid`/license/balances, embeds only so an injected `@everyone` cannot ping). An attacker holding the secret gets text defacement, not exfiltration. |

---

## Known risks

Engineering facts, no marketing language.

1. **The repo cannot verify its own world.** `qbx_garages`, `qbx_core`,
   `qbx_vehicles` and the rest of the base Qbox pack live on the game box and are
   not in this repository. Every garage name, every spawn point and every
   base-resource export is unverifiable from here by construction. The starter
   garage fix is built around that limit rather than pretending past it.
2. **`main` deploys on push, in two repos, with no gate.** `palm6-server` SFTPs
   the custom layer and restarts FXServer via Pterodactyl on any push to `main`
   touching `resources/**` or `custom.cfg`. `palm6-web` deploys the live site via
   Coolify on push to `main`. Neither has a passing-test precondition.
3. **`palm6_brain` is the largest live unknown.** Director committing goals with
   `DryRun = false` at a 48-slot target has never been load-observed. The money
   faucet is correctly double-gated off, which is the part that would have been
   unrecoverable.
4. **Config comments were wrong twice in one sweep**, in both cases claiming
   something was dark that was live. Any statement in a comment about a flag's
   value should be re-read off the value.
5. **The bot has no CI and the deployed branch is ahead of the local checkout.**
   That combination is how a rollback ships by accident.
6. **Documentation drift is the repeating pattern here**, not code defects. The
   stale registry count, WD-001 open for 2.5 months after it was resolved, the
   racing comments, and the starter-garage comment that said "confirm in-game
   before enabling in prod" directly above `enabled = true` are all the same
   failure: a record that was true when written and never re-checked. Every fix
   in this pass that could be made self-reporting was made self-reporting, for
   that reason.
