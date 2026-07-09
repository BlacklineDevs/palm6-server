# gtarp_laundering

The wash. The crime economy's dirty cash finally has a sink.

`qbx_bankrobbery` pays its hauls out as **`black_money`** — ox_inventory's
stock "Dirty Money" item (plain, count == dollars). You can hold it and hand
it around, but you can't bank it or spend it as clean money, and nothing in
the recipe or the rest of the custom layer converts it. `gtarp_laundering` is
the conversion: a hidden laundromat front takes `black_money`, skims a fee,
and returns **clean bank funds** — bounded by a daily ceiling, watched by an
internal heat model that can call the cops, and logged as an evidence trail.

## Commands

- **`/launder`** — at the front, wash dirty money. The server reads your real
  `black_money` balance and washes the smaller of {what you hold, the per-run
  cap, your remaining daily ceiling}, removing that many dollars and crediting
  the clean remainder (after the fee) to your **bank**. Per-character cooldown.
- **`/dirtymoney`** — read-only: how much dirty money you're holding, how much
  you can still wash today, and the current fee.

## What makes it 1-of-1 (and not a dupe)

- **It's the only thing that launders.** Dup-gated against the real deployed
  recipe tree and every `gtarp_*` resource: nothing converts `black_money` to
  clean money anywhere.
- **Strictly separate from `gtarp_counterfeit`.** Counterfeit's
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
  and cap are the guard (same pattern as `gtarp_chopshop`/`gunrunning`).

## Heat & evidence

Washing warms the front's heat (server-only accumulator, decays every sweep).
A single run at/above `Config.Heat.BigRunAlways` always trips a **native
police alert** (`police:server:policeAlert`, rendered by qbx_police); above
`AlertThreshold` a run trips it on a heat-scaled roll. A tripped run also opens
or appends a **`gtarp_evidence` v2 case** (via the frozen
`EnsureCase`/`AppendEntry`/`LinkSuspect` exports — never its tables directly),
bucketed to a 5-minute window so a burst shares one case. Launder small and
slow to stay quiet; dump a whole bank haul at once and dispatch hears about it.

## Data

`gtarp_laundering_runs` (`sql/0033_laundering.sql`) — one row per wash:
citizenid, dirty_in, clean_out, fee_bps, flagged, evidence_case_id, created_at.
Export `GetSummary()` returns `{ totalRuns, totalDirtyWashed, flaggedRuns }`.

## Tuning (`shared/config.lua`)

`Config.Cut` (fee), `MinPerRun`/`MaxPerRun`/`DailyCap`, `CooldownSec`,
`Config.Heat.*`, and `Config.Front.coords` (a Tier-3 Los Santos placeholder —
verify/retune the laundromat spot in-game).
