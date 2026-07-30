# Custom clothing on PALM6

**Status:** binding. Read this before adding any clothing asset to this repo.
**Written:** 2026-07-29, the day the second attempt at custom clothing took the
live server down.
**Revised:** 2026-07-29, after review found that the first draft's safety
argument rested on files being deleted from the repo, which does not remove them
from the live server. Sections 2, 3, 4, 5, 8 and 9 changed. The deleted test 2
(`ensure palm6_threads` on the live box) must not return; see section 8.

Two attempts at custom clothing have now failed the same way. This document
exists so the third one does not. If you only read one line, read this one:

> **A clothing resource is dangerous the moment it is STARTED, not the moment it
> is USED.** `Config.Enabled = false` protects nothing. FiveM mounts everything
> under `stream/` at resource start, whether or not any Lua ever runs.

---

## 1. The rule

**Replacement-style clothing is banned on PALM6.** No resource in this repo may
stream a file whose name collides with a base-game or official-DLC asset name.

Custom clothing may only arrive one of two ways:

| route | what it does | blast radius | status here |
| --- | --- | --- | --- |
| **Capture-and-reapply** | Reads the drawable/texture indices off a ped that is already wearing something, stores them, pushes them back later with `SetPedComponentVariation` | One ped, on demand | **Allowed. This is how uniform work is done today.** |
| **Addon-DLC pack** | Streams NEW assets under a pack namespace and declares them in a `SHOP_PED_APPAREL_META_FILE`, so they are APPENDED to the drawable list | Adds indices; existing outfits keep working | **Allowed, but nothing has ever been built this way here. See section 6.** |
| **Replacement pack** | Streams a file named like a base-game asset, so the engine serves your file wherever the game asked for Rockstar's | Every ped on the server, including peds whose owners never opted in | **BANNED.** |

There is no third safe option. In particular, the `AddReplaceTexture` + DUI
trick that people reach for when they want text on a garment is **not** a
per-ped mechanism and is not allowed either. Section 7 explains why.

---

## 2. What actually happened on 2026-07-29 (the worked example)

`resources/[custom]/palm6_threads` was a Stage A spike whose only question was
"does a `.ytd` built headlessly by `tools/threads-pipeline` render on a ped".
It streamed two loose files:

```
stream/mp_m_freemode_01^jbib_000_u.ydd            <- a copy of Rockstar's base male torso
stream/mp_m_freemode_01^jbib_diff_000_a_uni.ytd   <- our 6 KB generated texture
```

and shipped a client command `/threads_spike` that ran
`SetPedComponentVariation(ped, 11, 0, 0, 2)` so the texture could be eyeballed.

**The chain of reasoning that produced the bug, and where it goes wrong.**

The spike's own manifest comment argued, in good faith, that replacement was the
*safer* choice:

> "Stage A spike is REPLACEMENT-style, not addon-DLC, so NO
> SHOP_PED_APPAREL_META_FILE is needed: we overwrite the base game's existing
> male-torso jbib drawable 0. The base game's own shop meta already declares
> that slot, so it stays selectable at a fixed, deterministic index (component
> 11, drawable 0, texture 0) with no appended-index guessing."

Every clause of that is technically true. It is also exactly backwards. The
reason base drawable 0 is "fixed and deterministic" is that **every other outfit
on the server is already using it.** Choosing the slot with the most existing
users, precisely because it has the most existing users, is the failure.

**What the filenames mean.** FiveM mounts everything under a resource's
`stream/` folder into the global streaming store, keyed by filename, at resource
start. The `^` in `mp_m_freemode_01^jbib_000_u.ydd` separates the ped model from
the asset. There is **no DLC segment** in that name. An addon asset looks like
`mp_m_freemode_01_palm6pd^jbib_000_u.ydd`. Without the pack segment, the engine
resolves your file wherever it would have resolved Rockstar's. Not for the
player who ran the command. For everyone, immediately, at boot.

**The symptom.** The resource was found RUNNING on the live box (started by the
panel-managed `server.cfg`, which is outside this repo) while David reported
that every police work outfit rendered as **nothing** for everyone. Correct
diagnosis: every outfit built on the base torso had lost its drawable.

**The four things that failed to stop it.**

1. `Config.Enabled = false` shipped in the config, and the resource was still
   destructive. The flag gated the Lua command. The Lua was never the hazard.
2. This repo never had an `ensure palm6_threads` line, and the resource ran
   anyway, because the panel's `server.cfg` (outside this repo) started it.
   **"We didn't ensure it" is not a safety property.**
3. A warning comment in `fxmanifest.lua` and a long warning in `custom.cfg`.
   Comments do not stop resources.
4. The implementation plan
   (`docs/superpowers/plans/2026-07-22-palm6-threads-phase0-pipeline-spike.md`)
   contained a live instruction, "Add `ensure palm6_threads` to the canonical
   `custom.cfg` ... Since `Config.Enabled=false`, it streams assets but takes no
   action - safe." That sentence is wrong, and it was sitting in a checkbox
   waiting for the next worker to tick it.

The lesson is not "be careful". It is that the only reliable protection is that
**the dangerous file is not in a `stream/` folder on the machine that is
running the server.**

That last clause is not padding, and getting it wrong is how the first attempt
at this remediation failed review. **Deleting a file from this repo does not
remove it from the live box.** The deploy is additive: `mirror --reverse` runs
with `MIRROR_DELETE` defaulting to `false`
(`.github/workflows/deploy-custom-layer.yml:39` and `:148`), and
`deploy/README.md:184` says so outright. The upload overwrites the files it
carries and deletes nothing.

So a `git rm` of a hazard asset changes the repo and changes nothing on the
server. Both of the 2026-07-29 files are still in
`resources/[custom]/palm6_threads/stream/` on the host right now. Any safety
argument that ends in "the file is gone" is only true of a fresh checkout.
Safety on the live box has to come from something that positively executes (a
`stop` line in `custom.cfg`) or from content that neutralises the resource **in
place**, in a file the deploy uploads over the old one.

This repo already learned this once: `custom.cfg:307-313` force-stops
`prop_spawn` precisely because removing it from the repo did not remove it from
the box.

---

## 3. How palm6_threads is retired

It has not been deleted. It has been made inert.

### Why the directory stays in the repo

Not because deleting it would fail the audit. That reason was given in the first
draft of this document and it is **false**: a stale allowlist entry prints a
`NOTE` (`tools/audit/run.js:88-97`), and `RESULT` is computed from `failed`
alone, which only increments on `r.violations.length > 0`
(`run.js:64-65`, `:101-104`). A stale exception never fails the audit.

The real reason is the additive deploy. **The manifest is the only thing that
can neutralise this resource in place on the live box.** The deploy overwrites
`fxmanifest.lua` on the host with the retired tombstone. Delete the directory
from the repo and the deploy has nothing to upload over the old manifest, so the
box silently keeps the ORIGINAL, dangerous one, forever, next to a `stream/`
folder the deploy also will not remove. Deleting the directory would make the
live server strictly less safe while looking, in the repo, like the strongest
possible fix.

Secondary reason: the tombstone and the incident record stay where the next
worker will actually look, which is the resource directory.

### What holds the line, ranked by whether it executes

| lock | what it does | worth |
| --- | --- | --- |
| **`stop palm6_threads` in `custom.cfg:334`** | A line the server runs. `custom.cfg` execs last, after the panel's `server.cfg` ensures, and the deploy uploads `custom.cfg` verbatim (`UPLOAD_CUSTOM_CFG` defaults `true`). | **This is the lock.** The only control known to act on the live box today. Pre-existing; this work did not touch it and must not. |
| **Retired `fxmanifest.lua`** | Overwritten onto the box by the deploy. Declares no scripts, so `/threads_spike` is gone, and carries the unresolvable dependency. | Real, because it deploys in place. The in-place neutralisation. |
| **Unresolvable `dependency`** | `dependency 'palm6_threads_IS_RETIRED_DO_NOT_START'` names a resource that does not exist and must never be created. FiveM is documented to refuse a resource whose dependency it cannot resolve. | Belt, not braces. **Unverified on this build, deliberately.** The only way to test it is to start the resource, and while the host still has `stream/`, starting the resource is the outage. Never rely on it alone. |
| **Assets renamed `.RETIRED`** | The two files are kept in `retired-assets/` with an extension FiveM does not recognise as a game asset. | Protects the copies in the repo. Does nothing about the originals on the host. |
| **No `stream/` folder in the repo** | A fresh checkout, or any future host, mounts nothing. | **Not the decisive lock.** An earlier draft of this document called it that. It is false of the live box, where both files remain. |

### Outstanding: the payload is still on the host

`resources/[custom]/palm6_threads/stream/` and its two files still exist on the
live server and will survive every deploy until a human deletes them. The
runbook is `resources/[custom]/palm6_threads/HOST-CLEANUP-REQUIRED.md`. It is a
panel file-manager job on a stopped resource, it takes about two minutes, and it
restarts nothing.

Until that is done, every statement in this repo must say the payload is still
there, because it is.

**Never** remove the `stop` line, the manifest, or the tombstones. **Never** add
an `ensure palm6_threads`. If you want custom clothing, build a **new** resource
by section 6.

### Why it was retired rather than converted to an addon pack

Converting it correctly needs four things that are not in this repo, and none of
them can be produced from a text editor:

1. **A garment `.ydd` that is actually new.** The one present is Rockstar's base
   torso. An addon pack of it would add a duplicate of a garment the game
   already ships. Real geometry means Blender + Sollumz.
2. **A component `.ymt` / `SHOP_PED_APPAREL_META_FILE`.** The plan's Task 6 was
   to generate it with `gtautil genpeddefs --fivem`. **gtautil was never
   acquired** - `tools/threads-pipeline/README.md` still lists it as
   "TODO (Task 6 / Stage B)". There is no `meta/` folder in the resource.
3. **Correct addon naming, inside the binaries as well as on disk.** Both the
   file names and the internal RAGE asset names have to move into the pack
   namespace and agree with the `.ymt`. `.ydd` and `.ytd` are binary resources;
   renaming the file does not rename what is inside it.
4. **An in-game test.** There is no local FXServer. The only way to find out
   whether a pack is right is to put it on the live box, which is how this went
   wrong twice.

A half-converted addon pack fails in the same ways a replacement pack does, and
it fails less visibly. Retiring honestly beats converting half-way.

---

## 4. The streaming layout of a real addon pack

This is the shape a correct pack has. It is written down so it can be checked
against, not so it can be assembled by copy-paste. Nothing in this repo has this
shape yet.

```
resources/[custom]/palm6_pdpack/
  fxmanifest.lua
  stream/
    mp_m_freemode_01_palm6pd^jbib_000_u.ydd          -- geometry, male, drawable 0 OF THE PACK
    mp_m_freemode_01_palm6pd^jbib_diff_000_a_uni.ytd -- texture variation 'a'
    mp_m_freemode_01_palm6pd^jbib_diff_000_b_uni.ytd -- texture variation 'b'
    mp_f_freemode_01_palm6pd^jbib_000_u.ydd          -- the female body is a SEPARATE asset set
    mp_f_freemode_01_palm6pd^jbib_diff_000_a_uni.ytd
  meta/
    mp_m_freemode_01_palm6pd.meta                    -- SHOP_PED_APPAREL_META_FILE
    mp_f_freemode_01_palm6pd.meta
```

Reading the male `.ydd` filename left to right:

| segment | meaning |
| --- | --- |
| `mp_m_freemode_01` | the ped model the garment is built for |
| `_palm6pd` | **the pack namespace. Its absence is what broke production.** |
| `^` | separator between ped/pack and asset |
| `jbib` | the component slot's RAGE asset name. **Do not hand-type this.** See the warning below. |
| `000` | index **within this pack**, not the global drawable index |
| `_u` | uniform/"universal" race suffix on the geometry |
| `diff` / `_a_uni` | on a `.ytd`: diffuse map, texture variation letter `a` |

> **Never hand-name a garment file.** The slot segment (`jbib` here) is a RAGE
> asset name, not the component number, and the two do not look anything alike.
> Get it wrong and the engine binds your garment to a different component than
> you intended: the pack passes every headless check, the file looks right, and
> in game the wrong body part changes or nothing appears at all. That is the
> same failure mode as an invented drawable index.
>
> The pack tool (grzyClothTool / Durty Cloth Tool, section 6 step 3) emits these
> names itself from the component you select in its UI. Let it. Then **read the
> names back off what the tool produced** and check them against the `.meta` it
> wrote, rather than checking them against any table in this document.
>
> An earlier draft of this section pointed at the section 5 table as the
> authority for this segment, and that table had the wrong name on one slot.
> The names have been removed from it rather than corrected, because nobody
> here has captured them.

`stream/` is auto-mounted and needs no manifest line. The `.meta` files **must**
be declared:

```lua
fx_version 'cerulean'
game 'gta5'

data_file 'SHOP_PED_APPAREL_META_FILE' 'meta/mp_m_freemode_01_palm6pd.meta'
data_file 'SHOP_PED_APPAREL_META_FILE' 'meta/mp_f_freemode_01_palm6pd.meta'
```

Limits worth knowing before you design a pack. **None of these numbers were
measured here.** This repo has no local FXServer and nobody has profiled a pack
on the live box, so treat the shapes as real and the figures as unverified, and
confirm the current values in whichever pack tool you use before you commit to
a design.

- **Texture variations per drawable are addressed by a single letter** in the
  `_a_uni` segment, so the ceiling is the alphabet. This one is grounded: it is
  visible in the filename scheme above.
- **Drawables per component per gender are capped, and lower than you expect.**
  Pack tools warn well before the hard ceiling. Look up the current numbers in
  the tool; do not design against a figure quoted from memory.
- **`.ymt` slots are a finite, shrinking resource.** Rockstar consumes more with
  each title update, and every addon pack you ship burns one. The count is
  small enough that this matters. **Ship one pack for the whole department, not
  one per feature.** That conclusion holds whatever the exact number is.
- **Keep textures small.** For anything text-like, 512x256 is plenty. The
  retired spike's texture was 256x256 and 6 KB, which was never the problem.
- **The client texture pool is finite and shared** across clothing, vehicles and
  MLOs, and exhausting it crashes clients. A department-sized decal pack is not
  near any ceiling; one asset per hire eventually would be. This is the reason
  section 6 step 1 says pre-generate a block rather than one asset per officer.

### The rule that outranks the layout

**Never author a drawable or texture index by hand.** Not in a config, not in a
migration, not in a comment as "the one we'll use". This is the same rule as
never inventing a world coordinate, and it has the same failure mode: a number
that looks plausible produces an invisible or wrong garment, and nobody can tell
which from outside the game.

Global drawable indices are positions in a mount-ordered list of base game +
official DLC + every streamed addon pack. **Adding, removing or reordering any
pack shifts every index after it**, and a stored uniform silently becomes a
different garment. Title updates do the same.

So capture, do not author, and capture in the stable form:

```lua
-- collection-relative, survives title updates and pack additions
local collection = GetPedDrawableVariationCollectionName(ped, componentId)      -- "" means base game
local localIdx   = GetPedDrawableVariationCollectionLocalIndex(ped, componentId)
local texture    = GetPedTextureVariation(ped, componentId)

-- re-apply
SetPedCollectionComponentVariation(ped, componentId, collection, localIdx, texture, 0)
```

Validate with `IsPedCollectionComponentVariationValid` before applying, and
**skip** an invalid slot rather than applying it: invalid component data has
crashed clients.

`paletteId` is `0`. `illenium-appearance` passes `0` everywhere. The retired
`palm6_threads/client/debug.lua` passed `2`; do not copy that.

---

## 5. Component slots

These are the component **numbers**, which are what the natives take. The RAGE
asset-name abbreviations that appear in filenames are deliberately **not** listed
here. See the warning at the end of section 4: an earlier draft listed them, got
one wrong, and pointed section 4 at this table as the authority for naming
files. The tool emits those names; read them back off the tool's output.

| id | slot | uniform relevance |
| --- | --- | --- |
| 0 | head / face | never touched by a uniform |
| 1 | mask | gas mask, balaclava |
| 2 | hair | never touched by a uniform |
| 3 | torso / arms | long vs short sleeve |
| 4 | legs | duty trousers |
| 5 | bag / parachute | patrol pack |
| 6 | feet | duty boots |
| 7 | accessory (neck) | tie, radio strap |
| 8 | undershirt | the uniform shirt |
| 9 | body armor / vest | plate carrier, hi-vis, rain shell |
| 10 | decals | **patches, emblems, name tapes** |
| 11 | tops / jacket | duty jacket. **This is the slot the incident destroyed.** |

The one asset name this repo has actually observed is `jbib`, on component 11,
and it was observed the hard way: streaming `mp_m_freemode_01^jbib_000_u.ydd`
destroyed what component 11 drawable 0 resolves to, for everyone. That is a
captured fact from the incident, not a lookup. Every other slot's asset name is
uncaptured, so this document does not state one.

Props are a separate list: 0 head, 1 eyes, 2 ears, 6 watch, 7 bracelet. A prop
drawable of `-1` means "clear this prop".

**Component 10 is the correct slot for anything additive.** It is independent of
whatever an outfit is already using on the torso, jacket and vest slots, so a
decal pack ADDS capability without touching a single existing outfit. That is
the direct antidote to the 2026-07-29 incident: had the spike targeted component
10 as an addon, the worst case would have been "our decal does not show", not
"everyone's torso is gone".

**Male and female drawable index spaces are completely disjoint.** The same
integer is a different garment on `mp_m_freemode_01` and `mp_f_freemode_01`, and
the counts differ per slot. Capture every uniform twice, store the model string
with the capture, and **refuse** to apply a capture whose stored model does not
match the target ped. Do not guess and do not fall back.

---

## 6. How to add a pack, if David wants one

Honest split of who does what. Steps 1-3 cannot be done from a terminal.

**Step 1 - decide it is worth it (David).** A pack is static. Adding an officer
or changing a patch means rebuilding the `.ytd`, redeploying, and every client
re-downloading. Mitigate by pre-generating a block (say badge numbers 100-399)
rather than one asset per hire. If the answer is "we can live with the base game
plus captured outfits", stop here; that path is already working and risks
nothing.

**Step 2 - author the geometry (Blender + Sollumz, a human).** A garment that is
not a copy of a base-game garment. Export `.ydd` (+ `.yft`/`_hi` if the garment
needs them). Nobody can do this from a text editor and no amount of Lua
substitutes for it. If the pack is decals only (component 10), this step is
close to trivial: a flat decal plane and a texture. **Start there.**

**Step 3 - build the pack (grzyClothTool or Durty Cloth Tool, on Windows, a
human).** Point it at component 10, give the pack a namespace (`palm6pd`), add
one texture variation per tape/patch, and let it emit `stream/` + the `.meta`.
This is the step `gtautil genpeddefs --fivem` was supposed to do headlessly and
never did, because gtautil was never acquired. Use the GUI tool; it is the
shorter path and it writes the `.meta` for you.

**Step 4 - wrap it as a resource (agent work, safe).** `fxmanifest.lua` with the
two `data_file 'SHOP_PED_APPAREL_META_FILE'` lines, `stream/`, `meta/`. No Lua
at all. Then, before anyone ensures it, run the Part B preflight in section 8 and
verify by eye that **every** filename in `stream/` contains the pack namespace.

**Step 5 - stage it (David + one other person).** Section 8 Part B, tests 2-6.
Section 8 Part A must be complete first. Do not
put a new pack on a busy server.

**Step 6 - discover the indices (in game, David).** Wear the new garment from
the clothing store, then read back the collection name and collection-local
index with the natives in section 4. **This is the only legitimate source of
those numbers.** Whatever they turn out to be, store collection + local index,
never a bare global index.

> **There is no read-back command in this repo.** As of 2026-07-29 nothing under
> `resources/` calls `GetPedDrawableVariationCollectionName` or
> `GetPedDrawableVariationCollectionLocalIndex` (grepped; zero hits). Step 4
> above must therefore also ship a small admin-gated command that prints those
> two values for a given component, or step 6 cannot be executed at all. Name it
> in the pack's own README when you build it, and update section 8 Part B test 4
> with the real command name before handing the checklist to anyone.

**Step 7 - re-run every existing capture.** Mounting a new pack shifts global
indices. Any uniform stored as a bare global index is now wrong. This is why
step 6 says collection-relative.

---

## 7. Name and badge number on the cloth: why it is not built

David asked for the officer's name and badge number to appear on the uniform.
Taken literally, on the garment, that is not achievable safely today. The reason
is worth writing down because it is the trap the next attempt will walk into.

There is no native that draws text onto a ped garment. The mechanism people
reach for is `CreateDui` + `CreateRuntimeTextureFromDuiHandle` +
`AddReplaceTexture`. It has two independent disqualifiers:

1. **It is global, not per-ped.** `AddReplaceTexture` is keyed by
   *(texture dictionary name, texture name)* and resolves to a single engine
   texture pointer. There is no ped, entity or model argument anywhere in the
   call chain. Every draw call on the client that samples that texture gets the
   swap: the wearer, every other officer in the same garment, NPC cops, the
   clothing-shop preview. **Every officer would see their own name on every
   officer.**
2. **It is client-local and not networked.** Nothing crosses the wire. "Every
   client just runs it for every officer" does not rescue it, because all those
   calls collide on the same key and the last write wins for the whole client.

Two more reasons not to ship it: Cfx's own native documentation for
`AddReplaceTexture` and `RemoveReplaceTexture` says "Experimental natives,
please do not use in a live environment"; and the override is bound to a texture
pointer, so when the game evicts and re-streams the garment the override
silently disappears and never re-applies. Officers' tapes would vanish when they
walked out of and back into streaming range.

Ped decorations are genuinely per-ped and genuinely networked, but they
composite onto the skin and torso layer, underneath the jacket slot, so they
cannot put a tape on the outside of a duty jacket. Rejected too.

**What to do instead, in preference order:**

1. **Present the identity outside the cloth.** A nameplate on target/inspect, an
   ox_target "show badge" option, a NUI badge card, an MDT roster entry. This is
   per-officer-correct, needs no assets, and can ship today.
2. **Pre-baked decal pack on component 10.** One drawable/texture per name tape,
   selected per officer with `SetPedCollectionComponentVariation`. Component
   variation IS in the OneSync sync tree, so setting it on the owning client
   makes every other client see it for free. This is the only route that puts
   real per-officer text on the garment, and it is a static-asset build
   (section 6), not a runtime-text feature.
3. **Nothing else.** If a future design proposes runtime text on clothing,
   it must first pass section 8 Part B test 5 (cross-client visibility) and
   prove the scope claim wrong.

Note that the rank half and the season/weather half of what David asked for need
none of this. They are pure captured-outfit swaps keyed on a server-supplied job
grade and a server-supplied season, and they are unblocked today.

---

## 8. Verifying the retirement (do this now), and testing a future pack

**Part A is the retirement checklist and it is the only part that applies
today.** Part B is for whenever a real addon pack gets built; nothing in this
repo has that shape yet.

### Nothing in this document may tell you to start `palm6_threads`

An earlier draft's test 2 said, on the live server: *"In the server console:
`ensure palm6_threads`"*, to see whether the unresolvable dependency held. That
test has been **deleted**, and it must not come back. On the live box the
`stream/` folder is still present, so `ensure palm6_threads` is not a test of
the lock, it is a re-run of the 2026-07-29 outage with players connected. The
draft even pre-labelled the failure branch "not a crisis" on the false premise
that the folder was gone.

The dependency lock is therefore **unverified, permanently and on purpose.** The
only way to test it is to do the harmful thing. We accept an untested belt
because the braces (`stop palm6_threads` in `custom.cfg`) do execute, and
because Part A step 2 removes the payload the lock exists to contain.

**Never type any of these against the live server:**
`ensure palm6_threads`, `start palm6_threads`, `restart palm6_threads`.

---

## 8A. Part A - confirm the retirement holds (about 10 minutes)

Steps 1 to 3 are outside the game and change nothing except the deletion in step
2, which acts on a stopped resource. Steps 4 to 6 are in game.

### Step 1 - confirm the deploy actually landed (panel, 1 min)

Open the game panel file manager and go to
`resources/[custom]/palm6_threads/`. Open `fxmanifest.lua` and read the first
line.

- **Expected:** it begins `-- palm6_threads is RETIRED. 2026-07-29.` and further
  down there is a `dependency 'palm6_threads_IS_RETIRED_DO_NOT_START'` line.
  You should also see `HOST-CLEANUP-REQUIRED.md` and a `retired-assets/` folder
  in the directory listing.
- **If the manifest is the old one** (it will talk about overwriting the base
  male torso as though that were the plan, and there will be no
  `retired-assets/`): **the deploy has not run.** Stop here and deploy. Do not
  do step 2 yet: deleting the payload while the box still holds the original
  manifest leaves the box in a state nobody has described. The rest of the
  checklist is still safe to run, but record that the box is pre-deploy.

### Step 2 - delete the payload that the deploy could not remove (panel, 2 min)

Still in `resources/[custom]/palm6_threads/`, look for a `stream/` folder.

- **Expected: it is still there**, containing
  `mp_m_freemode_01^jbib_000_u.ydd` and
  `mp_m_freemode_01^jbib_diff_000_a_uni.ytd`. **This is not a surprise and not a
  new bug.** The deploy is additive and never deletes, so removing them from the
  repo left them here. Full explanation in `HOST-CLEANUP-REQUIRED.md`.
- **Action: delete the `stream/` folder and both files.** This is safe with
  players on. The resource is stopped by `custom.cfg`, so nothing has these
  files open and nothing is mounted from them. **Do not restart, refresh or
  ensure anything afterwards.** There is nothing to reload.
- **If the folder is already gone:** someone has done this already. Good, move
  on.
- **Do not copy the files anywhere under `resources/` first.** Byte-identical
  copies are already preserved in the repo under `retired-assets/`. A stray copy
  in any `stream/` folder is the entire bug again.

### Step 3 - confirm the resource is not running (browser, 1 min)

In a browser, open `http://<server-ip>:<game-port>/info.json` and search the
page for `palm6_threads`. This is the same read-only endpoint that was used on
2026-07-29 to discover the resource was running. It starts nothing.

- **Expected:** `palm6_threads` does **not** appear in the `resources` list.
- **If it does appear:** it is running right now. Go to the server console and
  type `stop palm6_threads`. Then check the panel's `server.cfg` for an
  `ensure palm6_threads` and remove it. Do not restart the server.

### Step 4 - the visible test: your own torso (in game, 2 min)

Join. Put on any police work outfit. Look at yourself in third person.

- **Expected:** the torso renders normally. You can see the shirt or jacket
  fabric.
- **If the torso is invisible or missing:** the payload is mounted, which means
  something started `palm6_threads` despite the `stop` line. Go to the server
  console, type `stop palm6_threads`, and look at your torso again. If it comes
  back, that confirms both the diagnosis and the fix. Then find what started it
  in the panel's `server.cfg`.

### Step 5 - the global test: someone else's torso (in game, 2 min)

Walk past any NPC cop, or any male pedestrian. You do not need a second player.

- **Expected:** their torsos render normally too.
- **Why this step exists:** the 2026-07-29 failure was global, not personal. It
  hit every male freemode ped, including NPCs and players who never ran a
  command. If step 4 looked wrong but every NPC looks fine, the problem is your
  own outfit, not a streamed replacement. If NPC torsos are also missing, it is
  the replacement, and it is the incident.

### Step 6 - re-assert the stop and read what it tells you (console, 1 min)

In the server console, type exactly:

```
stop palm6_threads
```

This is safe in both directions. Stopping an already-stopped resource does
nothing; stopping a running one is the fix. It is the same line `custom.cfg`
already runs at boot.

- **Expected:** the console reports that the resource is not running, was not
  started, or simply returns without stopping anything. **That is the pass.**
- **If the console reports that it stopped a running resource:** it *was*
  running, and steps 3 to 5 should have caught that. Something outside this repo
  started it after `custom.cfg` exec'd. Say so; that is a finding worth more
  than the rest of the checklist.

### What Part A does and does not prove

| it proves | it does not prove |
| --- | --- |
| The payload is off the host (step 2) | That the unresolvable `dependency` works. Untestable without causing harm. See above. |
| The resource is not running (steps 3, 6) | That nothing will ever start it again. Only the `stop` line and the missing payload guard that. |
| No male ped on the server has a replaced torso (steps 4, 5) | Anything about a future addon pack. That is Part B. |

---

## 8B. Part B - testing a future addon pack

Nothing in this repo has this shape yet. This is for whenever section 6 gets
done.

### Preflight, before anything is ensured

```powershell
python "<scratchpad>\luacheck.py" "C:/Users/Mgtda/Projects/Active/palm6-server/resources/[custom]/<resource>"
node "C:/Users/Mgtda/Projects/Active/palm6-server/tools/audit/run.js"
```

The audit must be **8 passed / 0 failed** before a pack is ensured. At the time
of writing the tree is **7 passed / 1 failed**: the `ensure-list` check reports
`palm6_uniform` and `palm6_insignia` as present but never ensured. Neither is
this document's doing, and neither is a clothing-streaming issue, but the gate
is the gate. Do not ensure a pack against a red audit.

Then, by eye:

- [ ] Every filename in `stream/` contains the pack namespace segment
      (`mp_m_freemode_01_<pack>^...`). If any file is `mp_m_freemode_01^...`
      with no pack segment, **stop**. That is the 2026-07-29 bug exactly.
- [ ] The resource declares a `SHOP_PED_APPAREL_META_FILE` for each gender.
- [ ] No filename matches anything that already exists in another resource's
      `stream/` folder.
- [ ] Part A above has been completed and `palm6_threads/stream/` is confirmed
      gone from the host.

### Test 1 - confirm palm6_threads is still dead (run this first, every time)

Part A steps 3, 4 and 5. Do not skip them because a pack is the interesting
part; a torso regression during pack testing is ambiguous unless you know the
baseline was clean.

### Test 2 - stage the pack, quiet server, two people

Never introduce a pack on a busy server. Restart with the pack ensured, with
David and one other person on.

- **Expected:** both spawn normally in their own clothes.
- **If either spawns with a missing or wrong garment anywhere:** the pack is
  colliding with a base asset. Stop the resource immediately and re-check the
  filenames.

### Test 3 - the pack ADDS rather than replaces

Before ensuring the pack, note what your current outfit looks like. After
ensuring it, look again.

- **Expected:** your existing outfit is pixel-identical. A correct addon pack
  changes nothing you were already wearing.
- **If anything you were already wearing changed:** it is a replacement pack.
  Stop it. Do not "test further".

### Test 4 - the new garment exists and is reachable

> **Precondition: this test needs a read-back command, and no such command
> exists in this repo.** Nothing under `resources/` calls
> `GetPedDrawableVariationCollectionName` or
> `GetPedDrawableVariationCollectionLocalIndex` (grepped 2026-07-29, zero hits).
> Section 6 step 4 must ship one with the pack. **Write its real name into this
> test before handing this checklist to anyone**, and delete this box. Until
> then the second half of this test cannot be executed, and saying so is the
> point: an unexecutable step in a checklist is worse than a missing one.

Go to a clothing store, find the new garment, wear it. Then, if the read-back
command exists, run it for the component the pack targets and read what it
reports.

- **Expected, no command needed:** the garment appears in the store list for
  your gender and can be worn.
- **Expected from the read-back:** a non-empty collection name (the pack) plus a
  collection-local index. Write those down; they are the only legitimate source
  of those numbers.
- **If the collection name is empty (`""`):** you are wearing a base-game
  garment, not yours. The `.meta` did not register.
- **If the garment is not in the store at all:** the `.meta` did not register,
  or it is registered for the other gender.

### Test 5 - cross-client visibility

David wears the new garment. The second player must see it correctly **without
running any command**, from a distance and up close.

- **Expected:** identical on both screens.
- **If the second player sees a blank, a wrong garment, or the base torso:** the
  pack did not stream to them, or the index was resolved against a different
  collection set. Do not ship.

### Test 6 - no collateral

Walk past NPC cops. Open the clothing store and scroll the torso list. Look at
other players.

- **Expected:** nothing anyone else wears has changed.
- **If an NPC or another player is wearing your asset:** something is replacing
  a shared base asset. Stop the resource.

### Test 7 - stored outfits survive the new pack

Mounting a pack shifts global drawable indices, so any outfit stored as a bare
global index is now wrong.

> **What "every capture" means depends on what has been built.** As of
> 2026-07-29 no resource in `resources/` stores a captured outfit, so there is
> nothing to re-run and this test is a no-op. Once a uniform resource exists,
> replace this box with its actual command names and its actual storage
> location (table or file), so this step names something a person can do.

Procedure, once there is something to test: for each stored outfit, wear it,
log out, log back in, and wear it again.

- **Expected:** identical outfit before and after the relog, and identical to
  what it looked like before the pack was mounted.
- **If it changed:** something stored a bare global index instead of collection
  plus local index. Fix the storage, not the number. Re-storing the shifted
  index just moves the failure to the next pack.

---

## 9. Quick reference: what is banned

- Any file in a `stream/` folder whose name lacks a pack namespace segment.
- Any `data_file` that points at a base-game meta path.
- `AddReplaceTexture` against a base-game clothing texture, for any reason.
- Authoring a drawable, texture or prop index by hand in config, code or SQL.
- Storing a bare global drawable index instead of collection + local index.
- Applying a capture taken on `mp_m_freemode_01` to `mp_f_freemode_01`, or vice
  versa.
- `ensure palm6_threads`, `start palm6_threads`, or `restart palm6_threads`,
  for any reason including "to test the lock". See section 8.
- Treating `Config.Enabled = false` as protection for a resource that streams.
- Testing a new pack for the first time on a populated live server.
- **Claiming a hazard file is gone because it was deleted from the repo.** The
  deploy is additive and deletes nothing on the host. A file is gone when
  somebody has looked at the server's filesystem and seen that it is gone.
- **Deleting a retired resource's directory from the repo.** The deploy can only
  neutralise a resource in place by overwriting its files. Delete the directory
  and the box keeps the old, dangerous manifest with nothing to replace it.
- Any checklist step that instructs a tester to run a command whose failure mode
  is the outage the checklist is verifying.
- Any checklist step naming a command that does not exist in the tree.
