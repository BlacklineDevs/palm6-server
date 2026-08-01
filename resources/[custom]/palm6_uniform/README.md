# palm6_uniform

Rank and season driven police uniforms, worn from a **walk-up wardrobe at the
police station**.

An officer's uniform follows their **grade** (a promotion re-dresses them with no
relog) and the **season / weather** (a winter coat, a rain shell, a short-sleeve
summer shirt). Every one of those uniforms is a **photograph of an outfit David
actually wore in game**, not a set of numbers anybody typed.

---

## The walk-up wardrobe

**This is the interface. Nothing in the normal flow requires typing anything.**

Walk to the police station. At the duty point there is a wardrobe: an
`ox_target` eye if `ox_target` is running on the box, otherwise a proximity
prompt that says `Press E Station Wardrobe`. Interact with it and an `ox_lib`
menu opens listing the uniforms **this officer is allowed to wear**. Click one.
The clothes change.

| in the menu | what it does |
|---|---|
| the uniform rows | Apply that uniform. Each row names its rank floor, season and weather, and marks the one the server would pick automatically and the one you already have on. |
| **Back to my own clothes** | The civilian restore. Greyed out with a reason when this wardrobe has not changed you. |
| **Save what I am wearing as a uniform** (admin) | Two clicks: pick the rank, pick the conditions. Whatever the ped has on becomes that uniform. This is how uniforms get created and it needs no command. |
| **Randomise my clothes** (admin) | The visible-change test tool, so a uniform swap is actually visible. |
| **Read out what I am wearing** (admin) | Prints the twelve components and five props. Stores nothing. |
| **Move this wardrobe to where I am standing** (admin) | Repositions the point at runtime and prints the exact config line to keep it. |

### Where the wardrobe is, and why nobody typed it

**No world coordinate is authored in this resource.** The position is read at
runtime, on the server, from the resource that already owns where the police
station is:

```
qbx_police_overrides/config.lua:61-65     Config.DutyToggle
    label  = 'Mission Row PD - Duty'
    coords = vector3(442.32, -988.43, 30.69)
    radius = 1.0

qbx_police_overrides/server/overrides.lua:45
    exports('GetDutyToggle', function() return Config.DutyToggle end)
```

`palm6_pd_life/bridge/sv_framework.lua:72-83` reads the same export the same
way, for the same reason. That export is **server realm** (that resource
declares no client script), which is why the server resolves the point and
pushes it to clients rather than clients reading it.

Order of resolution, reported at boot and in `/uniformstatus`:

1. a runtime move made from the menu itself;
2. `qbx_police_overrides:GetDutyToggle()`;
3. `Config.Wardrobe.FallbackCoords`, which is a **verbatim copy** of the coords
   line quoted above and says so in its comment.

The contract's own radius is `1.0`, an `ox_target` radius. It is widened to
`Config.Wardrobe.MinRadius` for a walk-up, which is a derived bound and not an
invented position, exactly as `palm6_pd_life/shared/config.lua:49` does.

**If the wardrobe is in the wrong spot, do not guess a number.** Walk to the
right spot and use *Move this wardrobe to where I am standing*. It prints the
`vector3(...)` line to paste into `Config.Wardrobe.FallbackCoords` if it should
survive a restart.

### The empty state is the most important screen

A wardrobe with nothing captured and a wardrobe that is broken look identical
from in game. So the menu is **never blank**. With nothing captured it says:

> **No uniforms have been captured yet.**
> This wardrobe is working. It is empty. A uniform here is a photograph of an
> outfit somebody actually wore in game, so until somebody captures the first
> one there is genuinely nothing to put on.

and, to an admin, the exact click path underneath it:

> **To create the first one, right here, with no typing:**
> 1. dress this character however the rank should look. 2. come back here and
> pick "Save what I am wearing as a uniform". 3. pick the rank. 4. pick the
> conditions.

and, to anyone else, who can do it and which permission it needs.

### Every failure says why, in the menu or as a notify

| what stops you | what you see |
|---|---|
| not on the police job | a row naming the job it wants and the job you have |
| your ped is not freemode | a row explaining that captured indices belong to the two freemode bodies |
| nothing captured at all | the empty state above |
| sets exist but none for your rank or body | a row saying how many are stored and why none of them is yours |
| nothing to restore | the restore row is greyed out and says why |
| already wearing it | a notify before the apply, so the zero-slots-changed message is expected |
| picking something above your rank | a notify naming the id, your job and your rank |
| the server does not answer | a menu row saying **the server did not answer**, plus a notify. Never mistaken for an empty wardrobe |
| `ox_target` absent | the wardrobe degrades to an `E` prompt, and the menu footer says which route this client used |
| `ox_lib` menu absent | a notify pointing at `/uniform` and `/uniformoff` |

### Server authority, with a menu in front of it

The menu is a **view**. The server builds every row, and it re-derives the
job, grade and ped model from `qbx_core` on **every pick**, checking the chosen
id against a permitted list computed at that moment. A modified client that
sends the chief's set id as a cadet is refused by name. See `allowedSets` and
`menuApply` in `server/main.lua`; `tests/suites/12_uniform_wardrobe_menu.lua`
pins both.

---

## The rule this resource exists to obey

**Not one drawable or texture id is authored anywhere in this repo.**

A drawable index is a position in a mount-ordered list: base game, plus official
DLC, plus every streamed clothing pack on the box, in mount order. An id that
looks plausible from outside the game renders as the wrong garment or as nothing
at all, and there is no way to tell which from here. This is the same class of
rule as never inventing a world coordinate.

So the flow is: **dial the look in, in game, then run a command that stores
exactly what you are wearing.** The only integers in the source are engine
constants (which component slots exist) and validation bounds.

This resource also **streams nothing and replaces nothing**. There is no
`stream/` folder, no `data_file`, no `SHOP_PED_APPAREL_META_FILE`. It reads and
writes component variations on the local player's own ped and that is all.
`palm6_threads` is the cautionary tale it was written against: that resource
overwrites the base game's male jbib drawable 0, which made every police work
outfit render as nothing for everyone on the live box. `custom.cfg` force-stops
it. If custom clothing is ever added to Palm6 it must be an addon-DLC pack in
its own resource, never a replacement, and never in this one.

---

## The capture workflow

This is the whole feature. Everything else is plumbing. **All of it is done from
the wardrobe menu; the commands in the appendix do the same things and are a
fallback.**

> **The one ordering mistake that makes this look broken.** A uniform swap is
> only visible if the uniform is different from what you are already wearing.
> Capture the outfit you are standing in and then put it on, and the server
> correctly picks that set, the client correctly writes it, and **nothing moves
> on screen** because every slot already held those numbers. Both steps report
> success. That reads as a dead resource and it is not one.
>
> Two things guard against it. The workflow below puts a clothing change
> *between* the capture and the apply. And if you do it in the wrong order
> anyway, the apply says so out loud: *"applied, but you were already wearing
> every slot of it, so nothing changed on screen."*

1. Get on the **police** job and pick a **male** character.
2. Dress the character exactly how that rank should look, in whatever clothing
   menu the box runs. Stand still and let the clothing finish streaming.
3. Walk to the station wardrobe and open it. Pick **Read out what I am
   wearing**. You get a printed list of the twelve components and five props,
   and a count of how many component slots are non-zero. **Nothing is stored.**
   If it says `0 of 12 component slots are non-zero`, your ped had not finished
   streaming. Walk a few metres and read it again; capturing a wall of zeros
   stores "wearing nothing" as a uniform.
4. Pick **Save what I am wearing as a uniform**, then the rank, then **Start
   here: All year round, any weather**.

   The rank you pick is a **floor**. That set now dresses that grade **and every
   grade above it** until a higher capture overrides it. One capture dresses the
   whole department. The label is composed for you from the real rank name, so
   there is nothing to type.
5. **Change out of it before you test it.** Either go back to the clothing menu
   and put your own clothes on, or pick **Randomise my clothes** in the
   wardrobe, which randomises what you are wearing (face and hair untouched)
   using the variations the engine reports as valid for your ped. No clothing id
   is authored by it. This step is not optional if you want to *see* step 6
   work.
6. Open the wardrobe again and click the uniform row. You should visibly snap
   back into the outfit captured in step 4, and the notify tells you how many
   slots changed.
7. **Back to my own clothes** puts back what you were wearing before this
   resource touched you.
8. Switch to a **female** character, dress her the same way, and capture again.
   The stored numbers will be different, and they have to be. See "Male and
   female" below.
9. Add overrides only where you want a visible difference: capture again at a
   higher rank, or with a season or weather variant, from the same two-click
   menu. Every extra variant then shows up as its own row in the wardrobe for
   anyone entitled to it.

   To feel-test a season without waiting for the calendar, pin the variant at
   runtime with `/uniformseason winter`, open the wardrobe, then
   `/uniformseason auto`. **Do not edit `Config.SeasonOverride` and restart the
   resource to do this** - a restart wipes every client's in-memory record of
   their own clothes, and whoever is in uniform at that moment gets *"No
   civilian outfit was recorded this session"* from the restore with no in-game
   way back.

After **any** change to the clothing packs on the box, **re-run every capture**.
Indices shift and a stored set silently becomes a different garment. Nothing can
detect that from outside the game.

**The step-by-step walk-up test, with what you should see at each point, is
[CHECKLIST.md](CHECKLIST.md).**

---

## Appendix: the commands

**These are the fallback, not the feature.** Every one of the normal steps above
is a click in the wardrobe menu. The commands stay because a chat command works
from anywhere on the map, works with no `ox_target`, works with no `ox_lib`
menu, and is the only route left if the wardrobe position itself cannot be
resolved.

| command | who | what it does |
|---|---|---|
| `/uniformcapture <grade> <season> <weather> [label]` | admin ACE **and** police | Stores what you are wearing right now as the uniform for that grade and up, on your current body, for that variant. Overwrites an existing row with the same key. Cannot be run from the console: it photographs a ped. The wardrobe menu does the same thing with two clicks and composes the label for you. |
| `/uniformshow` | admin ACE | Prints what you are wearing, plus how many slots are non-zero. Stores nothing, and deliberately does **not** require the police job, because it is a read. |
| `/uniformscramble` | admin ACE | Randomises your own clothes so a uniform swap is actually visible. Face and hair untouched. Authors no clothing id: the engine picks from the variations it reports as valid for your ped. |
| `/uniformseason <any\|winter\|spring\|summer\|autumn\|auto>` | admin ACE | Pins the season at runtime and re-dresses every on-duty officer. `auto` hands it back to the date schedule. **No restart**, which is the point. |
| `/uniformweather <any\|wet\|cold\|hot\|auto>` | admin ACE | The same for the weather bucket. |
| `/uniformlist` | admin ACE | Every stored set, plus which one **you** would get right now. |
| `/uniformdelete <id>` | admin ACE | Deletes one set. Ids come from `/uniformlist`. |
| `/uniformstatus` | admin ACE | The meter: enabled, schema, set count, current season and where it came from, current weather bucket and where it came from, **where the wardrobe is and which of the three sources answered**, whether the admin ACE is actually granted, and the client-side appearance-resource state. |
| `/uniform` | police | Re-apply my uniform. The **server** decides which one that is. Same as clicking the recommended row in the wardrobe. |
| `/uniformoff` | police | Back into the clothes you were wearing before this resource changed them. Same as **Back to my own clothes**. |

`<season>` is one of `any winter spring summer autumn`.
`<weather>` is one of `any wet cold hot`.

All ten are `RegisterCommand(..., restricted = false)` and check their gate
**inside the handler**, server-side. That is deliberate: a
`RegisterCommand(..., true)` with no `add_ace` line is runnable by `group.owner`
and by nobody else, which silently locks out every admin.

It has a cost, and the cost is paid for explicitly. Because none of them is
*restricted*, the repo audit's `command-aces` invariant cannot see a missing
`add_ace group.admin command.uniformcapture allow`: that check only reconciles
restricted commands against grants. So the resource checks the grant itself at
boot with `IsPrincipalAceAllowed` and prints the exact missing cfg line in red,
and `/uniformstatus` reports it too. It reads the ACE table; it never writes to
it. `custom.cfg` is the only authority for grants.

**Every refusal in this resource says so.** Not one command, and not one net
event handler, drops a call in silence. That includes the rate limits: if a
cooldown bites you get `Too fast: /uniformcapture is rate limited to one call
every 3 second(s). Try again in 2.` A silent drop is indistinguishable from a
broken command, and it gets reported as one. The single exception is the
client's own automatic `requestApply` on spawn, which is not a person typing
anything, and answering it would let a modified client spam its own chat.

---

## What applies the uniform automatically

| trigger | event hooked | requires |
|---|---|---|
| going **on duty** | `QBCore:Server:SetDuty` | police |
| **promotion / demotion / job change** | `QBCore:Server:OnJobUpdate` | police, on duty |
| **multi-job add or remove** | `qbx_core:server:onGroupUpdate` | police, on duty |
| **spawn / relog** | client raises `palm6_uniform:requestApply` | police, on duty |
| **season or weather bucket change** | internal tick, `Config.VariantTickSeconds` | police, on duty |

Going **off duty** restores the civilian look. So does leaving the police job.

All five automatic paths require the player to be police **and** on duty. The
manual `/uniform` requires police but not duty, because it is the officer's own
explicit request.

Every one of the three job-change hooks uses `AddEventHandler`, never
`RegisterNetEvent`. qbx_core raises them server-side with `TriggerEvent`, so
`AddEventHandler` is sufficient, and `RegisterNetEvent` would make a
framework-internal name network-addressable for every listener on the box. Do
not "fix" that. `palm6_eventguard/config.lua` documents the same hole being
closed in `palm6_whitelist_jobs` and `palm6_onboarding`.

---

## Server authority

The client can say exactly two things:

- "here is a photograph of the ped I am standing in, taken against the
  single-use token you just gave me", and
- "please dress me".

It cannot say which job it has, which grade it holds, which body it is wearing,
what the season is, or which uniform it wants. All of that is answered from
`qbx_core` and the server clock. A modified client that shouts *apply the
captain uniform* gets whatever its real grade is entitled to, which for a
civilian is nothing at all.

Three specifics worth calling out:

- **The model is confirmed server-side.** `Bridge.GetPedModelName` reads
  `GetEntityModel(GetPlayerPed(src))` on the server. A capture whose claimed
  model disagrees with the server's read is dropped and logged, so a client
  cannot poison the female rows with male drawables.
- **The capture token is server-minted and single-use.** An unsolicited
  `palm6_uniform:captured` has no pending token and is discarded on arrival.
- **Payloads are rejected, never clamped.** An out-of-range drawable means a
  modified client; "fixing" it would persist a fabricated garment as if David
  had worn it.

---

## Selection: which set does an officer get?

Given a real officer (job, grade, ped model) and the current (season, weather
bucket), the server scores every stored row:

1. Rows for a different job or a different **model** are out.
2. Rows whose `min_grade` is above the officer's grade are out.
3. A row matches a variant if it is an exact match **or** `any`. A row that
   names a *different* season or weather is out.
4. Of what is left: **highest `min_grade` wins first**, then the more specific
   variant.

**Rank dominates season, on purpose.** A sergeant in a season with no sergeant
set captured wears the sergeant's all-season uniform, not the rookie's winter
coat. Dressing an officer below their rank is a worse error than dressing them
for the wrong weather.

**If nothing matches, nothing is applied.** No default garment, no substitute
rank, and never half a set. The officer is told what is missing and keeps what
they had on. On the client side the whole set is validated with
`IsPedComponentVariationValid` **before the first component is written**, so one
bad slot aborts the entire apply rather than leaving an officer in a duty jacket
and no trousers.

---

## Season and weather

**GTA V and FiveM have no built-in concept of a season. None.** There is no
season native, no season event, no season field. The closest thing is the
in-game calendar (`GetClockMonth`, client realm, 0-indexed) and it is not usable
here for two independent reasons: it is client realm, so a modified client could
report any month and dress itself in whatever it liked; and the weather-sync
resources that run on this kind of box only ever call
`NetworkOverrideClockTime(hour, minute, second)` and never `SetClockDate`, so the
in-game date is unmanaged and drifts. It is display flavour, not state.

So the season is **derived server-side from the real-world date using a config
schedule**: `Config.SeasonByMonth` in `shared/config.lua`, northern-hemisphere
meteorological seasons keyed by `os.date('%m')`. That is stated in the config
comment, in the migration header, and in the `/uniformstatus` output, because it
is a design decision rather than a fact about the game.

To feel-test the winter uniform in July instead of waiting five months, use
`/uniformseason winter` and `/uniformseason auto`. That is a **runtime** pin: no
restart, and it re-dresses every on-duty officer immediately.

`Config.SeasonOverride` and `Config.WeatherOverride` still exist, but they are
only the **boot defaults** for those runtime pins. Do not reach for them to run
a test: changing them needs `restart palm6_uniform`, and a restart wipes every
client's in-memory record of their own clothes plus this resource's `dressed`
table. Anyone standing in uniform at that moment gets *"No civilian outfit was
recorded this session"* from `/uniformoff` and has no in-game way back out. A
feel-test must not be able to strand the person doing it.

**Weather** is a real game concept, but every weather native is client realm and
a client-reported weather value is untrusted. The server reads it from the
weather resource's **server** export (`getWeatherState()`), soft-called against
`qbx_weathersync` then `qb-weathersync`. Neither is in this repo, so absence is
a degrade, not a failure: with no weather resource everybody resolves to the
`any` bucket and wears the season set. `/uniformstatus` says which happened.

`Config.WeatherBuckets` names **eight** weather strings and maps them to three
buckets. GTA V has more weather names than that, and every one that is not
listed falls through to `any` on purpose: only weather extreme enough to justify
a different garment gets its own bucket, because a bucket per weather name would
mean a capture per name per rank per body, which nobody would ever finish.
`CLEARING -> wet` is a judgement call rather than a fact about the game, and the
config comment says so.

---

## Male and female

`mp_m_freemode_01` and `mp_f_freemode_01` have **completely disjoint drawable
index spaces**. The same integer is a different garment on each body, and the
per-slot counts differ.

So the ped model is stored with every capture, it is part of the unique key, and
both the server and the client refuse to apply a set whose model does not match
the wearer. **Every uniform has to be captured twice.** That is not a limitation
of this resource, it is how the game works. If a male and a female capture come
back with identical numbers, something is wrong, not convenient.

The model is read off the **ped**, never from `charinfo.gender`. There are three
disagreeing sources of "gender" on a Qbox box and only the ped model is the
thing a drawable index actually belongs to.

---

## Face, hair, and the civilian look

- **Components 0 (face) and 2 (hair) are never written.** They are captured, so
  a stored row is a complete record of the ped, and skipped on apply. A uniform
  changes what an officer wears, not who they are.
- **The civilian outfit is snapshotted client-side, in memory, at spawn, before
  the server is asked to dress anybody** and put back on `/uniformoff` or on
  going off duty. It is deliberately never sent to the server and never written
  to a database. This resource **cannot** overwrite a saved appearance row,
  because it never writes one. The classic data-loss bug in job outfit scripts
  is saving the uniform as the player's permanent skin; there is no code path
  here that can.
- **The snapshot survives death, and is discarded only on a character load or a
  ped-model change.** `playerSpawned` fires on every respawn, not only on a
  join, so the first version of this file threw the snapshot away every time an
  officer died. The server re-dressed them five seconds later and the next
  snapshot taken was *of the uniform*, so `/uniformoff` put the uniform back on
  and announced "Back in civilian clothes." Police die routinely; that would
  have surfaced on day one. `QBCore:Client:OnPlayerLoaded` (a character load) is
  now hooked separately from `playerSpawned` (a join or a respawn), and a new
  snapshot is only ever taken when this resource has not already changed your
  clothes.
- Cost of that choice: a resource restart or a relog forgets the snapshot. If
  that happens mid-shift, `/uniformoff` says it has nothing to restore instead
  of guessing. This is exactly why the season and weather pins are runtime
  commands rather than config edits.

---

## illenium-appearance is optional

It is not in this repo, and its manifest declares `version "main"`, so there is
no version string to gate on. This resource **capability-probes** it instead:
state must be `started`, and each getter must survive one `pcall`. Setters are
never probed (there is no safe no-op write) and are `pcall`-guarded at the call
site.

The raw natives are the **primary** path and illenium is an accelerator, because
illenium's `getPedComponents` / `setPedComponents` are literal
`GetPedDrawableVariation` / `SetPedComponentVariation` round-trips and produce
byte-identical output. A fork swap, a downgrade, or a switch to a different
appearance resource breaks nothing here.

An accelerator result is also **checked for completeness before it is
accepted**. A fork returning a *shorter* list would otherwise be stored as a
whole uniform: the missing slots are simply never written on apply, so the
officer keeps whatever was in them, and the row claims to be something it is
not. If any component or prop slot is missing, the accelerator result is
discarded and the raw natives run instead. The server re-checks the same thing
in `validateCapture` and rejects an incomplete payload by name
(`capture is incomplete: component slot N is missing`), because the client is
not evidence of anything.

This resource never routes through illenium's outfit or uniform **persistence**
plumbing (`changeOutfit`, `loadJobOutfit`, `syncUniform`). That is on purpose:
those paths can overwrite a player's saved skin and have two mutually
incompatible payload shapes for the same event. Direct component writes bypass
persistence entirely and cannot corrupt anything.

---

## The table

`palm6_uniform_sets`, self-creating at boot, with the identical DDL in
`sql/0076_uniform.sql`. Keep the two copies verbatim.

| column | meaning |
|---|---|
| `id` | surrogate key, quoted by `/uniformlist` and `/uniformdelete` |
| `job` | always `police` today. The column exists so a second department is a config change, not a migration |
| `min_grade` | inclusive **floor**. Grade G wears the highest `min_grade <= G` |
| `model` | `mp_m_freemode_01` or `mp_f_freemode_01` |
| `season` | `any` / `winter` / `spring` / `summer` / `autumn` |
| `weather` | `any` / `wet` / `cold` / `hot` |
| `label` | free text shown in `/uniformlist` and in the apply notify |
| `components_json` | `[{component_id, drawable, texture}, ...]`, ids 0-11 |
| `props_json` | `[{prop_id, drawable, texture}, ...]`, ids 0,1,2,6,7. Drawable `-1` clears the prop |
| `captured_by` | citizenid of whoever ran the command, for audit. Nullable |
| `captured_at` | when |

`UNIQUE KEY (job, min_grade, model, season, weather)` - re-capturing the same
combination overwrites it rather than growing a second row.

Losing the whole table costs the captured uniforms and nothing else. The
resource recreates it empty at boot, every officer keeps their own clothes, and
the fix is to re-run the captures.

---

## Orchestrator asks (files this resource does not own)

**Until the first of these is applied, this resource does not run at all.**
`/uniform` answers `Unknown command`, no boot banner prints, and every other
line in this README describes something that is not happening. The repo audit
fails `ensure-list` for exactly that reason, and it is the first thing
[CHECKLIST.md](CHECKLIST.md) has you confirm.

**custom.cfg** - one ensure and one ACE grant:

```
ensure palm6_uniform
add_ace group.admin command.uniformcapture allow
```

The `ensure` must come **after** `ensure palm6_eventguard` (`custom.cfg:112`) so
the guards register first in the handler chain; next to `ensure palm6_pd_life`
(`custom.cfg:172`) keeps it with the police resources. The `add_ace` belongs
with the other grants near `custom.cfg:481`.

One ACE grant covers the whole admin family (`/uniformcapture`, `/uniformshow`,
`/uniformscramble`, `/uniformseason`, `/uniformweather`, `/uniformlist`,
`/uniformdelete`, `/uniformstatus`) because all of them self-check the same
string, which is the shape `custom.cfg` already uses for the `/placeped` family
and for `/bizshell`.

The audit only enforces the **ensure** line. The `add_ace` line is structurally
invisible to it (see the note under Commands), so the resource enforces that one
itself: a red `ACE MISSING` block naming the exact line prints at boot, and
`/uniformstatus` reports the grant state in game.

**palm6_eventguard/config.lua** - two budgets:

```lua
['palm6_uniform:captured']        = { calls = 10, window_seconds = 60 },
['palm6_uniform:requestApply']    = { calls = 10, window_seconds = 60 },
['palm6_uniform:menuAction']      = { calls = 30, window_seconds = 60 },
['palm6_uniform:wardrobeRequest'] = { calls = 10, window_seconds = 60 },
```

The first two are tight on purpose. `captured` only ever fires in reply to a
server-minted single-use token held by an admin, and `requestApply` fires once
per spawn. `menuAction` is looser because it is the click channel: an officer
opening the wardrobe, trying two uniforms and restoring is four calls in ten
seconds and none of that is abuse. `wardrobeRequest` fires on spawn.

All four already carry their own in-handler per-source rate limit
(`Config.RateLimits`); these budgets are the blunter outer bound that runs
first. Nothing in this resource depends on them being present.

---

## What this resource does NOT do, stated plainly

**It does not put the officer's name and badge number on the cloth.** That half
of the request is a different problem with a different answer, and it is not
solvable the way it sounds:

- There is no native that draws text onto a ped garment.
- The `CreateDui` + `AddReplaceTexture` trick people reach for replaces a
  texture **by name**, globally, on the local client. It is not per-ped and not
  networked. Every officer near you would render **your** name on their own
  uniform. Cfx's own docs label both natives "Experimental natives, please do
  not use in a live environment."
- Ped decorations are genuinely per-ped and genuinely synced, but they composite
  onto the skin and `uppr` layer. They will not put a tape on the outside of a
  duty jacket.

The only route that is per-ped **and** natively synced is a pre-generated
addon-DLC decal pack on component 10, one drawable/texture per name tape,
selected per officer. That is a static-asset build with an artist and a
redeploy per block of badge numbers, and it belongs in its own resource.

What component 10 **can** carry today, through this resource, with no new
assets: a generic department patch or a rank chevron, captured exactly like any
other slot. Capture it on the ped and it ships with the set.

---

## Verification

Static gates, run from the repo root:

```
python <scratchpad>/luacheck.py "C:/Users/Mgtda/Projects/Active/palm6-server/resources/[custom]/palm6_uniform"
node tools/audit/run.js
cd tests && node run.js
```

`tests/suites/12_uniform_wardrobe_menu.lua` runs the **real** `allowedSets`,
`captureVariants` and `composeLabel` through a Lua VM (the production bytes are
lifted by anchor, so moving the code fails the suite rather than testing a stale
copy) and additionally pins the promises this interface is built on: that the
empty state still says what it says, that every menu row carries a description,
that a pick is re-authorised server-side against a freshly computed permitted
list, and that the station coordinate appears in exactly one file with a comment
citing where it was copied from.

None of that proves the feature works in game. It proves the Lua parses, the
repo's invariants hold, and the selection logic answers correctly. **The walk-up
test is the part that actually proves this works, and only David can run it:
[CHECKLIST.md](CHECKLIST.md)**, in this directory. It contains no step that
restarts a resource, no step that ensures `palm6_threads`, and no step that
requires typing a command.
