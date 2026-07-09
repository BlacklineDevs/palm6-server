# gtarp_economy

The operator's-eye view of the crime economy — the "ship the meter" rule at the
ecosystem level.

Every crime resource on this server exposes a `GetSummary()` export.
`gtarp_economy` aggregates them into one **staff scoreboard** so you can see,
live, whether the dirty-money economy is healthy: how much dirty money each
source has minted, how much the laundromat has washed and police have
forfeited, and the rough net still in circulation. It's how you actually
balance the economy — by watching real numbers, not guessing.

## Command

- **`/economy`** — ACE-restricted (`command.economy`, granted to `group.admin`
  + `group.mod` in `custom.cfg`, same as `gtarp_perf`'s `/diag`). Prints the
  scoreboard to the invoker (console or chat).

Example readout:

```
=== Horizon crime economy ===
laundering:  $412,000 washed clean  (58 run(s), 6 flagged)
seizure:     $84,500 forfeited by police  (19 seizure(s))
numbers:     140 draw(s), $220,000 staked (clean), $96,000 paid (dirty)
protection:  310 shakedown(s), $410,000 collected (dirty)
loanshark:   4 open / 11 defaulted, $180,000 lent (dirty)
smuggling:   72 delivered, $470,000 paid (dirty), 3 active
-- dirty minted ~$1,156,000 | removed (laundered+forfeited) ~$496,500 | net in play ~$659,500
   (net excludes recipe bank-robbery minting + black-market spend)
```

## What it is (and isn't)

- **Read-only.** It calls only sibling `GetSummary()` exports — no DB, no
  writes, **no new table**. It can't affect the economy, only report it.
- **Soft everything.** A crime resource that's stopped just shows `offline`; the
  scoreboard never errors.
- **Not a tuning knob.** Each resource's numbers are tuned in its own config;
  this is the scoreboard that tells you which ones to tune.
- The **net-in-play** figure is directional, not exact — it sums the dirty money
  our resources mint (numbers winnings, protection, loanshark principal,
  smuggling) minus what leaves circulation (laundered + forfeited). It does not
  see recipe `qbx_bankrobbery` minting or `black_money` spent at BlackMarketArms,
  so treat it as a lower-bound trend line, not a ledger.

## Exports

- `GetSummary()` → `{ dirtyMinted, dirtyRemoved, netInPlay }` (for a future web
  dashboard / devtest).
- `RunEconomy()` → the formatted scoreboard lines.
