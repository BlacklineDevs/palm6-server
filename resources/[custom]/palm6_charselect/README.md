# palm6_charselect

Premium character selection / spawn screen shown right after the FiveM
loading screen. Dark navy/gold/cyan brand, live blurred world background
(real 3D game view behind the CEF surface, blurred only where it passes
through a card via `backdrop-filter` — not a captured image), staggered
card entrance, hover-tilt cards, cinematic camera on select.

`qbx_core` remains the sole source of truth for character slot data
(citizenid, name, job, playtime, last-played) and the sole writer of the
`players` table. This resource is a skin over qbx_core's login/creation
flow, not a fork of it.

## Audit follow-up (2026-08-06) — the trust boundary, the stage, and the bail-out

Six defects from the 28-defect multi-agent audit landed in this resource.

**`confirmSelect` no longer takes an argument.** It used to accept the
citizenid as an event payload and, having proved only that *some* character
was loaded (`Bridge.IsPlayerLoaded`), write it into
`palm6_charselect_playtime`. Every other write path here goes through
`Bridge.OwnsCharacter` / `Bridge.FilterOwned`; this was the one that gated
nothing, and the length was unchecked against a `VARCHAR(50)` column reached by
a bare `MySQL.query.await` on a `while true` thread — one crafted event
permanently killed the periodic flush for *every* player until restart. It now
reads the citizenid from `Bridge.GetLoadedCitizenId`, i.e. off qbx_core's own
loaded player object, so ownership and length are settled by construction.
**Do not add a citizenid parameter back to this event.**

**`confirmCreate` is new, and the create path now waits for it.** Sessions are
only ever started by a confirm handler and the create path fired none, so a
brand-new character's entire first session banked as zero. It also went
straight into the teardown, the appearance editor and a spawn on the assumption
that `Game.CreateCharacterViaQbx` returning meant qbx_core had logged the
player in — it communicates neither success nor failure to its caller. The
teardown/hand-off now lives in the `createAccepted` handler, and a failure
arrives on `palm6_charselect:error` instead.

**Playtime flushing is reentrancy-safe.** `flushSession` advances
`session.since` (or clears the session) *before* the yielding
`Bridge.AddPlaytime`, because anything landing during that await otherwise
recomputes the same elapsed and writes it a second time — client-triggerable by
bursting confirm events. The periodic flush iterates a **snapshot** of the keys
rather than `pairs(sessions)` directly (it yields, and `confirmSelect` inserts
keys while `playerDropped` deletes them — undefined per the Lua manual, and
`invalid key to 'next'` would kill the thread that is this feature's only
durability guarantee) and `pcall`s each flush.

**The stage has exactly one driver: NUI focus.** Lua used to stage
`previewable[1]` — the first character *with* an appearance, which on a mixed
roster is not the first *card* — while the NUI focused card 1, painting one
character's medallion and "No saved appearance" note over another character's
live ped. Moving focus onto a character without an appearance posted nothing at
all, so the old ped stayed lit while the nameplate and rail switched. Now:
`focusRow` always posts `previewCharacter`, Lua answers `live = false` (and
destroys the ped) when it has nothing to stage, and the NUI matches answers
against the citizenid of the request it last *sent*, so a slow spawn for a
character you have already arrowed past is discarded.

**A stage spawn cannot outlive the scene.** `Game.SetStageCharacter` yields on
a ground probe (up to 2s) and a model load (up to 5s); pressing PLAY inside
that window tore the scene down and then let the suspended spawn create a ped
that nothing destroyed, plus a `Wait(0)` turntable thread whose own generation
guard could never go false. The cancellation token is now passed *into* the
bridge and re-checked after every yield, alongside a `sceneTornDown` flag that
every teardown path sets and `SetupScene` clears. The final check happens
**after** the ped is assigned to `stagePed`, so `DestroyStagePed` can reach the
handle — checking before assignment would orphan it just the same.

**`/palm6charselect_release` rescues instead of worsening.** It calls
`exports.palm6_appearance:forceCloseEditor()` *first* (the likeliest moment to
need rescuing is mid-creation, which is inside that resource — and NUI focus
and `RenderScriptCams` are global, so releasing them here stripped that
editor's cursor and camera while it still rendered full-screen, with no cancel
and no Escape). The server now also tells the client whether qbx_core has a
character loaded, because that decides what the rescue may do: spawn if
loaded; reopen character select if not. **Never spawn the not-loaded case** —
`Game.SpawnAtPosition` fires `QBCore:*:OnPlayerLoaded`, which seven other
palm6_* resources act on and which must not fire for a client with no player
object.

## Rendered-in-a-browser pass (2026-08-05) — one bug made the whole screen unclickable

Everything below this section was found by reading code. Then the page was
opened in a real browser for the first time (`html/index.html?preview=1`,
which is what that stub is for) and two defects showed up in the first
screenshot that no amount of reading would have found, because **the JS is
correct** — it sets `.hidden = true` in every place it should.

**The screen could not be clicked at all.** `.create-panel` is
`position: fixed; inset: 0; display: flex; pointer-events: auto`. The UA
stylesheet's `[hidden] { display: none }` has the weakest specificity in CSS,
so any class rule that sets `display` beats it — meaning the "hidden" create
panel was a full-viewport, invisible, clickable sheet lying on top of
everything. Measured, not inferred:

```js
document.elementFromPoint(cardCentreX, cardCentreY)  // -> #createPanel
```

A player joining the server would have seen the character list, clicked a
character, and had nothing happen — forever, with no ESC path off this screen
by design. The delete panel had the identical defect. Fixed with
`[hidden] { display: none !important; }`, and pinned by
`tests/suites/14_charselect_nui.lua` (verified to go red when the
`!important` is removed).

The same class of defect, found the same way: `.loading-state` is also
`display: flex`, so the spinner and "Loading characters…" sat permanently over
the finished screen. And in the rebuilt layout, the commit-state fade
(`.is-committing`) was silently doing nothing because `.rail`/`.topbar` run
their entrance animations with `forwards`, and a filled animation outranks a
plain declaration in the cascade — `animation: none` in that rule set is
load-bearing.

### The layout was rebuilt to match the market

Compared side by side against CodeM mMultichar, Quasar Multicharacter 2.0 and
DirkScripts' multicharacter, the old layout was doing the one thing none of
them do: **putting a row of three tall cards in the dead centre of the
screen** — exactly where the character ped stands — and repeating the same
stat labels (cash, bank, born, phone) on every card.

This page is a *transparent surface over the live 3D view*. The centre belongs
to the character. So:

```
┌──────────────────────────────────────────────────────────────┐
│ PALM6            CHARACTER SELECTION            2 / 3 SLOTS  │
├───────────────┬──────────────────────────────┬───────────────┤
│ YOUR          │                              │ DETAILS       │
│ CHARACTERS    │                              │ Job    ...    │
│ ┌───────────┐ │         (the ped —           │ Cash   ...    │
│ │ JV Jordan │ │      this column is a        │ Bank   ...    │
│ │ SR Sasha  │ │       HOLE, no paint,        │ Born   ...    │
│ └───────────┘ │      no pointer-events)      │ Phone  ...    │
│ + New         │                              │ Last seen ... │
│               │        Jordan Vance          │               │
├───────────────┴──────────────────────────────┴───────────────┤
│                        [   PLAY   ]                          │
└──────────────────────────────────────────────────────────────┘
```

Compact roster rows on the left, one details rail on the right, the name under
the ped's feet, and a single primary CTA. Edge scrims darken the left and
right thirds so the chrome stays readable over a bright daytime street — the
headings and hint text sit directly over the game view with nothing but a text
shadow otherwise.

**States verified in the browser, not assumed:** empty roster (welcome copy,
PLAY disabled, delete hidden, create focused), slots full (create disabled
with a reason), a 20-character first name + 18-character surname (ellipsises
in the row, shows in full on the nameplate without touching either rail —
measured), 8-figure balances, arrow-key navigation (each move fires
`previewCharacter` for the right citizenid plus a nav sound, and moves real
DOM focus), Enter to play, and the double-submit guard (a second Enter while
`busy` posts nothing — qbx_core hard-drops a client that logs in twice).

The type-to-confirm delete gate was exercised end to end: the expected word is
now `"Jordan"` rather than `""`, wrong input keeps the button disabled, correct
input unlocks it, and it is case-insensitive.

## Market-parity pass (2026-08-05) — the cards were rendering fields qbx_core does not return

This pass compared the screen against what premium multicharacter scripts
actually ship, and the first thing it found was not a missing feature but that
**every card was displaying placeholder text for real data.** The character
object was being read as if `firstname`, `lastname`, `playtime` and
`lastPlayed` were top-level fields. None of them are. Verified against the real
qbx_core source (`server/storage/players.lua`, `fetchAllPlayerEntities`), whose
SELECT is:

```
citizenid, charinfo, money, job, gang, position, metadata,
UNIX_TIMESTAMP(last_logged_out) AS lastLoggedOut
```

with `charinfo` / `money` / `job` / `gang` / `metadata` JSON-decoded into
tables. So:

- **Every card read "Unnamed"** — the name is at `charinfo.firstname`.
- **Every card read "Never played"** — the field is `lastLoggedOut`, and it is
  a UNIX time in **seconds**; `new Date(1754400000)` is January 1970.
- **Every card read "New character"** — `playtime` was invented. qbx_core does
  not track playtime anywhere in its metadata defaults. That line is gone
  rather than left permanently wrong.
- **Delete was unusable.** The confirmation panel requires typing the
  character's first name and keeps the button disabled until it matches; the
  expected word came from `char.firstname`, so it was always empty and
  `!(expected && typed === expected)` never unlocked. Nobody could delete a
  character.

Fixed, with the accessors documented at the top of `html/script.js`, and the
`?preview=1` devtools stub re-shaped to a real `PlayerEntity` — the old stub
invented the same non-existent fields, which is exactly why this survived a
build and two reviews.

**Content the cards now carry** (all of it real data qbx_core already returns,
none of it new plumbing): job **and grade**, gang (skipped when it's qbx_core's
sentinel "none"), cash and bank off the decoded `money` table, date of birth,
phone number, and the district the character was last standing in — resolved
from the `position` this resource already had and was only ever using to
teleport with (`Game.GetZoneLabel` → `GetNameOfZone` + `GetLabelText`).

### Playtime (this resource's own, because qbx_core has none)

Every premium select screen shows how long a character has been played.
qbx_core tracks it **nowhere** — confirmed against its real metadata defaults,
which is why the card line that used to read `char.playtime` could never have
shown a number and was deleted.

So this resource keeps its own, in its own table (`palm6_charselect_playtime`,
self-created at boot next to `palm6_charselect_hidden`; qbx_core's `players`
row is never written by this resource):

- The clock starts when the **server** confirms a login (`confirmSelect`), not
  when the client says so — a client can lie about how long it played.
- It flushes on `playerDropped` and every `Config.PlaytimeFlushIntervalMs`
  (5 min). The periodic flush is the load-bearing one: a crash or hard kill
  never fires `playerDropped`, so without it every session since the last
  restart would be lost.
- **There is deliberately no `onResourceStop` flush.** The obvious one was
  written and removed: it reaches `MySQL.query.await`, and this repo's audit
  enforces "no MySQL `.await` reachable from an `onResourceStop` handler"
  (it caught it). A yielding call in a stop handler may never resume, so the
  write likely would not land anyway. A restart therefore costs each player at
  most one flush interval, which is what the interval is for.
- Starting a session **banks any session already open on that source first**.
  Server ids are reused, and a player can switch character without
  disconnecting; overwriting would discard everything the previous character
  had accrued since its last flush.
- The number rides the same ownership-checked round trip as the appearances,
  so it cannot be used to probe for a character the requester does not own.

### The live character stage

The headline gap against every premium multichar on the market: this screen
showed a circle with the character's initials in it. It now shows the
character.

- One ped, standing at `Config.SceneCamera.lookAt` — by construction the point
  the camera already frames — snapped onto a probed ground Z. **No world
  coordinate is authored for this.** If the ground probe finds nothing (world
  not streamed in yet), no ped is spawned and the screen falls back to exactly
  the silhouette cards it showed before. Same for a character with no saved
  appearance.
- The appearance is applied by **palm6_appearance**
  (`exports:applyAppearanceToPed`), not by a second copy of that logic here, so
  the model guard from `docs/CUSTOM-CLOTHING.md` §5 lives in one place.
- Hovering, focusing or arrow-keying to a card swaps who is on the stage
  (debounced client-side; the ground Z is probed once, not per swap).
- The CSS only rearranges itself into the stage layout once the Lua side
  confirms a ped is genuinely standing there (`stage` with `live: true`).
  Strip that class and the layout is byte-identical to the pre-stage one — an
  in-game feature that cannot be verified from this repo is not allowed to be
  load-bearing for the UI.
- Time and weather are locked for the screen (`Config.PreviewStage`,
  client-local, cleared on every teardown path) so a character doesn't render
  as a silhouette at 03:00.
- The dead `Game.SpawnPreviewPed`/`DestroyPreviewPed` pair this README
  previously flagged as "exists and works but is never called" has been
  **deleted**, not wired up: it only ever applied the `components` half of an
  appearance, so it would have produced the right clothes on a default face.

Also: arrow-key/controller navigation between cards (Tab alone was the only
way to move without a mouse), a visible focus state, and navigation sounds
through an **allowlisted** name table — the same "never pass the client's
string to the native, look it up in our own table" rule that fixed
`palm6_radialmenu`'s dispatch.

New net event `palm6_charselect:requestAppearances` (client → server, ownership
proved per citizenid against qbx_core's `players` table before any appearance
is returned), with a `palm6_eventguard` budget. A budget was also added for
`palm6_appearance:server:save`, which shipped with none despite being a
client-triggered DB write.

## Adversarial review pass (2026-08-05) — what it caught

An independent code-reviewer, cross-checking every claim against the actual
cloned qbx_core/ox_lib source rather than this file's own comments, found
that the first qbx_core-integration rewrite fixed the *call contract* but
left the *lifecycle* unowned. `config.characters.useExternalCharacters`
doesn't just disable qbx_core's multichar NUI - it deletes its ENTIRE
`client/character.lua`, which was also the only place that: disabled
spawnmanager's autospawn, shut down the FiveM loading screen, actually moved
the ped to a spawn point, and fired `QBCore:Server:OnPlayerLoaded` /
`QBCore:Client:OnPlayerLoaded` (which 7 other palm6_* resources' `cl_game.lua`
files listen for - `palm6_insignia`, `palm6_pd_life`, `palm6_onboarding`,
`server_identity`, `server_base`, `palm6_turf`, `palm6_uniform`, confirmed
via repo-wide grep). None of that existed here. Fixed, all in
`bridge/cl_game.lua`'s new spawn-pipeline functions
(`DisableAutoSpawn`/`ShutdownLoadingScreen`/`SpawnAtPosition`/
`StartTutorialProtection`), wired into `client/main.lua`:

- **Real spawn.** An existing character now spawns at ITS saved position
  (`char.position`, a real `vector4` qbx_core already returns from
  `getCharacters` - `characterPositions` in `client/main.lua`); a brand-new
  character spawns at `Config.DefaultSpawn`, which is qbx_core's own
  `defaultSpawn` coordinate near Legion Square (`vector4(-540.58, -212.02,
  37.65, 208.88)`), not a guess.
- **Loading screen** now closes explicitly (`Game.ShutdownLoadingScreen`)
  once charselect's NUI is actually ready, instead of assuming FiveM
  auto-closes it (only true when qbx_core's own file, which calls this, is
  the thing running).
- **Autospawn** disabled once at startup (`Game.DisableAutoSpawn`) so
  spawnmanager's own default behavior can't spawn the ped into the world
  while charselect's NUI is still up.
- **Three black-screen softlocks** fixed: `Game.FadeIn` was missing from 3
  of the 4 teardown paths (`selectAccepted`, `forceRelease`,
  `onResourceStop`) - `Game.TeardownScene` fades to black and nothing faded
  back in on those paths.
- **A permanently invisible/frozen player after character creation**: the
  hand-off to `palm6_appearance` only revealed the real ped on a failure
  branch; `palm6_appearance` never touches the real ped either way (only its
  own separate preview ped), so success meant the player stayed hidden
  forever. `Game.RevealRealPed()` is now unconditional inside the hand-off
  callback.
- **A double-click exploit-drop**: qbx_core's own `Login()` hard-drops a
  client for `"attempting to login twice"` if it's called while already
  mid-login. Neither `selectCharacter` nor `createCharacter` had an in-flight
  guard, and the NUI stayed fully clickable during the multi-hundred-ms
  `lib.callback.await`. Fixed with a `busy` flag (`client/main.lua`) that
  blocks a second submission and is surfaced to the NUI (`action: 'busy'`).
- **A fake cinematic**: the "select" camera transition built a second camera
  at the IDENTICAL coordinates as the scene camera and interpolated between
  two identical cameras - visibly nothing moved. Now a real push-in on the
  same lookAt point (`Config.SelectZoomDistance`/`SelectZoomFov`,
  `Game.PlaySelectCinematic`).
- **Unhandled `lib.callback.await` timeouts/rejections** (ox_lib rejects the
  awaited promise on a 300s timeout or if the target callback was never
  registered, e.g. qbx_core not running) would previously raise INSIDE the
  NUI callback handler and strand the player with focus/scene state stuck.
  All three qbx_core calls in `bridge/cl_game.lua` are now `pcall`-wrapped
  and return an explicit `ok` the caller must check.
- **Soft-delete didn't free a real slot**: qbx_core's own slot-cap check
  counts every row in `players`, including this resource's soft-hidden ones
  - `client/main.lua` now subtracts the hidden count from the real `maxSlots`
  before showing it to the NUI.
- **The hidden-character list was global**, sent unscoped to every
  connecting client (`palm6_charselect_hidden` had no owner column at all).
  Added `owner_license`, scoped `Bridge.GetHiddenSet`/`HideCharacter` to it.
- Smaller fixes: `Bridge.OwnsCharacter` no longer builds a query param array
  with a possible `nil` hole; `ensureSchema` now retries every 10s instead of
  giving up permanently if the DB is briefly unreachable at boot, and
  `deleteCharacter` surfaces a real error instead of silently no-oping while
  not-yet-ready; `Bridge.Notify` prints to console instead of going nowhere
  when called by a console admin (`source == 0`); added `palm6_eventguard`
  budgets for all three of this resource's net events (it shipped with
  none).
- **Not fixed, deliberately out of scope** (at the time of that review; the
  first item has since been superseded - see the market-parity pass above,
  which replaced those dead functions with a single live character stage): full
  per-card ped previews (`Game.SpawnPreviewPed`/`DestroyPreviewPed` exist and
  work but are never called - cards currently show only the initials
  silhouette); a real hard
  qbx_core delete remains reachable by a modified client calling the
  deprecated `qbx_core:server:deleteCharacter` net event directly, bypassing
  this resource's soft-delete entirely (a qbx_core-level characteristic, not
  fixable from this resource); `Config.NameRules.regex` (Lua) and the
  hardcoded name regex in `html/script.js` express the same intent but
  aren't literally the same value - cosmetic drift, not a functional bug.

## What it does

1. Opens on its own `onResourceStart`, takes `SetNuiFocus`, and paints a
   full-viewport branded panel.
2. Requests the connecting player's character list from the server
   (`palm6_charselect:requestCharacters`).
3. Renders one glass card per character slot plus a trailing "+ New
   Character" card, with a staggered entrance animation and JS-driven
   hover-tilt.
4. On character select: tells the server to call `qbx_core`'s login path,
   plays a cinematic camera zoom timed to the CSS card transition, then
   fades out and tears down the scene (camera, HUD, frozen ped) so the
   normal game view takes over.
5. On "+ New Character": opens an in-panel creation form (name,
   nationality, gender, DOB), validates client-side for UX and again
   server-side (never trusts the client), then calls the same qbx_core
   creation path a "new" click would have used.
6. **Character deletion is a SOFT delete**, deliberately never a real
   `DELETE`/qbx_core call: the character disappears from the list, its slot
   frees up for a new character, and the underlying `players` row and every
   other palm6_* table referencing that citizenid (vehicles, houses, gang
   membership, bank, business ownership, ...) is untouched. Requires the
   player to type the character's first name to confirm
   (`html/index.html`'s `#deletePanel`). Implementation:
   - `palm6_charselect_hidden` is this resource's OWN table (self-created at
     boot, `server/main.lua`'s `ensureSchema`), NOT a write against
     qbx_core's `players` table.
   - `Bridge.HideCharacter(citizenid)` inserts a row; `Bridge.GetCharacters`
     filters any hidden citizenid out of BOTH the export path and the SQL
     fallback path before returning the list.
   - Fully reversible: `/palm6charselect_restore <citizenid>` (admin,
     `command.palm6charselect_restore` ACE) deletes the hide-row again.
   - This design exists specifically because there is no confirmed qbx_core
     delete export (unlike Login, which at least has a documented name to
     verify) — see "qbx_core integration" below. A wrong guess at a REAL
     delete would be irreversible data loss; this can't be, by construction.

## Files

```
palm6_charselect/
  fxmanifest.lua
  README.md
  shared/config.lua        -- camera coords, entrance timing, tilt clamp, max-slots fallback
  bridge/cl_game.lua        -- ONLY file calling GTA natives / camera / ped streaming
  bridge/sv_framework.lua   -- ONLY file calling qbx_core exports / MySQL directly
  client/main.lua           -- open/close flow, NUI message plumbing, calls Game.* only
  server/main.lua           -- character list / select / create flow, calls Bridge.* only
  html/index.html
  html/style.css            -- --p6-* brand tokens, glass cards, cinematic zoom
  html/script.js            -- vanilla JS, no build step, NUI message contract
```

## qbx_core integration: CONFIRMED against the real source (2026-08-05)

`qbx_core` is **not vendored** in this repo — it's recipe-deployed to the
box — but the exact version this was verified against was cloned read-only
from `github.com/Qbox-project/qbx_core` (main branch) specifically to
resolve every "MEDIUM CONFIDENCE" guess this resource shipped with
originally. Everything below is read directly from that source, not
inferred from docs or forum posts. **Still confirm the live box is running
a compatible version before the first `ensure`** — this was verified against
one commit of qbx_core, not this server's actual deployed build, and qbx_core
does not pin/advertise its version anywhere this resource can check.

**The character list/create/login calls are qbx_core `lib.callback`s,
registered SERVER-side, callable only from a CLIENT.** ox_lib's
`lib.callback.register` on the server wires a `RegisterNetEvent` that only a
client-side `lib.callback.await` can trigger (`ox_lib/imports/callback/server.lua`
- there is no server-to-server path). This is why `Game.GetCharacters()` /
`Game.CreateCharacterViaQbx()` / `Game.LoginCharacterViaQbx()` live in
`bridge/cl_game.lua` and are called directly from `client/main.lua`, NOT
routed through this resource's own server - an earlier version of this file
guessed at server-side `exports.qbx_core:GetCharacters()`, which does not
exist under that name anywhere in qbx_core.

**What IS a real, confirmed cross-resource export** (`server/functions.lua`,
`server/player.lua`): `exports.qbx_core:GetPlayer(source)` and
`exports.qbx_core:Login(source, citizenid, newData)`. `Bridge.IsPlayerLoaded`
still uses the former. `Login` itself is no longer called directly by this
resource (see the callback rewrite above) - calling it raw requires an exact
`newData.charinfo.*` shape and a server-computed `cid` this resource would
have to duplicate qbx_core's own `getNextCid` logic to get right; going
through `qbx_core:server:createCharacter` gets that (and starter items, and
qbx_core's own sanitization) for free instead.

**`config.characters.useExternalCharacters` is the real suppression switch**
(`config/client.lua`, default `false`) - `if config.characters.useExternalCharacters
then return end` is the FIRST line of qbx_core's own `client/character.lua`.
Set `true`, qbx_core's entire default multichar UI never runs. **This is a
plain Lua config value with NO convar path** - qbx_core's config files
(`config/client.lua`, `config/server.lua`) contain zero `GetConvar` calls
for anything character/multichar-related. It can only be set by editing
qbx_core's own config file on the live box directly (qbx_core is not
vendored in this repo, so that edit cannot ship from here) - **this is a
required manual step before the first live `ensure`, not optional polish.**
Until it's set, qbx_core's own multichar UI and this resource's UI will both
try to run - this resource still takes `SetNuiFocus` and paints over it
regardless, so the player only ever sees/interacts with the Palm6 skin
either way, but the underlying double-UI race is real and untested.

**⚠️ Separate, pre-existing finding, NOT part of this resource:**
`[config_overrides]/qbx_core_overrides` publishes `qbx:multichar_slots`,
`qbx:character_name_regex/min/max`, `qbx:character_dob_min_year/max_year`
as convars — **none of these are read anywhere in the real qbx_core.** They
were built on the same "qbx_core is convar-driven" assumption this resource
originally made, and are silently no-ops against the actual framework. The
real values (`config.characters.defaultNumberOfCharacters = 3` by default,
name/DOB validation, etc.) can only be changed by editing qbx_core's own
config files directly. This predates this build and is out of scope to fix
here, but worth flagging to whoever owns that resource - the max-character
count and name/DOB rules that server owner thinks are configured probably
aren't taking effect.

**Real field shapes** (`qbx_core:server:createCharacter`, matching qbx_core's
own `client/character.lua` `characterDialog()` payload exactly):
`{ firstname, lastname, nationality, gender, birthdate }` - `gender` is a
NUMBER, `0` (male) / `1` (female), not a string, and the field is
`birthdate`, not `dob`. `client/main.lua`'s `createCharacter` NUI callback
converts the NUI form (which still uses `'male'`/`'female'`/`dob` - friendlier
for an HTML `<select>`/`<input type=date>`) to this shape at the one seam
that has to match.

**Character deletion**: qbx_core DOES ship a real, ownership-validated
hard-delete callback (`qbx_core:server:deleteCharacter`, confirmed in
`server/player.lua` - checks the caller's license/license2 against the
citizenid before calling `storage.deletePlayer`). This resource deliberately
does NOT call it - see "What it does" #6 above for why (no cross-resource
cascade cleanup, same risk a hard delete built here would have had).

**Appearance hand-off**: qbx_core's own `createCharacter` flow does
**NOT** call `illenium-appearance`'s `startPlayerCustomization` at any
point - it only uses a plain `lib.inputDialog` for identity fields, then
spawns the character with a random default look
(`client/character.lua`'s `randomPeds` table). The `qb-clothes:client:CreateFirstCharacter`
event is the closest thing to a "customize after creation" hook in the
default flow, and this resource doesn't use that either. Instead,
`client/main.lua`'s `createCharacter` handler calls
`exports.palm6_appearance:startPlayerCustomization(...)` DIRECTLY after a
successful create - this resource owns that hand-off itself rather than
assuming qbx_core would trigger it, because it confirmedly does not.

## Deliberately out of scope

- **No REAL/hard character deletion.** See "What it does" #6 above. A real,
  ownership-validated qbx_core delete callback DOES exist and is confirmed
  (`qbx_core:server:deleteCharacter`) — this resource deliberately still
  doesn't call it, because it has the exact same gap a hand-built hard
  delete would: no cross-resource cascade cleanup for vehicles, houses,
  gang membership, bank, business ownership, etc tied to that citizenid in
  OTHER palm6_* resources. Soft delete already does everything a
  player-facing "delete" needs to do without that risk, so there's no
  pressure to revisit this — it would only be worth it as part of a
  dedicated cross-resource cleanup project, not a drop-in swap.
- **No new streamed clothing/ped assets.** The character stage
  (`Game.SetStageCharacter`) only ever re-applies a citizen's already-saved
  appearance indices, and it does so by calling
  `exports.palm6_appearance:applyAppearanceToPed` rather than applying them
  here — so the `IsPedCollectionComponentVariationValid` check and the
  always-`0` `paletteId` are that resource's single implementation, not a
  second copy in this one. The two ped models it can spawn are the stock
  freemode pair, taken from the saved payload's own allowlisted model stamp.
- **Does not touch `server_identity`'s loadscreen.** This is a separate,
  later NUI screen. It never sets `loadscreen_manual_shutdown` and never
  calls `ShutdownLoadingScreen()` — FiveM auto-closes the real loadscreen
  once resources are ready, and charselect opens after that.
- ~~Does not touch `custom.cfg`~~ — done: `ensure palm6_charselect` is wired
  in, directly after `ensure server_identity` (see the "Load order" note in
  `custom.cfg` itself). Still not `ensure`d on any LIVE box - local `custom.cfg`
  only, see the manual verification checklist below before that changes.

## Manual verification required before the first live `ensure`

Per PALM6's `docs/CUSTOM-CLOTHING.md` precedent — new resources that touch
the spawn flow get a staging/maintenance-window test, never a blind live
`ensure`. Do all of the following first, on a quiet server:

1. **Set `config.characters.useExternalCharacters = true`** in qbx_core's
   own `config/client.lua` on the live box. This is now the ONLY unresolved
   integration item that genuinely cannot be verified or applied from this
   repo (see "qbx_core integration" above for the full writeup) - qbx_core
   is not vendored here, so this edit has to happen directly on the box.
   Without it, qbx_core's own multichar UI and this one both try to run at
   once; this resource still wins the NUI focus race, but the double-UI
   state underneath is untested.
2. **Confirm the qbx_core version on the box matches what this was verified
   against.** Everything in "qbx_core integration" above was read directly
   from `github.com/Qbox-project/qbx_core`'s `main` branch on 2026-08-05 -
   real callback names, real field shapes, real config structure - but
   qbx_core doesn't advertise a version this resource can check at runtime,
   and a large enough gap between that commit and the deployed build could
   still change a callback name or a field. `lib.print.info` lines in
   qbx_core's own `server/character.lua` log every successful
   create/login to the server console - watch for those during the first
   test to confirm the real calls are actually landing, not silently
   failing into `Game.CreateCharacterViaQbx`/`LoginCharacterViaQbx`
   returning nothing.
3. **Confirm a real, safe scene camera coordinate** — `shared/config.lua`
   ships `Config.SceneCamera` pointing at the map origin
   (`vector3(0,0,0)`, ocean floor) as an intentional placeholder that must
   be replaced before the first `ensure`, not a real spawn-safe spot. Pick
   a quiet interior/skyline location with no nearby traffic or ped
   spawns, matching what other menu/character cams already use in
   `server_base` if one exists.
4. **Run `node tools/audit/run.js`** and confirm it stays at the repo's
   known-good baseline (8/8) immediately before the first `ensure` — never
   let a *new* failure hide behind an old one.
5. Stage the first `ensure palm6_charselect` solo on a quiet/maintenance
   server, watch a full join → character-select → spawn cycle end to end,
   including the "+ New Character" path with an empty account (confirm the
   palm6_appearance hand-off actually opens and the real ped doesn't flash
   visible for a frame before it does - see `Game.TeardownSceneKeepPedHidden`
   in `bridge/cl_game.lua`), before this goes live during normal play hours.
6. **Restart safety and the admin bail-out.** `onResourceStart` fires for
   every currently-connected client, not just new joins, so a mid-game
   `restart palm6_charselect` (e.g. a hotfix) would try to reopen charselect
   on top of already-playing clients. `server/main.lua`'s
   `requestCharacters` handler guards this with `Bridge.IsPlayerLoaded`
   (CONFIRMED real export, `exports.qbx_core:GetPlayer`) and answers
   `alreadyLoaded` instead of `clearToOpen` for anyone already past this
   screen. Separately, because character creation is mandatory there is no
   cancel button on the panel — if the qbx_core callback chain ever hangs
   or errors, a player can get stuck staring at nothing with NUI focus
   held. `/palm6charselect_release <server id>` (admin-only,
   `command.palm6charselect_release` ACE, granted to `group.admin` in
   `custom.cfg`) force-clears NUI focus and tears down the scene for that
   one client without needing a full resource restart. Test this command
   works, on the same quiet server, before relying on it as the incident
   response for a stuck player in production.
7. **Test the delete/restore round trip.** On the same quiet server: create
   a throwaway character, delete it from the card grid (type-to-confirm),
   confirm the slot frees up and the card disappears, then run
   `/palm6charselect_restore <citizenid>` and confirm it shows up again on
   next open (`Game.GetCharacters()` now returns it since it's no longer in
   `palm6_charselect_hidden`). This exercises the soft-delete table
   end-to-end before a real player ever touches delete.

## NUI message contract

**Lua → JS (`SendNUIMessage`):**
- `loading` — `{ action: 'loading' }`
- `show` — `{ action: 'show', characters: [...], maxSlots, nameRules }`
  (`characters` are real qbx_core `PlayerEntity` rows — `charinfo`/`money`/
  `job`/`gang` are nested tables, `lastLoggedOut` is UNIX seconds — plus a
  `zoneLabel` this resource resolves from `position`)
- `busy` — `{ action: 'busy' }` (a select/create is in flight)
- `previewable` — `{ action: 'previewable', citizenids: [...], playtime: { [citizenid]: seconds } }` (which
  characters have a saved appearance the stage can show)
- `stage` — `{ action: 'stage', citizenid, live }` (`live: false` means the ped
  could not be placed; the card keeps its silhouette and the layout does not
  change)
- `error` — `{ action: 'error', code, message }`
- `confirmSelect` — `{ action: 'confirmSelect' }`
- `hide` — `{ action: 'hide' }` (hot-reload hygiene only)

**JS → Lua (`fetch` + `RegisterNUICallback`):**
- `POST https://palm6_charselect/selectCharacter` — `{ citizenid }`
- `POST https://palm6_charselect/createCharacter` — `{ form }`
- `POST https://palm6_charselect/deleteCharacter` — `{ citizenid }`
- `POST https://palm6_charselect/previewCharacter` — `{ citizenid }`
- `POST https://palm6_charselect/uiSound` — `{ name }` (allowlisted key, not a
  sound name — see `UI_SOUNDS` in `client/main.lua`)

No `close` callback — character selection is mandatory before spawn, so
there is intentionally no ESC/close path from the player's side.
