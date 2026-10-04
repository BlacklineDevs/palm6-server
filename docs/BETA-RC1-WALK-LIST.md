# Palm6 Beta RC1 Walk List

**Date:** 2026-10-04
**For:** David plus 2 to 4 testers
**Companion to:** `docs/BETA-RC1-STATUS.md`

Run this top to bottom. Every step says exactly what to type and exactly what
counts as a pass. You should not need to read any other document.

**Before you start, enable the tools.** `custom.cfg` must grant
`command.p6tp`, `command.coords` and `command.anchors` to your group, or the
teleports below will silently do nothing. `palm6_anchors` prints the missing
grant in red at boot.

**Two commands do all the work:**
- `/p6tp <name>` or `/p6tp <x> <y> <z>` teleports you.
- `/coords` prints a paste-ready coordinate line for wherever you are standing.

**When something is wrong, do not guess a fix.** Stand where it should be, run
`/coords`, and paste that line into this document under the step. No coordinate
in this project may be invented. `/anchors` (or F7) lists all ~102 anchors and
teleports to any of them, which is how you reach anything without a `/p6tp` name.

---

## 0. The starter path (do this first, it is the beta gate)

This is the single most important section. A new player who fails here has no
reason to come back.

1. Join with an account that has **never** played. Not an alt that already has a
   `palm6_onboarding` row.
2. Loadscreen appears, music plays, no missing images, no console errors.
   - The animated background and animated logo are intentionally blank. Static
     poster plus 19 rotating plates is correct, not a fault.
3. Allowlist admits you. Denial message, if any, is useful and leaks nothing.
4. Character select appears. Create a character. The appearance editor opens.
5. You spawn. The rules dialog appears and you accept it.
6. **Starter cash lands: $1,500 to bank.** Check your bank, not your cash.
7. **Starter vehicle.** Read the server console as you accept. You will see one
   of these, and each means something different:

   | Console line | Meaning | What to do |
   |---|---|---|
   | `starter garage "motelgarage" resolved in qbx_garages` | Correct. | Go to step 8. |
   | `starter garage "..." does NOT exist in qbx_garages` | The name is wrong. **No car was created and no grant was burned.** | Step 7a. |
   | `starter garage "..." could NOT be verified` | `qbx_garages` exposes no readable list. Grant is deferred, nothing burned. | Step 7a. |
   | `starter_vehicle_granted column MISSING` | `sql/0045_onboarding_starter_grants.sql` was never applied. No car can ever be granted. | Apply that migration, then relog. |

   **7a. Find the real garage name.** Walk to the public garage new players
   should use. Confirm the name qbx uses for it. Then set it in `server.cfg`:

   ```
   set palm6:onboarding_garage "<real garage name>"
   ```

   You do **not** need a code deploy for this. Relog and the deferred grant lands
   automatically on your next character load. That retry is the whole point of the
   fix: a deferral is recoverable, an unreachable car was not.

8. Go to that garage and **retrieve the car**. This is the step that was broken:
   before this release, a wrong garage name still reported success, still said
   "Your starter vehicle is parked at the motel garage", and left the car
   permanently unreachable with the grant used up.
   - **PASS:** the blista is listed in that garage and you can take it out.
   - **FAIL:** it is not there. Record the garage name you checked.
9. `/help` lists commands and does not error.
10. Earn money legally once (any starter job). Confirm the payout lands.
11. **Disconnect and reconnect.** Confirm: cash is still there, the car is still
    in the garage, the rules dialog does **not** reappear, and you are **not**
    granted a second $1,500 or a second car.
12. Repeat step 11 but disconnect *during* the job payout. Confirm you are paid
    exactly once, not zero times and not twice.

---

## 1. Priority coordinates (P0, these strand players)

For each: teleport, then check three things. **On solid ground** (not floating,
not buried, not clipped into a wall), **reachable** (a player can physically walk
or drive to it), and **sensible** (it is the kind of place the feature claims).

### 1a. Prison yard, 3 nodes

All three are round to the nearest 10 and the tool's own note reads "round
placeholder, verify!". A jailed player who cannot reach commissary or labour has
no loop at all, just a cell.

| Step | Command | Should be |
|---|---|---|
| 1 | `/p6tp jail_labor` | The prison work area |
| 2 | `/p6tp jail_shop` | The commissary. Note: this is exactly 20 m due west of labour, which looks typed rather than walked |
| 3 | `/p6tp jail_bail` | The bail/release point |

Then actually get arrested and confirm you can reach all three from inside.

### 1b. Smuggling, 7 nodes

All placeholder, all hand-round. Two are sea drops at `z = 1.0`. An air drop at
`z = 41` over the wrong ground is a crash, not a cosmetic bug. No `/p6tp` names
exist, so use raw coordinates or `/anchors` keys `smuggling_pickup` and
`smuggling_dropoff_*`.

| Step | Command | Note |
|---|---|---|
| 1 | `/p6tp -119.0 -2489.0 6.0` | Pickup, Elysian Island docks |
| 2 | `/p6tp 1470 3260 40` | Round on all three axes. Most suspect node in the repo |
| 3 | `/p6tp -540 5320 74` | |
| 4 | `/p6tp 3860 4460 1` | Sea drop, confirm it is water |
| 5 | `/p6tp -1600 5260 1` | Sea drop, confirm it is water |
| 6 | `/p6tp 2130 4790 41` | Confirm ground height |
| 7 | `/p6tp 1720 3290 41` | Confirm ground height |

Then run one full smuggling job: start it, capture the destination, complete it,
and **confirm the payout lands exactly once.** Then run a second job and
disconnect before completion; reconnect and confirm there is **no** duplicate
payout and no stuck mission state.

### 1c. Market, 2 nodes

Both explicitly "Tier-3 placeholder, VERIFY IN-GAME".

| Step | Command | Should be |
|---|---|---|
| 1 | `/p6tp -40.00 -2530.00 6.00` | The exchange. Anchor key `market_exchange` |
| 2 | `/p6tp 1075.00 -2005.00 32.00` | The refinery. Anchor key `market_refine_station`. Note it is 34.7 m from the `palm6_grind` Ore Buyer, so one of the two may be the wrong spot |

### 1d. Drugs, the flagged nodes

| Step | Command | Note |
|---|---|---|
| 1 | `/p6tp drug_corner` | **Known wall-clip reported.** Confirm or clear it |
| 2 | `/p6tp drug_buyer` | |
| 3 | `/p6tp 1391.2 3605.5 38.9` | The mixing trailer sits 0.3 m from an `ox_inventory` garden-supply shop counter. Both are marked unverified. Decide which moves |

---

## 2. The duplicate clusters (P1, one walk settles many)

These are copy-paste groups. Standing in one place answers several files at once.

### 2a. The Legion Square cluster, 9 sites across 7 resources

`/p6tp 195.17 -933.77 30.69`

The player spawn, the `legion_square` turf center, the `palm6_clout` danger zone,
the `palm6_tips` payphone and a `palm6_brain` NPC scene are **all literally this
same square metre**. Walk it once and decide whether that is intended or whether
some of them should move apart. Anchor key `tips_payphone_legion`.

### 2b. The `vinewood` zone error (highest-confidence real bug)

The zone center keyed `vinewood` is at `-1222.10 -906.90 12.33`, which is Little
Seoul / Vespucci. The business declaring `zone = 'vinewood'` is "Vinewood Pawn"
at `373.87 325.90 103.57`. Those are about **2,017 m apart** against a 200 m
radius.

| Step | Command |
|---|---|
| 1 | `/p6tp -1222.10 -906.90 12.33` then confirm: this is not Vinewood |
| 2 | `/p6tp 373.87 325.90 103.57` then confirm: this is Downtown Vinewood |

The server now prints this mismatch at boot, so you will see it flagged. **The
decision is yours and it is a design call, not a typo fix:** `palm6_turf` owns
zone centers, so moving this one relocates a turf capture point. Either move the
zone center to Vinewood, or re-key the zone to the neighbourhood it is actually
in, or reassign the business. Do not let the code pick.

Today the consequence is limited (owned-business extortion is off), so this is
not a beta blocker. It becomes one the moment that flips.

### 2c. The 4-value cluster

`/p6tp 1163.87 -323.86 69.21`

Six sites use **four slightly different values** for what is meant to be one
spot: the Mirror Park Deli, the `mirror_park` turf center, a clout zone, a tips
location and an `ox_inventory` shop. Converge them on one captured value.

### 2d. Shared points worth a decision

| Command | Two things claim this point |
|---|---|
| `/p6tp 25.70 -1347.30 29.5` | The lottery kiosk and the Legion Square Liquor shakedown target |
| `/p6tp 434.0 -983.0 30.7` | The evidence locker and the counterfeit serial terminal. **The anchors README names this as the cause of a past incident:** pressing E here got a player kicked, because it is actually qbx_police's duty point, not the evidence room. Still uncorrected |
| `/p6tp -815.09 -1078.97 11.13` | The insurance office and the insurance agent desk, identical |

---

## 3. Multiplayer pass (minimum 4 testers)

Run these together, not as four solo sessions. Cross-player interaction is the
part no automated gate touches.

**Roles:** one civilian, one criminal, one police, one EMS.

1. **Police and criminal.** Criminal commits a crime that raises heat. Police
   sees the dispatch. Confirm `/mdt` shows the case, `/heat` reflects it, and the
   wanted state is consistent on both screens.
2. **Arrest to booking.** Full chain: arrest, booking, rapsheet, citation or
   charge, release or jail. Then check section 1a from inside the cell.
3. **EMS.** Down the criminal. EMS revives. Confirm the EMS bill exists and the
   amounts agree on both sides.
4. **Evidence.** Fire a weapon, let police collect a casing, confirm the serial
   cross-reference appears. Check whether evidence renders as readable text and
   not raw JSON.
5. **Two players, one payout.** Both attempt the same job or robbery
   simultaneously. **Nobody should be paid twice and the total paid must not
   exceed one payout.**
6. **Radial menu.** Confirm PageUp opens exactly one menu and that pressing Esc
   releases mouse control. Two radial menus were previously able to run at once,
   with one taking focus and the other releasing it.
7. **Reconnect under load.** With all four connected, have one hard-crash out and
   rejoin. Confirm no duplicated vehicle, money or inventory.

---

## 4. Record results here

Copy this block per session.

```
Date / testers:
Server build (git sha on the box):

Section 0 starter path:        PASS / FAIL  notes:
  Console garage line seen:
  Garage actually used:
Section 1a prison (3):         PASS / FAIL  bad coords:
Section 1b smuggling (7):      PASS / FAIL  bad coords:
Section 1c market (2):         PASS / FAIL  bad coords:
Section 1d drugs:              PASS / FAIL  wall-clip confirmed? Y/N
Section 2a legion cluster:     decision:
Section 2b vinewood:           decision:
Section 2c 4-value cluster:    captured value:
Section 3 multiplayer:         PASS / FAIL  notes:

Any double payout observed?    Y / N   <- if Y, stop the beta and report
Any player stranded?           Y / N
```

**Two findings end the test immediately and get reported before anything else:**
a payout that lands twice, and a player who cannot progress. Everything else can
wait for the next pass.
