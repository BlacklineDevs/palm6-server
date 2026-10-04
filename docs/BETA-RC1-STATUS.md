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
| Migrations, fresh database | **AUDITED STATICALLY, see the section below.** Numbering is consistent and the next free number is 0078. Not applied to a clean DB in this session. |
| Migrations, production upgrade | **AUDITED STATICALLY, see below.** |
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
| 10 | **Wanted state is stored four times and two player-facing surfaces contradict each other.** A citizen can have `/fines` and `/priors` both saying "WARRANT OUT" while `/amiwanted` says "You are clean" and the MDT shows nothing | `palm6_citations`, `palm6_wanted`, `palm6_mdt` | Open. Fix is a design decision about which store wins. See the law-enforcement section |
| 9 | **A wanted player can break a police pursuit by walking into a shop**, and **admin spectate silently fails on anyone inside an interior.** `Config.Interiors = true` with `Config.Interior.PublicEntry = true` and `AdminBucketFollow = false`. The config header names both as decisions to make *before* going live; neither was made. Routing-bucket isolation is real, so the pursuing officer cannot follow or see them. Both are inert **only while no interior shell has been captured**, which this repo cannot determine | `palm6_business/shared/config.lua:330,378` | **HUMAN REQUIRED: run `/bizshells`.** If it lists any shell, both are live and #9 is a beta blocker for the police loop |

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
| `palm6_business` Phase 0 core | `Config.Enabled = true` | Yes, hardened |
| `palm6_business` storefronts (1a) | `Config.Phase1Enabled = **true**` since 2026-07-21 (`2dfd572`) | Yes. `docs/GO-LIVE-RUNBOOK.md`'s table said DARK and was stale; the config comment was honest. **Not re-darked:** unlike `palm6_racing` this was a deliberate step in the documented 6-gate sequence, not a forgotten feel-test. |
| `palm6_business` per-type / manager / lifecycle / robbery | all `false` | Yes, keep dark. Robbery especially: player-vs-player value transfer with no feel-test on record. |
| `palm6_business` interiors | `Config.Interiors = **true**` | ⚠️ **Two undecided balance calls, see P1 #9.** |
| `palm6_protection Config.ExtortOwned` | `false` | Yes, keep dark. It is also what keeps the `vinewood` zone error latent. |
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

## Police / DOJ / EMS stack

Audited as a system on 2026-10-04. The money paths are sound; the problems are
**duplicate sources of truth that disagree on screen**, and documentation that
would mislead a tester.

### Fixed this pass

| Finding | Severity | Resolution |
|---|---|---|
| `/record [citizenid]` left **no trace** when one citizen read another's criminal history. The only gate is `IsOnDutyLawyer`, and the resource's own README concedes the lawyer job is one any player can take. It was the only record read in the stack with no audit, while `palm6_mdt` audits both its writes and `/sentence` audits its own reads in the same file | **P1** | **FIXED (`657cdb6`)** — audited through the existing `palm6_staff` sink. Logged rather than rate-limited: a budget throttles casework without stopping a patient attacker |
| `palm6_pd_life:takePost` was an unguarded second duty-transition path (`SetDuty(src, true)` with no `atDutyPoint` and no rate limit, while `toggleDuty` has both) | **P2 latent** | **FIXED (`657cdb6`)** — gate is conditional on the duty *transition*, so an already-on-duty officer can man a post anywhere. Unreachable today (`Config.Rooms = {}`) but its trigger ships with it |

### Open: wanted state is stored four times and two surfaces contradict each other

**P1, and a player can see it.** `palm6_mdt_warrants` is authoritative.
`palm6_wanted` re-queries it raw rather than calling `HasActiveWarrant`.
`palm6_citations` marks a fine `escalated` **before** issuing the warrant and
keeps the mark when `IssueWarrant` returns nil, which it does on three paths.

So a citizen can end up with `status='escalated'`, `warrant_id = NULL` and zero
warrant rows, at which point:

- `/fines` says **"OVERDUE — WARRANT OUT"**
- `/priors` says **"OVERDUE, WARRANT OUT"**
- `/amiwanted` says **"You are clean. No active warrants, bounties or BOLOs."**
- `/warrants` and the MDT show nothing

Separately, a bounty with no warrant puts a citizen top of the public `/wanted`
board while every officer tool reads clean, because no MDT surface knows bounties
exist. Fixing this is a design decision about which store wins, so it is recorded
rather than patched.

### FIXED: evidence rendered as raw JSON to officers

**P2. Fixed (`a1f0c9d`).** `palm6_evidence` json-encodes table payloads into the
free-text `description` column, and **none of the three render paths decoded it**.
Table-payload writers include `palm6_mdt` itself, `palm6_chopshop`,
`palm6_counterfeit`, `palm6_insurance` and `palm6_drugs`, so this was the common
case for export-written entries. A detective running `/evidence case 7` read
`- [fact] palm6_counterfeit — {"serial":"QX7731","hop":2,"from_citizenid":"ABC12345"}`,
and `palm6_mdt` then truncated it **mid-JSON** at 100 characters. Only
`palm6_witnesses` read correctly, because it humanises before writing.

A render-side fix only: `describeEntry()` tries `json.decode` behind a cheap
first-character pre-check, emits `key: value` for an object or ordered values for
an array, and returns the input untouched on anything that is not decodable JSON.
`appendEntry` still stores exact JSON, so a machine consumer that decodes the
column is unaffected. Exposed as `exports.palm6_evidence:FormatEntry` and called
softly from `palm6_mdt` rather than duplicated, because a second copy of a
formatter is how two surfaces start disagreeing about what one row says. The
`palm6_mdt` trim now runs **after** formatting.

Verified against eight payload shapes: prose, a real counterfeit payload, an
array, an empty object, malformed JSON, leading whitespace, a brace inside prose,
and empty. All eight behave, and the test caught that integral numbers were
rendering as `hop: 2.0` (and would have rendered money as `amount: 1500.0`).

### Open: EMS billing is unbounded in aggregate

A medic types the amount as a chat argument. It is capped **per bill** at $50-$5000
(a reject, not a clamp) and everything else is server-authoritative: target is a
server id mapped server-side, both positions are read off server peds, self-billing
is blocked, 8 m proximity. But there is **no per-patient cap, no outstanding-total
cap and no per-shift quota**, and the budget allows 10 per minute, so a medic can
impose **$30,000/min of permanent unconsented debt** on one citizen. There is no
accept/decline prompt.

The debt is also unenforceable: `GetOpenFor` has **zero call sites repo-wide**, so
unpaid EMS debt has no consequence of any kind. **Not a mint** — the money goes to
the `ambulance` society account, not the medic, so it destroys player-side money
rather than creating it.

### Open: documentation would mislead a tester

Roughly 30 doc-vs-runtime mismatches. The ones that matter for a beta:

| Claim | Reality |
|---|---|
| `/help` says *"Each entry was confirmed against a real `RegisterCommand` call"* | False for `/witnesses` and 3 of 5 EMS rows |
| `/cite [id] [offense]` (in `/help` **and** `BETA-TEST.md`) | Takes `[citizenid\|serverid] [amount] [reason]`. **Following the documented form fails.** The README is correct |
| `/emsbill [id] [amount]` | A 5-140 char `reason` is **mandatory** |
| `/witnesses` *"(on-duty police)"* | ACE-restricted, admin/mod only. An on-duty officer gets access-denied |
| `/mdt`, `/warrant`, `/book`, `/calls` *"(on-duty police)"* | **Also require the `mdt_tablet` item** |
| `/expunge` *"(on-duty lawyer)"* | **Any citizen may expunge their own booking.** Omits courthouse proximity, 168 h age, no-warrant, no-open-citations, and the $2,500 fee |
| `/treat` *"Treat a patient"* | Writes a log row. Does **not** revive, heal or change health state |
| `/blotter` *"Weekly"* | 24 h window. The weekly digest is off |
| `palm6_mdt` *"server-only, no client script at all"* | Has a client NUI that performs warrant and BOLO **clears** |
| `palm6_mdt` charge catalogue *"SHIPS OFF"* | `Config.Charges.Enabled = true` |
| `palm6_witnesses` `FirePoliceAlerts` *"defaults OFF"* (config prose, header, **and the boot banner**) | **`= true`**. Only the README is right |
| `palm6_yard` jail persistence (README **and** `sql/0047`) | `Bridge.PersistJailMinutes` is an unconditional `return true` no-op |
| `palm6_seizure` `Config.PayOfficer = false` *"so police can't farm dirty money"* | The constant is read **nowhere**. Setting it true does nothing |
| `palm6_insignia` README says chest tape throughout | Config anchors it **above the head** |
| `palm6_uniform` CHECKLIST sends David to the duty point to verify the wardrobe | A 4th, higher-priority `Config.Wardrobe.Coords` wins, ~13.6 m away |
| `palm6_bounty` board *"Alta St"* | Mission Row front entrance. Its 4 `file:line` citations all point at unrelated code |
| **51 registered commands are absent from `/help`** | Including `/id`, the only way to learn a citizenid, which three documented commands require |

`palm6_ems`, `palm6_pd_life`, `palm6_rapsheet`, `palm6_wanted` and `palm6_blotter`
have **no README at all**. For `palm6_ems`, the money-handling one, the only
player-facing description is the `/help` entry that is wrong on 3 of 5 commands.

### Other open items worth naming

- **No command in the stack checks a job GRADE.** `qbx_police_overrides` defines
  Cadet through Chief; a Cadet has identical warrant, booking, BOLO and seizure
  authority to the Chief.
- **Warrant drops are unaudited on both paths** (`/warrantclear` and the NUI
  clear), while warrant *issues* are audited. Cancellation is the half that is not.
- `palm6_mdt_bookings.custody_status` / `released_at` have **zero readers and zero
  writers** repo-wide, so every booking reads `housed` forever. Harmless now
  because nothing renders it; if the intended out-of-repo `/ops` board is built
  against these columns it will report every citizen ever booked as in custody.
- `palm6_replay` writes evidence with a raw INSERT and **no `case_id`**, so the
  "REPLAY EXHIBIT" its README promises is attached to no case and never appears in
  `/evidence case` or `/mdtcase`.
- `/expunge` is a booking-existence and foreign-ownership **oracle**: the "no such
  booking" message fires before the authorisation message.

---

## Allowlist: the single recommended RC1 configuration

`palm6_allowlist` has **two independent admit paths, OR-matched**, and the order is
correct: the DB `allowlist` table is checked **first and synchronously**, then the
real-time Discord role lookup. `Config.FailOpen = false`, so a Discord API outage
denies rather than admits. Because the DB path runs first, an outage still admits
every already-synced player, which is the right failure shape. txAdmin's native
whitelist must stay `disabled` or joins get double-gated; the config says so.

So §10's concerns are already satisfied in design. What is **not** decided:

### 1. Set both bot convars. This is the recommendation.

```
set palm6:discord_bot_token  "<token>"
set palm6:discord_guild_id   "<guild id>"
```

Two reasons, and the second matters more than the documented one:

- It removes the ~10 minute admit lag.
- **It removes a dependency on an out-of-repo scheduled task.** Nothing in this
  repo writes the `allowlist` table. The rows come from
  `sync-horizon-allowlist.py` / Task `HorizonAllowlistSync`, running every ~10
  minutes somewhere else. While the convars are unset, **that task is the only
  thing standing between a whitelisted applicant and a denial**, and if it dies
  the symptom is invisible in the worst way: every already-synced player keeps
  joining normally, so the box looks healthy, while nobody newly whitelisted can
  get in. There is direct precedent on this stack for a dead scheduled job
  staying green and silent for days.

The boot banner now reports the table's row count and when a new person was last
added, with an explicit note that this is **not** proof the sync ran (`identifier`
is UNIQUE so the sync upserts, and `created_at` records first-add, not last-run).
It is a sanity check, not a heartbeat.

### 2. Decide whether the admit role set is a closed beta

`Config.AllowedRoles` currently admits **six** roles: `admin`, `moderator`,
`whitelisted`, `member`, `customer`, `investor`.

If `@member` is granted broadly in the Discord, this is an **open** beta wearing a
closed beta's name. That is a product decision, not a bug, and it is left alone
here. For a closed founding beta the narrow set is `admin` + `moderator` +
`whitelisted`, with `customer` and `investor` added only if those are deliberately
play-granting tiers.

Correctly handled already and worth not breaking: the **Founding Tester role is
deliberately excluded**, because `/beta` tells reservation holders that approval is
still required before play. A founding reservation must not by itself grant entry.

---

## Migrations: does a fresh database match an upgraded one?

Audited statically on 2026-10-04. **No live database was inspected, so nothing here
is a claim about production's actual schema.**

There are **three** schema authorities, not two: hand-applied `sql/` (67 files),
`palm6_dbmigrate/server.lua` (46 numbers, including 0067 and 0068-0073 which have
no `sql/` file), and **40 resources that self-create their own tables at boot**
with `CREATE TABLE IF NOT EXISTS`. The existing `migrations` invariant reads the
first two and compares CREATE bodies; it never looks at the third.

**The good result, and it is load-bearing:** 109 tables have a CREATE somewhere,
**82 are created in more than one authority, and CREATE-body drift is zero.** Every
one was compared normalised. The "copied VERBATIM from the matching sql/ file"
convention is genuinely holding. Every `UNIQUE` constraint that a guard depends on
is present identically in every copy, including the three the code explicitly calls
load-bearing (`palm6_fightclub_bets(match_id, citizenid)`,
`palm6_onboarding(citizenid)`, `palm6_officer_badges(badge)`).

**The real divergence is entirely in ALTER-added columns.** 56 of the 58
ALTER-added columns appear in **no** CREATE body. A fresh box builds the table
without them and then depends on `ADD COLUMN IF NOT EXISTS` to add them. That form
is **MariaDB-only and throws on MySQL 8 even when the column already exists**, which
is why every resource deliberately keeps these ALTERs out of its `schemaOk` signal
(otherwise a healthy MySQL box prints "schema MISSING" every boot). The reasoning is
sound; the cost is that the one signal that would catch this divergence is off on
purpose.

| Finding | Severity | State |
|---|---|---|
| `palm6_insurance_policies.status` created as a 3-member enum in **both** CREATE bodies; `'claimed'` is added only by `sql/0065`'s MODIFY. If that ALTER ever fails, the retire-on-claim UPDATE throws into a bare `pcall` and a damage claim becomes re-filable on one policy | **P1** | **FIXED (`4d25503`)** — the enum is now verified out of `information_schema` at boot, claims refuse *before* filing if it is definitely wrong, and the retire checks its own affected rows |
| 56 columns + 9 indexes exist only in MariaDB-only ALTERs. On the documented MariaDB 11.8 target the paths converge. On MySQL 8 a fresh box silently lacks all of them, and 15 of them are claim-before-credit settlement flags, so the crash-recovery design of migrations 0054-0063 would not exist on that box | **P1 on MySQL 8 / P3 on MariaDB** | Open. Engine-dependent. The highest-leverage fix is to fold ALTER-added columns into the CREATE bodies in all three authorities, leaving the ALTERs purely as the upgrade path |
| 24 tables and migration numbers 0067-0073 are invisible to `sql/` and therefore to `tools/apply-migrations.sh`'s `palm6_schema_migrations` ledger. A restore driven by that ledger reports success while missing them (runtime fills them in via `dbmigrate` + `ensureSchema`) | **P2** | Open. The ledger is not a description of the schema, and nothing in the repo says so |
| Six `palm6_mdt` schema changes carry no migration number in either authority | **P2** | Open. Both paths get them, so they converge; they are just invisible to the ledger |
| Two `dbmigrate` ALTERs target tables no authority has created yet at that point, so they fail by construction on the first boot of a fresh box. `dbmigrate/server.lua:36-39` admits this | **P2** | Open. Harmless, but they are the only red FAIL lines a *correct* fresh install produces, which trains an operator to read the FAIL summary as noise |
| `palm6_racing` satisfies its table dependency with `Wait(6000)` rather than a dependency check | **P3** | Moot while racing is dark (`d03beca`), real if it is re-enabled |
| `sql/0002` and `sql/0003` are not idempotent *as data* (they reset society balances and job salaries to seed values) | **P3** | Ledger-guarded. `0002`'s target has zero in-repo writers |

### One correction to the audit, recorded because acting on it would have caused harm

The audit reported the `paid` column default on `palm6_season_rewards` and
`palm6_lottery_draws` as a **P1** divergence (fresh `DEFAULT 0` vs upgraded
`DEFAULT 1`) and described the fresh value as the dangerous one. **Both are
non-issues, and "fixing" the default to match would have been actively harmful.**

- `palm6_season/server/main.lua:590` inserts `paid` **explicitly as 0**
  (`INSERT IGNORE ... (..., paid) VALUES (?, ?, ?, ?, ?, ?, 0)`), so the default is
  never read.
- `palm6_lottery/server/main.lua:430` **resets `paid = 0` at the drawing-to-drawn
  finalize**, guarded by `WHERE status='drawing'` so only a genuine new transition
  resets it. The payout reconcile only scans `status='drawn' AND paid=0`, so an
  `open` row's `paid` value is unreachable. `sql/0059`'s header states this design
  outright.

`TINYINT(1)` vs `TINYINT` is display width only. Verdict: **P3, cosmetic.** The
design anticipated exactly this case; the severity came from reading the ALTER's
comment without tracing the write paths.

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
