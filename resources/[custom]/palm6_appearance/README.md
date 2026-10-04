# palm6_appearance

Premium character creation / appearance customization screen for PALM6. Bone-indexed
orbit camera with DOF, 3-parent face blend (`SetPedHeadBlendData`), and wardrobe
editing that only ever touches components/props that are **already streamed** on the
client — nothing new is ever loaded from disk by this resource.

## 2026-08-06 — the editor opens on the right character, or refuses to open

Five defects from the 28-defect multi-agent audit, plus a new export.

**`/palm6appearance` used to open on a blank ped and destroy the saved look.**
The admin net event called `openAppearanceScreen` directly with a nil payload,
so it skipped the stored-appearance load that lives in
`exports('openAppearanceEditor')` — the editor opened on a default freemode ped
(parents 0/0/0, mix 0.5) that was not the admin's character, and one slider
nudge plus Save upserted *that* over the real row. No diff check, no undo:
Reset restores what the screen opened with, which was the same blank. Both
entry points now share `openEditorForExistingCharacter`. **If a third re-edit
entry point is ever added, route it through that function too** — this bug was
exactly one entry point bypassing the load.

**The preview body is resolved from `payload.model`, never `payload.gender`.**
`applyToRealPlayer` already keyed off `model` with a comment forbidding exactly
this, and `openAppearanceScreen` was the un-converted half. The two fields are
validated independently by the sanitiser with no cross-check, so a row where
they disagreed spawned the wrong-gender preview, had its own apply silently
refused by the §5 model guard, and let the first Save overwrite the real look
with a blank. `genderKeyForModel` is the reverse of `allowlistedModelHash` and
the two must stay in step.

**A payload that cannot be applied refuses to open the editor.** The boolean
from `applySavedAppearance` used to be discarded. Refusing is recoverable;
opening on a lie is not.

**`exports('forceCloseEditor')`** closes the screen without resolving the
pending callback, for `palm6_charselect`'s admin bail-out. The callback is
deliberately *dropped* rather than resolved: it is charselect's own "creation
finished" handler, which spawns the player and clears its busy flag, and the
rescue does both itself — firing both would spawn twice.

**`refresh` is a distinct NUI action from `open`.** Randomize, Randomize All
and Reset all rebuild the controls and all three did it by re-sending `open`,
which the NUI could not tell from a first open — so it ran
`setActiveSection("head-blend-panel")`: back to the Face tab, scroll zeroed,
and a `setCameraFocus` post that also reset the orbit distance. Those three
buttons live in the pinned save bar, reachable from every tab, so randomizing
your outfit zoomed you to your face and hid the outfit controls.
**`handleRefresh` and `rebuildControls` must never call `setActiveSection`** —
there is a test asserting they do not.

**Server:** `sanitizeAppearance` now writes components and props into
**id-keyed** tables and flattens them, capping at 12 and 8 entries. Both lists
were previously appended to with no count cap and no de-dup while every other
field is bounded by construction, so 50,000 valid-looking entries all carrying
one id survived into `appearance_json LONGTEXT` via a blocking `json.encode`.
(A duplicate id was meaningless anyway — the apply path overwrites, which is
what keyed assignment gives.) And `palm6_appearance:server:load` now
rate-limits per source: it is one `MySQL.single.await` per call with no limit,
and it is the **one** client-reachable entry point palm6_eventguard
structurally cannot cover — the guard keys on literal net-event names and hooks
them with `AddEventHandler`, while an ox_lib callback arrives on a fixed
transport event registered by a recipe resource that starts before
`custom.cfg`.

## 2026-08-05 — Reset, and a 720p pass

**Create mode had no way back.** Character creation is mandatory and has no
Cancel button, so a player who hit "Randomize All" and hated the result was
stuck with it — there was no revert anywhere on the screen. Every appearance
editor on the market has one.

`Reset` reverts the preview ped to how the screen opened. The snapshot is taken
in `openAppearanceScreen` **after** the defaults and any saved appearance have
been applied, so "reset" means "how this looked when I got here". It re-applies
through the same guarded `applySavedAppearance` path as any other restore, then
re-sends `open` so every slider, cycle row and swatch re-seeds from the ped
rather than showing the values the player last dragged. It does not close the
screen — it is an undo, not an exit. It takes Cancel's slot in create mode
(exactly one of the two ever shows), keeping the bar at three buttons.

> **Order is load-bearing in that handler.** `HeadBlend.Reset()` zeroes every
> cached blend/feature/overlay value, so running it *after* the apply would
> wipe what was just restored: the ped would show the reverted look while
> `buildOpenPayload` reported zeros and every slider snapped to 0. Clear first,
> then apply — the same order `openAppearanceScreen` uses. Pinned by an
> ordering assertion in `tests/suites/15_appearance_nui.lua`, which had to be
> fixed once itself: the first version matched the `HeadBlend.Reset()` mention
> inside the explanatory comment above the code and stayed green when the order
> was deliberately inverted.

**Verified at 1280x720** with an emulated viewport: the panel stays 380px, the
camera region tabs stay clear of it, and Save stays on screen on every tab.
Three buttons in a fixed 380px bar wrapped their labels onto two lines, so the
save-bar metrics were tightened to keep them on one.

## 2026-08-05, rendered in a browser for the first time

`html/index.html?preview=1` exists for exactly this and had never been used.
Three things showed up immediately.

**The panel was one flat mega-scroll.** Measured: **1885px of content in a
945px panel** — every slider, every wardrobe row, all three 64-swatch colour
grids and the save bar, stacked in a single scroll. "Save & Continue" sat
~940px below the fold. Character creation is a **mandatory step with no cancel
path**, so the primary action of the screen was reachable only by scrolling a
panel that gave no indication it scrolled. (It *was* reachable — the panel
scrolls — so this was not a softlock, but it is the first thing a new player
meets.)

Fixed the way every appearance editor on the market does it: **section tabs**
(Face / Wardrobe / Colors / Tattoos) with only one section mounted at a time,
a scroll container that is *just* the section body, and the save bar **pinned
outside it**. Verified at both a 945px and a 768px panel height: the save bar
stays on screen on every tab, and only Colors needs to scroll its body at all.
The camera follows the section — Face and Colors frame the head, Wardrobe the
whole body, Tattoos the torso.

**The colour swatches were a lie.** The grid painted itself with a generated
HSL rainbow (`hsl(i / 64 * 360, 55%, 45%)`), so swatch 10 rendered lime green
while the hair colour it selects is brown. GTA's 64 hair colours are blacks,
browns, blondes, greys and reds with a block of unnatural shades at the end.
The palette is now **read out of the game** with `GET_PED_HAIR_RGB_COLOR`
(`Game.GetHairRgbPalette`, guarded so a build without the native degrades to
neutral swatches) and passed to the NUI on open — captured, never authored,
the same rule `docs/CUSTOM-CLOTHING.md` applies to drawable indices.

**Eye colours are not colours.** They are texture variations on the eye and
the game exposes no getter that turns an index into an RGB value, so every
colour shown for them was invented. They render as numbered chips now.

Smaller, same pass: `.btn` is `flex: 1` (so the three save-bar buttons share
its width), which inside a section header made "Randomize" swallow all
remaining space and run into the heading text; and the section `<h2>`s now
duplicate their own tab label, so they are visually hidden and kept for screen
readers.

**A regression the same session found, caused by the palette fix itself.**
`buildSwatchGrid` was `(container, total, selectedId, onSelect)`. Adding a
`colorFor` parameter *ahead of* `onSelect` silently repurposed the overlay call
site's callback: `colorFor` became the apply-colour function and `onSelect`
became `undefined`. So **building** an overlay's colour grid called the
apply-colour callback once per swatch — 192 spurious `setHeadOverlayColor`
posts on open across the three colour-capable overlays, leaving every one of
them set to colour 63 — the swatches rendered blank white (the callback returns
nothing), and clicking one threw `onSelect is not a function`. Measured in a
browser: **192 posts on open before, 0 after.**

Fixed at the root rather than at the call site: `buildSwatchGrid` now takes a
**named options object**, which cannot be silently reordered. Overlay colour
swatches are painted from the same live hair palette they apply (the apply call
has always passed `colorType: 1`, the hair colour table), so the swatch shows
the colour it sets.

The preview stub was also made faithful: it now sends the real
`Config.FaceFeatureLabels` trait names (it sent none, so the preview rendered
"Feature 1".."Feature 20" — the exact label problem an earlier pass had already
fixed in the game path), the real seven `Config.WardrobeComponents` slots, and
`overlayDefs` carrying the `count`/`hasColor` fields the variant cycler and
colour picker key off. A stub that agrees with the code instead of with the
payload is how the `palm6_charselect` field bug survived two reviews.

Pinned by `tests/suites/15_appearance_nui.lua` (34 assertions, trap-verified:
moving the save bar back inside the scroll container turns it red).

## 2026-08-05 — the editor was cosmetically inert. Six defects, all fixed.

A market-parity pass against the premium appearance/multichar scripts started
by asking what this resource was missing, and found instead that the thing it
was for did not happen at all. All six below were verified by reading the code
paths end to end (and, where it mattered, the real qbx_core source), not
inferred.

1. **The finished appearance was never applied to the player.** `save` built a
   payload, sent it to the database, deleted the preview ped, and resolved its
   callback. Nothing anywhere put any of it on the real ped. A player spent as
   long as they liked in the creator and then spawned in whatever random
   freemode look qbx_core's own `createCharacter` had already assigned
   (`client/character.lua`'s `randomPeds`). Fixed: `applyToRealPlayer` sets the
   model and applies the payload inside `closeAppearanceScreen`.
2. **The player's ped model was never set either**, so the male/female choice
   made at character creation had no effect on the body they spawned in.
3. **Saved appearances were never read back.** `palm6_appearance:server:load`
   shipped registered and called by *nothing* — a repo-wide grep found exactly
   one hit, its own registration. Every save went into a table that was written
   and never read; every rejoin was another random look. Fixed: a
   `QBCore:Client:OnPlayerLoaded` handler restores it (`Config.RestoreOnPlayerLoaded`).
4. **The payload carried no model stamp**, in direct conflict with
   `docs/CUSTOM-CLOTHING.md` §5 ("store the model string with the capture, and
   refuse to apply a capture whose stored model does not match the target ped.
   Do not guess and do not fall back") — male and female drawable index spaces
   are disjoint, so the same integer is a different garment on each. Fixed:
   `model` + `gender` + `version` are stamped on save, and
   `applySavedAppearance` refuses outright on a mismatch or a missing stamp.
5. **The whole creator ran behind a black screen** when entered from
   `palm6_charselect`. That resource hands off via
   `Game.TeardownSceneKeepPedHidden`, whose last line is `DoScreenFadeOut(0)`,
   and this resource contained no fade call of any kind (grepped: zero hits for
   `DoScreenFadeIn`). Nothing faded back in until charselect's post-creation
   callback, long after the player had finished. Fixed: `openAppearanceScreen`
   fades in once the scene is ready; `closeAppearanceScreen` fades out before
   swapping the ped model and hands back black in create mode, which is what
   the caller expects.
6. **`palm6_appearance:server:save` did no validation**, under a comment
   claiming it did ("server-side re-validation mirrors client clamps — never
   trust the client for ranges"). The real check was `type(payload) == 'table'`;
   everything else was stored verbatim. Since the stored row is read back and
   applied to a ped, and now feeds `SET_PLAYER_MODEL`, that was an
   arbitrary-write into what a player looks like — including their model. Fixed:
   `sanitizeAppearance` enforces shape, numeric ranges, and an **allowlist of
   the two freemode models**, dropping unknown keys instead of passing them
   through. `tests/suites/13_appearance_payload.lua` pins it (45 assertions,
   lifted from the shipped source with `T.slice`, verified to go red when the
   allowlist is defeated).

Also added for the character-select screen: `exports('applyAppearanceToPed')`
(so `palm6_charselect` can dress its preview ped through *this* resource's
apply path and model guard rather than a second copy of it) and a server-only
`exports('GetAppearanceForCitizenIds')` batch read. `openAppearanceEditor` now
loads the character's stored appearance when the caller doesn't pass one, so a
re-edit opens on the look they are wearing instead of a blank default.

> ⚠️ **One thing to check on the box before the first ensure.**
> `Config.RestoreOnPlayerLoaded` re-applies a saved look on spawn. If the
> recipe-deployed `illenium-appearance` (or any other appearance resource) is
> running on this server, it does the same thing on the same event, and two
> resources dressing one ped in one frame is a load-order race. Decide which
> one owns appearance and turn the other off. Nothing in this repo can detect
> that from here — those resources live outside `resources/[custom]/`.

## What it does

- **New-character flow**: exposes `exports('startPlayerCustomization', function(callback, config) ... end)`,
  matching the shape qbx_core's mandatory new-character step is expected to call
  (see "qbx_core integration" below).
- **Re-edit flow**: exposes `exports('openAppearanceEditor', function(genderKey, savedAppearance, onDone) ... end)`
  for changing appearance after the character already exists (allows Cancel; the
  new-character flow does not).
- **Camera**: bone-indexed orbit camera (`whole` / `head` / `torso` / `legs` / `shoes`
  regions), each with its own zoom baseline, pitch, FOV and depth-of-field strength.
  Region swaps use `SetCamActiveWithInterp` (250ms) with a DOF ramp running in
  parallel; free-drag rotate/zoom repositions the camera directly (no interp) for
  1:1 responsiveness.
- **Face**: `SetPedHeadBlendData` 3-parent shape/skin blend + mix sliders, 20
  `SetPedFaceFeature` sliders (each labeled with its real trait name —
  "Nose Width", "Jaw Bone Shape", etc, `Config.FaceFeatureLabels`, sourced
  from the canonical FiveM native reference — not "Feature 1".."Feature 20"),
  head overlays (eyebrows, makeup, blemishes, etc — each with a live
  `GetNumHeadOverlayValues`-bounded variant picker AND, for the overlays that
  support it, a 64-swatch color picker via `setHeadOverlayColor`, not just an
  opacity slider), hair color/highlight, eye color. "Randomize" only rolls
  face-blend values inside configured ranges. "Randomize All" is actually
  comprehensive: face blend + all 20 face features (`HeadBlend.RandomizeFeatures`,
  biased toward the middle of the range so 20 simultaneous rolls don't produce
  a distorted face) + overlays (`HeadBlend.RandomizeOverlays`) + hair/eye color
  (`HeadBlend.RandomizeColors`) + every configured wardrobe component/prop
  (`Wardrobe.RandomizeAll`) — still only ever picking live-enumerated, validated
  indices, never a guessed one, and never streaming anything.
- **Tattoos: current scope.** There is no true opacity native for ped decorations,
  and this resource ships no tattoo *catalog* — `client/headblend.lua`'s
  `EnumerateTattooTiers`/`ApplyTattooTier` can only cycle across *existing*
  pre-baked density-variant decoration hashes already mounted on the ped (when a
  design ships sibling variants), never apply a brand-new design. No UI calls
  `setTattooTier` today because there is nowhere in the UI to pick a starting
  `collectionHash` from — that would require enumerating the game's tattoo-shop
  catalog by zone, which is not built. Decorations are also **not** captured or
  restored by save/load (`buildAppearancePayload`/`applySavedAppearance` in
  `client/main.lua` don't touch them) — a tattoo applied to the preview ped this
  session is gone on next open regardless. The one tattoo control actually shipped
  is "Clear Tattoos" (`ClearPedDecorationsLeavingScars`), useful for a preview ped
  that inherited decorations from a prior session. A real tattoo shop is future
  work, not a hidden bug.
- **Wardrobe**: cycles drawables/textures/props via `SetPedCollectionComponentVariation`
  / `SetPedCollectionPropIndex`, using indices obtained ONLY from live capture
  (`GetPedDrawableVariationCollectionName`/`...LocalIndex`) or bounded enumeration
  (`GetNumberOfPedCollectionDrawableVariations` etc), each validated with
  `IsPedCollectionComponentVariationValid` / `IsPedCollectionPropValid` immediately
  before every apply. `paletteId` is hardcoded `0` everywhere — never `2` (the
  retired `palm6_threads` bug is not repeated here). Component slots shown:
  **hair**, mask, torso, legs, shoes, undershirt, jacket
  (`Config.WardrobeComponents`); prop slots: hat, glasses, ears
  (`Config.WardrobeProps`). Cycle-row counts (e.g. "3 / 12") and color-swatch
  selection are seeded from a live capture on open
  (`buildOpenPayload`'s `wardrobeState`), not left at "0 / 0" until the
  player clicks an arrow.
- **Persistence**: owns its own table, `palm6_appearance_data`, self-created
  at boot (`server/main.lua`'s `ensureSchema`, `palm6_heat`'s precedent — idempotent
  `CREATE TABLE IF NOT EXISTS`, no manual migration step), keyed by `citizenid`.
  Does not write into qbx_core's player-metadata shape, since that key name is
  unverified (see below). Covers face blend, features, overlays, hair/eye color,
  components and props — does NOT cover tattoos/decorations (see above).

## Safety compliance (no new streamed assets)

- No `stream/` directory anywhere in this resource, no `data_file`, no addon-DLC
  pack, no hand-authored drawable/texture/prop index anywhere in the tree.
- Preview peds are restricted to exactly `mp_m_freemode_01` / `mp_f_freemode_01`
  via `Config.AllowedPreviewModels` — both already resident on every multiplayer
  client, so selecting either streams nothing.
- Every wardrobe read/write goes through `client/wardrobe.lua`, which never types
  a literal drawable/texture/prop index by hand.
- Every native call in this resource lives in exactly two files:
  `bridge/cl_game.lua` (GTA natives) and `bridge/sv_framework.lua` (qbx_core
  exports). Verify with:
  ```
  grep -rn "qbx_core\|\.Functions\.\|PlayerData" server/ client/
  grep -rn "AddBlipFor\|GetEntityCoords\|PlayerPedId\|CreatePed\|SetPedComponentVariation\|SetPedHeadBlendData" server/ client/
  ```
  Both must return nothing outside `bridge/`.

## qbx_core integration — assumptions and fallback

**Confirmed with reasonable confidence**: qbx_core's own new-character flow does not
render its own appearance screen; it calls out to an external customization
resource. This is documented behavior for `illenium-appearance` via
`exports['illenium-appearance']:setPedAppearance(...)` / `startPlayerCustomization`,
and qbx_core's docs describe appearance as a pluggable step rather than a built-in
screen.

**NOT verified against this server's live `qbx_core` install**:

1. The exact export name/signature qbx_core's `client/character.lua` actually calls
   on the new-character step.
2. Whether a config key (e.g. something like `useExternalCharacters` /
   a resource-name setting) lets PALM6 point that call site at `palm6_appearance`
   instead of `illenium-appearance`, or whether it requires a small patch to
   qbx_core's `character.lua`.
3. The exact multichar hand-off sequence around `Bridge.CompleteCharacterCreation`
   (`exports.qbx_core:Login(source, citizenid, newCharData)`) in
   `bridge/sv_framework.lua` — this export name/signature is a best guess pending
   verification.
4. Whether/when to call `ShutdownLoadingScreen()` / `ShutdownLoadingScreenNui()` —
   this resource does not call either; it assumes `palm6_onboarding`'s existing
   `Game.OnPlayerLoaded` / mandatory-dialog sequencing owns that, and appearance
   should slot into the same sequence rather than racing it independently.

**Design choice to make this safe regardless**: `client/main.lua`'s
`startPlayerCustomization` export mimics the documented default contract
(`callback, config` in, `callback(appearanceTable)` resolved on save) exactly, so if
qbx_core ends up needing a straight resource-name swap (config key or a one-line
patch to point at `palm6_appearance` instead of `illenium-appearance`), no logic in
this resource needs to change — only which resource answers the call.

## Manual verification required before the first `ensure` on the live server

Per `docs/CUSTOM-CLOTHING.md` precedent (two prior production outages were caused by
resources that touch the spawn/appearance flow going straight to a live `ensure`),
do NOT `ensure` this resource on a populated server. Before the first `ensure`,
in order:

1. **Read qbx_core's actual source off the live box** (not a GitHub search
   snippet) — `client/character.lua` and any `config/*.lua` that governs the
   appearance-resource hand-off. Confirm the three "NOT verified" items above.
   If the export name/signature differs from `startPlayerCustomization(callback,
   config)`, either add a thin adapter export under that exact name in
   `client/main.lua`, or (only if there's no config-key redirect available) patch
   qbx_core's call site — do not fork/patch qbx_core as a first move.
2. **Confirm `Bridge.CompleteCharacterCreation`** (`bridge/sv_framework.lua`)
   against the live `qbx_core` server export table — `exports.qbx_core:Login(...)`
   is a placeholder pending that confirmation.
3. **Nothing to apply manually.** The `palm6_appearance_data` table self-creates
   at boot (`server/main.lua`'s `ensureSchema`, idempotent `CREATE TABLE IF NOT
   EXISTS`) the same way `palm6_heat_state` does — CI never touches the DB, so
   this must stay boot-safe.
4. **Run `node tools/audit/run.js`** before the first `ensure` — must not introduce
   any new failure beyond the repo's pre-existing baseline.
5. **First `ensure` happens on a quiet server** (David + one other person only),
   never on a populated live server. Use the `/palm6appearance [male|female]`
   command (client/main.lua) to open the screen standalone for QA — this bypasses
   the qbx_core hand-off entirely and is the safe way to test camera/blend/
   wardrobe systems in isolation before wiring the mandatory new-character step.
6. **Verify the tattoo-tier natives** (`GetPedDecorationsCount` /
   `GetPedDecorationCollectionAt`, flagged VERIFY in `bridge/cl_game.lua` and
   `client/headblend.lua`) actually exist on this build's natives table. If not,
   the code degrades to "no tiers found" and the opacity control stays disabled —
   confirm that degrade path is what actually happens in-game, not a silent error.
7. **Nothing in this README or setup should ever instruct anyone to `ensure`,
   `start`, or `restart palm6_threads`** — that resource stays stopped per
   `custom.cfg:334`, unrelated to this build.

## File tree

```
palm6_appearance/
├── fxmanifest.lua
├── README.md
├── bridge/
│   ├── cl_game.lua        — the ONLY file that calls GTA natives
│   └── sv_framework.lua   — the ONLY file that calls qbx_core exports
├── shared/
│   └── config.lua         — tunables only, no native/framework calls
├── client/
│   ├── camera.lua         — bone-indexed orbit camera + DOF ramp
│   ├── headblend.lua      — 3-parent face blend, features, overlays, tattoo tiers
│   ├── wardrobe.lua       — capture-and-reapply wardrobe, existing indices only
│   └── main.lua           — orchestration, NUI callbacks, qbx_core export hand-off
├── server/
│   └── main.lua           — save/load, self-creates palm6_appearance_data at boot,
│                             routes all DB/framework calls through Bridge.*
└── html/
    ├── index.html
    ├── style.css           — vanilla CSS, --p6-* tokens, no build step
    └── script.js           — vanilla IIFE, no framework, no bundler
```

No `stream/` directory anywhere in this tree, ever — this is a structural
guarantee, not a configuration flag.
