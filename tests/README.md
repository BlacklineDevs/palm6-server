# palm6 Lua unit tests

Real Lua execution of the pure logic that decides **money, sentences, heat and
capture outcomes**. Not a linter, not a parser, not a mock: the production Lua
runs and its actual return values are asserted.

## Run it

```
cd tests
npm install      # once
npm test
```

Or run one suite:

```
node run.js turf         # any substring of a suite filename
```

Exit code is 0 when every assertion passed and 1 otherwise, so it drops into CI
or a pre-push hook unchanged.

Requires Node. It installs one dev dependency, `fengari` (a Lua 5.3 VM written
in JavaScript). **No resource depends on this directory**; nothing in
`resources/` imports it and the server never loads it.

## Why this exists

Before this directory the only automated checks on this repo were `luacheck.py`
(does the Lua *parse*) and a jsdom suite that exercises NUI **JavaScript**.
Neither executed a single line of the Lua that decides how long a player is
jailed, how much an insurance claim pays, how fast heat bleeds off, or when a
turf zone changes hands. Roughly 17 commits of new gameplay landed in 24 hours
with no in-game testing behind them. Everything ships behind a Config flag
defaulting to current behaviour, so the risk today is low, but the moment a flag
is flipped that safety net is gone.

## What is covered

| Suite | Resource | What it pins down |
|---|---|---|
| `00_harness_selfcheck.lua` | the harness | Every assertion helper is proved capable of FAILING. Source extraction is proved to raise on a moved, missing or ambiguous anchor. |
| `01_sentencing.lua` | `palm6_mdt/shared/sentencing.lua` | Charge stacking, concurrency, priors, the half-up rounding boundary, the charge limit cutting the least serious charge, both clamps, determinism, order independence, and a structural check that the file reads no clock and no PRNG. |
| `02_heat.lua` | `palm6_heat/server/main.lua` | The decay curve at every interesting age, tier boundaries from both sides, the cool-down estimate, and the whole `AddHeat` amount clamp against NaN, infinity, negatives, strings, nil, exactly-at-cap and over-cap. |
| `03_turf_contest.lua` | `palm6_turf/server/main.lua` | Contest progress accounting: normal ticks, a delayed tick, a pathological stall (capped, and provably unable to bank a capture from one sample), attacker-only, defender-only, outnumbered, ties, an empty zone, the anti-lock stall clock, a backwards clock, and the presence ledger that decides who pays heat. |
| `04_insurance_money.lua` | `palm6_insurance/server/main.lua` | Premium / coverage / deductible at every tier and both band edges, plus theft, total-loss and repairable-damage payouts. Includes a sweep over the whole value band proving a self-inflicted damage claim can never pay back its own premium. |
| `05_legal_lookup_budget.lua` | `palm6_legal/server/main.lua` | The rolling `/sentence` lookup budget, its window boundary, per-source isolation, the audit de-dup that keeps a read command off the Discord webhook, and citizenid comparison. |

Total: **560 assertions**.

## How the pure logic is reached

Most of the logic worth testing is a `local function` (or a bare block) inside a
server file that also opens MySQL connections, registers commands and installs
event handlers. Those files cannot be loaded here.

The tests therefore do **not** refactor the resources. Refactoring a deployed
resource to make it importable is a real behaviour risk, and this directory owns
no resource. Instead `T.slice()` and `T.line()` lift the **exact production
text** of a block out of the file by anchor lines and compile it, with the
handful of values it reads from its enclosing scope turned into parameters. The
bytes under test are the bytes that ship.

Both helpers require each anchor to match **exactly one line**. If somebody
moves, renames or duplicates the code, the lift raises and the suite fails
loudly rather than quietly testing nothing. `00_harness_selfcheck.lua` proves
that.

`palm6_mdt/shared/sentencing.lua` needs none of this: it is a deliberately pure
file and is loaded directly, along with its shipped `shared/config.lua`.

## What could NOT be tested, and why

This list is part of the deliverable. Nothing below is covered by any assertion
here, and none of it should be described as tested.

**Needs a database (MySQL round-trips, not reachable without a live DB):**

- `palm6_heat` `addHeat`'s atomic `INSERT ... ON DUPLICATE KEY UPDATE`. This is
  where the settle-and-add and the SQL-side decay actually happen, and its own
  comment notes the SQL decay is **not bit-identical** to the Lua `decayed()`
  helper this suite does test (DECIMAL truncation vs IEEE double, up to a
  1-point drift at boundaries). The Lua side is tested; the SQL side is not.
- `palm6_heat` `getHeat`, `getTop`, `sweep`, `GetSummary`.
- `palm6_turf` `finishCapture` (guarded `UPDATE`, the `palm6_gangs:AddRep` wire,
  the `palm6_heat:AddHeat` wire), `persistBrake`, `loadZones`, `ensureSchema`.
- `palm6_insurance` `scoreClaim` (three `SELECT`s plus a resource-state check),
  `creditClaim` idempotency and the boot reconcile, the payout release sweep,
  policy lapse.
- `palm6_legal` `bookingsFor`, `hasWarrant`, `openCitations`, `petitionCounts`,
  the expungement filing/fee/refund path.
- `palm6_mdt` `priorsFor` and `RecommendForBooking` (which is `priorsFor` plus
  the calculator this suite covers).

**Needs the game (natives / server entity state):**

- `palm6_turf` `presenceInZone` and `presenceSnapshot`. These read every online
  ped's coordinates through `Bridge.GetCoords`. The contest suite treats the
  attacker and defender COUNTS they produce as inputs, so everything downstream
  of the headcount is tested and the headcount itself is not.
- `palm6_insurance` `clampedValue` (`Bridge.GetVehicleValue`),
  `Bridge.GetVehicleDamageFrac`, `Bridge.FindVehicleByPlate`.
- Every `Bridge.*` function in every resource, by definition.

**Tangled with I/O, testable only after a refactor this lane does not own:**

- `palm6_insurance` `doClaim` as a whole. The money LINES inside it are lifted
  and tested individually, but the branch selection (theft vs damage vs total
  loss), the early returns and the notification text are interleaved with
  `Bridge` calls and cannot be driven end to end.
- `palm6_turf` `contestBlocked` / `defenderGateBlocked` / `displaceable`. These
  read module-level ledger tables (`gangOpenAt`, `gangRepelAt`, `gangNotifyAt`),
  `conflictBootAt` and `os.time()` that are declared hundreds of lines away from
  the functions, so lifting them by anchor would mean lifting most of the file.
  `displaceable`'s threshold is checked indirectly in the contest suite via
  `stalledFor`.
- `palm6_turf` `closeContest` and the ticker's outcome branch. The branch
  CONDITIONS (`progress >= HoldSeconds`, `stalledFor >= AbandonSeconds`,
  `defenderSeen`) are all tested; what the branch then DOES (notify, persist,
  flip) is not.
- `palm6_legal` `sentenceGate` (four `Bridge` job/ace calls).
- `palm6_mdt` `cmdSentence`, `/book`, `/warrant`, `/id`, `/runplate`.

**Deliberately out of scope:** clients, NUI, `qbx_*` and `ox_*` resources, and
anything under `[config_overrides]`.

## Findings

The suite was written by a lane that owned `tests/**` only, so it originally
asserted what the code **did** and wrote the case up here rather than patching
it. Findings 1 and 2 were **real bugs and have since been FIXED**; their
assertions now pin the fixed behaviour instead of the bug. The rest are recorded
behaviour, not defects.

### FIXED (assertions now pin the fix)

1. ~~**`Sentencing.Calculate` raises instead of returning a result when `priors`
   is a float with no integer representation.**~~ **FIXED** in
   `palm6_mdt/shared/sentencing.lua`: a count with no integer representation is
   normalised to the priors cap, so the export can no longer be made to throw. A
   legitimate over-cap count (8 against a cap of 5) is deliberately left alone,
   because the breakdown reports "of 8, capped at 5" and clamping would delete
   that line's meaning. Original write-up follows.
   Input was:
   `exports.palm6_mdt:CalculateSentence({'gta'}, math.huge)` (or `1e300`).
   `math.floor(math.huge)` stays a float, survives `math.max`, and the
   breakdown line `('priors: %d counted%s, ...'):format(...)` then raises
   `bad argument #1 to 'format' (number has no integer representation)`.
   The arithmetic itself is fine (`math.min(inf, 5) = 5`); only the display
   formatting throws. `Sentencing.Failure()` exists precisely so this file never
   throws at a caller, so this is a hole in that contract.
   *Reachability:* the in-repo caller (`priorsFor`) is a `SELECT COUNT(*)` and
   can only produce a non-negative integer, and the whole feature ships behind
   `Config.Charges.Enabled = false`. The exposure is the exported
   `CalculateSentence`, which any other resource may call with anything.
   NaN is safely absorbed (`math.max(0, nan)` returns `0` in Lua 5.3), so only
   infinities and very large floats are affected.

2. ~~**`palm6_heat`'s `decayed()` has no guard for a negative age, so heat goes
   UP.**~~ **FIXED** in `palm6_heat/server/main.lua`: `age` is clamped to 0, so a
   clock running backwards costs a player nothing and can never mint heat.
   Original write-up follows. `decayed(100, -60)` returns `101`; `decayed(150, -3600)` returns `195`,
   which is above `Config.HeatCap`. The age comes from
   `TIMESTAMPDIFF(SECOND, updated_at, NOW())`, which is negative whenever
   `updated_at` is in the future, i.e. after a backwards clock correction on the
   DB host. There is no clamp back to `HeatCap` on the read path, so an inflated
   value would flow into `tierOf` and out through `GetHeat`/`GetTop`.
   *Reachability:* requires the database clock to move backwards between a write
   and a read. Low, but not impossible.

### Recorded behaviour, not defects

3. **A capped catch-up window credits presence a player may not have earned.**
   In the turf ticker, `presentSec[cid]` accrues the full (capped) `elapsed` for
   whoever is in the radius at the moment the tick runs. After a long stall that
   is up to `maxStep` (20s) credited to someone who arrived during the freeze.
   *Impact:* `presentSec` only ranks heat recipients at capture, and
   `HeatMinPresenceSec` is 60, three times the cap, so a single catch-up window
   cannot by itself push a bystander over the heat floor. Recorded because it is
   a real asymmetry, not because it is currently exploitable. Pinned by
   `'a catch-up window credits at most the cap'`.

Not findings, but worth knowing, and each pinned by an assertion:

- The concurrent-sentencing model means that at the `MaxSentence` ceiling extra
  charges change only the fine, never the time. The code says so out loud in the
  breakdown; the test checks that line is printed.
- The fine ceiling (`MaxFine` $250,000) and the sentence floor (`MinSentence` 1)
  are both **unreachable** with the shipped catalogue: the worst possible
  10-charge sheet fines $198,500, and no catalogue entry has a zero sentence.
  Both clamps are exercised by moving the bound, so the logic is still covered.
- Ties go to the defender in a turf contest: `atk > 0 and atk > def` is false at
  equal numbers, so an even 5v5 bleeds at the full `DefenderDecayMult` rate.
- Heat sheds nothing for the first 80 seconds at the shipped 0.75/min rate,
  because the loss is floored to an integer.

## Harness limitations

- `fengari` implements Lua 5.3 semantics; `palm6_mdt` declares `lua54` in its
  fxmanifest. The only 5.4 feature the code under test uses is integer floor
  division (`//`), which is 5.3 and behaves identically.
- `fengari` is stricter than reference Lua about `string.format('%d', x)` for a
  float `x`: reference Lua accepts any float with an exact integer
  representation, fengari rejects some of them (`1e15`). No assertion here
  depends on that difference, and finding 1 above was verified against reference
  Lua semantics (`string.format('%d', math.huge)` raises in real Lua too).
- `fengari` does not ship the `io` library, so file access is handed in from
  JavaScript as `__readFile`.
- No world coordinate is authored anywhere in this directory. `palm6_turf`'s
  config calls `vector3`, which is stubbed to a plain table; nothing here reads
  a coordinate.

## Adding a suite

Drop a `.lua` file in `suites/`. It runs in a fresh Lua state with `T` (the
harness), `REPO` (absolute repo root, forward slashes) and `SUITE_FILE` already
set. Start with `T.begin('title')`, end with `T.done()`, and assert with the
helpers in `lib/harness.lua` (every one of which is proved fallible by
`00_harness_selfcheck.lua`).

Keep two rules:

- **Never assert a number you derived by re-implementing the code.** Assert the
  number the model is supposed to produce, and show the arithmetic in a comment.
- **Never refactor a resource to make it testable.** Lift the text, or write the
  case down in "What could NOT be tested" above.
