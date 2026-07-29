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
turf zone changes hands. Roughly 19 commits of new gameplay landed in 24 hours
with no in-game testing behind them. Almost everything ships behind a Config
flag defaulting to current behaviour, so the risk today is low, but the moment a
flag is flipped that safety net is gone.

The heat CONSEQUENCE layer is the largest body of value-deciding logic that
arrived that way: a haircut on drug money, an extra bust roll, a fence's
reduced payout, a bounty premium, and a laundering charge. Every one is pure
arithmetic and therefore testable today, without a game client, which is what
suites 06 through 10 do. One of the five (`palm6_laundering`) does **not** ship
behind a flag: both its blocks are live right now.

## What is covered

| Suite | Resource | What it pins down |
|---|---|---|
| `00_harness_selfcheck.lua` | the harness | Every assertion helper is proved capable of FAILING. Source extraction is proved to raise on a moved, missing or ambiguous anchor. |
| `01_sentencing.lua` | `palm6_mdt/shared/sentencing.lua` | Charge stacking, concurrency, priors, the half-up rounding boundary, the charge limit cutting the least serious charge, both clamps, determinism, order independence, and a structural check that the file reads no clock and no PRNG. |
| `02_heat.lua` | `palm6_heat/server/main.lua` | The decay curve at every interesting age, tier boundaries from both sides, the cool-down estimate, and the whole `AddHeat` amount clamp against NaN, infinity, negatives, strings, nil, exactly-at-cap and over-cap. |
| `03_turf_contest.lua` | `palm6_turf/server/main.lua` | Contest progress accounting: normal ticks, a delayed tick, a pathological stall (capped, and provably unable to bank a capture from one sample), attacker-only, defender-only, outnumbered, ties, an empty zone, the anti-lock stall clock, a backwards clock, and the presence ledger that decides who pays heat. |
| `04_insurance_money.lua` | `palm6_insurance/server/main.lua` | Premium / coverage / deductible at every tier and both band edges, plus theft, total-loss and repairable-damage payouts. Includes a sweep over the whole value band proving a self-inflicted damage claim can never pay back its own premium. |
| `05_legal_lookup_budget.lua` | `palm6_legal/server/main.lua` | The rolling `/sentence` lookup budget, its window boundary, per-source isolation, the audit de-dup that keeps a read command off the Discord webhook, and citizenid comparison. |
| `06_drugs_heat_price.lua` | `palm6_drugs/server/main.lua` | The heat haircut on dirty-cash payouts: every tier from both sides (composed with `palm6_heat`'s own `tierOf`), both clamps against config typos, and the invariant that decides whether the flag is safe to flip: the risky street buyer must out-pay the safe corner-dealer stash at **every** tier and **every** unit price the engine can mint. Also pins the reachable price band (`$23`..`$477`) and that a discounted seller burns more product for the same dollar-denominated daily cap. |
| `07_drugs_heat_bust.lua` | `palm6_drugs/server/main.lua` | The extra bust roll: bounded to `[0,1]` at every tier and every heat value, each gate's threshold recovered exactly out of the shipped code by bisection, and a **draw-counted** proof that the durable-heat roll only ever fires after the pre-existing `dealerHeat` model has already declined (no double-counting). Plus a full grid sweep proving no draw sequence can be flagged with the term off and clean with it on, and the composed rates (0.612 sale / 0.672 cook worst case) measured against a deterministic generator. |
| `08_chopshop_heat_payout.lua` | `palm6_chopshop/server/main.lua` | The fence's payout reduction: every `Config.ClassPayout` class against every tier, both clamps, every soft-guard failure mode (stopped / booting / throwing / non-string `palm6_heat`), and a sweep from `$0` past the most expensive class proving a payout is never negative and never exceeds `max($1, base)`. |
| `09_bounty_heat_premium.lua` | `palm6_bounty/server/main.lua` | The only heat effect that MINTS: the premium's `[0, Cap]` bound, the warrant-count ladder, the stored ceiling (`$6,200`) and the real payout ceiling once `palm6_pulse`'s modifier lands on top. Every dollar figure in the config's "SIZING THE FAUCET" comment is **recomputed from both resources' shipped config and then asserted to appear in the comment text**, so retuning either without updating the prose fails. Also covers the private-contract cancel fee and its boot-reconcile twin. |
| `10_laundering_heat.lua` | `palm6_laundering/server/main.lua` | The amount-proportional `PlayerHeat` charge, the `HeatScrutiny` cut (the one heat effect that ships **ON**), the clean-payout clamp, the ledger's basis-point record, the front's own bust model, and the design-intent property the reshape existed to buy: minimum-size splitting must never be the cheap way to move a haul. Includes an adversary search over every haul the daily cap allows, and a self-falsification pass that zeroes `Base` and requires the sweep to break. |

Total: **1,080 assertions** across 11 suites.

The five new suites cover the money math behind the three gameplay systems that
landed dark in the same 24 hours. Four of the five effects ship behind a
`Config` flag; `palm6_laundering`'s two blocks do not.

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
- `palm6_drugs` `dirtySoldToday` and `resolveDealer`'s persistence
  (`saveDealer`, `loadDealer`), so the daily-cap ACCOUNTING is untested even
  though the cap arithmetic that reads it is covered.
- `palm6_chopshop` `cmdSellStolen` end to end (the ownership `SELECT`, the
  stolen-report lookup, the sale `INSERT`, the `player_vehicles` retire and its
  void-on-failure path, `Bridge.CreditBank`) and `cmdReportStolen`.
- `palm6_bounty` `syncState`'s warrant `SELECT` and its guarded `UPDATE`/`INSERT`,
  `claimSettled`, `reconcileUnsettled`, the private-contract escrow charge and
  the expiry refund sweep.
- `palm6_laundering` `dirtyWashedToday`, the runs `INSERT`, and
  `Bridge.HasActiveWarrant`.

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
- `palm6_drugs` the sell handler and `resolveDealer` as whole functions. The
  money LINES inside both are lifted and tested individually and the two are
  proved to apply the identical haircut expression, but the surrounding item
  removal, payout, ledger write and notification text are interleaved with
  `Bridge` calls and cannot be driven end to end.
- `palm6_drugs` `heatTierOf`, `palm6_chopshop` `heatPayoutMult`,
  `palm6_bounty` `heatPremium` and `palm6_laundering` `heatScrutiny` all read
  `GetResourceState` and `exports.palm6_heat:GetTier`. The last three are lifted
  WITH those two calls stubbed, so their soft-guard branches are covered against
  a stubbed export; the live cross-resource call itself is not, by definition.
- `palm6_laundering` `cmdLaunder` and `cmdDirtyMoney` as whole functions. The
  two are proved to compute the fee with the identical expression, but the
  door refusals and the item/bank round-trips are not driven end to end.

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

### OPEN: found by the heat-money suites, not fixed (this lane owns `tests/**` only)

**A. `palm6_laundering`'s anti-splitting guarantee is not monotone. LIVE
today.** `Config.PlayerHeat` was reshaped from a flat per-run charge to an
amount-proportional one specifically so that splitting a haul into many small
runs would stop being the cheap way to move it. In the direction the config
comment states, the fix works and works well: the same $75,000 costs 39 heat as
three $25,000 runs and 150 heat as 150 minimum-size runs, where the old flat
model charged 15 and 750.

But the charge is `math.floor`ed **per run**, and the discarded fraction is
per run, so a run size just under a $2,000 boundary is more heat-efficient per
dollar than a maximum-size run. "More runs" is therefore not always "more heat":

    haul $60,000, playerHeatFor(amount, false):
      3 runs of $20,000  -> floor(1 + 10.0)  = 11 each -> 33 heat   (fewest runs)
      4 runs of $15,000  -> floor(1 +  7.5)  =  8 each -> 32 heat
     16 runs of  $3,750  -> floor(1 +  1.875)=  2 each -> 32 heat

    smallest hand-checkable witness, haul $4,500:
      2 runs of  $2,250  -> floor(1 + 1.125) = 2 each  ->  4 heat
      3 runs of  $1,500  -> floor(1 + 0.75)  = 1 each  ->  3 heat

An adversary search over every haul the $75,000 daily cap allows (run sizes
discovered by scanning the production function itself, then a shortest-path
pass) puts the worst case at **7.1%**: a $25,001 haul costs 14 heat played the
obvious way and 13 played the clever way. Over the full daily cap the leak is a
single point of heat (39 vs 38).
*Assessment:* real, bounded, and nothing like the 50x inversion the reshape
removed. Also gated in practice by `Config.CooldownSec = 45` between runs. Left
alone deliberately, but pinned by exact witnesses in `10_laundering_heat.lua` so
it cannot grow unnoticed, along with a hard proof that no split can ever get
below the per-thousand term. The config comment's own claim ("150 small runs
total 150 heat against 39 for three big ones") is correct as written; it is the
stronger reading of it that does not hold.

**B. `palm6_laundering`'s `heatScrutiny` reads its sub-tables UNGUARDED, and it
is the only one of the four heat consumers that ships ENABLED.** The three
siblings all degrade safely:

    palm6_drugs      local HeatPrice = Config.HeatStreetPrice or {}
                     tonumber((HeatPrice.Mult or {})[tier])
    palm6_chopshop   local HP = Config.HeatPayout or {}
                     tonumber((HP.Mult or {})[tier])
    palm6_bounty     tonumber((HB.PerTier or {})[tier])

`palm6_laundering` does not:

    if Config.HeatScrutiny.Refuse[tier] then return 0.0, tier, true end
    return tonumber(Config.HeatScrutiny.ExtraCut[tier]) or 0.0, tier, false

Deleting either sub-table raises `attempt to index a nil value` inside
`heatScrutiny`, which is called from `cmdLaunder` before any item is removed and
is not itself `pcall`-wrapped. `Config.HeatScrutiny.Enabled = false` is a safe
way to turn the feature off; deleting the table is not, even though every other
heat block in the repo tolerates exactly that. Pinned by two `T.raises`
assertions.
*Reachability:* a config edit only. No player input reaches it.

**C. `palm6_chopshop` can mint $1 from a $0 class price.** The haircut line is
`payout = math.max(1, math.floor(payout * hMult))`, so a class priced at $0
pays **$1** once `Config.HeatPayout.Enabled` is on, and $0 while it is off. That
is the one input at which "a payout never exceeds the base" is false, which is
why the assertion in `08_chopshop_heat_payout.lua` is worded as `max($1, base)`.
*Reachability:* none today. No `Config.ClassPayout` entry is zero and an
unmapped class is refused outright before the line is reached. It becomes
reachable the moment somebody adds a `[13] = 0` line, and a separate assertion
fails if any shipped class price drops below $1.

**D. Every `x 0.70` heat haircut quietly loses one extra dollar to binary
floating point.** `2600 * 0.70` is `1819.9999999999998` in an IEEE double, not
`1820`, so `math.floor` takes $1,819. The dollar goes to the house, the same
direction every other truncation in these resources goes, and the player is told
the true figure because the message prints `cleanPayout - payout` rather than
recomputing. Not a defect; pinned in `08_chopshop_heat_payout.lua` so a future
switch to rounding is a deliberate decision. The same shape appears in
`palm6_laundering`'s 0.90 cut clamp (`1.0 - 0.90` is `0.09999999999999998`, so a
$1,000 wash at the clamp returns $99). That clamp is unreachable at shipped
values.

**E. A NaN in a heat multiplier table survives both clamps.** In
`palm6_drugs`'s `streetHeatMult` and `heatBustExtra`, every comparison against
NaN is false, so `if m > 1.0` and `if m < floorMult` both miss and NaN is
returned. Both call sites then gate on `hMult < 1.0` / `extra > 0.0`, which are
also false for NaN, so the effect degrades to "no haircut" and "no extra roll"
rather than to a wrong number. Recorded and pinned rather than reported as a
bug: the failure mode is safe and only a config typo can produce it.

**F. VERIFIED CORRECT: the bounty faucet-sizing comment.** An earlier review
found `Config.State.HeatBonus`'s "SIZING THE FAUCET" comment understating the
real mint. The CURRENT numbers were recomputed from the shipped config of BOTH
`palm6_bounty` and `palm6_pulse` and all six agree:

    stored ceiling            Cap 5000 + HeatBonus.Cap 1200        = $6,200
    shipped surge, premium ON   6200 x 1.75                        = $10,850
    structural ceiling, ON      6200 x 2.00 (Config.MaxModifier)   = $12,400
    shipped surge, premium OFF  5000 x 1.75                        = $8,750
    structural ceiling, OFF     5000 x 2.00                        = $10,000
    increase from flipping the flag      $2,100 shipped / $2,400 ceiling

`09_bounty_heat_premium.lua` asserts each recomputed figure appears verbatim in
the comment text, so retuning `Cap`, `PerTier`, `MaxModifier` or the Bounty
Surge modifier without updating the prose fails the suite. Note the trap the
comment now warns about is real and tested: the increase is `Cap x 1.75`, not
`Cap`.

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
- The risky NPC street buyer strictly out-pays the risk-free corner-dealer stash
  at every `palm6_heat` tier and at every unit price the drug price engine can
  mint ($23 to $477), with the flag on and with it off. The two channels tie
  only at a $1 unit, which the catalogue cannot produce.
- `Config.MaxUnitPrice` ($500) is **unreachable** with the shipped drug
  catalogue: the dearest possible unit is $477 (meth, Heavenly, the eight
  highest-valued effects).
- `palm6_laundering`'s `Config.PlayerHeat.MaxPerRun` (15) is a safety rail, not
  an active guard. The largest legal wash ($25,000) scores 13, and the cap does
  not bind until a $30,000 run, which the per-run dollar ceiling forbids. The
  config says so; the suite checks it.
- The two laundering heat models deliberately pull in opposite directions on
  splitting: the durable per-run charge punishes many runs, while the front's
  `BigRunAlways = 20000` makes every maximum-size run an automatic police alert.
  Both directions are pinned so neither can change without the other being
  reconsidered.
- `palm6_bounty`'s `posted` amount is deliberately NOT re-clamped to
  `Config.State.Cap`: the heat premium rides on top, which is why the faucet has
  to be sized off $6,200 rather than $5,000.
- A private bounty under $10 would cancel for free (`floor(amount * 0.10)` is
  zero), which `Config.Private.MinAmount = 100` makes unreachable.

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
- `fengari`'s 64-bit integer and bitwise behaviour is **unreliable**: a
  `splitmix64` and an `xorshift32` written the ordinary way both returned
  degenerate values under it (measured, not assumed). The one suite that needs a
  pseudo-random stream (`07_drugs_heat_bust.lua`) therefore uses a float-only
  L'Ecuyer combined generator whose every intermediate product stays under 2^53
  and is exact in a double. Fixed seed, so it is bit-identical on every run and
  cannot go flaky. It was validated against known marginals before use.
- No world coordinate is authored anywhere in this directory. `palm6_turf`'s and
  `palm6_drugs`'/`palm6_laundering`'s configs call `vector3`, which is stubbed to
  a plain table; nothing here reads a coordinate.
- Where a suite needs a resource that is not its own (`palm6_heat`'s tier
  thresholds, `palm6_pulse`'s modifier ceiling), the other config is loaded
  FIRST, captured into a local, and the `Config` global is then handed to the
  resource under test. Two configs never share a global in one state.
- Cross-resource exports (`exports.palm6_heat:GetTier`) and
  `GetResourceState` are stubbed as locals inside the lifted chunk. Those stubs
  are the only non-production code in the call path, and they exist so the
  soft-guard branches (stopped / booting / throwing / non-string) are reachable.

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
- **Name the property, not the number.** A failure that reads `street pays
  better than stash at WANTED` tells the reader what broke; `expected 0.7` does
  not.
- **Prove the suite can fail.** The cheapest way is a temporary mutated copy:
  duplicate the suite as `zz_probe_<name>.lua`, inject one config mutation right
  after the `T.loadFile` of the resource config, run `node run.js zz_probe`, and
  confirm the assertions go red before deleting the copies. All five heat-money
  suites were verified this way (86 assertions failed across five one-line
  mutations). `10_laundering_heat.lua` also carries a permanent in-suite
  falsification: it zeroes `Config.PlayerHeat.Base` and REQUIRES the splitting
  sweep to break.
