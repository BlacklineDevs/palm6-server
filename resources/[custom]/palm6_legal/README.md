# palm6_legal — rap sheets + expungement petitions

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

## Sentencing review — `/sentence` (v0.2.0, SHIPS OFF)

`Config.Sentencing.Enabled = false`. With the flag off the command is not
registered at all and nothing in this section exists.

`/sentence [citizenid] [booking#] [code...]` prints a recommended sentence and
fine for a booking **and the arithmetic that produced it**. Charge codes come
from the catalogue in `palm6_mdt/shared/config.lua` (`/charges` lists them).

Gate (server-side, all branches **fail closed**), two tiers:

- **court**: the server console, or the `palm6.judge` ace. May pass `*` in
  place of a citizenid, and is the only tier that can read a **sealed
  (expunged)** booking. See "Handing off to qbx_police" below for the ace
  grant, which cannot be added from this repo.
- **job**: an on-duty judge / lawyer / police officer. Must name the subject.

**You have to already know whose booking it is.** Booking ids are small
consecutive integers, and the lawyer job is one any player can take, so
`/sentence 1`, `/sentence 2`, … used to walk out every name, citizenid and
charge sheet on the box at a lookup every 5 seconds. The citizenid is now a
required argument and is checked against the record. Every other read surface
in the stack already worked this way (`/record` via `resolveSubject`,
`palm6_rapsheet`'s `/priors`, `palm6_mdt`'s `/warrant` and `/book`).

**A sealed booking is invisible below the court tier**, and its refusal is
worded *identically* to "no booking with that number for that citizen", and so
is a citizenid mismatch. That is deliberate: a distinct "that record is sealed"
would confirm an expungement, and a distinct "that belongs to someone else"
would confirm the booking exists. A player who paid the court fee and won their
petition does not get it read back out.

**Bounded.** Beyond the 5s cooldown there is a rolling budget
(`MaxPerWindow = 8` per `WindowSec = 300`, console exempt). It is spent on every
well-formed record request, hit or miss, so aiming at ids that do not exist
costs the same as a real lookup; usage mistakes and hard denials are free.

**Omitting the codes does not produce a number.** The booking text is still
scanned (literal whole-token matching, never fuzzy) but the hits are printed as
*suggestions* and nothing is priced. The scan structurally cannot see a
compound code, and on this catalogue the compound codes are the severe ones, so
a number derived from it is biased low by construction. The full worked example
is in `palm6_mdt/README.md`.

It is **read-only**. It moves no money, alters no record, jails nobody, and
never notifies the subject — output goes to the caller only, which is what
stops it being a way to spam somebody with fake court notices. Successful
lookups are written to the house staff audit sink (`palm6_staff:Log`), soft, so
a missing sink never fails the command, and de-duplicated per source per window
so a read-only command cannot become a Discord webhook loop.

## Handing off to qbx_police

**This repo cannot jail anyone, and nothing above pretends otherwise.**

`qbx_police` owns the physical side — `/cuff`, `/jail`, the cell, the timer,
the release. It is not in this tree; it lives on the game box. What this repo
owns is the paperwork either side of that: the charge catalogue, the
deterministic recommendation, and the review step. The recommendation is
advice printed to a human, who then types the qbx command themselves.

To close the loop on the box, three things have to exist that do not exist
today:

1. **The ace grant.** `add_ace group.admin palm6.judge allow` (or a dedicated
   judge group) in `custom.cfg`. `custom.cfg` is not in this repo. Until then
   the ace branch never passes and access falls to the job branches.
2. **A unit mapping.** `Config.Charges.SentenceUnit` is a display *label*.
   Nothing in this repo converts the number into game time, because nothing in
   this repo knows what unit `qbx_police`'s jail command takes. Whoever wires
   this must read that command's signature on the box first. **Do not assume
   the recommendation is already in the right unit.**
3. **A deliberate decision about who applies it.** The recommendation is
   advisory on purpose. Auto-jailing off a calculated number would mean a bug
   in the arithmetic becomes a bug in somebody's play session with no human in
   the loop. If that is ever wanted, it belongs in a resource that owns the
   physical side, reading `exports.palm6_mdt:RecommendForBooking`.

The exports that handoff would consume are additive:
`palm6_mdt` `GetChargeCatalogue()`, `CalculateSentence(codes, priors)`,
`RecommendForBooking(bookingId, codes, opts)`. All three return `nil` while the
catalogue flag is off. A handoff resource reading `RecommendForBooking` gets
`nil` for a sealed booking unless it passes `opts.allowSealed`. Do not pass it
unless the caller is an operator/admin surface, or the handoff re-opens
expunged records.

## Design notes

- **Server-only** — no client script; courthouse check is a server-side
  position read; fee comes from the filer's server-read bank.
- Sibling data access is exports-only: `palm6_mdt` `GetBookingsFor` /
  `GetBooking` / `HasActiveWarrant` / `SealBooking` (all additive, added
  for this resource), `palm6_citations` `GetOpenFor`. This resource
  never touches those tables.
- Ruling marks the petition BEFORE sealing — a crash can't double-rule;
  a granted-but-unsealed row is visible and fixable.
- Soft dependencies: `palm6_citations` missing → citation gate skipped;
  `palm6_discord` missing → no feed post; `palm6_mdt` missing → both
  commands report records offline.
- Exports: `GetSummary() -> { processing, granted }`, and — only while
  sentencing is on — `GetSentenceCommand() -> string`, which `palm6_mdt`'s
  `/charges` footer reads so it never advertises a command that is off or
  renamed.
- Sentencing adds no table and no migration. The recommendation is a pure
  function of (charge codes, priors), so storing it would be storing a
  derivation; auditability comes from `palm6_staff:Log` instead, which needs
  no schema. `sql/` is also outside this resource's ownership.

## Dup-gate (2026-07-07)

No record/rap-sheet/expungement/petition system anywhere in deployed
`[qbx]`/`[ox]`/`[standalone]`. The `lawyer` and `judge` jobs exist in
`qbx_core/shared/jobs.lua` with zero mechanics; qbx_police's only
lawyer touchpoint is `/paylawyer` (an on-the-spot payment command) —
complementary, untouched.
