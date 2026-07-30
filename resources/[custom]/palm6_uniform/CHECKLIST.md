# palm6_uniform - in-game verification

**For David. Ten minutes, one life. Nothing here can take the server down.**

Every step below is either a chat command typed by you in game, or reading a
line in the server console. Nothing here writes an asset, streams anything,
touches a base-game file, or restarts a resource. Two things are called out
explicitly because they are the ways this could go wrong:

- **Do not `ensure palm6_threads`.** That is the resource that took the box down
  on 2026-07-29. It is force-stopped at `custom.cfg:334` and nothing in this
  procedure needs it. It is not related to palm6_uniform in any way except as
  the cautionary tale palm6_uniform was written against.
- **Do not `restart palm6_uniform` in the middle of this.** A restart wipes the
  client-side memory of what you were wearing before, and you would be left in
  whatever outfit you had on with `/uniformoff` answering *"No civilian outfit
  was recorded this session"*. That is why the season test below uses
  `/uniformseason` instead of editing the config. If you do restart by accident,
  the way out is a relog, not a command.

**Get out of anything at any time:** `/uniformoff`. If that says it has nothing
to restore, relog: this resource never writes your saved appearance, so your
character comes back in their own clothes.

---

## Step 0 (console) - is it even running?

**Read the server console** for this line, printed once at boot:

```
[palm6_uniform] ready - schema ok | 0 set(s) loaded | season summer | weather bucket any (no weather resource) | job police
```

- **`schema ok`** - the `palm6_uniform_sets` table exists. If it says `MISSING`,
  stop; there will be a red `schema init FAILED` line just above it with the
  reason, and no capture can be stored until that is fixed.
- **`season summer`** - correct for July. The season comes from the real-world
  date on the server, not from the game. There is no season in GTA V.
- **`weather bucket any (no weather resource)`** - expected. Neither
  `qbx_weathersync` nor `qb-weathersync` is in this repo, so every officer
  resolves to the `any` bucket. This is a documented degrade, not a fault.

**If there is NO `[palm6_uniform]` line at all**, the resource is not running,
and every step below will answer `Unknown command`. The fix is two lines in
`custom.cfg` (see "If it is not running" at the bottom). Do not go any further
until this line is on screen: a resource that never started looks exactly like a
resource that is broken, and you would spend the whole session on the wrong
question.

**Also look for a red ACE line.** If you see:

```
[palm6_uniform] ACE MISSING: group.admin cannot run the admin commands
[palm6_uniform]   add this line to custom.cfg:  add_ace group.admin command.uniformcapture allow
```

then unless you are connected as `group.owner`, steps 2 onward will answer *"You
do not have permission to do that."* Add that line before you load in.

---

## Before step 1

You need the **police** job. `/setjob` is granted to `group.admin` at
`custom.cfg:383`; its argument order belongs to `qbx_core`, not to this repo, so
type `/setjob` on its own first and read its usage rather than guessing.

You do **not** need to be on duty. `/uniform` is the officer's own explicit
request and does not check duty. Every automatic path does.

Pick a **male** character for this run. The female capture is a separate pass and
is not part of the ten minutes.

---

## Step 1 - `/uniformstatus`

**Type:** `/uniformstatus`

**Expect** six blue `Uniform` lines in chat:

```
enabled=true  schema=ok  sets=0
season=summer (Config.SeasonByMonth, real date, server-side)
weather bucket=any (from no weather resource)
admin ACE "command.uniformcapture": you=true, group.admin=true
season is a CONFIG SCHEDULE: GTA V and FiveM have no built-in season, ...
client: illenium-appearance absent | ped model mp_m_freemode_01 | in uniform: false | clothes changed by us: false | civilian snapshot: held
```

**What each failure means:**

| what you see | what it means |
|---|---|
| `Unknown command` | the resource is not running. Go back to step 0. |
| `You do not have permission to do that.` (plus a line naming the ACE) | the `add_ace` line is missing from custom.cfg. The message tells you the exact line. |
| `you=false` on the ACE line | same thing, seen from the other side. |
| `ped model nil` | your character is not one of the two freemode models. Nothing in this resource will work on it, by design, and it will say so rather than guess. |
| `civilian snapshot: none` | the client did not manage to photograph you at spawn. Relog; if it persists, the client half is not loading. |
| no reply at all | this cannot happen any more. Every command in this resource answers, including every refusal. Silence means the resource is not running. |

---

## Step 2 - `/uniformshow`

**Type:** `/uniformshow`

**Expect** `Reading what you are wearing...`, then about twenty lines:

```
Worn right now on mp_m_freemode_01:
  component 0   drawable 0     texture 0
  component 1   drawable 0     texture 0
  ... twelve component lines and five prop lines ...
  7 of 12 component slots are non-zero.
Nothing was stored. Use /uniformcapture to store it.
```

**Pass:** you get twelve component lines and five prop lines, and the count line
says something above zero.

**Fail, and what it means:**

- **`0 of 12 component slots are non-zero`** - the resource prints an extra line
  telling you this is almost always a ped that has not finished streaming. Walk
  twenty metres, wait five seconds, run it again. Do **not** capture a reading of
  all zeros; you would store "wearing nothing" as a uniform.
- **`Too fast: /uniformshow is rate limited...`** - you ran it twice inside a
  second. Wait and repeat. This is the resource refusing out loud, which is the
  point: it never drops a command in silence.

---

## Step 3 - `/uniformscramble`  ← **the first visible thing**

**Type:** `/uniformscramble`

**Expect, on screen:** your character's clothes visibly change. Shirt, trousers,
shoes, possibly a hat or glasses. **Your face and your hair do not change.**

**Expect, in chat:** `Randomising your clothes. Face and hair are left alone.`
followed by `clothes randomised. /uniform to put the captured uniform on,
/uniformoff to go back to what you were wearing before this.`

**Why this step exists:** you need two different outfits to see a uniform swap.
Without it the natural first test is "capture what I am wearing, then put it
on", which correctly writes the same numbers back and changes nothing on screen,
and the whole resource reads as a no-op. This command gets you the second outfit
without a clothing store. It picks from the variations the engine reports as
valid for your ped, so no clothing id is authored anywhere.

**Fail:**

- **clothes did not change** - run it once more. The randomiser can land close to
  what you had on. If two runs in a row change nothing, the client half is not
  applying writes and step 6 will fail the same way.
- **your face or hair changed** - that is a bug; report it. Those two slots are
  read off your ped before the randomise and written straight back.

---

## Step 4 - `/uniformcapture 0 any any Patrol`

You are now standing in the random outfit from step 3. Capture **that**, so the
uniform is provably different from your own clothes.

**Type:** `/uniformcapture 0 any any Patrol`

**Expect:** `Photographing what you are wearing...` then

```
Captured 12 components and 5 props for police grade 0 and up, mp_m_freemode_01, season any, weather any, labelled "Patrol".
Run /uniform to put it on, and remember to capture the same set on the other body.
```

`0` is a **floor**, not an exact grade: this one set now dresses every grade from
0 upwards until a higher capture overrides it.

**Fail:**

- **`You must be on the police job to capture a police uniform.`** - exactly what
  it says. Fix the job and repeat.
- **`Capture rejected: capture is incomplete: component slot N is missing`** -
  the snapshot did not cover all twelve slots. Report it; the raw path always
  returns twelve.
- **`That capture timed out. Run the command again.`** - the reply took longer
  than 30 seconds to come back. Repeat.
- **nothing stored and no message** - cannot happen; the reply path answers on
  every branch including the rate limit.

---

## Step 5 - `/uniformlist`

**Type:** `/uniformlist`

**Expect:**

```
1 stored set(s):
  #1   Patrol           grade>=0  mp_m_freemode_01  season=any    weather=any   12 comps / 5 props
You (grade 0, mp_m_freemode_01) would get set #1.
```

The last line is the selection engine answering for **you** specifically. If it
says `would get NOTHING`, read the reason it gives: it names the job, grade,
model, season and weather it looked for.

---

## Step 6 - `/uniformoff`  ← **visible**

**Type:** `/uniformoff`

**Expect, on screen:** you change back into the clothes you had on when you
loaded in, before step 3.

**Expect, in chat/notify:** `Back in civilian clothes (N slots changed).` with N
above zero.

**Fail:**

- **`Back in civilian clothes, though every slot already matched them`** - means
  the randomiser landed on your own outfit. Harmless, but redo steps 3-4 to get a
  genuinely different capture, otherwise step 7 will not be visible either.
- **`No civilian outfit was recorded this session`** - the snapshot was lost.
  Almost always because the resource was restarted mid-session. Relog.
- **`This resource has not changed your clothes, so there is nothing to change
  back.`** - the server has no record of dressing you. Means step 3 did not reach
  the server.

---

## Step 7 - `/uniform`  ← **visible, and this is the actual feature**

**Type:** `/uniform`

**Expect, on screen:** you snap into the outfit captured in step 4.

**Expect, in notify:** `Uniform: Patrol (any / any) (N slots changed)` with N
above zero.

**Fail:**

- **`Uniform "Patrol (any / any)" applied, but you were already wearing every
  slot of it, so nothing changed on screen.`** - the resource is working; you
  captured what you were already wearing. Not a bug, and it tells you the fix.
- **`You have no uniform to change into.`** - you are not on the police job.
- **`no uniform captured for police grade N on mp_m_freemode_01 ...`** - your
  grade is below nothing, or you are on the other body. The message names every
  value it searched on.
- **`component N (drawable D, texture T) is not valid on this ped`** - the whole
  apply was aborted and you kept what you had on. This is the all-or-nothing
  refusal working; it means the stored set does not fit this ped.

---

## Step 8 - the season, without a restart

Now prove that season selection actually switches the garment. Four commands.

1. **`/uniformscramble`** - a third outfit. **Expect:** clothes visibly change.
2. **`/uniformcapture 0 winter any Winter Coat`** - **Expect:** `Captured 12
   components and 5 props for police grade 0 and up, mp_m_freemode_01, season
   winter, weather any, labelled "Winter Coat".`
3. **`/uniformseason winter`** - **Expect:**
   ```
   season is now: winter (/uniformseason pin, runtime)
   Re-applied to N on-duty officer(s). If you are off duty, run /uniform to see it.
   ```
   If you are on duty you will visibly change here. If you are off duty, N is 0
   and nothing moves yet; that is correct.
4. **`/uniform`** - **Expect, on screen:** you are in the winter outfit.
   **Expect, in notify:** `Uniform: Winter Coat (winter / any) (N slots changed)`.

Then hand the season back:

5. **`/uniformseason auto`** - **Expect:** `season is now: summer
   (Config.SeasonByMonth, real date, server-side)`.
6. **`/uniform`** - **Expect, on screen:** you are back in the step-4 Patrol
   outfit. **Expect:** `Uniform: Patrol (any / any) (N slots changed)`.

**That swap between 4 and 6 is the whole season feature.** If both land on the
same outfit, the two captures were of the same clothes: redo step 8.1 and make
sure the scramble actually changed something.

**Fail:** `Unknown season "winter"` means you typed a value outside `any winter
spring summer autumn`. The message lists them.

---

## Step 9 - finish clean

**Type:** `/uniformoff`

**Expect:** back in the clothes you loaded in wearing.

Optionally clear the two throwaway captures so the department is not wearing
random clothes: `/uniformlist` to read the ids, then `/uniformdelete 1` and
`/uniformdelete 2`. This only ever deletes rows in `palm6_uniform_sets`; losing
that whole table costs the captured uniforms and nothing else.

---

## After the ten minutes (not part of this run)

- **Capture the real look.** Dress a police character properly in whatever
  clothing menu the box runs, then `/uniformcapture 0 any any Patrol`.
- **Capture it again on a female character.** `mp_m_freemode_01` and
  `mp_f_freemode_01` have completely disjoint drawable index spaces. Every
  uniform must be captured twice. If the two captures come back with identical
  numbers, something is wrong, not convenient.
- **Promotion.** Capture a second set at a higher grade
  (`/uniformcapture 3 any any Sergeant`), then have someone change your grade and
  watch the uniform change with no relog. `/setjob` is granted to `group.admin`;
  read its own usage rather than guessing its argument order.
- **Re-run every capture after any clothing pack changes on the box.** A drawable
  index is a position in a mount-ordered list. Adding or removing a pack shifts
  every index after it and a stored set silently becomes a different garment.
  Nothing can detect that from outside the game.

---

## If it is not running

`custom.cfg` is not owned by this resource. Two lines are needed, and the audit
(`node tools/audit/run.js`) fails `ensure-list` until the first one is present:

```
ensure palm6_uniform
add_ace group.admin command.uniformcapture allow
```

The `ensure` must sit **after** `ensure palm6_eventguard` (`custom.cfg:112`) so
the guards register first; anywhere in the `palm6_*` block below it is fine, and
next to `ensure palm6_pd_life` (`custom.cfg:172`) keeps it with the police
resources. The `add_ace` belongs with the other grants near `custom.cfg:481`.

Starting it without a restart is safe from the console: `ensure palm6_uniform`.
This resource has no `stream/` folder, no `data_file` and no
`SHOP_PED_APPAREL_META_FILE`, so starting it mounts no asset and cannot replace
a base-game garment. **That safety statement is about `palm6_uniform` only.** It
is not true of `palm6_threads`, which must stay stopped.
