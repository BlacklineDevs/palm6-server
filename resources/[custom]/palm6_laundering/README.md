# palm6_laundering

The wash. The crime economy's dirty cash finally has a sink.

`qbx_bankrobbery` pays its hauls out as **`black_money`** — ox_inventory's
stock "Dirty Money" item (plain, count == dollars). You can hold it and hand
it around, but you can't bank it or spend it as clean money, and nothing in
the recipe or the rest of the custom layer converts it. `palm6_laundering` is
the conversion: a hidden laundromat front takes `black_money`, skims a fee,
and returns **clean bank funds** — bounded by a daily ceiling, watched by an
internal heat model that can call the cops, and logged as an evidence trail.

## Commands

- **`/launder`** — at the front, wash dirty money. The server reads your real
  `black_money` balance and washes the smaller of {what you hold, the per-run
  cap, your remaining daily ceiling}, removing that many dollars and crediting
  the clean remainder (after the fee) to your **bank**. Per-character cooldown.
- **`/dirtymoney`** — read-only: how much dirty money you're holding, how much
  you can still wash today, and the fee **you** would actually pay, heat
  surcharge included. If the front would turn you away at the door (an active
  warrant while `Config.BlockWhileWanted` is on, or a heat tier listed in
  `Config.HeatScrutiny.Refuse`) it says so instead of quoting a fee for a wash
  that would be refused.

## What makes it 1-of-1 (and not a dupe)

- **It's the only thing that launders.** Dup-gated against the real deployed
  recipe tree and every `palm6_*` resource: nothing converts `black_money` to
  clean money anywhere.
- **Strictly separate from `palm6_counterfeit`.** Counterfeit's
  `counterfeit_cash` is *fake* money that gets *passed* (fenced/spent) and its
  README states it can never be laundered. This resource touches **only**
  `black_money` and never `counterfeit_cash`. The two never interact.
- **Correct item, verified against the box.** The dirty-money item actually
  registered on this server is `black_money`, not the `markedbills` that some
  older custom-layer comments mention (`markedbills` isn't registered here —
  `qbx_storerobbery`'s reward no-ops and `qbx_drugs` runs `useMarkedBills=false`).

## Anti-abuse (all server-side)

- Position (`Bridge.GetCoords` off the caller's ped), dirty balance
  (`ox_inventory:Search`), and the fee (`Config.Cut`) are all read/derived
  server-side. The client supplies nothing but the command trigger — there is
  no client script and no client-supplied amount, item, or coordinate.
- Dirty money is **removed before** the clean credit; if the credit somehow
  fails the dirty money is handed straight back (never charged for a wash you
  didn't get). Money is never credited for cash that wasn't actually removed.
- Per-character `CooldownSec` + a per-day `DailyCap` (enforced by
  `SUM(dirty_in) WHERE created_at >= CURDATE()`) bound throughput. Chat
  commands aren't net events, so eventguard doesn't cover them — the cooldown
  and cap are the guard (same pattern as `palm6_chopshop`/`gunrunning`).

## Heat & evidence

Washing warms the front's heat (server-only accumulator, decays every sweep).
A single run at/above `Config.Heat.BigRunAlways` always trips a **native
police alert** (`police:server:policeAlert`, rendered by qbx_police); above
`AlertThreshold` a run trips it on a heat-scaled roll. A tripped run also opens
or appends a **`palm6_evidence` v2 case** (via the frozen
`EnsureCase`/`AppendEntry`/`LinkSuspect` exports — never its tables directly),
bucketed to a 5-minute window so a burst shares one case. Launder small and
slow to stay quiet; dump a whole bank haul at once and dispatch hears about it.

## Data

`palm6_laundering_runs` (`sql/0033_laundering.sql`) — one row per wash:
citizenid, dirty_in, clean_out, fee_bps, flagged, evidence_case_id, created_at.
Export `GetSummary()` returns `{ totalRuns, totalDirtyWashed, flaggedRuns }`.

## Tuning (`shared/config.lua`)

`Config.Cut` (fee), `MinPerRun`/`MaxPerRun`/`DailyCap`, `CooldownSec`,
`Config.Heat.*`, and `Config.Front.coords` (a Tier-3 Los Santos placeholder —
verify/retune the laundromat spot in-game).

Two knobs govern this front's relationship with `palm6_heat` (the durable,
per-character police-attention score, not the transient `Config.Heat` above):

- `Config.PlayerHeat` is what a wash **costs** you in heat. It is
  amount-proportional (`Base + dirty/1000 * PerThousand`, plus `FlaggedBonus`
  when the law noticed; `MaxPerRun` is a safety rail that never binds at the
  shipped numbers, since the $25,000 per-run ceiling already tops the formula
  out at 13 against a cap of 15). It used to be a flat
  charge per run, which made the fewest, largest runs the cheapest way to move
  a haul (a $500 wash and a $25,000 wash scored the same 5), the exact
  inverse of the stated design, where dumping a whole bank haul at once is
  supposed to be the loud play. This is a **default-on balance change**: a
  minimum $500 wash now scores 1 instead of 5. Reverting is config only, one
  line: put the pre-reshape table back as
  `Config.PlayerHeat = { Base = 5, FlaggedBonus = 8 }`. Every key is read
  guarded, so an absent (or zero) `PerThousand` charges exactly `Base` and an
  absent `MaxPerRun` means no cap, restoring the old flat 5 / 13-when-flagged
  exactly. `Base` is guarded too rather than mandatory: a table that omits it
  charges 0 heat per run silently instead of erroring, so always set one.
- `Config.HeatScrutiny` is what your existing heat **costs you at the front**.
  A `HOT` or `WANTED` citizen pays `ExtraCut` on top of `Config.Cut` (quoted
  honestly by `/dirtymoney`), or is refused outright if their tier is listed in
  `Refuse`. Set `Enabled = false` to restore the old flat-cut behaviour. This is
  the first live consumer of the `palm6_heat:GetTier` export.
