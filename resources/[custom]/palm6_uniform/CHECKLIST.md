# palm6_uniform - the walk-up test

**For David. Ten minutes, one life, and no typing.**

You walk to the police station wardrobe, a menu opens, you click a uniform, your
clothes change. That is the whole feature. Everything below is that, plus what
each thing on screen means when it does not happen.

Two things are called out because they are the ways this could go wrong:

- **Do not `ensure palm6_threads`.** That is the resource that took the box down
  on 2026-07-29. It is force-stopped at `custom.cfg:334` and nothing here needs
  it. It is unrelated to palm6_uniform except as the cautionary tale it was
  written against.
- **Do not `restart palm6_uniform` in the middle of this.** A restart wipes the
  client-side memory of what you were wearing before, and you would be left in
  whatever outfit you had on with the restore answering *"No civilian outfit was
  recorded this session"*. If you do restart by accident, the way out is a
  relog, not a command.

**Get out of anything at any time:** open the wardrobe and pick **Back to my own
clothes**, or type `/uniformoff`. If it says it has nothing to restore, relog:
this resource never writes your saved appearance, so your character comes back
in their own clothes.

---

## Step 0 (console, ten seconds) - is it running, and where did it put the wardrobe?

**Read the server console** for these two lines, printed once at boot:

```
[palm6_uniform] ready - schema ok | 0 set(s) loaded | season summer | weather bucket any (no weather resource) | job police
[palm6_uniform] wardrobe at 442.32, -988.43, 30.69 (radius 1.8) - source: qbx_police_overrides:GetDutyToggle() ("Mission Row PD - Duty")
```

- **`schema ok`** - the `palm6_uniform_sets` table exists. If it says `MISSING`,
  stop; there is a red `schema init FAILED` line just above it with the reason.
- **`source: qbx_police_overrides:GetDutyToggle()`** - the wardrobe position was
  **read** from the resource that owns the police station's location, not typed
  in by anybody. If instead it says
  `source: Config.Wardrobe.FallbackCoords, because ...`, the reason is on the
  same line and the position is still the same coordinate; that is a degrade,
  not a fault.
- **`weather bucket any (no weather resource)`** - expected. Neither
  `qbx_weathersync` nor `qb-weathersync` is in this repo, so every officer
  resolves to the `any` bucket.

**If there is no `[palm6_uniform]` line at all**, the resource is not running
and there will be no wardrobe at the station. The fix is two lines in
`custom.cfg` (see the bottom of this file). Do not go further: a resource that
never started looks exactly like a resource that is broken.

**Also look for a red ACE line.** If you see
`ACE MISSING: group.admin cannot run the admin commands`, then unless you are
connected as `group.owner` the admin options will not appear in the wardrobe
menu and the menu will say so.

---

## Before you walk over

You need the **police** job. `/setjob` is granted to `group.admin` at
`custom.cfg:383`; its argument order belongs to `qbx_core`, not to this repo, so
type `/setjob` on its own first and read its usage rather than guessing.

You do **not** need to be on duty. Picking a uniform from the wardrobe is your
own explicit request and does not check duty. Every automatic path does.

Pick a **male** character for this run. The female capture is a separate pass.

---

## Step 1 - walk to the station wardrobe

**Where:** the police station duty point, Mission Row. Same spot the duty toggle
is at.

**What you should see:** an `ox_target` eye when you look at it, labelled
**Station Wardrobe**. If `ox_target` is not running on the box you instead get
an on-screen prompt, `Press E Station Wardrobe`, when you are within about two
metres. Both are correct; the menu footer tells you which one you got.

**Fail:**

- **nothing there at all** - go back to step 0 and read the wardrobe line. If it
  says the position could not be resolved, the console names which source
  failed.
- **it is in the wrong place** - that is fixable from in game and it does not
  need a coordinate. Do steps 2 and 3 first, then see "If the wardrobe is in the
  wrong spot" at the bottom.

---

## Step 2 - open it. This is the screen that matters.

**Interact.** A menu opens. With nothing captured yet it says, in the menu:

```
Season: summer. Weather: any.
No uniforms have been captured yet.
    This wardrobe is working. It is empty. A uniform here is a photograph of an
    outfit somebody actually wore in game, so until somebody captures the first
    one there is genuinely nothing to put on.
To create the first one, right here, with no typing:
    1. dress this character however the rank should look. 2. come back here and
    pick "Save what I am wearing as a uniform". 3. pick the rank. 4. pick the
    conditions.
Save what I am wearing as a uniform
Randomise my clothes (test tool)
Read out what I am wearing
Move this wardrobe to where I am standing
```

**Pass:** the menu is not blank. That is the point of this step. An empty
wardrobe and a broken wardrobe used to look identical, and now they do not.

**Fail:**

- **`The server did not answer.`** - a real fault, and it is saying so rather
  than showing you an empty list. Check the server console for `palm6_uniform`
  lines.
- **`You are not a police officer.`** - exactly what it says; the row names the
  job it wants and the job you have. Fix the job and reopen.
- **`Your character is not a standard freemode ped.`** - captured clothing
  indices only mean anything on the two freemode bodies.
- **the admin rows are missing** - you do not hold the admin ACE. The ACE is
  named in the console line from step 0.

---

## Step 3 - create the first uniform, with four clicks and no typing

1. Dress the character however a cadet should look, in whatever clothing menu
   the box runs. Stand still and let it finish streaming.
2. Open the wardrobe. Pick **Read out what I am wearing**. Twelve component
   lines and five prop lines print to chat, and a count line. **Nothing is
   stored.** If the count says `0 of 12 component slots are non-zero`, your ped
   had not finished streaming: walk twenty metres, wait five seconds and read it
   again. Capturing a wall of zeros stores "wearing nothing" as a uniform.
3. Open the wardrobe. Pick **Save what I am wearing as a uniform**.
4. Pick the rank. The list is the real police rank roster, read out of
   `qbx_police_overrides`: Cadet, Officer, Sergeant, Lieutenant, Chief. Pick
   **Cadet**.
5. Pick **Start here: All year round, any weather**.

**Expect a notify:** `Photographing what you are wearing, to be saved as
"Cadet".` then `Saved "Cadet" as a uniform. Open the wardrobe again to put it
on.` and the same in chat with the slot counts.

The rank you picked is a **floor**: that one set now dresses Cadet and every
rank above it. You have just dressed the whole department in four clicks.

**Fail:**

- **`You must be on the "police" job to save a police uniform.`** - fix the job.
- **`Capture rejected: capture is incomplete: component slot N is missing`** -
  the snapshot did not cover all twelve slots. Report it; the raw path always
  returns twelve.
- **`Saving a uniform needs the "command.uniformcapture" permission`** - the
  message names the exact `custom.cfg` line to add.

---

## Step 4 - the actual feature. Two clicks, and your clothes change.

1. Open the wardrobe. Pick **Randomise my clothes (test tool)**. Your clothes
   visibly change; your face and hair do not. **This step is not optional.** You
   need two different outfits to see a uniform swap; without it the apply
   correctly writes the same numbers back, nothing moves, and the whole thing
   reads as a no-op.
2. Open the wardrobe again. There is now a row:

   ```
   Cadet
       Cadet and up | season any | weather any | the automatic pick for right now
   ```

   Click it.

**Expect, on screen:** you snap into the outfit you captured in step 3.

**Expect, in notify:** `Uniform: Cadet (any / any) (N slots changed)` with N
above zero.

**That is the whole round.** You walked to a wardrobe, a menu opened, you picked
a uniform, your clothes changed, and you typed nothing.

**Fail:**

- **`Uniform "Cadet (any / any)" applied, but you were already wearing every
  slot of it, so nothing changed on screen.`** - the resource is working; you
  skipped the randomise. Do step 4.1 and click again.
- **`You already have "Cadet" on. Putting it on again, so nothing will visibly
  change.`** - the same thing, said before it happens.
- **`component N (drawable D, texture T) is not valid on this ped`** - the whole
  apply was aborted and you kept what you had on. That is the all-or-nothing
  refusal working: the stored set does not fit this ped.
- **`You are not allowed to wear that one.`** - the server re-checked your rank
  and the id you clicked is not on your list. Reopen the wardrobe.

---

## Step 5 - back to your own clothes

Open the wardrobe. Pick **Back to my own clothes**.

**Expect, on screen:** you change back into what you had on when you loaded in,
before the randomise.

**Expect:** `Back in civilian clothes (N slots changed).`

**Fail:**

- **the row is greyed out** and says *"this wardrobe has not changed your
  clothes this session"* - correct if nothing has dressed you.
- **`No civilian outfit was recorded this session`** - the snapshot was lost,
  almost always because the resource was restarted mid-session. Relog.

---

## Step 6 - the variant choice, still no typing

1. Randomise your clothes again from the wardrobe (a third outfit).
2. **Save what I am wearing as a uniform** -> **Cadet** -> **Winter only, any
   weather**.
3. Open the wardrobe. There are now **two** rows for you: `Cadet` and
   `Cadet winter`. Click **Cadet winter**.

**Expect:** you change into the third outfit, and the notify says
`Uniform: Cadet winter (winter / any)`.

That is the season variant working, chosen by hand from the menu. The
**automatic** side of it (the server switching you when the real season changes)
is the same rows and is marked `the automatic pick for right now` on whichever
one currently wins. To feel-test that half you do need one command,
`/uniformseason winter`, and that is the one place a command is still the
shortest route.

---

## Step 7 - finish clean

Open the wardrobe. Pick **Back to my own clothes**.

Optionally clear the throwaway captures so the department is not wearing random
clothes: `/uniformlist` to read the ids, then `/uniformdelete 1` and
`/uniformdelete 2`. That only ever deletes rows in `palm6_uniform_sets`; losing
that whole table costs the captured uniforms and nothing else.

---

## If the wardrobe is in the wrong spot

**Do not guess a coordinate and do not ask for one.** Walk to where the wardrobe
should actually be, open the menu wherever it currently is, and pick **Move this
wardrobe to where I am standing**.

It moves immediately for everyone, tells you so, and prints the exact line in
chat and to the console:

```
Wardrobe moved to vector3(441.02, -981.45, 30.69). This is a RUNTIME move; a restart puts it back.
To keep it, set Config.Wardrobe.FallbackCoords in palm6_uniform/shared/config.lua to: vector3(441.02, -981.45, 30.69)
```

The move lasts until the resource restarts. If it is right, paste that line into
`Config.Wardrobe.FallbackCoords` to keep it.

---

## After the ten minutes (not part of this run)

- **Capture the real look.** Dress a police character properly, then save it
  from the wardrobe at the rank it belongs to.
- **Capture it again on a female character.** `mp_m_freemode_01` and
  `mp_f_freemode_01` have completely disjoint drawable index spaces. Every
  uniform must be captured twice. If the two captures come back with identical
  numbers, something is wrong, not convenient.
- **Promotion.** Save a second set at a higher rank, then have someone change
  your grade and watch the uniform change with no relog.
- **Re-run every capture after any clothing pack changes on the box.** A
  drawable index is a position in a mount-ordered list. Adding or removing a
  pack shifts every index after it and a stored set silently becomes a different
  garment. Nothing can detect that from outside the game.

---

## If it is not running

`custom.cfg` is not owned by this resource. Two lines are needed, and the audit
(`node tools/audit/run.js`) fails `ensure-list` until the first one is present:

```
ensure palm6_uniform
add_ace group.admin command.uniformcapture allow
```

The `ensure` must sit **after** `ensure palm6_eventguard` (`custom.cfg:112`) so
the guards register first; next to `ensure palm6_pd_life` (`custom.cfg:172`)
keeps it with the police resources. The `add_ace` belongs with the other grants
near `custom.cfg:481`. That one ACE covers the admin options in the wardrobe
menu as well as the admin commands, because both check the same string.

Starting it without a restart is safe from the console: `ensure palm6_uniform`.
This resource has no `stream/` folder, no `data_file` and no
`SHOP_PED_APPAREL_META_FILE`, so starting it mounts no asset and cannot replace
a base-game garment. **That safety statement is about `palm6_uniform` only.** It
is not true of `palm6_threads`, which must stay stopped.

---

## Appendix: the commands, if the menu is unavailable

Every step above is a click. These do the same things from anywhere on the map
and are the fallback if `ox_target` and the `ox_lib` menu are both unavailable,
or if the wardrobe position cannot be resolved at all.

| command | equivalent menu action |
|---|---|
| `/uniform` | clicking the recommended uniform row |
| `/uniformoff` | **Back to my own clothes** |
| `/uniformcapture <grade> <season> <weather> [label]` | **Save what I am wearing as a uniform** |
| `/uniformshow` | **Read out what I am wearing** |
| `/uniformscramble` | **Randomise my clothes** |
| `/uniformlist`, `/uniformdelete <id>` | no menu equivalent; deleting a stored set is deliberately not a click |
| `/uniformstatus` | no menu equivalent; it is the console-facing meter, and it now also reports where the wardrobe is and which source answered |
| `/uniformseason`, `/uniformweather` | no menu equivalent; these are test pins, not part of the normal flow |
