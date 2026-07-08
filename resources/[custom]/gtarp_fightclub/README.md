# gtarp_fightclub — the underground ring

Two citizens queue at the ring, get auto-paired, and the crowd bets cash on
who walks out. Bare knuckles only — the fight is unarmed, server-monitored,
and ends in a real knockout, a forfeit, or a timeout draw. Payouts are a
**parimutuel pool**: every spectator wager on both fighters is pooled, the
house skims a rake, the winner gets a purse cut straight off the top, and
whatever's left splits proportionally among everyone who bet on the winner.

## Player surface

All chat commands (server-only resource, no NUI/client script):

- `/fcjoin` — queue up at the ring (Elysian Island backlot). The instant a
  second citizen queues, the two of you are paired into a match — queueing
  IS the consent, same as `gtarp_bounty`'s `/postbounty` needs no separate
  accept step. Auto-dropped from the queue after 5 minutes with no
  opponent.
- `/fcleave` — leave the queue before you're paired.
- `/fcbet [match #] [1 or 2] [$50-5000]` — spectator wager on fighter 1 or
  2. Fighters cannot bet on their own match. One bet per citizen per match.
- `/fcmatches` — the open board: betting windows (with time left) and live
  fights.

Betting runs for 60 seconds after a match is created. When it closes the
fight goes live: both fighters must stay inside the ring, stay unarmed, and
the first one at or below 110 HP (GTA's 100-200 ped scale — solidly
knocked out, one notch past `gtarp_bounty`'s 120 "beaten down" capture
bar) loses. Leaving the ring, drawing any weapon, or disconnecting is an
instant forfeit. No knockout inside 180 seconds is a draw.

## Why this can't be gamed from the client

- **Every fight-ending condition is server-derived.** Health, position, and
  current weapon are all read straight off the live synced peds
  (`GetEntityHealth`, `GetEntityCoords`, `GetSelectedPedWeapon` — same
  technique `gtarp_bounty`'s `/capture` uses for its proximity+health
  check). A modified client claiming "I won" or "I'm unarmed" changes
  nothing; the sweep thread only ever reads the real ped state.
- **Betting is a database-enforced atomic claim, not a Lua check.** The bet
  insert is `INSERT ... SELECT ... FROM gtarp_fightclub_matches WHERE id=?
  AND status='betting'` — the row only lands if the match was still taking
  bets at the exact instant of insert, no read-then-write gap for a closing
  window to slip through. The `UNIQUE(match_id, citizenid)` key on
  `gtarp_fightclub_bets` is what actually stops a citizen double-betting a
  match: it's a schema constraint, not an in-memory table, so two racing
  `/fcbet` commands from the same player can't both land the way
  `gtarp_pumpcoin`'s ticker-uniqueness bug let two racing mints both pass a
  stale in-memory check before either insert had landed. Here the second
  insert just fails the constraint — caught and reported as "you already
  have a bet," no double charge possible.
- **Resolution is a guarded `UPDATE ... WHERE status='live'`** before any
  money moves, so a match can only be paid out once even if the sweep
  logic somehow evaluated it twice in the same tick.
- **Fighters can't bet on themselves** — checked against both fighters'
  citizenids at bet time. (A fighter colluding with an *alt* to bet against
  themselves and intentionally throw the fight is an accepted economic/
  social risk in any wagering system, same category `gtarp_bounty`
  documents for escrow self-dealing — not a security bug.)
- **Money only moves after the claim is safe.** A bet's row is inserted
  before the bank charge; if the charge fails the row is deleted
  immediately so no phantom, unpaid bet ever pollutes the pool math.

## Design notes

- Bridge-pattern (see `docs/GTA6-READINESS.md`): all logic is in
  `server/`; every qbx/native call lives in `bridge/sv_framework.lua`. No
  client script at all — matching `gtarp_citations`/`gtarp_mdt`/
  `gtarp_bounty`'s "nothing for a modified client to abuse" precedent.
- Payouts credit by citizenid, online or offline (the
  `gtarp_bounty`/`gtarp_pumpcoin`/`gtarp_insurance` pattern), so a bettor
  who logs off between placing a wager and the match resolving still gets
  paid.
- Parimutuel math: `rake = pool * RakePct`, `purse = pool * WinnerPursePct`
  paid straight to the winning fighter, and the remainder splits among
  winning bettors proportional to their stake, rounded down per bettor.
  Losing-side bets and rounding remainder are the sink — the same "buys
  round up, payouts round down" honesty `gtarp_pumpcoin` documents. If
  nobody bet on the winning side, that remainder simply isn't paid to
  anyone (no winning bettors to pay).
- A mutual forfeit (both fighters disqualified in the same sweep tick, e.g.
  both leave the ring) or a 180s timeout with no knockout is a full refund
  to every bettor — no rake, no purse.
- The in-memory queue does not survive a resource/server restart (nothing
  is written to the DB until a match exists) — a restart mid-queue just
  means both citizens need to `/fcjoin` again. Open matches themselves
  (`betting`/`live` rows) DO survive a restart; the sweep picks them back
  up on the next tick.
- Exports: `GetSummary() -> { openMatches, queued }`.
- `Config.Ring.coords` is a Tier-3 placeholder (see
  `docs/GTA6-READINESS.md` §2) — retune once a real MLO/prop is picked.

## Dup-gate (2026-07-08)

Checked against every documented recipe resource name collected across
this repo's own dup-gate paper trail (`docs/BUILD-ROADMAP.md`,
`docs/GTA6-READINESS.md`, and the "why this doesn't duplicate X" sections
of `gtarp_bounty`, `gtarp_counterfeit`, `gtarp_robbery`, `gtarp_turf`,
`gtarp_legal`, `gtarp_mdt`, `gtarp_witnesses`, `gtarp_pumpcoin` — the
recipe itself isn't vendored in this git repo, so those README trails are
the only queryable record of its resource surface): `qbx_police`,
`qbx_ambulancejob`, `qbx_management`, `qbx_pawnshop`, `qbx_scrapyard`,
`qbx_customs`, `qbx_streetraces`, `qbx_lapraces`, `qbx_drugs`, `qbx_weed`,
`qbx_houserobbery`, `qbx_truckrobbery`, `qbx_storerobbery`,
`qbx_bankrobbery`, `qbx_garages`, `qbx_vehicles`, `qbx_properties`,
`qbx_smallresources`, `qbx_truckerjob`, `qbx_taxi`, `qbx_garbagejob`. None
of them are a combat mechanic, a wagering/gambling system, or a spectator
economy of any kind — `qbx_streetraces`/`qbx_lapraces` are vehicle races
with no documented betting layer, and `qbx_police` has cuff/jail/MDT
plumbing but (per `gtarp_bounty`'s own dup-gate) "no reward-for-capture
loop," let alone a PvP wagering one.

`grep -riE "\bbet\b|wager|duel|fight.?club|gambl|casino"` across every
`docs/*.md` and every `resources/[custom]/gtarp_*/README.md` in this repo
returns nothing before this resource's own files — no existing custom
resource does spectator wagering, consensual PvP dueling, or any kind of
gambling/casino mechanic. The two closest neighbors are genuinely
different domains: `gtarp_bounty` is asymmetric hunt-and-capture with
escrowed contracts on a specific citizen (not a scheduled, consensual,
two-sided duel with pool betting), and `gtarp_turf` is zone capture
between gangs (not player-vs-player combat at all). `gtarp_pumpcoin` is
the closest *mechanical* cousin — both are server-side pooled-economy
games with a house rake — but it's asset speculation on a bonding curve,
not wagering on a live combat outcome, and shares no code or tables with
this resource.

This is also **not** a repeat of the two documented near-misses
(`civilian_runs`, the early housing system) that got reverted for
skimming override configs instead of reading real recipe surface: this
dup-gate is against the *feature category* (combat wagering / gambling),
which the aggregated evidence above shows has zero footprint anywhere in
the recipe's documented surface, not just an absence of a
similarly-named config file.

## Install

1. `ensure gtarp_fightclub` in `custom.cfg` (after `qbx_core`, `ox_lib`,
   `oxmysql`).
2. Apply `sql/0028_fightclub.sql` — creates `gtarp_fightclub_matches`,
   `gtarp_fightclub_bets`.
3. Tune `shared/config.lua` (at minimum, check `Config.Ring.coords` fits
   your map edits before launch).

No external APIs, no keys, no custom assets — config coordinates only.

## Deferred to v2

- No spectator UI/board blip — matches are chat-command only for now.
- No fighter entry fee / ranked ladder — pure open queue.
- No admin cancel command for a stuck match (a mutual forfeit or timeout
  always resolves it within `Config.Fight.MaxDurationSec`, so nothing can
  hang forever, but there's no manual override yet).
- Single global ring; no per-location rings.
