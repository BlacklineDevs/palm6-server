# gtarp_legal — rap sheets + expungement petitions

The civilian counterweight to the police paperwork stack. Bookings,
citations and warrants now follow a citizen around — this resource is
how they see it and how they claw their way back clean.

## Player surface

- `/record` — your rap sheet: unsealed bookings (with case links), open
  citations and total owed, active-warrant flag. An **on-duty lawyer**
  can pull a client's record: `/record [citizenid]` — the first real
  mechanic behind the recipe's defined-but-inert `lawyer` job (the
  recipe's `/paylawyer` finally has work to pay for).
- `/expunge [booking#]` — at the Rockford Hills courthouse, $2500
  non-refundable filing fee (charged to the filer — lawyers can file
  for clients). Eligibility: booking older than 7 days, subject has no
  active warrant and no open citations. The court rules in ~10 minutes.
  Petitions land on the police Discord feed — cops get to notice.
- Granted → the booking is **sealed**: it stays in the police desk
  totals but leaves the rap-sheet surface. Evidence case entries that
  referenced the arrest are the case file, not the rap sheet — they
  stay.

## The trap that makes it a story

Eligibility is checked at filing AND re-checked at ruling. Pick up a
warrant or a fresh citation while your petition is before the court and
it's **denied — court costs kept**. Behave for ten minutes.

## Design notes

- **Server-only** — no client script; courthouse check is a server-side
  position read; fee comes from the filer's server-read bank.
- Sibling data access is exports-only: `gtarp_mdt` `GetBookingsFor` /
  `GetBooking` / `HasActiveWarrant` / `SealBooking` (all additive, added
  for this resource), `gtarp_citations` `GetOpenFor`. This resource
  never touches those tables.
- Ruling marks the petition BEFORE sealing — a crash can't double-rule;
  a granted-but-unsealed row is visible and fixable.
- Soft dependencies: `gtarp_citations` missing → citation gate skipped;
  `gtarp_discord` missing → no feed post; `gtarp_mdt` missing → both
  commands report records offline.
- Exports: `GetSummary() -> { processing, granted }`.

## Dup-gate (2026-07-07)

No record/rap-sheet/expungement/petition system anywhere in deployed
`[qbx]`/`[ox]`/`[standalone]`. The `lawyer` and `judge` jobs exist in
`qbx_core/shared/jobs.lua` with zero mechanics; qbx_police's only
lawyer touchpoint is `/paylawyer` (an on-the-spot payment command) —
complementary, untouched.
