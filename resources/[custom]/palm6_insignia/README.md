# palm6_insignia

**The officer's NAME and BADGE NUMBER, owned by the server and visible to everyone standing near them.**

This resource ships **no assets at all**. No `stream/` folder, no `.ytd`, no `.ydd`, no
`data_file`. It cannot repeat the palm6_threads incident, because there is nothing here for
the game to replace.

---

## IN-GAME VERIFICATION CHECKLIST

**Ten minutes, one life. Run these in order and stop at the first one that fails - each step's
"if it fails" tells you which layer is broken, so you never have to guess.**

Two rules for this whole checklist:

* **Never run `start`, `ensure` or `restart` on `palm6_threads`.** custom.cfg does
  `stop palm6_threads` on purpose (custom.cfg:334) because that resource's `stream/` folder
  overwrote a base-game drawable and took the server down. Deleting the file locally does not
  remove it from the live box - the deploy uploads, it does not delete - so that `stop` line is
  the live safety and starting it by hand undoes it. Nothing below needs it.
* Everything here is either a chat command or a single-resource console command. Nothing
  restarts the server, wipes anything, or touches another resource.

### Prerequisite (someone other than David does this first)

`ensure palm6_insignia` must exist in `custom.cfg` and be deployed. See
**"Orchestrator asks"** below. Until it is, every command in this checklist answers
`Unknown command` and there will be nothing in the log, because the resource never ran.

---

**1. Prove the resource is actually running.**

In the Pterodactyl / txAdmin **server console** (not chat), type:

```
ensure palm6_insignia
```

*Expect:* within a second or two, this line in the console:

```
[palm6_insignia] ready - schema ok, N badge(s) on file, N retired, range 100-999, N officer(s) on duty
```

followed by one line about rate limits.

*This is safe:* `ensure` on an already-running resource is a no-op, and on a stopped one it
starts just that resource. It touches nothing else.

*If you see nothing at all:* the files are not on the box. The deploy did not run, or it ran
before this resource existed.
*If you see `schema UNAVAILABLE`:* the resource is running but cannot reach MySQL. There will be
a `schema init FAILED` line just above it with the reason. Badges will not allocate; the tape
will show names with no numbers. Stop here, that is a database problem, not a uniform problem.
*If you see the yellow `no eventguard budget` line:* that is expected until ask 3 is applied and
is **not** a failure. The resource's own 3s floor is running. Keep going.

---

**2. Prove the server knows who you are.**

In **chat**:

```
/mybadge
```

*Expect:* three blue INSIGNIA lines - your name and badge line, `Badge number: #NNN` with NNN
between 100 and 999, and an `On duty:` line.

*If you get `Unknown command`:* step 1 did not actually take. Go back.
*If you get "You are not a police officer":* correct and expected on a civilian character. Go to
step 3.
*If you get "No character loaded":* qbx_core has not finished spawning you. Wait and retry.
*If you get no reply at all:* you ran it inside 3 seconds of the last `/mybadge`; the per-source
floor silently swallows the repeat. Wait three seconds and run it once.

---

**3. Get onto the police job and on duty.**

Skip this if your character is already police and on duty.

```
/setjob <your server id> police 4
/pdduty
```

`/setjob` is **qbx_core's** admin command, not part of this build. `/pdduty` is
`palm6_pd_life`'s duty toggle (it is namespaced so it never clobbers qbx's own `/duty`).

*Expect:* `/mybadge` now shows `On duty: yes (your tape is visible)`.

*Reverting afterwards:* `/setjob <your server id> unemployed 0`. Your badge number is **kept** -
it is bound to your citizenid across firing and rehire, by design.

*If `/pdduty` does nothing:* you are not on the police job yet, or `palm6_pd_life` is not
running. Check `/mybadge` first; it reports duty state from the server.

---

**4. Prove the server is publishing you to the roster.**

```
/insignia
```

*Expect:* `officers currently wearing a tape: 1` (or more, if others are on duty), plus the
schema, issued and retired counts.

*If it says 0 while `/mybadge` says you are on duty:* the roster derive is failing - that is a
server-side bug in `entryFor`, not a rendering problem, and it is the useful thing to report.

---

**5. THE ACTUAL TEST - look at the tape.**

Press `V` until you are in **third person**, so you can see your own ped. You should be looking
at the front of your character, or use another player.

*Expect:* two lines of white text on a dark plate, floating at your character's **chest**:

```
D. OLVERSON
PBPD #415  -  SERGEANT
```

Give it up to a second after `/pdduty` - the roster push is immediate, but the client rebuilds
its candidate list four times a second.

Read the failure by **where** the text is:

| What you see | What it means |
|---|---|
| Two lines at chest height | Working. Go to step 6. |
| Two lines **at your feet / ankles** | The bone name did not resolve on your ped model. Go to step 6a. |
| Two lines but far too high or low on the torso | The bone resolved; the offsets need a nudge. Go to step 6b. |
| **Nothing at all**, and `/insignia` said 1 | You are in first person (`Config.Render.HideOwnInFirstPerson`), or more than 12m from the ped you are looking at. Press `V` again. |
| Nothing at all, right after a `restart palm6_insignia` | Wait ~4 seconds. The client asks for the roster at 500ms and retries once at 4s. |
| Coloured text, or text that is not the name | Sanitisation regression. Screenshot it, that is security-relevant. |

---

**6. Capture the correct anchor (only if step 5 was not perfect).**

**6a - tape at your feet.** Open F8 (client console); there will be a one-time line naming every
bone name that was tried. Then try names until one lands:

```
/insigniabone SKEL_Spine3
```

It resolves the name against **your own ped right now** and refuses a name your model does not
have, so a typo cannot silently do nothing. Others worth trying: `SKEL_Spine2`, `SKEL_Spine_Root`,
`SPINE3`. `/insigniabone` with no argument reports what is in use. `/insigniabone reset` restores
the config list.

**6b - height is off.** Metres, forward first:

```
/insigniaoffset 0.18 0.10
```

Forward pushes the tape out of the chest, up raises it. `/insigniaoffset reset` restores config.

**Both commands change only your own client.** Nothing is written anywhere. When something looks
right, **report the values** - they go into `Config.Render.BoneNames` / `OffsetForward` /
`OffsetUp` in `shared/config.lua`, and that is how a guessed constant becomes a captured one.

---

**7. Prove it is the same for everyone (needs a second player).**

Have someone else stand within 12m of you and read your tape aloud.

*Expect:* the exact same two lines you see. They are the same server-composed strings; nobody's
client composes anything.

*If they see different text, or nothing:* the roster is not fanning out. `/insigniasync` on their
client forces a re-pull.

If no second player is available, `/badge` next to any player (including an NPC-free empty area
will report "Nobody close enough") is the fallback - it sends a notification card to everyone
within 6m, chosen from **server-read** positions.

---

**What is NOT worth reporting as a bug**

* Off-duty officers have no tape. Deliberate - an undercover officer must not wear a name tag.
* The tape draws through walls within 12m. Known, documented under "Known limits".
* A ~4 second blank after `restart palm6_insignia`. Known, and step 5 accounts for it.

---

## Read this first: why the text is not printed on the garment

David asked for the name and badge number **on the uniform**. That phrasing deserves an
honest answer rather than a thing that looks like it works.

**There is no way to print per-officer text onto a ped's clothing in FiveM that other players
can see.** Not "it is hard", not "nobody has bothered". The mechanism people reach for is
`ADD_REPLACE_TEXTURE` fed by a DUI, and it is disqualified twice over:

1. **It is global, not per-ped.** The native is keyed on a `(texture dictionary, texture
   name)` string pair and resolves to a single engine texture pointer. There is no `Ped`, no
   `Entity`, no model argument anywhere in the call chain. Every draw call on the client that
   samples that texture gets the swap. Two officers in the same jacket, and both wear the same
   tape. Cfx's own native docs for `ADD_REPLACE_TEXTURE` and `REMOVE_REPLACE_TEXTURE` carry the
   literal line *"Experimental natives, please do not use in a live environment."*
2. **It is client-local and not networked.** Nothing about a runtime texture crosses the wire.
   "Every client runs it for every officer" does not rescue it either, because all those calls
   collide on the same texture name and the last write wins for the whole client.

There are two further practical killers: the override is bound to a texture **pointer**, so it
silently dies when the game evicts and re-streams the garment (the tape vanishes when officers
walk out of and back into streaming range), and everything is wiped on disconnect.

**The only mechanism that is genuinely per-ped AND natively network-synced is ped component
variation** - a pre-generated addon-DLC decal pack on component 10, one drawable/texture per
name tape, rebuilt and redeployed every time the department hires someone. That is a static
art pipeline, not a feature, and it would need an artist plus a client re-download per hire.

So this resource does the thing that is actually correct: **the server publishes each on-duty
officer's identity, and every client renders that officer's tape in world space, anchored to
their chest bone.** Every player near an officer reads the same name and the same number,
because they are all drawing the same server-supplied strings.

If David later wants literal pixels on cloth, this resource is the right foundation for it:
the badge number is already stable, unique and server-owned, which is exactly what a
component-10 decal pack would key on. Nothing here would be thrown away.

---

## What it does

| Surface | Who sees it | Where the data comes from |
|---|---|---|
| **World-space name tape** on the officer's chest | every player within 12m, on their own client | the server-published roster |
| **`/badge`** presents a badge card | players within 6m, chosen by SERVER-read positions | the server |
| **`/mybadge`** | you | the server |
| **`exports.palm6_insignia:GetBadge` / `GetBadgeByCitizenId` / `GetInsignia` / `EnsureBadge`** | other resources | the server |

The tape is two lines:

```
D. OLVERSON
PBPD #415  -  SERGEANT
```

Line 1 is the name (format configurable). Line 2 is the department brand, the badge number,
and the **framework grade label** - so a promotion changes the tape with no extra plumbing,
because `job.grade.name` is what qbx already updates.

---

## Server-authoritative identity

This is the whole integrity of the feature, so it is worth being precise about.

* **Both strings on the tape are composed on the server** (`nameLine` / `badgeLine` in
  `server/main.lua`). The client receives finished text and draws it. It never composes an
  identity and cannot render one the server did not publish.
* **There is exactly one inbound net event**, `palm6_insignia:requestRoster`, and it carries
  **no payload at all** - not a badge, not a name, not a job. A modified client therefore has
  no surface through which to claim an identity. The test suite asserts that there is exactly
  one `RegisterNetEvent` in the server file, so a second one cannot be added quietly.
* **Name, rank, job and duty state all come from `exports.qbx_core:GetPlayer`**, via
  `bridge/sv_framework.lua`, wrapped in `pcall`.
* **`/badge` picks its recipients from server-read ped positions** (OneSync makes these
  authoritative), never from a client-supplied target, so it cannot be aimed at someone across
  the map.
* **`/setbadge` is ACE-gated** and every use prints an audit line to the console naming the
  old number, the new number, and who did it.

### Tape text sanitisation is a security control, not cosmetics

The client draws the name with `AddTextComponentSubstringPlayerName`, which **parses tilde
markup**. Surnames are typed by players at character creation. A surname of `~r~WANTED` would
render as coloured text of the player's choosing above their own ped, on everyone else's
screen. `sanitiseTapeText` is therefore a **whitelist** (letters, digits, space, dot,
apostrophe, hyphen, and bytes >= 128 so accented names survive) rather than a blocklist, and
the test suite attacks it from six directions.

---

## Where the badge number comes from, and why

`palm6_mdt` and `palm6_pd_life` were both read before anything was written here. **Neither has
a badge or callsign concept** - palm6_mdt keys everything on `citizenid`, palm6_pd_life on post
ids. A repo-wide search for `badge` / `callsign` in `resources/[custom]` found no officer
identifier of any kind. So this is the **first** authority on the box, not a competing second
one.

Three candidates were considered and rejected:

* **`metadata.callsign`.** `qbx_police` registers `/callsign` with **no gate at all** - any
  officer sets their own to any string. A self-settable field cannot be an authoritative badge
  number, and building on it would let a player wear another officer's identity. Rejected.
* **The qbx grade level.** Not unique. Every patrol officer is grade 0. Rejected.
* **The citizenid.** Not a short number an officer can say over the radio. Rejected.

**What ships:** a Palm6-owned table, `palm6_officer_badges`, keyed on `citizenid`, with a
`UNIQUE` index on `badge`. Numbers are allocated **lowest-free in `[Config.Badge.Min,
Config.Badge.Max]`** (100-999 by default).

* *Stable* - the number is bound to the character, kept across demotion, firing and rehire, so
  an officer who returns gets their old number back.
* *Unique* - guaranteed by the database, not by the in-memory set. The in-memory set makes the
  common path one insert; a race just loses the `INSERT` and retries the next free number,
  bounded by `Config.Badge.MaxAllocAttempts`.
* *Never recycled* - enforced, not asserted. **This claim was false in the first revision and
  is worth spelling out.** `/setbadge` moved a citizen onto a new number and dropped the old
  one from both the in-memory taken set and (by `UPDATE`-ing the row) the database, so the next
  hire could be handed it by lowest-free allocation - exactly the failure this bullet said was
  impossible. Now, when a number leaves a character, it is **retired**: a tombstone row is
  written into `palm6_officer_badges` so the reservation survives a restart, and `lowestFree`
  can never issue it again. The tombstone's `citizenid` is `retired:<badge>:<previous holder>`
  and its `job` is `retired`, so it needs no schema change and is obvious in the table.
  The one permitted exception is the **original holder** taking their own retired number back,
  which restores history rather than breaking it. Set `Config.Badge.RetireOnReassign = false`
  to go back to releasing numbers, and accept that old records naming them become ambiguous.
* *Short and human* - lowest-free rather than `max+1`, so a department that has churned through
  forty officers still issues `#103`, not `#143`.

Other resources should read it through the exports rather than duplicating the table.

---

## The render budget, and how it is enforced

Requirement: no unbounded per-frame loop over every player. Three mechanisms, all in
`client/main.lua`:

| Loop | Interval | What it iterates | Bound |
|---|---|---|---|
| **scan** | `Config.Render.ScanIntervalMs` (250ms) | the **roster** - on-duty officers only | `Config.Roster.MaxEntries` (48), server-enforced |
| **draw** | every frame | a **pre-built candidate list** | `Config.Render.MaxTapes` (5), hard truncation |
| **idle** | `Config.Render.IdleIntervalMs` (1s) | nothing | roster empty or nothing in range |

* The scan **never** calls `GetActivePlayers()` and never scans peds. It walks the roster, which
  on a normal shift is under ten entries, four times a second.
* What the test suite actually pins here, stated honestly: it asserts `GetActivePlayers` is
  absent from **`bridge/cl_game.lua`**. Keeping every native in the bridge is a convention this
  resource follows (`client/main.lua`'s last direct native call, `DoesEntityExist`, is now
  `Game.EntityExists`), but the suite cannot enforce that convention on `client/main.lua`, so a
  per-player scan added *there* would not be caught. Treat the assertion as a tripwire on the
  bridge, not a proof about the whole client.
* The draw loop reads a list the scan already sorted by distance and truncated to `MaxTapes`.
  Its per-frame cost is therefore **fixed at 5 tapes** regardless of how many officers or
  players exist.
* Text width is measured in the **scan** (the strings are static per officer) and cached on the
  candidate. The draw loop measures nothing.
* With no police on duty the whole resource costs one timer tick per second.

Officers out of streaming scope are skipped in one branch (`GetPlayerFromServerId` returns -1),
so distance is never computed for a ped that does not exist on this client.

---

## Cross-resource safety

* Every `qbx_core` touch is inside `pcall`, in `bridge/sv_framework.lua`. If qbx_core is
  stopped or restarting, every getter returns `nil` and the resource degrades to "no officer
  has an identity" instead of throwing on a hot path.
* There are **no calls into sibling palm6 resources at all**, so no sibling being stopped can
  break this one.
* Every framework signal is hooked with `AddEventHandler`, never `RegisterNetEvent`.
  `QBCore:Server:OnJobUpdate`, `qbx_core:server:onGroupUpdate`, `QBCore:Server:SetDuty` and
  `QBCore:Server:OnPlayerLoaded` are raised **inside** the server VM; net-registering one opens
  a framework-internal name to the network for every listener on the box.
  `palm6_eventguard/config.lua:23-32` documents exactly this mistake being found and fixed in
  two other bridges.
* `SetJobDuty` fires **only** the `SetDuty` pair and never `OnJobUpdate`, which is why both are
  hooked. Hooking one gives an officer a stale tape when they clock on.
* **No `onResourceStop` handler exists on the server side, deliberately.** Nothing here is dirty
  state needing a flush (the registry is written through on every change), so there is no reason
  to open a teardown path, and a MySQL `.await` inside one yields into a coroutine teardown
  never resumes.

---

## Commands

| Command | Who | What |
|---|---|---|
| `/mybadge` | any player | your server-derived identity, and your badge number |
| `/badge` | police | present your badge to players within 6m |
| `/insignia` | any player | system status: schema, badges issued, badges retired, officers wearing a tape, which rate-limit layers are live |
| `/insigniasync` | any player | force a roster resync (client-side, server rate limited) |
| `/insigniabone [NAME\|reset]` | any player | **client-local**: report or re-point the tape anchor bone, live. Resolves the name against your own ped and refuses a name your model does not have |
| `/insigniaoffset <fwd> <up>` \| `reset` | any player | **client-local**: nudge the tape off the bone, in metres, live |
| `/setbadge <server id \| citizenid> <number>` | `command.setbadge` ACE | override a badge number |

`/insigniabone` and `/insigniaoffset` change what **your own client** draws and nothing else.
They exist so the anchor is a value that was *seen to work in game* and then written into
`shared/config.lua`, rather than a number somebody asserted in a comment. That is how the
invented bone id got in, and it is the failure mode they close.

All are registered **unrestricted** and gated inside the handler, which is the house pattern:
a `RegisterCommand(..., true)` with no matching `add_ace` is runnable by `group.owner` and by
nobody else.

---

## Orchestrator asks - REQUIRED BEFORE THIS RESOURCE DOES ANYTHING

> These are lines in files this resource does not own and cannot edit. The first one is not a
> nicety: **without it the resource never starts**, every command below answers
> `Unknown command`, and there is nothing in the server log to say why, because nothing ran.
> The first revision shipped with this outstanding and the whole feature was invisible.

### 1. `custom.cfg` - the ensure line (BLOCKING)

Insert immediately after `ensure palm6_mdt` (currently custom.cfg:179). That is well after
`ensure palm6_eventguard` (custom.cfg:112), which matters: eventguard has to register its
handler before the resource whose event it guards.

```
# palm6_insignia - server-authoritative officer NAME + BADGE NUMBER, drawn as a
# world-space name tape on each on-duty officer's chest. Ships no assets.
ensure palm6_insignia
```

**How to confirm it took:** `node tools/audit/run.js` goes from `7 passed / 1 failed` to
`8 passed / 0 failed`. The `ensure-list` check reads custom.cfg directly and is the only gate
that can see this; nothing inside this resource can.

### 2. `custom.cfg` - the ACE grant

Next to the other command grants, after `add_ace group.admin command.placeped allow`
(currently custom.cfg:481):

```
# /setbadge (palm6_insignia/server/main.lua) - overrides an officer's badge
# number. Registered unrestricted and gated server-side on Config.AdminAce, so
# WITHOUT this grant only group.owner and the server console can run it.
add_ace group.admin command.setbadge allow
```

**If it is absent the resource still works.** `/setbadge` fails closed: admins are refused, and
the refusal now prints the exact missing line back to them instead of a bare "no permission".
Owner and console are unaffected.

### 3. `palm6_eventguard/config.lua` - the budget

Append inside `Config.Events`, next to the other police entries (after the `palm6_pd_life`
block, currently ends at line 459):

```lua
    -- palm6_insignia - the roster pull. Fires on spawn, on a resource restart
    -- and on a manual /insigniasync, so a handful a minute is generous.
    ['palm6_insignia:requestRoster']      = { calls = 10, window_seconds = 60 },
```

**If it is absent the resource still works.** `Config.RateLimits.requestRoster` (3s per source,
enforced in `rl()` in `server/main.lua`) is a real limiter on the same event and runs
regardless. What changes is that it becomes the *only* limiter, so the boot banner says so out
loud:

```
[palm6_insignia] no eventguard budget for palm6_insignia:requestRoster (...). The 3s
per-source floor in this resource is the ONLY limiter on that event. Add to
palm6_eventguard/config.lua: ['palm6_insignia:requestRoster'] = { calls = 10, window_seconds = 60 },
```

`/insignia` reports the same state on demand. The check is a read of the guard's config file
via `LoadResourceFile`; it starts nothing, depends on nothing, and reports `unknown` rather
than guessing if the guard is stopped or the file is unreadable.

---

## Configuration worth knowing about

| Key | Default | Why you would change it |
|---|---|---|
| `Config.Render.BoneNames` | `{ 'SKEL_Spine3', 'SKEL_Spine2', 'SKEL_Spine1', 'SKEL_ROOT' }` | the tape sits too high or too low. These are **names**, resolved at runtime against the ped actually standing there. Find the one you want with `/insigniabone <NAME>` in game, then write it here. |
| `Config.Render.OffsetForward` / `OffsetUp` | `0.18` / `0.04` | metres off the resolved bone, in **world** space: forward along the ped's facing, up along world Z. Tune live with `/insigniaoffset`. |
| `Config.Render.MaxTapes` | `5` | the hard per-frame cap |
| `Config.Render.MaxDistance` | `12.0` | how close you must be to read a tape |
| `Config.Name.Format` | `initial_last` | `last` -> `OLVERSON`, `first_last` -> `DAVID OLVERSON` |
| `Config.Roster.OnDutyOnly` | `true` | off-duty and undercover officers wear no tape |
| `Config.Badge.Min` / `Max` | `100` / `999` | the department's number range |
| `Config.Brand` | `PBPD` | the department prefix on line 2 |

**No world coordinate is authored anywhere in this resource. No clothing drawable or texture id
either, because no garment is ever touched. And, since this revision, no bone id.**

That last one was a real defect, not a hypothetical. The first revision hard-coded
`BoneId = 24819` and asserted in four places that it was `SKEL_Spine3`. It is not a ped bone at
all: the spine run is `SKEL_Spine1 = 24816`, `SKEL_Spine2 = 24817`, `SKEL_Spine3 = 24818`, and
24819 is one past the end of it - the shape a plausible-looking invented number takes. A bad
bone number does not error; `GetPedBoneCoords` falls back to the entity position, so the tape
would have rendered at every officer's **ankles** with nothing in any log. The README then
advised "24818 is SKEL_Spine2, one notch down", which would have landed on Spine3 by accident.

The fix is not a better number. It is that **no number is authored**: `bridge/cl_game.lua`
passes each configured NAME to `GET_ENTITY_BONE_INDEX_BY_NAME` against the ped in front of you,
that native returns `-1` for a name the model does not have, and the first name that resolves
wins. The engine decides. If none resolve, the tape draws at the ped's origin *and the client
console prints which names were tried*, so the failure is visible and reportable instead of
silent.

---

## Tests

`tests/suites/11_insignia_identity.lua` - 64 assertions, run with `cd tests && node run.js 11_insignia`.

The production bytes are **lifted** out of `server/main.lua` by anchor and executed, not
reimplemented, so moving the code fails the suite loudly rather than testing a stale copy.

Covered: badge allocation (holes, floors, exhaustion, inverted ranges, determinism, and a
structural proof that the allocator reads no clock, no PRNG and no database); tape text
sanitisation from six attack directions plus the legitimate cases that must survive
(hyphens, apostrophes, initials, accents) and UTF-8-aware truncation; both tape lines across
every name format; and the no-asset invariant - that the client bridge calls no clothing or
texture-replacement native, that the manifest has no `data_file` and streams nothing, that
there is exactly one inbound net event, and that no teardown handler exists.

---

## Known limits, stated plainly

* **The tape is drawn in world space, not painted on the cloth.** It reads as a name tape at
  chest height and every nearby player sees the same text, but it is text the engine draws, not
  a texture on the garment. The section at the top of this file explains why that is the only
  honest option, and it should be said to David rather than discovered by him.
* **Occlusion.** `SetDrawOrigin` text draws through geometry. An officer behind a wall within
  12m and on screen will show a tape through the wall. `Config.Render.MaxDistance` keeps that
  local; if it bothers anyone in play, the fix is a line-of-sight check in the scan, which is
  cheap because the scan is already bounded.
* **The anchor is engine-resolved but the resulting HEIGHT is still unverified in game.** The
  bone is no longer a number anyone typed: `SKEL_Spine3` either exists on that ped model or it
  does not, and the engine answers. What nobody has seen yet is whether Spine3 plus 0.18m
  forward and 0.04m up puts the tape at chest height or at the collarbone. Worst case is a tape
  at the wrong height, never an error. Checklist step 5 is exactly this, and
  `/insigniabone` / `/insigniaoffset` let it be corrected and captured in the same 30 seconds.
* **Off-duty officers have no tape.** Deliberate: an undercover officer must not be wearing a
  name tag. `/badge` still works for them.
* **The badge range holds 900 officers.** Beyond that, allocation logs a loud console warning
  and the officer gets a name-only tape rather than a duplicate number.
