# Changelog - Palm6 (palm6 server)

All notable changes to the Palm6 RP server's custom layer. **This is the
source of truth we post from** — every entry has an internal/technical list for
tracking *and* a ready-to-post **📣 Public** blurb (player-facing, no jargon) for
the Discord `#「📝」updates` channel, the website, and public announcements.

Format: newest first. Dates are EDT.

---

## 2026-08-06 (later) - The audit's remaining 18 defects, all closed

The other half of the 28-defect audit below. Nothing cosmetic in here either:
the two that matter most are a database write that trusted a string the client
chose, and a menu where clicking one item could perform a different one.

**Trust and persistence (server):**
- 🔴 **`confirmSelect` wrote an unauthenticated client string straight to the
  DB.** `Bridge.IsPlayerLoaded` proved only that *some* character was loaded;
  the citizenid itself was taken from the event payload with no ownership check
  and no length check, against a `VARCHAR(50)` column reached by a bare
  `MySQL.query.await` on a `while true` thread. One oversized string killed
  playtime tracking for the **whole server** until restart. The handler now
  takes no argument at all and reads the citizenid off qbx_core's own loaded
  player object, so ownership and length are settled by construction rather
  than checked.
- 🔴 **Playtime double-credited itself, and could kill its own flush thread.**
  The bank happened *before* the bookkeeping advanced, so anything landing
  during the DB await recomputed the same elapsed and wrote it again — N
  `confirmSelect` events credited N × the time. Separately, the periodic flush
  traversed `sessions` with `pairs()` while yielding inside it, which
  `confirmSelect` and `playerDropped` mutate; that is undefined per the Lua
  manual and can raise `invalid key to 'next'`, killing the thread that is the
  feature's only durability guarantee. Now: advance first, iterate a key
  snapshot, and `pcall` the body.
- **A new character's entire first session banked as zero.** Only a confirm
  handler starts the clock and the create path fired none. It also proceeded
  into the teardown, the appearance editor and a spawn with *no* proof
  qbx_core's login had actually taken — `CreateCharacterViaQbx` returning
  communicates neither success nor failure. There is now a `confirmCreate`
  round trip with the same server-side proof, and a failure surfaces as a real
  error instead of spawning a player with no character.
- **`palm6_appearance:server:load` was an unbudgeted client-triggerable DB
  read** — one `MySQL.single.await` per call, looped as fast as the network
  allows. It is the one entry point palm6_eventguard structurally cannot cover
  (it keys on net-event names; this is an ox_lib callback on a transport
  registered by a recipe resource that starts first), so the limit now lives in
  the handler.
- **The appearance sanitiser capped every field except the two that mattered.**
  Components and props were appended with no count cap and no de-dup, so 50,000
  entries all carrying one id survived into `LONGTEXT` via a blocking
  `json.encode`. Now keyed by id and flattened: at most 12 and 8, which is also
  what the apply path effectively did anyway.

**The character select screen:**
- **The stage showed one character's body under another's name.** The NUI
  focused card 1 while Lua staged the first character *with* an appearance —
  not the same thing on a mixed roster — and moving focus onto a character
  without one told Lua nothing at all, so the old ped stayed lit. Deleting the
  last character left them standing spotlit next to "Create your first
  character". Focus is now the single driver, "nothing to show" is an answer
  rather than a silence, and a late answer for a character you have already
  arrowed past is ignored.
- 🔴 **An in-flight stage spawn leaked a ped and a runaway per-frame thread.**
  The spawn yields on a ground probe and a model load; pressing PLAY inside
  that window tore the scene down and *then* let the suspended spawn create its
  ped, which nothing destroyed — a frozen clone near the spawn point plus a
  `Wait(0)` loop whose own guard could never go false. The cancellation token
  now goes *into* the bridge and is re-checked after every yield.
- **The admin bail-out made a stuck player less interactive, and never
  spawned.** The likeliest moment to need it is mid-creation, which is inside
  palm6_appearance — and NUI focus and script cameras are global, so releasing
  them here stripped that editor's cursor and camera while it still rendered
  full-screen, with no cancel and no Escape. It now closes the editor first,
  and branches on whether qbx_core actually has a character: spawn if so,
  return to character select if not (spawning fires `OnPlayerLoaded`, which
  seven other palm6_* resources act on and which must never fire for a player
  with no character).

**The character creator:**
- **`/palm6appearance` opened on a blank ped and destroyed the saved look.**
  It called the editor directly instead of through the export that loads the
  character's stored appearance, so it opened on a default freemode ped — and
  one slider nudge plus Save upserted *that* over the real row, with Reset
  restoring the same blank. Both entry points now share one function.
- **The preview body was resolved from `gender` while everything else uses
  `model`.** Two independently-validated fields that can disagree were each
  driving half of it: a mismatched row spawned the wrong-gender preview, had
  its own apply silently refused, and let the first Save overwrite the real
  look. The model stamp now decides, and a payload that cannot be applied
  refuses to open the editor rather than opening on a lie.
- **Randomize and Reset bounced you to the Face tab and yanked the camera to
  the head.** All three rebuild paths re-sent `open`, which the NUI could not
  tell from a first open. Those buttons live in the pinned save bar and are
  reachable from every tab, so randomizing an outfit zoomed you to your face
  and hid the outfit controls. There is now a distinct `refresh`.

**The radial menu:**
- 🔴 **Sibling items dispatched each other's arguments.** The allowlist was
  keyed by event *name*, but the qb idiom is one event with different
  positional args per item — three leaves on `palm6_shop:buy` collapsed to one
  entry and the last won, so clicking Bandage bought a medkit. Silently: the
  "forged callback?" diagnostic cannot fire when the name is genuinely in the
  map. Leaves are now identified by their path in the tree.
- **Wedges stayed clickable through the 180ms transition**, which corrupted the
  breadcrumb (a level became its own ancestor), made the next Back press do
  nothing, and could fire a leaf event for a level that was already closing.
- **Nothing ever closed the menu once open.** The state check ran at open and
  never again, and the force-close event has no senders anywhere in the repo.
  Dying with the menu up held NUI focus over the death screen, so hold-E
  respawn and the ambulance controls got nothing. There is now a watchdog.
- **`custom.cfg` ensured our radial without stopping qbx_radialmenu.** Both
  bind the command *and* keybind `radialmenu`, and FiveM invokes every handler
  under a name — both menus would open, two owners would grab NUI focus, and
  only ours releases it. One `stop` line, plus a startup warning if it is found
  running anyway.
- **The hub was sized in px while the ring scales with the viewport**, so below
  a 1048px minor dimension it overhung the wedges and drew its gold border
  across every one of them (27.5px of overhang at 1280x720). Now a ratio of the
  ring, as it always should have been. Wedge labels also had a size floor added
  — they live inside the scaled SVG and were rendering at 6.9px at 720p.
- **The registry had no de-dup and no owner cleanup**, so restarting a resource
  that registers wedges duplicated all of them and shrank the whole level.
- **The deferred job-sync server file would have net-registered two qbx_core
  *internal* event names** — promoting them to the network for every listener
  on the box, the exact failure palm6_eventguard records as already found and
  fixed twice here — and read its player id from argument 1 rather than
  `source`, so one event could have rewritten every connected player's job.
  Still not loaded; fixed before anyone uncomments it.

Also fixed: the radial's browser-preview stub was inventing a tree without the
dispatch key the real one carries — the same "a stub that agrees with the code
instead of the contract" shape that hid the charselect field-name bug through a
build and two adversarial reviews.

New suite `tests/suites/16_radialmenu_dispatch.lua`; suites 14 and 15 extended.
Full suite **1499/1499**, audit **8/8**. Twelve assertions trap-verified (each
new ordering and negative assertion broken deliberately, confirmed red, then
restored). **All 28 audited defects are now closed**; the 5 market gaps (outfit
slots, the four unexposed wardrobe slots, a player-facing barbershop entry
point, live job gating, in-creator gender switch) remain open by choice.

**📣 Public:** The last of the pre-launch audit is done. Highlights: the radial
menu could perform the wrong action when two items shared an event, dying with
it open locked your controls, the character creator's admin tool could wipe a
saved look, and randomizing your outfit no longer throws you back to the face
tab.

---

## 2026-08-06 - Multi-agent adversarial audit: 10 defects fixed, 4 of them server-breaking

A 64-agent audit (6 review dimensions, every finding independently attacked by a
refuter before it was allowed to stand) returned **28 verified defects + 5 market
gaps**. Ten fixed so far, worst first.

**TIER 0 — would have broken the server for everyone:**
- 🔴 **Every player permanently invisible to every other player.**
  `NetworkStartSoloTutorialSession()` instances the local player into their own
  network session; `NetworkEndTutorialSession()` existed **nowhere in the repo**,
  and the old loop sat *waiting* on `NetworkIsInTutorialSession()` for something
  to end a session nothing ended. All three join paths hit it — 100% of players,
  100% of joins. qbx_core pairs start/end; only the start half had been copied,
  and `useExternalCharacters` deletes the file holding the other half. The solo
  window and the invincibility window are now separate and both wall-clocked.
- 🔴 **Every new character saved and re-spawned naked.** The creator's preview
  ped never got `SetPedDefaultComponentVariation`, so it opened on the bare
  freemode body, the wardrobe captured drawable 0 on every slot, and
  `applyToRealPlayer` wrote that back over the ped's defaults on every join
  forever. Editing only the face shipped an undressed character permanently.
- 🔴 **A qbx_core hiccup stranded the player on the loading screen forever.**
  The failure path returned *before* the block that shuts the loading screen
  down, so the error toast rendered underneath it, autospawn was already
  disabled, and the admin bail-out couldn't rescue them either. Screen takeover
  is hoisted above the fallible call; `forceRelease` now closes it too.
- 🔴 **Deleting characters locked players out of their own account.**
  `math.max(maxSlots - hiddenCount, #visible)` self-cancels at cap; delete
  everything and it became "0 / 0 slots" — create disabled, nothing to play,
  focus held, no cancel — and it **survived rejoins**. A soft delete cannot free
  a qbx_core slot, so the UI now reports true consumption and names the cause.

**TIER 1 — wrong behaviour on the mandatory first-run path:**
- **Texture/colourway selection was completely unreachable** — the largest
  wardrobe gap. `cycleTexture` was registered with zero callers,
  `cyclePropTexture` had no callback at all, and `wardrobe.lua` reset to texture
  0 on every drawable change, so the first arrow press stripped the colourway
  permanently. Now a colourway row per slot, shown only when there is more than
  one, fed from the `textureId`/`textureCount` the messages always carried.
- **Reset re-applied the look you were undoing.** The snapshot stored
  *references* to the module tables, which every edit mutates in place — and
  `HeadBlend.Reset()` zeroes `faceFeatures` in place, zeroing the snapshot about
  to be applied. Deep-copied now. Reset is the only undo in create mode.
- **Picking a hair highlight silently reset hair colour** (and vice versa) —
  both grids closed over values seeded only at open.
- **Removing a hat never stuck** — the apply loop had no branch for a cleared
  prop, though the server deliberately preserves that state.
- **Hat/Glasses/Ears arrows were permanently inert on every new character** — a
  fresh ped wears no props, so the cached state had no collection name and every
  click bailed. `RandomizeAll` already had the fallback the cycle path lacked.
- **One invalid drawable dead-ended the cycle arrow**, walling the cursor into
  whichever arc of the ring it started in, with no feedback.

Full suite **1380/1380**, audit **8/8**. 18 verified defects remain, prioritised.

**📣 Public:** A deep audit caught several serious problems before launch —
including one that would have made every player invisible to everyone else. Also
fixed: character clothing colours are now selectable, removing a hat sticks, and
the creator's Reset button actually undoes.

---

## 2026-08-06 - Contract audit: a QA command had become a free barbershop

**Tracking (internal):**
- 🔴 **`/palm6appearance` was an unrestricted CLIENT command** — unrestrictable
  by definition, since an ACE check only means anything server-side. That was
  harmless while the appearance editor was inert (it applied nothing to the
  real ped and saved nothing). **Making the editor actually work turned the
  same command into a free, unlimited barbershop for every player**: retype it
  any time, change your face, and it persists — bypassing any barbershop fee or
  job-locked look. Now registered on the SERVER with `restricted = true`,
  reaching the client only through an event the server sends after the ACE
  check, with `add_ace group.admin command.palm6appearance allow` wired in
  `custom.cfg`. **The repo audit does not catch this** (it reconciles
  *restricted* registrations against ACEs, so an unrestricted command is
  invisible to it) — confirmed by trap test; `tests/suites/15` does.
- **Cross-resource contract audit.** Every `exports.palm6_*` call is
  `pcall`-wrapped, so a wrong name degrades silently rather than erroring.
  Checked all four against their definitions, including which *side* each is
  defined on (a client export called from the server fails silently):
  `startPlayerCustomization`, `applyAppearanceToPed` and
  `GetAppearanceForCitizenIds` all match, client↔client and server↔server.
- **Playtime session overwrite** (found reviewing the previous pass's own
  code): starting a session overwrote any open one without banking it. Server
  ids are reused and a player can switch character without disconnecting —
  either way the previous character's unbanked time was discarded. Now banks
  first; trap-verified.
- Stale references cleaned after the `Bridge.GetAppearances` split
  (`FilterOwned` / `GetAppearancesFor`), the manifest comment that named one
  table when the resource now owns two, and the README NUI contract missing
  `previewable`'s new `playtime` field.
- **Test-quality:** the comment-stripping helper was JS-only (`//`), so an
  assertion against a *Lua* file went on matching the `--` comment quoting the
  very code it asserted the absence of — the fourth instance of this shape.
  The helper now takes the language's comment token. Full suite **1356/1356**,
  audit **8/8**.

**📣 Public:** Internal hardening — an admin-only tool was reachable by
everyone; it now requires staff permissions.

---

## 2026-08-05 (late) - Playtime, a turntable, camera controls, and an orphan-ped race

**Tracking (internal):**
- 🔴 **Orphan stage ped race, found by tracing the state machine.** A
  `showOnStage` thread can sit in its debounce while the scene is torn down —
  and `Game.SetStageCharacter` is not instant (model load up to 5s, first
  ground probe up to 2s). A thread resuming afterwards spawned a ped nothing
  ever destroyed. The create path is the one that bit: it tears the scene down
  and then sits in the appearance editor for minutes with no further teardown.
  Fixed with `cancelPendingStage()` on every commit/teardown path.
- 🔴 **The repo's own audit caught a bug I introduced.** A "bank every open
  play session on resource stop" handler reached `MySQL.query.await`, which
  violates the `stop-await` invariant (a yielding call in a stop handler is not
  guaranteed to resume). Removed; the periodic flush already bounds the loss to
  one interval.
- **NEW: playtime.** qbx_core tracks none anywhere, which is why the old
  hardcoded card line could never show a number. This resource now keeps its
  own `palm6_charselect_playtime` table: the clock starts when the server
  *confirms* a login (not client-reported), flushes on disconnect and every 5
  minutes, and shows in the details rail. Ownership is proved once per request
  and the surviving ids are reused for both the appearance and playtime reads,
  so playtime cannot be used to probe for someone else's character.
- **NEW: the stage ped turns.** A slow, frame-rate-independent turntable
  (7°/s) so you can see the outfit instead of a mannequin. Generation-guarded
  so a previous ped's thread cannot rotate a deleted entity.
- **NEW: camera controls in the creator.** The subtitle said "drag to rotate,
  scroll to zoom", which is a hint, not an affordance — and useless on a
  trackpad with no usable scroll. Four buttons, hold-to-repeat, through the
  same two NUI callbacks the gestures use.
- Stage spotlight + contact shadow behind the character, and a tapered gold
  rule under the nameplate.
- **Test-quality fix:** three assertions this session matched the prose in
  their own explanatory comments rather than the code — one stayed green while
  the behaviour it guarded was deliberately broken. Suites 14 and 15 now strip
  full-line comments before asserting, and the affected assertions were
  re-trap-verified. Full suite **1346/1346**, audit **8/8**.

**📣 Public:** Your character now slowly turns on the select screen so you can
see your outfit, and the screen shows how long you've played each character.
The creator got on-screen rotate and zoom buttons.

---

## 2026-08-05 (evening) - Verified at 720p, and a way back from a bad randomize

**Tracking (internal):**
- **All three screens verified at 1280x720** (a real FiveM resolution) with a
  properly emulated viewport, not just at 1920. `palm6_charselect`'s media
  query fires and the rails narrow; `palm6_appearance`'s panel stays 380px with
  the region tabs clear of it and Save on screen; `palm6_radialmenu`'s SVG
  scales to 302px off `vmin` and centres with no text overflow.
- **The error toast covered "Delete Character" at 720p.** Measured: banner
  634-673 over a button at 630-667. It sat at `bottom: 6vh`, which clears the
  action bar at 1080p and lands on it at 720p. It is `pointer-events: none` so
  it never blocked the click, but an error message covering an interactive
  control is still wrong. Moved to top-centre, where it cannot collide with the
  primary action at any height.
- **Create mode had no way back from "Randomize All".** Character creation is
  mandatory and has no Cancel, so a player who mangled their character was
  stuck with it — every appearance editor on the market has a revert. Added
  **Reset**, which reverts the ped to how the screen opened (snapshotted after
  defaults and any saved appearance are applied) and rebuilds every control
  from the reverted ped. It takes Cancel's slot in create mode, so the bar
  stays at three buttons in both modes.
- Three buttons in a fixed 380px bar wrapped their labels onto two lines;
  tightened metrics keep "Reset / Randomize All / Save & Continue" on one line
  at every resolution.
- Suites 14 and 15 extended. Full suite **1344/1344**, audit **8/8**.

**📣 Public:** Made sure everything looks right on smaller screens, moved error
messages so they can't cover a button, and added a **Reset** button to the
character creator — if you randomize your character and hate the result, you
can now put it back the way it was.

---

## 2026-08-05 (later still) - The character creator, rendered for the first time

**Tracking (internal):**
- **The creator panel was one flat mega-scroll.** Measured: 1885px of content
  in a 945px panel — every slider, every wardrobe row, all three 64-swatch
  colour grids and the save bar in a single scroll, with "Save & Continue"
  ~940px below the fold on a **mandatory step with no cancel path**. (Reachable
  — the panel scrolls — so not a softlock, but it is the first thing a new
  player meets.) Rebuilt with **section tabs** (Face / Wardrobe / Colors /
  Tattoos), one section mounted at a time, and the save bar **pinned outside
  the scroll container**. Verified at 945px and 768px panel heights: the bar
  stays on screen on every tab; only Colors scrolls its body. The camera
  follows the section (Face/Colors → head, Wardrobe → whole, Tattoos → torso).
- **The colour swatches were a lie.** The grid painted itself with a generated
  HSL rainbow, so swatch 10 rendered lime green while the hair it selects is
  brown. GTA's 64 hair colours are blacks/browns/blondes/greys/reds. The
  palette is now read out of the game with `GET_PED_HAIR_RGB_COLOR` and passed
  to the NUI — captured, never authored, same rule as drawable indices.
- **Eye colours are not colours** — they are texture variations with no rgb
  getter, so any swatch shown was invented. Numbered chips now.
- `.btn { flex: 1 }` (correct for the save bar) made "Randomize" swallow the
  section header and run into the heading; section `<h2>`s now duplicated
  their own tab label and are visually hidden but kept for screen readers.
- **`palm6_radialmenu`:** the hub printed its own title twice ("Interactions"
  over "INTERACTIONS") because the breadcrumb was the whole stack and the root
  stack is one element. It now shows the ancestor path when nested, and "Esc
  to close" at the root — which nothing on screen was saying.
- 🔴 **A regression the palette fix itself caused, caught by rendering again.**
  `buildSwatchGrid` was `(container, total, selectedId, onSelect)`; inserting
  `colorFor` ahead of `onSelect` silently repurposed the overlay call site's
  callback. **Building** an overlay colour grid then called the apply-colour
  callback once per swatch — 192 spurious `setHeadOverlayColor` posts on open,
  every overlay left on colour 63, swatches blank white, and clicking one threw.
  Measured: 192 posts before, 0 after. Fixed at the root — `buildSwatchGrid`
  now takes a **named options object**, which cannot be silently reordered.
- The preview stub was made faithful: real `Config.FaceFeatureLabels` trait
  names (it sent none, so the preview showed "Feature 1".."Feature 20"), the
  real seven wardrobe slots, and `overlayDefs` with the `count`/`hasColor`
  fields the variant cycler and colour picker key off.
- Removed a duplicate source of truth introduced the same session
  (`Config.HairColorCount` alongside the pre-existing `Config.HairColorRange`);
  the count is derived from the range at its one call site.
- **New suite `tests/suites/15_appearance_nui.lua`** — 34 assertions,
  trap-verified. Full suite **1326/1326**, audit **8/8**.

**📣 Public:** The character creator got the same treatment as the select
screen. It's split into Face / Wardrobe / Colors / Tattoos tabs instead of one
endless scroll, Save is always on screen, and the hair colour swatches now show
the actual colours your hair will be instead of a rainbow.

---

## 2026-08-05 (later) - The select screen was unclickable, and the layout has been rebuilt to match the market

**Tracking (internal):**
- 🔴 **THE CHARACTER SELECT SCREEN COULD NOT BE CLICKED.** Found by opening
  `html/index.html?preview=1` in a real browser for the first time.
  `.create-panel` is `position:fixed; inset:0; display:flex;
  pointer-events:auto`, and the UA stylesheet's `[hidden]{display:none}` has
  the weakest specificity in CSS — so any class rule setting `display` beats
  it. The "hidden" create panel was a full-viewport invisible clickable sheet
  on top of everything. Measured: `document.elementFromPoint()` at the centre
  of a character card returned `#createPanel`, not the card. A joining player
  would have clicked a character and had nothing happen, forever, with no ESC
  path off the screen by design. Same defect on the delete panel, and visibly
  on `.loading-state` (spinner stuck over the finished screen). Fixed with
  `[hidden] { display: none !important; }`.
- **Layout rebuilt against the market.** Compared side by side with CodeM
  mMultichar, Quasar Multicharacter 2.0 and DirkScripts multicharacter: the
  old layout put three tall cards in the dead centre of the screen — exactly
  where the character ped stands — and repeated cash/bank/born/phone labels on
  every card. This page is a transparent surface over the live 3D view, so the
  centre belongs to the character. Now: compact roster rows left, a single
  details rail right, the character's name under their feet, one big PLAY
  button, and edge scrims so the chrome stays readable over a bright daytime
  street.
- Also fixed: the commit-state fade was silently doing nothing, because
  `.rail`/`.topbar` run entrance animations with `forwards` and a filled
  animation outranks a plain declaration in the cascade.
- **States verified in the browser rather than assumed:** empty roster, slots
  full, a 20-character first name against an 18-character surname (no rail
  collision — measured), 8-figure balances, arrow-key navigation (fires the
  right `previewCharacter` per row, moves real DOM focus, plays a nav sound),
  Enter to play, and the double-submit guard (a second Enter while busy posts
  nothing — qbx_core hard-drops a client that logs in twice). The
  type-to-confirm delete gate was exercised end to end and now unlocks.
- **New suite `tests/suites/14_charselect_nui.lua`** — 21 assertions over the
  shipped HTML/CSS/JS pinning the `[hidden]` rule, the qbx_core field shape,
  the honest preview stub, the empty-centre layout invariant and the sound
  allowlist. Trap-verified: removing the `!important` turns it red. Full
  suite now **1298/1298**, audit **8/8**.

**📣 Public:** The character select screen has been rebuilt. Your characters
are listed down the left, your character stands in the middle of the screen,
and their details are on the right — pick with the mouse or the arrow keys and
hit Play. (It also no longer had a bug where clicks didn't register.)

---

## 2026-08-05 - Character creation actually applies now, and the select screen shows the real character

**Tracking (internal):**
- ⚠️ Still local/uncommitted and still NOT staging-verified. Same gate as the
  2026-08-04 entry below, plus one new required pre-`ensure` decision — see
  `docs/PROD-DEPLOY-RUNBOOK-2026-08-05-premium-ui.md` Step 3b.
- **`palm6_appearance` was cosmetically inert. Six defects, all fixed:**
  (1) the finished appearance was never applied to the real player ped — the
  payload went to the database and nowhere else, so a new character spawned in
  qbx_core's random default look; (2) the ped **model** was never set either,
  so the male/female choice had no effect on the body; (3)
  `palm6_appearance:server:load` was registered and called by nothing, so saved
  appearances were never read back on rejoin — persistence that only wrote;
  (4) the payload carried no model stamp, against `docs/CUSTOM-CLOTHING.md` §5
  ("store the model string with the capture ... refuse ... do not guess and do
  not fall back") — now stamped, and applying refuses on a mismatch; (5) the
  entire creator ran behind a **black screen** when entered from charselect
  (the hand-off ends in `DoScreenFadeOut(0)` and this resource contained zero
  fade calls); (6) `palm6_appearance:server:save` did no validation at all
  under a comment claiming it did — now a real sanitizer with an **allowlist of
  the two freemode models**, which matters because that value now reaches
  `SET_PLAYER_MODEL`.
- **`palm6_charselect` cards were rendering placeholder text for real data.**
  Verified against the actual qbx_core source (`server/storage/players.lua`):
  the character shape is `charinfo`/`money`/`job`/`gang`/`metadata` (decoded
  tables) + `lastLoggedOut` (UNIX **seconds**). The NUI was reading
  `char.firstname`, `char.lastname`, `char.playtime` and `char.lastPlayed`, none
  of which exist — so every card read "Unnamed / Never played / New character",
  and **delete was impossible** (the type-to-confirm word came from the same
  missing field, so the button never unlocked). `playtime` is gone entirely:
  qbx_core does not track it.
- Cards now carry job **and grade**, gang, cash/bank, date of birth, phone, and
  the district the character was last in (resolved from the `position` this
  resource already had).
- **New: the live character stage.** One ped standing at the point the scene
  camera already frames, wearing the selected character's real saved
  appearance, swapping as you move between cards. No world coordinate is
  authored for it; if the ground probe finds nothing, or a character has no
  saved look, no ped spawns and the screen falls back to exactly the previous
  layout. Appearance is applied through `palm6_appearance`'s own export so the
  model guard lives in one place; the dead per-card preview functions that
  never applied a face have been deleted rather than wired up.
- Arrow-key/controller navigation between cards, a visible focus state, and
  navigation sounds via an allowlisted name table.
- New `palm6_charselect:requestAppearances` event (ownership proved per
  citizenid against qbx_core's `players` table) with a `palm6_eventguard`
  budget; a budget was also added for `palm6_appearance:server:save`, which had
  none despite being a client-triggered DB write.
- **New test suite `tests/suites/13_appearance_payload.lua`** — 45 assertions
  lifted from the shipped source with `T.slice`, covering the model allowlist,
  range clamping, wardrobe shape and the "no prop" state. Verified to go red
  when the allowlist is deliberately defeated, then restored. Full suite:
  1277/1277. `node tools/audit/run.js`: 8/8.

**📣 Public:** Character creation and the character select screen got a serious
pass. Your character now actually looks like the one you made — the face, body
and clothes you pick are what you spawn in, and they stick when you rejoin.
The select screen shows your character standing there in person instead of a
placeholder, along with your job and rank, your cash and bank, and where you
left off. Deleting a character works properly now too.

---

## 2026-08-04 - New resources ensured (NOT yet staging-verified): charselect, appearance, radial menu

**Tracking (internal):**
- ⚠️ **NEW resources added and ensured (local only): `palm6_charselect`,
  `palm6_appearance`, `palm6_radialmenu`** — NOT yet verified on a live/staging
  box, see each resource's README.md for required manual verification steps
  before this reaches production.
- Added to `custom.cfg` directly after `ensure server_identity` (before
  `ensure server_base`): character/spawn-flow resources, so they start after
  the loading-screen resource per the existing load-order comment, and ahead
  of a player reaching the world. `palm6_onboarding` (ensured elsewhere in the
  general resource block) is unaffected.
- `palm6_threads` was NOT touched — it remains deliberately `stop`ped per the
  existing warning in that section.
- **Post-implementation review found and fixed 3 real issues** before this
  entry was written: (1) `palm6_appearance_data` was queried but never
  created — `docs/CUSTOM-CLOTHING.md`'s wrong-file convention was copied by
  mistake; moved to a boot-time `CREATE TABLE IF NOT EXISTS` in
  `server/main.lua`, `palm6_heat`'s precedent. (2) `palm6_radialmenu`'s NUI
  `select` callback dispatched a client-supplied event name with no
  allowlist — a modified client could POST to the callback endpoint directly
  and trigger any registered event by name; now gated to only the events
  present in the tree the client was actually just shown. (3)
  `palm6_charselect` re-opened on every connected client on its own
  `onResourceStart`, including already-playing ones, and forwarded the raw
  client-submitted character-creation form into the qbx_core hand-off
  unfiltered; fixed with a `Bridge.IsPlayerLoaded` guard (skip clients
  already past this screen) and a whitelisted/re-validated field set, plus
  an ACE-gated `/palm6charselect_release` admin bail-out for a client stuck
  on a broken export. `node tools/audit/run.js` is 8/8 (no known failures)
  after these fixes. None of this has touched a live or staging box yet —
  see the "Manual verification" section in each resource's README.md.
- **UX/completeness pass found and fixed 4 more real gaps in
  `palm6_appearance`:** hairstyle (component id 2) was missing from
  `Config.WardrobeComponents` entirely — face/skin/colors/clothes were all
  editable but never hair itself; "Randomize All" called the exact same
  handler as plain "Randomize" (face-only) despite the name, now actually
  randomizes hair/eye color and every wardrobe slot too
  (`Wardrobe.RandomizeAll`, `HeadBlend.RandomizeColors`); wardrobe cycle-rows
  and color swatches rendered "0 / 0" / nothing-selected on open until the
  player clicked an arrow once, now seeded from a live capture
  (`buildOpenPayload`'s new `wardrobeState` field); the tattoo tier system
  was fully built server/client-side with zero UI ever calling it (a
  no-op stub) — added the one control that's actually achievable without a
  full tattoo-shop catalog (`Clear Tattoos`), documented the real scope
  limit in README.md instead of leaving it silently broken. Also flagged,
  NOT fixed at the time: `palm6_charselect` had no character-deletion
  feature. `node tools/audit/run.js` still 8/8.
- **Character deletion shipped for `palm6_charselect`, as a soft delete.**
  No confirmed qbx_core delete export exists, and a wrong guess at a hard
  delete is irreversible data loss — so this never touches qbx_core's
  `players` row or any other palm6_* table. Instead: a new self-created
  table (`palm6_charselect_hidden`) tracks hidden citizenids;
  `Bridge.GetCharacters` filters them out of both the export path and the
  SQL fallback path; the card grid gets a type-the-name-to-confirm delete
  flow; `/palm6charselect_restore <citizenid>` (admin, ACE-gated) undoes it,
  since nothing was ever destroyed. Also fixed: the charselect screen was
  fully blank/transparent for the length of the initial network round trip
  (no brand mark, no spinner) — now shows a loading state immediately.
- **Further appearance completeness pass:** the 20 face-feature sliders were
  labeled "Feature 1".."Feature 20" — now real trait names ("Nose Width",
  "Jaw Bone Shape", etc, sourced from the FiveM native reference). Head
  overlays (makeup, facial hair, blemishes, etc) had an opacity slider and
  NOTHING else — no way to pick a different pattern/variant, and
  `setHeadOverlayColor` existed server-side with zero UI caller, so
  color-capable overlays (makeup, lipstick, blush, eyebrows, facial hair)
  had no color control at all. Added a live-bounded variant picker
  (`GetNumHeadOverlayValues`) and a 64-swatch color picker to every
  `hasColor` overlay. "Randomize All" now also rolls face features and
  overlays (previously stopped at face-blend + colors + wardrobe).
  `node tools/audit/run.js` still 8/8; all script.js files pass
  `node --check`; HTML tag balance verified.
- **`palm6_charselect`'s entire qbx_core integration was rebuilt against the
  REAL qbx_core source**, not guesses. Cloned `github.com/Qbox-project/qbx_core`
  (main, 2026-08-05) and `ox_lib` directly and read the actual code. Findings
  that changed the resource:
  - Character list/create/login are qbx_core `lib.callback`s registered
    SERVER-side, and ox_lib's callback system has NO server-to-server path
    (only client-invoked). The old server-side `exports.qbx_core:GetCharacters`
    call was calling an export THAT DOES NOT EXIST. Moved all three calls to
    the client (`bridge/cl_game.lua`'s new `Game.GetCharacters` /
    `CreateCharacterViaQbx` / `LoginCharacterViaQbx`), which is the only
    place ox_lib allows them to be invoked from.
  - `exports.qbx_core:GetPlayer` and `exports.qbx_core:Login` ARE real,
    confirmed exports — no change needed there, just confidence upgraded
    from guess to verified.
  - The create-character form was sending `gender: 'male'/'female'` and a
    `dob` field; qbx_core's real callback expects `gender: 0|1` (a number)
    and a `birthdate` field. Fixed at the one seam that has to match.
  - `qbx:multichar_slots` / `qbx:character_name_*` / `qbx:character_dob_*`
    convars, which this resource (and the pre-existing
    `[config_overrides]/qbx_core_overrides`) both assumed qbx_core reads —
    **it doesn't. qbx_core's config has zero `GetConvar` calls anywhere.**
    Those convars are silent no-ops against the real framework. Flagging
    `qbx_core_overrides` as a separate, pre-existing repo issue — its
    multichar/name/DOB settings currently do nothing. Max character count
    now comes from the real second return value of the getCharacters
    callback instead.
  - `config.characters.useExternalCharacters` (plain Lua config, default
    `false`) is the confirmed real switch to fully disable qbx_core's own
    multichar UI — but it has no convar path either, so it can only be set
    by editing qbx_core's own config file directly on the live box. This is
    now the single loudest remaining manual step before any live `ensure`.
  - qbx_core's own character-creation flow does **not** call
    `illenium-appearance`'s `startPlayerCustomization` at any point — new
    characters just get a random default look. `palm6_appearance` was
    correctly built to expose that same export shape, but nothing was ever
    calling it — the whole appearance screen was orphaned from the
    create-character flow. `palm6_charselect` now calls it directly right
    after a successful creation, with careful ped-visibility choreography
    (`Game.TeardownSceneKeepPedHidden` / `Game.RevealRealPed`, new) so the
    real player ped doesn't flash visible between charselect's teardown and
    palm6_appearance's own preview ped spawning in.
  - A real bug caught in the process: the old `Bridge.Login`/`CreateCharacter`
    only checked whether `pcall` succeeded, not qbx_core's actual `true`/
    `false` return — a login that qbx_core legitimately rejected (e.g. no
    matching account) would have been reported as successful.
  `node tools/audit/run.js` is 8/8 after the full rewrite.
- **`palm6_charselect` adversarially reviewed and 12 findings fixed** (4
  critical, 3 high, 5 medium — see `README.md`'s new "Adversarial review
  pass" section for the full list). Headline ones: `useExternalCharacters`
  deletes ALL of qbx_core's spawn pipeline (autospawn suppression, loading
  screen shutdown, the actual spawn, `QBCore:*:OnPlayerLoaded` — 7 other
  palm6_* resources depend on that last one), and none of it existed here —
  added as new `Game.*` functions in `bridge/cl_game.lua`. Also fixed: 3 of
  4 teardown paths were missing `Game.FadeIn` (permanent black screen);
  successful character creation left the player invisible/frozen forever
  (`Game.RevealRealPed()` was only called on a failure branch); no in-flight
  guard on select/create meant a fast double-click could trigger qbx_core's
  own double-login exploit-drop; the "cinematic" camera interpolated between
  two identical camera positions and visibly moved nothing; unhandled
  `lib.callback.await` timeouts could strand a player with NUI focus stuck;
  soft-delete didn't actually free a character slot (qbx_core's own slot cap
  doesn't know about our hidden table); the hidden-character list was
  unscoped and broadcast to every client. `node tools/audit/run.js` still
  8/8 after all fixes.
- **Follow-up pass (same review cycle):** the adversarial review's `AllowedEvents`
  finding for `palm6_radialmenu` — event NAME was validated but `eventType`/`args`
  weren't, and `select`/`close` never checked `isOpen` or cleared the allowlist —
  had NOT actually been fixed yet (the reviewer flagged it, nothing addressed it).
  Fixed: `data.event` from the client is now used only as a lookup key into a tree
  built from OUR OWN nodes; the real `eventType`/`args` dispatched always come from
  that lookup, never the client payload; `select`/`close` both route through
  `CloseRadial()`, which checks `isOpen` and clears the allowlist on every close.
  Also added a missing `case "busy"` handler in `palm6_charselect`'s NUI (the
  Lua-side double-click guard from the review had no matching visual feedback —
  a second click would just silently do nothing instead of looking "busy").
  Plus first-pass sound design across the two: `PlaySoundFrontend` cues (existing
  GTA HUD sound bank, no new streamed assets) on radial open/select and charselect
  card select — the one clearly-missing "premium script" polish item found when
  comparing against the earlier Myxel/NXS/Wasabi research; none of the three
  resources had any audio feedback at all before this. Resolution responsiveness
  was re-checked against the original 720p/1080p/1440p/ultrawide methodology —
  `palm6_appearance`'s panel already uses `width: min(380px, 92vw)` +
  a 720px breakpoint, `palm6_radialmenu`'s SVG root already sizes off `vmin`
  specifically to hold proportion at any aspect ratio — both already correct,
  no changes needed. `node tools/audit/run.js` still 8/8.

**📣 Public:** Not yet — internal/local only, holding this entry back from the
public feed until staging verification passes.

---

## 2026-07-31 - Loading screen: logo, socials, staff, tips, rules

The join screen now carries Palm6 branding beyond the key art and progress bar.

**Tracking (internal):**
- Enhanced `server_identity` loadscreen: System A logo, Discord social (other
  networks toggleable in `html/config.js`), staff roster panel, rotating tips,
  rules panel (collapsed by default), optional music player (off until an mp3
  is added; Space toggles when enabled).
- `loadscreen_cursor` enabled; `files { 'html/**' }` streams assets.
- Restored missing `html/palm6_screen.jpg`; logo at `html/assets/logo.svg`.
- Removed unused Lua `LoadingScreenTips` — loadscreen copy is `html/config.js` only.
- Local QA via `html/loading.html#preview`.
- Progress percentage above the bar; website social (`palm6rp.com`); rules
  aligned with `palm6_onboarding` house rules; Discord presence skips the
  all-zero placeholder App ID.
- v0.3: live FiveM load-stage status, news + keybinds panels, chapter line,
  clock, dock hotkeys (`1`–`4` / Esc), color app-icon logo, premium plate.
- v0.4: gallery panel (`5`), music playlist + skip controls, ambient Ken Burns,
  progress milestone ticks.

**📣 Public:**
When you connect, you’ll see the Palm6 logo, a Discord button, staff list,
quick city rules, and rotating tips while the city loads — same warm progress
bar as before.

---

## 2026-07-17 - Gap/flaw sweep + the black-market gun dealer gets a face

A fresh ultracode audit (regression on the last day's code + a new
discoverability dimension, every finding adversarially verified) turned up 11
real issues. The important ones are closed, plus the street-weapon dealer is now
an actual person you can find.

**Tracking (internal):**
- 🔴 **Gang rename destroyed a gang's turf (HIGH).** `/gang` rename updated only
  the gang name, but `palm6_turf` keys ownership on that name — so a rename lost
  turf attribution + protection income immediately, and the every-boot migration
  0049 permanently NULLed the gang's territory on the next restart. Rename now
  cascades onto turf (DB rows + in-memory cache + client re-sync) via a new
  `palm6_turf:RenameOwner` export. Other gang consumers (protection, pumpcoin,
  ganginfo, clout, season) resolve identity live/by-id, so turf was the only gap.
- 🔴 **Lottery ticket count NaN (HIGH).** A forged `NaN` ticket count slipped
  past every `<`/`>` guard and drove a player's bank balance to `NaN`. Count is
  now sanitized to a finite positive integer before any guard or charge.
- **Chop shop left no paper trail on chop-before-report (MEDIUM).** Evidence
  cases were only opened for *reported*-stolen cars, so chopping a stolen car
  before the owner reported it destroyed their vehicle + paid clean money with
  zero forensic record. A case is now opened + the seller linked as a suspect on
  every chop that has a real victim.
- **Lottery kiosk leaked winners' legal names (LOW).** The recent-winners board
  broadcast every winner's full name to any walk-up; now shows amount + time only.
- **New players never told about `/help` (LOW).** The onboarding tour now points
  to `/help`, the index of every city command.
- **Gun dealer NPC.** `/buyweapon` was invisible (no ped, no blip) at an unmarked
  scrapyard lot. Added a dealer NPC + map blip + catalog menu (mirrors the
  lottery/insurance clerk); buying routes into the existing server authority
  (proximity, price, charge, serialized grant) + a new eventguard budget.
- Removed a dead `Config.StakeAccount` knob in numbers. All changes luaparse-clean
  and adversarially verified (5/5 clean, 0 regressions).

**📣 Public:** The city keeps getting sharper. The **black-market weapon dealer**
now has a spot you can actually find (look for the new blip). New here? The
welcome tour now tells you about **/help** — every command in one list. Plus a
round of behind-the-scenes fixes to gangs, turf, the chop shop, and the lottery.

---

## 2026-07-17 - City Lottery kiosk

The lottery is now a place you go, not a command you have to know. Walk up to
the new **City Lottery** clerk (map blip) and the menu shows the **live
jackpot** (what the winner takes), your tickets, time to the next draw,
quick-buy 1/5/10 or a custom amount, and a **recent winners** board.

**Tracking (internal):** new client layer for `palm6_lottery` (was server-only)
— clerk NPC + blip + ox_lib menu (mirrors the insurance agent). Presentation
only: `kiosk:buy` routes to the existing server-authoritative `cmdBuy` (rate
limit, open-draw, bank charge, per-draw cap); `kiosk:data` is a read-only
snapshot; both DoS-budgeted in `palm6_eventguard`. Ultracode-verified (0
confirmed / 6 refuted). Kiosk coord is a placeholder near the Davis 24/7.

Also added **instant scratch cards** at the kiosk — pay $500, roll a server-side
weighted prize (No luck → 💎 JACKPOT), ~30% house edge so it's a clean cash sink.
Server-authoritative RNG, charge-before-grant, adversarially reviewed clean.

**📣 Public:** The **City Lottery** now has a kiosk — find the ticket blip, check
the live jackpot, grab tickets, or try an **instant scratch card** right there.
Draws pay a random ticket holder the whole pot (minus the house cut). Recent
winners are on the board.

---

## 2026-07-16 - Insurance agent NPC + plan tiers

Mors Mutual is now a person you talk to, not a slash command. Walk up to the
agent at the Little Seoul office and shop for a plan like real insurance.

**Tracking (internal):**
- 🧑‍💼 **Agent NPC** at the Mors Mutual desk (ox_target eye / E-prompt fallback →
  ox_lib menus): **Buy a policy**, **File a claim**, **My policies & claims**.
- 🛡️ **Three plan tiers** — a policy remembers its tier and claims pay at that
  tier's theft % and payout speed:
  | Tier | Premium | Coverage | Deductible | Term | Payout | Theft |
  |---|---|---|---|---|---|---|
  | Basic | 3% | 40% | 15% | 48h | 15 min | 70% |
  | Standard | 5% | 60% | 10% | 72h | 10 min | 100% |
  | Premium | 8% | 85% | 5% | 120h | 3 min | 100% |
  Standard = the old flat plan exactly, so any existing policy is unchanged.
- 🔒 **Server-authoritative** — the menu only chooses plan/plate/kind; the server
  recomputes the premium from the resolved tier and re-runs every guard, so a
  modified client can't buy a richer plan than it pays for. New agent events are
  DoS-budgeted in palm6_eventguard.
- 🧾 Buy quotes all three tiers for the car you're sitting in; claims let you pick
  which insured plate to claim (theft can't use the car you're in — it's gone).
- ⚖️ Insurance protects against LOSING the car: theft / total-loss pay the full
  tier coverage. A repairable-damage claim (you keep the car) instead pays a
  modest **repair subsidy**, so a real accident is covered but "ram your own car
  and claim" is never profitable.
- Commands still work: `/insure [plate] [basic|standard|premium]`, `/fileclaim`,
  `/policy`. Migration `sql/0064` (policies.tier). Ultracode-verified (authority
  clean); 5 review findings fixed.

**📣 Public:** Car insurance got a real agent — visit Mors Mutual in Little Seoul,
talk to the rep, and pick a plan: **Basic** (cheap, light cover), **Standard**
(balanced), or **Premium** (top cover, low deductible, fast payouts). File
damage or theft claims right there with them.

---

## 2026-07-16 - Payout recoverability: no money lost to a restart

The server restarts on every deploy, so a payout that was mid-flight when the
server went down could strand money forever. This pass makes every bank-money
payout **crash-recoverable**: if the server dies partway through paying someone,
the payout is finished automatically on the next boot — and, critically, it can
**never pay anyone twice** (each payout is claimed before the money moves, so a
replay skips anything already paid). A follow-up to the 2026-07-16 restart/
persistence integrity audit, extended into a full sweep of every payout resolver.

**Tracking (internal):**
- 💰 **13 payout resolvers made recoverable** with the same claim-before-credit +
  boot-reconcile idiom: `palm6_fightclub` (bets + purse), `palm6_flashdrop`
  (consignment sale), `palm6_pumpcoin` (coin delist), `palm6_bounty` (capture +
  cancel + TTL expiry escrow), `palm6_courier` (delivery payout + all refund
  paths), `palm6_insurance` (claim payout), `palm6_ransom` (kidnapper payout),
  `palm6_lottery` (winner payout), `palm6_clout` (brand-deal cashout, + the
  missing revert-on-failure), `palm6_season` (prize claim + close reorder).
  Each terminal payout now claims an idempotency flag **before** the credit and
  a delayed `onResourceStart` reconcile re-drives anything a crash interrupted.
- 🛡️ **First-boot-safe** — every new flag column is added `DEFAULT 1` so existing
  (already-paid) history is backfilled as settled and the reconcile can never
  re-pay the whole payment history on the first restart after deploy; the flag is
  reset to 0 only when a record newly reaches its payout state.
- 🧱 **`palm6_pumpcoin` delist** no longer deletes holdings before paying — it
  keeps them behind a per-holder settled flag + a pool/supply snapshot, so an
  interrupted delist finishes on boot instead of stranding holders.
- 🗄️ **Migration integrity** — registered the base drugs (`0039`) and gang
  (`0041`) table creates in `palm6_dbmigrate`, which the later `0043`/`0049`
  statements depend on; closes a rebuild-from-migrate gap. New migrations
  `0054`-`0063` (all idempotent `ADD COLUMN IF NOT EXISTS`).
- ✅ Verified: all 13 files parse clean; three adversarial review passes
  (find → implement → first-boot harden), each checking specifically for
  newly-introduced double-pays. Deliberately **not** reconciled: item-delivery
  payouts (`smuggling`/`numbers`) where an ox_inventory autosave replay could
  double-give; and synchronous online-credit paths with no real crash window.

**📣 Public:** Under-the-hood reliability pass — if the server ever restarts
right as you're getting paid (a fight-club purse, a consignment sale, a bounty,
an insurance claim, a lottery win, a season prize), the payout now always
completes and you'll never lose what you earned to a restart.

---

## 2026-07-15 - Economy coherence pass: crime unlocked, gangs unified, seasons pay out

A big pass over the whole economy — turning on content that was built but
unreachable, making the gang systems agree with each other, giving the season a
real payoff, and closing a few money loopholes.

**Tracking (internal):**
- 🆕 **Black Market** (`ox_inventory_overrides`) — a gated vendor selling meth
  precursors (pseudo/acid/red phosphorus) and counterfeiting supply
  (printer/paper/ink), all priced with a real cost basis. Both the **meth cook**
  and **counterfeit** verticals were shipped + enabled but had **no in-game input
  source**, so they teased dead stations; they are now fully playable, still
  bounded by the existing dirty-cash daily cap / rank gate / fence quota / heat.
- 🔗 **Gang identity unified** — turf ownership, the `/ganginfo` directory, the
  season ladders, and reputation now all key on the **player-run gang**
  (`palm6_gangs`) instead of a mix of that and the static qbx gang. `Turf held`
  finally shows real numbers; holding turf pays (protection racket) and earns
  **reputation** on a genuine takeover (persisted anti-farm cooldown).
- 🏆 **Season 1 is live and rewarding** — auto-opens on boot; `/season`,
  `/seasontop`, and end-of-season **cash prizes** claimed with **`/seasonclaim`**
  (offline-safe, one-time). Five boards: Top Crews (rep, display-only), **Turf
  Held**, Drug Empire, Dirtiest Hustler, and **City Pulse** (most check-ins).
  Gang prizes pay the crew leader.
- 🔧 **`repair_kit` / `tirepack` now work** — use a Repair Kit from your
  inventory to fix the nearest vehicle, or a Tire Pack to fit fresh tyres
  (self-service, no mechanic needed; complements the mechanic invoice job).
- 🚚 **Courier runs require the pickup** — deliveries now make you visit the
  pickup before the dropoff will pay (was dropoff-only).
- 🛒 Grind tools (fishing rod / pickaxe / hunting knife) now also stocked at the
  **24/7 General Store** so a fresh spawn can start earning in-city.
- 🎥 **Going live needs a Streamer Phone** — clout streaming now requires a
  `streamer_phone` (General Store, $2500), so it isn't free money-printing.
- 🚔 **Warrants bite harder** — you can't launder dirty money while you have an
  active warrant, and **posting bail now protects you from instant re-arrest**
  for a short grace window.
- 🧪 Shipped across 7 commits, each boot-verified; three multi-agent adversarial
  review passes caught and closed five issues (incl. a rep-farm→cash exploit and
  a gang-prize name-reuse exploit) before they reached players.

**📣 Public:** Huge economy update dropped. **Meth cooking and counterfeiting are
now fully playable** — grab your supplies from the new **Black Market**. **Gangs
got real**: hold turf, run protection, climb the reputation board. **Season 1 is
live** with leaderboards and **cash prizes** you claim with `/seasonclaim` — top
the Drug Empire, Dirtiest Hustler, Turf, or City Pulse boards. **Repair Kits and
Tire Packs finally work** — fix your own ride from your inventory. Plus: grind
tools sold in the city now, going live needs a Streamer Phone, and skipping bail
or laundering while wanted just got riskier. Type `/season` and `/help` to see
what's new.

---

## 2026-07-13 - Prison economy (`palm6_yard`)

Jail stops being dead time. Inside Bolingbroke you can now **work to shave your
sentence** and earn commissary cash, buy from a **commissary**, or **post bail**
to walk early (with a catch).

**Tracking (internal):**
- 🆕 **`palm6_yard`** — three server-authoritative loops on top of the existing
  xt-prison jail: **labor** (`E` at the yard: a task pays a small trickle and
  shaves your sentence), **commissary** (buy-only cash shop), **bail** (pay to
  release early).
- ⛏️ **Labor**: pay ~$75 per ~35s task (deliberately below street earning), each
  task shaves 1 min but the **total shave is capped at 50% of the sentence** so
  jail always costs something. The shave is computed server-side from the
  sentence baseline (never the client) and bound to the live clock, and a
  **persisted** per-character cooldown means relogging can't reset it.
- 🏪 **Commissary**: server-owned prices, a **daily per-item cap** (kills the
  buy-low/resell-high loop), consume-before-grant with a refund ladder.
- ⚖️ **Bail**: superlinear price (short sentences are cheap to skip, long ones
  hurt) with a floor above typical crime payout so it stays a deterrent. Money
  is taken **before** release; if release fails it refunds. Bail is **not a
  clean slate** — it re-issues an `palm6_mdt` warrant (so `palm6_bounty`
  auto-posts a contract on the skipper) and stamps a re-arrest cooldown.
- 🔒 Server-authoritative sentence: stored/persisted via xt-prison's own Qbox
  `injail` metadata, keyed to citizenid; disconnect/death/restart never clears
  it; only timer expiry, paid bail, or admin release does. Never trusts a client
  "I'm free" or a client shave/price/amount.
- 🔧 Wiring: `sql/0047` (4 palm6_-prefixed tables); 3 `palm6_eventguard` budgets;
  3 ox contraband/commissary items (`yard_pruno`, `yard_commissary_snack`,
  `yard_soap`); self-disables loudly if xt-prison isn't running or an item is
  missing. Bridge-pattern native (§6 clean). **Coords are Bolingbroke Tier-3
  placeholders — VERIFY IN-GAME.** Item PNGs owed (David).

**📣 Public:** Doing time just got real. In prison you can now **work the yard**
to knock time off your sentence and earn commissary money, hit the **commissary**
for supplies, or **post bail** to get out early. But skipping court isn't free:
bail puts a fresh warrant on your head, so bounty hunters and cops get a payday
for bringing you back in.

---

## 2026-07-13 - Refining tier (`palm6_market` v2)

The Commodity Exchange gets a value-add tier: turn raw goods into **refined
goods** worth more, at a new **Refinery**.

**Tracking (internal):**
- 🆕 **Refinery** — `E` at the refinery converts raw stacks into refined goods:
  3 `raw_ore` -> `refined_metal`, 2 `animal_pelt` -> `cured_leather`, 2
  `raw_fish` -> `fillet`, 2 `raw_meat` -> `cured_meat`. Instant, lossless-by-
  ratio, integer batches.
- 📈 Refined goods sell **only** at the exchange, priced at ~1.4x
  (raw_base x ratio), and they ride the **same dynamic marginal-crash + recovery
  curve** as raws — so flooding the market with refined goods crashes their price
  faster than it recovers. Self-limiting, no money printer (the exchange is
  sell-only, so there's no round-trip arbitrage).
- 🔒 Instant is safe here because the throttle is the dynamic **sell** side
  (cooldown + marginal crash + per-sale cap), not the conversion: atomic per-
  player refine cooldown before any yield, server-side proximity, consume-before-
  grant with a refund ladder, refinery self-disables if a refined item def is
  missing.
- 🔧 Wiring: 4 new ox items (`refined_metal`, `cured_leather`, `fillet`,
  `cured_meat`); `palm6_market:refine` eventguard budget; no new SQL table.
  **Refinery coords are a Tier-3 placeholder — VERIFY IN-GAME.** Item PNGs owed.

**📣 Public:** The exchange now has a **Refinery**. Turn your raw ore, pelts,
fish and meat into refined metal, cured leather, fillets and cured meat, then
sell the refined goods for a premium. Just don't flood the market with them, or
the price drops the same way raw goods do.

---

## 2026-07-13 - Commodity Exchange (`palm6_market`)

The legal grind gets a real market. A new **Palm6 Commodity Exchange** buys raw
goods (`palm6_grind` outputs) at a **live price that moves with supply and
demand** instead of a flat vendor rate — and it's the first place you can ever
sell **animal pelts**, which hunting drops but nothing used to buy.

**Tracking (internal):**
- 🆕 **`palm6_market`** — sell all raw goods (`raw_fish`, `raw_ore`, `raw_meat`,
  `animal_pelt`) at the exchange counter with **E**; check live prices any time
  with **`/market`** (a branded `palm6_ui` panel).
- 📈 **Dynamic price model, server-authoritative, no client ticks.** Price is a
  pure function of the last persisted `{price, timestamp}` and the current time:
  it recovers toward a rested `base` over wall-clock time and drops per unit
  sold — **marginally within a single sale**, so dumping a big stack crashes the
  price as it sells (no selling 500 units at the top). Floored at `floorPct` of
  base. Restart- and relog-safe, same discipline as the drug grow/dry/cook
  timers.
- 🐟 `raw_fish`/`raw_ore`/`raw_meat` can be sold at *either* their fixed
  `palm6_grind` buyer (the safe floor, with the grind XP bonus) *or* the
  fluctuating exchange — a genuine sell-now-or-time-it choice. **`animal_pelt`
  is exchange-only** (fixes the confirmed orphan).
- 🔒 Money/dupe-safe: atomic per-player cooldown set before any yield;
  server-side proximity (the client sends no items, amounts or prices);
  consume-before-grant; the market only moves on a completed sale; in-memory
  price set before the DB write so concurrent sellers can't double-dip the top
  price; marginal loop hard-capped.
- 🔧 Wiring: `sql/0046` (`palm6_market_state` + `palm6_market_trades`,
  `palm6_`-prefixed); `palm6_eventguard` budgets `palm6_market:sell` (now
  guarding 51 events); `palm6_economy` shows an informational **clean-cash**
  line via a `GetSummary` export. Bridge-pattern native (§6 gate clean).
  **Exchange coords are a Tier-3 placeholder — VERIFY IN-GAME.** No new items,
  so no PNG debt. Refining tier (`raw_ore→refined_metal`, `pelt→cured_leather`)
  deferred to v2.

**📣 Public:** The city has a **Commodity Exchange**. Fish it, mine it, hunt it,
then bring your raw goods to the exchange and sell at a **price that actually
moves** — flood the market and it drops, let it rest and it climbs back. It's
also the only place to sell **animal pelts**. Sell now, or hold for a better
price. Check the board any time with **/market**.

---

## 2026-07-13 - Branded UI: NUI panel + loading screen (`palm6_ui`, `server_identity`)

The server got its look. Command output moved out of the raw chat feed into a
branded panel, and the first thing every player sees is now a Palm6 loading
screen.

**Tracking (internal):**
- 🆕 **`palm6_ui`** — a shared `ox_lib` panel renderer. Nine server-only commands
  (help, gangs, economy, city stats, wanted, and more) route their multi-line
  output through one branded panel instead of dumping lines into chat; a
  one-liner falls back to a non-blocking toast so it never freezes the player.
- 🎛️ **Branded NUI panel (Phase 2)** — a self-contained dark glassmorphism panel
  with a per-command accent colour, section styling, scroll, and ESC-to-close.
  XSS-safe (game text is rendered as text, never HTML), releases focus on close.
- 🖥️ **`server_identity`** — a Palm6-branded loading screen with a live progress
  bar, the first impression for every join.

**📣 Public:** Palm6 has a fresh look. Commands now open in a clean branded panel
instead of spamming chat, and there's a new Palm6 loading screen when you join.

---

## 2026-07-12 - Nine civic + info systems shipped to live

A batch of quality-of-life and civic systems went live together, filling in the
city's public-facing layer.

**Tracking (internal):**
- 🆕 Shipped nine self-contained resources: **`palm6_help`** (in-game command
  directory), **`palm6_citystats`** (live city economy stats), **`palm6_ems`**
  (EMS billing + dispatch reader), **`palm6_lottery`** (scheduled civic lottery),
  **`palm6_blotter`** / **`palm6_wanted`** (public crime + wanted boards),
  **`palm6_rapsheet`** (criminal history), **`palm6_ganginfo`** (public gang
  directory), **`palm6_season`** (season framework).
- 🎨 Shipped a branded **`palm6_props`** prop set into the live custom layer.
- 🔧 Fixed EMS/lottery commands registering behind a boot delay instead of at
  boot, and granted the correct staff ACEs.

**📣 Public:** Type `/help` in-game to see everything you can do. New civic
systems are live: city stats, EMS billing, a lottery, public wanted + crime
boards, rap sheets, and a gang directory.

---

## 2026-07-11 - Palm6 dealership + new-arrival starter kit

**Tracking (internal):**
- 🚗 Branded **Palm6 dealership catalog** of purchasable vehicles.
- 🎁 New-arrival **starter kit** (a car + clothes) so fresh players aren't
  dropped into the city with nothing.

**📣 Public:** New in town? You start with a car and a fresh outfit, and the
Palm6 dealership is open for your next upgrade.

---

## 2026-07-11 - The server is now Palm6

**Tracking (internal):**
- 🌴 Rebranded the entire custom layer from "Horizon" to **Palm6** — every
  banner, label and reference across all custom resources.

**📣 Public:** Welcome to **Palm6**. New name, same city we've been building.

---

## 2026-07-11 - Meth cook lab (`palm6_drugs` §9)

The Schedule I supply chain gets its second drug: **meth**, via a new cook
station. Meth is not a strain (it can never be planted); the cook lab is its
only source. It reuses the same restart-safe, wall-clock, resolve-on-interaction
timer as the drying rack, so there are no client ticks and nothing to dupe on
relog.

**Tracking (internal):**
- 🆕 **Cook station** (3 burners). Load a pseudo stack (its grade sets the
  quality floor) plus acid and red phosphorus; the batch cooks over wall-clock
  time in `palm6_drugs_processes` (`kind='cook'`, reusing the drying table) and
  mints `meth_raw` crystal on collect.
- 🎲 **Outcome rolled AND stored at start**, never at collect: success (scales
  with rank, capped at 0.9), quality (grade floor, one tier lower on a failed
  cook), yield (config range plus a per-4-ranks bonus, one less on failure), and
  a possible junk effect on a bad batch. Re-collecting can never re-roll a
  better result.
- 🔒 Money/dupe-safe, mirroring grow and dry: precursors consumed before the row
  is written (full refund ladder on any failure), an atomic `running` to
  `collecting` claim so a double-fire can't collect twice, crystal reverted if
  your hands are full, and a per-character concurrent-cook cap. A stranded
  `collecting` row is deleted at boot (err toward loss, never a dupe).
- 🚔 **Cooking is loud**: it warms dealer heat faster than a street sale and has
  a high flat chance to ping police and open a `palm6_evidence` case the moment
  the burner lights.
- 💊 `meth_raw` and `meth_product` flow through the existing mix, sell and price
  engine automatically (base-agnostic refactor: the base id is `meta.base or
  meta.strain`). Also fixed a latent bug where the street buyer offered meth but
  the sell handler still hardcoded weed items and rejected the sale.
- 🔧 Wiring: 5 ox_inventory items (`pseudo`, `acid`, `red_phosphorus`,
  `meth_raw`, `meth_product`); `palm6_eventguard` budgets for the 3 cook events;
  a soft boot gate that leaves the lab dark (weed unaffected) until all five
  items are registered. **No new SQL migration** (reuses `palm6_drugs_processes`).
  Cook coords are a placeholder to verify in-game; item PNGs are still needed
  (David) before icons render.

**📣 Public:** The city has a new product. Set up in the **meth lab**: load your
pseudo, acid and red phosphorus into a burner and let it cook. Higher-grade
pseudo and more experience mean purer crystal and bigger yields, but a sloppy
cook comes out dirty, and cooking is **loud**, so expect the heat. Rank up
through weed to unlock it.

---

## 2026-07-11 - Gang rename (`palm6_gangs`)

**Tracking (internal):**
- ➕ `/gang` gains a leader-only **Rename** action: change your gang's name and
  tag for a bank-charged fee (refunded if the change fails). The server
  re-derives leadership from the DB, sanitises and uniqueness-checks the new
  name and tag (excluding your own gang), rejects a no-op before charging, and
  re-mirrors every online member's gang label on success.

**📣 Public:** Gang leaders can now **rename** their crew (name and tag) from the
`/gang` menu for a fee.

---

## 2026-07-10 — Player-run gangs (`palm6_gangs`)

New custom resource: the **player-created gang layer Qbox does not ship**.
qbx_core owns only the STATIC gang registry (predefined gangs + grades,
`PlayerData.gang`, `/setgang`); this adds what qb-gangs/ps-gangs add to QBCore —
gangs players create and run themselves, membership + ranks, a shared cash
vault, and reputation. The static qbx model is **not** duplicated; it's read
read-only through the bridge, with an opt-in (default-off) mirror seam.

**Tracking (internal):**
- 🆕 **palm6_gangs** — `/gang` menu. Create (unique name+tag, sanitised/length-
  limited/profanity-filtered, bank-charged founding cost) / disband (leader).
  Membership + ranks (Leader/Officer/Member): invite the closest eligible nearby
  player (server-chosen, never client-named), accept, leave, kick (officer+,
  lower ranks only), promote/demote (leader). **One gang per player** enforced by
  a PK on `citizenid`.
- 💰 **Shared CASH vault** — rank-gated deposit (any member) / withdraw
  (officer+). Deposits are consume-before-credit; withdraws use an **atomic
  guarded decrement** (no double-withdraw race, no overdraft) with rollback on a
  failed payout. Every move logged to `palm6_gang_vault_log` with a balance
  snapshot. Disband pays the vault remainder back to the leader's bank.
- 📈 **Reputation** — per-gang `rep` + a server-only `AddRep(gangId, amount,
  reason)` export (floors at 0) so turf/protection/drugs can reward gang activity
  later. Exports: `GetGang`, `IsSameGang`, `AddRep`, `GetSummary`.
- 🔒 Server-authoritative throughout (rank/membership/amounts re-checked
  server-side; parameterised SQL; bridge-isolated per GTA6-readiness).
- 🔧 Wiring: `sql/0041_gangs.sql` (3 indexed, restart-safe tables); rate-limit
  budgets in `palm6_eventguard`; devtest shape + table-map assertions; a `gangs:`
  line on the `/economy` scoreboard; `docs/TESTING.md` §43. (custom.cfg ensure
  line left for the operator — after qbx_core, near the crime resources, after
  `palm6_eventguard`.)

**📣 Public:** Start your own **crew**. Found a gang with a name and a tag, run
your roster with officer and member ranks, invite people, and pool your money in
a **shared gang vault** only your officers can pull from. Gangs also build a
**reputation** as you run the streets — the foundation for turf and crime payouts
to come. Type `/gang` to get started.

---

## 2026-07-10 — Economy anti-exploit hardening + coord retune

A server-wide adversarial audit of the money-handling systems (find →
independently verify → fix), plus real-location retuning of placeholder coords
and a continued bridge-pattern rollout. **8 confirmed-exploitable bugs fixed;
the other 12 audited resources came back clean.**

**Tracking (internal):**
- 🔴 **palm6_courier** — fixed a **critical double-payout race**: `complete` now
  atomically gates the `UPDATE` on `status='taken' AND courier_citizenid` and only
  pays when rows-affected == 1. Same guard on cancel-refund and both lifetime sweeps.
- **palm6_insurance** — policy is now consumed on claim (one payout per policy);
  no-scene damage claims are hard-denied instead of trusting client health.
- **palm6_chopshop** — closed a free-money faucet: ambient/NPC cars (no
  `player_vehicles` row, no active stolen report) can no longer be sold.
- **palm6_bounty** — fixed a city-money faucet: captured state contracts update in
  place (`status IN ('active','claimed')`) instead of re-posting every sweep.
- **palm6_mechanic** — repairs now require a **customer consent handshake**
  (offer → confirm → accept, re-validated server-side) plus a per-customer cooldown;
  a mechanic can no longer force-charge a non-consenting nearby player.
- 🧩 **Bridge pattern** — extended to `ox_inventory_overrides` (isolated its
  `ox_inventory`/`ox_target`/native calls behind `bridge/`), per GTA6-readiness. The
  other candidate resources already had adapters.
- 📍 **Coord retune** — replaced Tier-3 placeholder map coords with real Los Santos
  locations across bounty, fightclub, gunrunning, laundering, loanshark, numbers,
  protection, and robbery. All flagged `VERIFY IN-GAME`.
- Audited clean (no fixes needed): laundering, numbers, loanshark, protection,
  seizure, smuggling, pumpcoin, economy, ransom, gunrunning, counterfeit, grind.

**📣 Public:**
> 🔧 **Server maintenance — economy hardening**
> We ran a full security sweep of the crime economy and patched several money
> exploits (courier payouts, insurance claims, chop-shop, bounties). Repairs from
> mechanics now ask for your approval before charging you. Plus we moved a bunch of
> racket locations to their real spots around the city. Cleaner, fairer hustle. 💰

## 2026-07-10 — 🌿 New: `palm6_drugs` (Schedule I-style) — MVP Phase 1 built

The missing drug supply chain — a faithful adaptation of **Schedule I**. Design
locked in `docs/DRUGS-SPEC.md`; **MVP (weed only) built**: grow → mix a custom
branded product with stacking effects + quality → sell → dirty cash → laundering
+ heat/evidence. Not yet wired into `custom.cfg` (operator step).

**Tracking (internal):**
- 🌱 **Grow loop** — buy `weed_seed` + `soil` (+ optional grow additive), plant at
  an ox_target grow plot, water over **wall-clock DB timers resolved on
  interaction** (restart-safe, no client ticks), harvest `weed_bud` with
  `{strain,quality,effects,dried}` metadata. Neglect (water → 0%) drops quality/yield.
- 🌬️ **Drying rack → Heavenly** — hang a stack of fresh `weed_bud` on the rack
  (ox_target) to dry it over a **wall-clock `palm6_drugs_processes` timer** (`kind='dry'`,
  epoch seconds, resolved on interaction like the grow timers). On collect the buds
  come back **bumped to Heavenly (tier 4, ×1.30)** with `dried=true`, and the price
  engine applies the markup on any later mix/sell. One run per rack slot (UNIQUE
  `(kind,station_id)`); server-owned by its starter; **atomic `running→collecting`
  collect claim**; a crash-stranded run reverts to `running` at boot (never lost).
  No new item — the rack is a world station.
- 🧪 **Mixing station** — pick a base stack + one additive; the **server** resolves
  effects (**reactions first, then append-if-absent, 8-cap, order kept**), recomputes
  quality + unit price via the spec §5 formula, sanitizes a player brand, mints one
  `weed_product` (`{brand,base,effects[],quality,unit_value,batch_id,producer}`).
  Bad-mix roll can inflict a junk effect. Named recipes saved to `palm6_drugs_recipes` for
  one-click repeat.
- ⚗️ **Effect reaction/transform system** — the signature Schedule I mechanic:
  mixing now **transforms** existing effects into other (often higher-value) ones
  when an additive reacts with them, so the result is **order-dependent**
  (`Cuke→Banana` ≠ `Banana→Cuke`). `Config.Reactions` (112 real reaction rules
  across all 16 additives, cross-checked 2026-07-10 against the Schedule 1 Fandom
  wiki + Steam "Complete Mixing Database" / "Full Transformation Guide" + calculator
  charts) is the tuning surface; deterministic, server-side (`reactEffects` in
  `doMix`), 8-cap preserved. Retune vs the live mixing DB as the game patches it.
- 💵 **Selling** — real players via ox_inventory trade, plus one **rate-limited NPC
  street-buyer** paying DIRTY `black_money` priced from the item's real metadata,
  bounded by a **per-character daily faucet cap**. Logged to `palm6_drugs_sales`.
- 🚔 **Heat/evidence (basic)** — sales warm a per-dealer heat model; a hot dealer or
  witness roll (and the odd big harvest) trips a native police alert +
  `palm6_evidence` case. Every unit carries `batch_id`+`producer` for audit.
- 🧱 **Full §1–5 config** — 4 weed strains, 16 additives→effects, all 34 effect
  multipliers, 5 quality tiers, and the server-authoritative `Config.Price` helper.
- 🛡️ **Server-authoritative** — never trusts client price/effects/quality/amount;
  recomputes from config + metadata; consumes inputs before granting outputs;
  proximity re-derived server-side; all SQL parameterized. 12 net events registered
  in `palm6_eventguard`. New items added to `ox_inventory_overrides` (replacing the
  earlier generic `cannabis_leaf`/`weed_baggie` draft). SQL: `palm6_drugs_plants`,
  `palm6_drugs_recipes`, `palm6_drugs_progression`, `palm6_drugs_sales` (`sql/0039_drugs.sql`) +
  `palm6_drugs_processes` (the drying-rack timer, `sql/0040_drugs_drying.sql`).
- ⏭️ **Deferred to Phase 2/3:** meth/shrooms/coke, NPC customers + hired dealers,
  and rank/XP-gated properties.

**📣 Public:**
> 🌿 **New hustle incoming — grow, cook, and brand your own product**
> Plant strains, keep them watered, then take your buds to the mixing bench and
> cut them with additives to build custom effects and quality — then slap your own
> brand on it. Better product, better payout. Sell to other players or move it fast
> to a street buyer for dirty cash you'll need to launder. Bring heat if you get
> greedy. 💨

<!-- Template:
## YYYY-MM-DD — <title>
**Tracking (internal):**
- <change> (`resource`)
**📣 Public:**
> 🎮 <player-facing line(s)>
-->
