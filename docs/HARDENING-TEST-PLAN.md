# Hardening branch — in-game test plan

Covers `feat/palm6-ultracode-hardening`. Everything below was verified headlessly
(530/530 Lua parse-clean, 21/21 NUI smokes, zero authored coordinates) but headless
checks cannot prove engine behaviour, MySQL semantics, or anything involving a second
player. This is the list of things only a live box can settle.

Work top to bottom. Sections 1 and 2 gate everything else: if the server does not boot
clean, stop and read the console rather than continuing down the list.

⚠️ **Deploying restarts FXServer and kicks everyone online.** Pick the window.
⚠️ **No admin should be mid-grab or mid-carry in the map editor when this deploy lands.**
The fix that protects grabbed props is not in the *running* build, so the deploy carrying
it is the last one that can still destroy them.

---

## 1. Boot — do this first, it gates the rest

| # | Do | Expect | Proves |
|---|---|---|---|
| 1.1 | Watch the console through a **full server restart** (not `restart <resource>`) | `[palm6_eventguard] guarding N events` and **no** red `RESTARTED after consumers` block | Guard-first ordering holds on a clean boot. If the red block appears, the custom.cfg-execs-last assumption is wrong and the eventguard budgets are inert |
| 1.2 | Read the boot banners for courier, evidence, mdt, flashdrop, insurance, counterfeit, numbers, seizure | `schema OK`, no red `MISSING`, no `INERT` line | Self-create DDL is correct. A red line here means the DDL diverged from `sql/` |
| 1.3 | `/diag` | `schema: OK` | The always-on schema check resolves all ~93 tables on the real box |
| 1.4 | Scan console for Lua errors from any `palm6_*` | none | 12 commits of edits did not break a boot path |

**If 1.2 or 1.3 reports MISSING**, note exactly which table and stop. That means a table
exists in the map but not on the box, which is information worth having before anything else.

---

## 2. The 911 seam — three separate changes landed on one event

This is the highest-risk interaction in the branch: eventguard, MDT provenance, and the
witnesses heat hook all changed behaviour on `police:server:policeAlert`.

| # | Do | Expect | Proves |
|---|---|---|---|
| 2.1 | Trigger a **flagged drug sale** (server-side producer). Check `/myheat` before and after | Heat moves by exactly **3** (`drug_sale`), **not 18** | The suppression latch works: an in-repo emitter that scores its own heat is not charged again by the witnesses bus. **If it moves 18, the latch is inverted — report it** |
| 2.2 | Same event, check `/calls` | Row present, **no** `(unverified)` suffix | Server-raised alerts are recognised as server-raised. This is the `nil / <=0 / 65535` predicate holding on the real runtime |
| 2.3 | Do a **qbx store robbery** end to end (client-side producer) | Officers pinged · `/calls` row **with** `(unverified)` · witness markers appear · `/heat` shows robber **+15** | All four consumers still work for the crimes that matter most. These producers are out-of-repo, so this is the one path nothing in the repo could verify |
| 2.4 | Optional stress: script ~45 client `policeAlert` raises in 60s | First ~40 land · **no kick** · no `event_violations` row · `/calls` stops gaining past the budget | The flood exploit is bounded and the drop-without-kick class works. A kick here is a bug |

---

## 3. Police loop — previously unusable end to end

| # | Do | Expect |
|---|---|---|
| 3.1 | Go on duty, stand near a player, `/id` | Name, citizenid, active-warrant flag |
| 3.2 | Paste that **server id** into `/cite`, `/warrant`, `/book` | All three accept it |
| 3.3 | Use a raw **citizenid** on the same three | Still works (backward compatibility) |
| 3.4 | `/runplate <plate>` on a stolen vehicle | Reports stolen + owner |
| 3.5 | `/book` someone, then check the staff audit log | Booking recorded |
| 3.6 | `/pdduty` | Works (station gate ships OFF, so location should not matter) |
| 3.7 | On the live box, confirm no other resource stole `/id` | `/id` is ours. ~157 resources start after palm6_mdt and a later registration silently wins |

---

## 4. Map editor — the rank-1 critical fix

| # | Do | Expect |
|---|---|---|
| 4.1 | `/maplivegrab` several props, then **`restart palm6_mapeditor` while still carrying** | Console: `queued N/N abandoned grabbed prop(s)`. Props are back after the restart. **This is the fix that matters most — losing props here means it did not work** |
| 4.2 | Grab a ped from the Entities outliner, carry, drop with Enter | Ped lands where aimed |
| 4.3 | Grab a second entity while already carrying | Refused with a message, first entity not destroyed |
| 4.4 | Snapshot a map, edit it, Restore | Map swaps back. A pre-restore snapshot appears automatically |
| 4.5 | Rename a map, then Merge it into another | Props, lights **and** entities all follow. Merge refuses if it would exceed the per-map cap |
| 4.6 | `/mapexportlive <map>` and read the file | Lights present. Entities present after a rename. Load the `.ymap.xml` in CodeWalker |
| 4.7 | `/propui` → Entities → check the map chip bar | Chips match the prop-side map names (this is the only surface that reveals a drift) |

---

## 5. Boot-window refusals (3s after a resource restart)

| # | Do | Expect |
|---|---|---|
| 5.1 | `restart palm6_counterfeit`, immediately `/place` a printer and hit a fence | Clear refusal message, not a broken-looking resource |
| 5.2 | `restart palm6_numbers`, immediately place a bet | Same |
| 5.3 | `restart palm6_pumpcoin` with a **live paid billboard** | Billboard blip survives. **If it vanishes, the rehydrate fix failed** |

---

## 6. The three flags — all ship OFF, flip one at a time

Flip, restart the resource, test, decide. Do **not** flip more than one per test pass.

### 6.1 `palm6_mapeditor Config.LiveCull = true` — the sellability item
The reason to want it: a big map is currently 6000 permanent client objects for **every**
player, not just admins.
- Walk a large map. Watch for pop-in at the ~300 m ring (60 m hysteresis).
- Teleport somewhere dense and see whether 25 spawns/tick at 750 ms keeps up.
- `/maplivegrab` a prop near the ring boundary.
- ⚠️ **`/mapexportlive` on a large map requires this OFF.** Export reads rotation off the live
  entity, so a culled prop has no rotation to read. It refuses loudly rather than exporting
  flat, but that means export and culling are mutually exclusive on big maps. That tradeoff
  is the actual decision here.

### 6.2 `palm6_mapeditor Config.ScenePedScenarioUnfreeze = true`
- Place one ped per scenario family: stand (`GUARD_STAND`), sit (`SEAT_LEDGE`), sunbathe.
- Do they settle onto the surface, or sink through un-streamed custom floors?
- Can a player or vehicle shove them off post? That is the cost of unfreezing.

### 6.3 `palm6_brain Config.PoliceBus.Enabled = true`
- Commit a crime near an NPC that the AI notices.
- Does it reach `/calls`? Does it open a witness incident against the **named player**?
- ⚠️ Watch for a **double ping**: brain's own blip plus qbx_police's 911 notify for one crime.
- ⚠️ This is the flag most likely to feel wrong. It scores real players for what an NPC
  thought it saw. Judge it on whether that reads as fair.

---

## 7. Economy call — yours, not mine

`palm6_laundering Config.PlayerHeat` changed from a **flat 5/run** to **amount-proportional**
(`Base 1 + 0.5/$1000`, capped 15/run). A $500 wash now scores **1** where it scored 5; a
$25,000 wash scores **13**.

- Run a wash at both extremes and see whether the pressure curve feels right.
- Run one as a HOT launderer: `/dirtymoney` should quote the +10% skim honestly and
  `/launder` should charge it.
- Revert in one line if you dislike it: set `PerThousand = 0` and it returns to the flat model.

This rode in on a hardening batch, which is not where a balance change belongs. Flagging it
rather than burying it.

---

## 8. Blocked on you — capture sessions, not tests

| Item | What to do | Why it is blocked |
|---|---|---|
| `palm6_pd_life Config.Rooms` is **empty** | Stand in MRPD, `/placeped`, tag each post, `/pedexport`, paste the lines in | The whole Phase-B duty/post layer is built and unreachable without it. **Never author these coordinates** |
| ~35 `VERIFY IN-GAME` anchors | `/p6tp <anchor>` then `/coords` on the broken ones | Guessed coordinates put a location on an airport runway once. Every fix comes from your `/coords` |
| Police roster | One hardcoded Discord ID (yours) | Zero cops on beta night unless you are online. Also `lawyer` is a job no player can obtain, so `palm6_legal` can never be exercised |
| ELS | Check the panel for `els-fivem` / `ultra-lightbar` / `luxart-vehicle-control` | Zero hits in this repo, but the repo is the custom layer only and the box runs ~157 resources. Vendor rather than write |
| MRPD double-population | Stand at MRPD and look | Whether the MLO scenario spawner and pd_life peds occupy the same points is engine behaviour with no code in this repo |

---

## Notes

- `/placeped` is now ACE-gated. You keep access via the `group.owner` blanket allow, and
  `group.admin` was granted. The perm handshake is **one-shot at client load**, so an admin
  granted the ACE mid-session must reconnect.
- If `/witnesses` or `/replayflag` were unusable before, they work now — their `add_ace`
  grants were missing entirely.
- `palm6_brain` is **live in production** and always was, despite three separate places
  claiming it ships dark. Those claims are now corrected.
