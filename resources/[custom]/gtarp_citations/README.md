# gtarp_citations — recorded fines with due dates and warrant escalation

Debt with memory. A citation is a ledger row on the **citizen** —
online or offline — payable later at city hall, and it escalates to a
`gtarp_mdt` warrant when it goes overdue. Non-payment is a story hook,
not a free pass.

## Player surface

- `/cite [citizenid] [amount] [reason]` — police + `mdt_tablet`. Writes
  the citation against server-validated citizen records ($25-5000,
  72h due window); the cited player is told immediately if online.
- `/fines` — anyone; your own open citations with time left and total
  owed. Overdue-escalated rows read `OVERDUE — WARRANT OUT`.
- `/payfine [#]` — at the city hall desk (server-checked position),
  from bank. Settles the row and routes the money to the police
  society account (same destination as the recipe's instant fines).
  Paying does NOT auto-lift an already-issued warrant — resolving that
  with the police is deliberate RP.

## Escalation

A sweep (every 5 min) flips unpaid-past-due rows to `escalated` and
issues a warrant via `gtarp_mdt`'s additive `IssueWarrant` export
("City Hall Collections"). The row is marked BEFORE the warrant issues
so a crash can't spam warrants; if the citizen already has an active
warrant the citation still escalates and the debt stays open. With
`gtarp_mdt` missing, citations simply stay overdue — nothing is
forgiven silently.

## Design notes

- **Server-only** — no client script. `/cite` acts on citizen records,
  `/payfine` on the payer's own server-read position and bank balance.
- Settlement charges the bank FIRST, then marks paid — a charge with a
  failed ledger write is visible (money log + open row) and fixable; a
  double-settle isn't.
- Soft dependencies: `gtarp_mdt` (escalation), `Renewed-Banking`
  (police account credit) — both pcall-guarded, absence never blocks
  the ledger.
- Exports: `GetSummary() -> { open, settled }`.

## Dup-gate (2026-07-07)

The recipe's `police:server:BillPlayer` (client dialog → instant bank
debit, target must be online AND physically nearby) and radar speed
fines (`police:server:Radar`) both **record nothing** — if
`RemoveMoney` fails the event returns and the debt evaporates. Read
directly in `qbx_police/server/main.lua` (lines ~163, ~291). No
citation/ledger/due-date/escalation system exists anywhere in deployed
`[qbx]`/`[ox]`/`[standalone]`. Both systems coexist: instant billing
stays for on-the-spot RP, citations are the paper trail.
