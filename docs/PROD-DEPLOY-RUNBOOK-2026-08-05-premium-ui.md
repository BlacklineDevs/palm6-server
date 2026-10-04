# Prod deploy runbook — palm6_charselect / palm6_appearance / palm6_radialmenu (2026-08-05)

Turnkey steps to get the three new premium UI resources live, safely, in
order. Written because none of this can happen automatically: qbx_core is
recipe-deployed and **not vendored in this repo** (see `docs/SETUP.md`), so
the one config edit that actually matters here has to happen by hand on the
live box, by someone with txAdmin/panel access — not by this repo's deploy
pipeline, and not by Claude, which has no such access.

Do not skip steps or reorder them. Every resource's own README has a
"Manual verification" checklist too — this runbook is the sequencing across
all three plus the parts that live outside this repo entirely.

## 0. Current state (as of this writing)

- `palm6_charselect`, `palm6_appearance`, `palm6_radialmenu` are built,
  reviewed twice (an adversarial code review + a follow-up polish/security
  pass), and `node tools/audit/run.js` is 8/8. **Still local, uncommitted.**
- `custom.cfg` already has `ensure palm6_charselect` / `ensure palm6_appearance`
  / `ensure palm6_radialmenu` wired in (after `ensure server_identity`).
- None of the three has ever been run against a live qbx_core build. Every
  qbx_core-facing call (`Game.GetCharacters`, `CreateCharacterViaQbx`,
  `LoginCharacterViaQbx`, the spawn-pipeline functions) was verified against
  a **cloned copy** of `github.com/Qbox-project/qbx_core` (main branch,
  2026-08-05) — not this server's actual deployed version. Confirm the two
  aren't meaningfully different before trusting any of this in front of
  real players (Step 3 below).

## 1. David reviews and approves the commit

Nothing below can start until this repo's changes are committed and pushed.
Review the diff (`git status` / `git diff` from repo root), then tell
Claude — or do it yourself — to commit and push to `origin/main`
(`BlacklineDevs/palm6-server`). This repo's own culture on prior prod
deploys was to wait for explicit push approval; same here.

Once pushed, GitHub Actions SFTPs `resources/[custom]/` to the live box
automatically (per Ward/LaunchWise's pipeline — confirm the deploy workflow
still targets `193.31.31.27:30149`, not a stale host, before relying on
this: `docs/PROD-DEPLOY-RUNBOOK-2026-07-08.md` flagged this exact
host-pointer risk once already). **This step alone does NOT make any of the
three new resources live** — they land on disk `ensure`d in `custom.cfg`
already, so they WILL start on the box's next restart unless Step 2 happens
first. If the deploy pipeline restarts the server automatically, either
pull the `ensure` lines from `custom.cfg` before pushing, or make sure Step
2 happens before the next restart — do not let this go live by accident on
a restart nobody was watching.

## 2. The one edit outside this repo: `qbx_core`'s own config

**Requires txAdmin or file access to the live box.** In the deployed
`qbx_core` resource's `config/client.lua` (NOT in this repo — it's part of
the recipe-provided base pack, lives in the game server's `resources/`
tree outside `[custom]/`), find:

```lua
characters = {
    useExternalCharacters = false, -- ...
```

Change `false` to `true`. This is the confirmed-real switch (read directly
from qbx_core's source) that fully disables qbx_core's own multichar UI —
without it, both qbx_core's default screen and `palm6_charselect` try to
run at once. `palm6_charselect` still wins the NUI-focus race regardless,
but the underlying double-UI state has never been tested and shouldn't be
relied on.

Restart `qbx_core` (or the whole server) for the config change to take
effect. **Do this and Step 3 back-to-back, on the same quiet-server window**
— there's no reason to run with `useExternalCharacters=true` and the new
resources not yet `ensure`d, or vice versa.

**Also worth doing while you're in there (separate, pre-existing issue, not
part of this rollout):** `[config_overrides]/qbx_core_overrides` publishes
`qbx:multichar_slots` / `qbx:character_name_*` / `qbx:character_dob_*` as
convars, but qbx_core's config has zero `GetConvar` calls anywhere — those
convars are silent no-ops. If the real character-count/name-rule values
matter (`config.characters.playersNumberOfCharacters` /
`defaultNumberOfCharacters`, currently `3` by default, and the name/DOB
validation logic in `config/server.lua` / `config/client.lua`), those also
need to be edited directly in qbx_core's own config files — there's no
convar path for them. Not blocking for this rollout (the new resources read
the real values live off `qbx_core:server:getCharacters`'s own return, so
they're correct regardless), but the site owner's assumption that those
convars are doing something is currently false.

## 3. Confirm the qbx_core version assumption holds

Before the first `ensure`, on the live box: check `qbx_core/fxmanifest.lua`'s
`version` line, or run `/version qbx_core` in console if available, and
sanity check it's reasonably close to whatever was current on
`github.com/Qbox-project/qbx_core`'s `main` branch on 2026-08-05 (this repo
has no way to pin or check that automatically). If it's wildly different,
grep the live `qbx_core/server/character.lua` and
`qbx_core/server/player.lua` for `lib.callback.register('qbx_core:server:` —
the four callback names this build depends on
(`getCharacters`/`createCharacter`/`loadCharacter`/`deleteCharacter`) and
the two confirmed exports (`Login`, `GetPlayer`) should all still be there
by name. If any are missing or renamed, `palm6_charselect` will fail loudly
(every qbx_core call in `bridge/cl_game.lua` is `pcall`-wrapped and returns
an explicit `ok` the caller checks — expect a `qbx_unavailable` /
`create_failed` error surfaced in the NUI, not a silent hang) rather than
soft-locking anyone, but better to catch it here.

## 3b. Decide who owns appearance: this repo, or `illenium-appearance`

**Added 2026-08-05 by the appearance fix pass. This is a second edit outside
this repo, in the same category as Step 2, and it has to be settled before the
first `ensure`.**

`palm6_appearance` now re-applies a character's saved look on
`QBCore:Client:OnPlayerLoaded` (it previously saved appearances and never read
them back, so nothing ever competed for that event). The Qbox recipe normally
deploys `illenium-appearance`, which does the same thing, on the same event,
from its own table. Two resources dressing one ped in one frame is a race whose
winner is load-order dependent, and the symptom is subtle: appearance sometimes
sticks and sometimes doesn't, per join, per player.

On the box, before the first `ensure`:

1. Check whether `illenium-appearance` (or `fivem-appearance`, or any other
   appearance resource) is in the panel's `server.cfg` / `resources/`. The
   read-only `http://<server-ip>:<game-port>/info.json` endpoint lists running
   resources without starting anything.
2. If one is running, pick one owner:
   - **PALM6 owns it** (expected, since `palm6_charselect` hands new
     characters straight into `palm6_appearance`): stop the other resource, or
   - **illenium owns it**: set `Config.RestoreOnPlayerLoaded = false` in
     `resources/[custom]/palm6_appearance/shared/config.lua` and push that
     before deploying. The editor still saves and still applies on save; only
     the on-join restore stands down.
3. If nothing else is running, no action — this is the clean case.

Whichever way it goes, **write down which one won** in the deploy notes. A
future "appearance randomly resets" report is unanswerable without it.

## 4. Stage the first `ensure`, on a quiet server

Per this repo's own `docs/CUSTOM-CLOTHING.md` precedent (two prior outages
both skipped exactly this step): **never the first `ensure` of a
spawn-flow resource on a populated live server.** David + at most one other
person online, not during normal play hours.

If `ensure palm6_charselect` / `palm6_appearance` / `palm6_radialmenu` are
already in `custom.cfg` from Step 1's push, this happens automatically on
restart — so Steps 2-4 really are "restart once, with useExternalCharacters
already flipped, on a quiet server," not three separate restarts.

Watch, end to end:
1. Loading screen closes, `palm6_charselect` opens (not qbx_core's default
   UI — if you see the default multichar screen, Step 2 didn't take effect;
   check the restart actually picked up the config change).
2. Select an **existing** character (use a throwaway/test account if
   possible) — confirm the camera cinematic plays once and the world
   reveals correctly, no black screen.
3. "+ New Character" — confirm the full creation form, then the hand-off
   into `palm6_appearance`'s customization screen, then a correct
   reveal/spawn at `Config.DefaultSpawn` (Legion Square,
   qbx_core's own `defaultSpawn` coordinate) with the ped visible and
   unfrozen — this is the exact sequence three separate bugs were found and
   fixed in during review (permanently invisible ped, black screen, fake
   cinematic) — confirm all three stayed fixed in the real environment, not
   just in the two agents' reasoning about it.
4. Delete the throwaway character (type-to-confirm), confirm the slot frees
   up, then `/palm6charselect_restore <citizenid>` and confirm it's
   recoverable.
5. Open the radial menu (`palm6_radialmenu`'s default keybind), confirm the
   example tree renders, a wedge selects correctly, back/escape work, and
   the SELECT sound plays (new this pass — silence would mean
   `PlaySoundFrontend`'s sound-set name isn't valid on this build, harmless
   but worth knowing).
6. `/palm6charselect_release <server id>` on a second test connection (or
   yourself after a deliberate restart mid-flow) — confirm the admin
   bail-out actually un-sticks a client.
7. Run `node tools/audit/run.js` one more time from the deployed checkout
   if you have shell access to the box, purely as a sanity check that
   nothing drifted between the push and the live copy.

**Added by the 2026-08-05 appearance/market-parity pass — these are the new
things to watch for, and each one maps to a specific defect that was fixed
blind and has never run in game:**

8. **The character creator is not black.** Entering it from "+ New Character"
   should fade up onto the preview ped. A black screen with a floating panel
   means the fade added to `openAppearanceScreen` isn't landing.
9. **The look you built is the look you spawn in** — right body, right face,
   right clothes. This is the fix that matters most; it never worked at all
   before this pass.
10. **It survives a rejoin.** Disconnect, reconnect, select the same
    character: same appearance. If it reverts to a random look, the on-join
    restore lost its race (see Step 3b) or the server callback timed out —
    the console prints `[palm6_appearance] appearance restore call failed`
    in the second case.
11. **A female character is female** in the creator and after spawn. The
    gender chosen on the creation form previously never reached the editor at
    all.
12. **The select screen shows real card data** — actual names, a real
    last-played date, cash/bank, job and grade. "Unnamed / Never played" on
    every card means the live qbx_core returns a different character shape
    than the one verified here (`charinfo.firstname`, `lastLoggedOut` in UNIX
    seconds); say so rather than working around it, and check
    `server/storage/players.lua` on the box.
13. **Delete is reachable.** The type-to-confirm button must actually unlock
    when the first name is typed. It could not before, because the expected
    word was always empty.
14. **The character stage.** A ped should be standing in frame, wearing the
    selected character's saved look, swapping as you move between cards. If
    there is no ped: not a failure by itself — no saved appearance, or the
    ground probe found nothing at the scene camera's look-at point. The cards
    fall back to initials and the layout stays centred, by design. Note which
    it was.
15. **Time/weather lock.** The select screen should look the same regardless
    of the server clock, and normal weather must return after spawning. If the
    world stays permanently sunny at 14:20 after you spawn,
    `Game.ClearStageEnvironment` isn't being reached on some teardown path.

**Added by the later 2026-08-05 passes. These are the parts that could not be
verified from the repo at all, so they need a deliberate look:**

16. **Does the stage ped actually turn?** The turntable calls
    `SetEntityHeading` on a ped that is also `FreezeEntityPosition(ped, true)`.
    That combination is standard in character-preview scripts and is expected
    to work, but it has not been confirmed on this build. If the ped stands
    still, set `Config.PreviewStage.turntable = false` — it is cosmetic and
    everything else works without it — and note it, rather than unfreezing the
    ped (an unfrozen preview ped can be shoved by traffic).
17. **Is the ped framed sensibly against the nameplate?** The name sits at the
    bottom of the centre column, roughly where a standing ped's legs are. The
    exact framing depends on `Config.SceneCamera`, which still wants an
    in-game look (step 3). Adjust the camera, not the CSS.
18. **No leftover ped after spawning.** Walk back to where the select-screen
    camera was pointed (qbx_core's `defaultSpawn`, near Legion Square). There
    must be no stray character standing there. A race that could leave one was
    fixed (`cancelPendingStage`), and this is how you would see it if any path
    was missed.
19. **Playtime.** Brand-new characters correctly show no playtime line at all
    (under a minute). Play one for a few minutes, disconnect, rejoin: the
    details rail should show it. **A restart loses at most 5 minutes per
    player by design** (`Config.PlaytimeFlushIntervalMs`) — there is
    deliberately no flush on resource stop, because that path cannot safely
    use `MySQL.await`. Confirm the `palm6_charselect_playtime` table appears at
    boot alongside `palm6_charselect_hidden`.
20. **Creator camera buttons.** The four buttons under the ped should rotate
    and zoom exactly like dragging and scrolling do, and holding one should
    repeat smoothly and stop the moment you release or move off it.
21. **`/palm6appearance` must be refused for a normal player.** Have a
    non-admin test account run it: it should do nothing. It is registered
    server-side with `restricted = true` and needs
    `add_ace group.admin command.palm6appearance allow` (wired in
    `custom.cfg`). If a normal player CAN open the editor, that is a free
    unlimited barbershop — every player can change their face at will, for
    free, forever. **The repo audit does not catch this**, because it only
    reconciles restricted registrations; there is a test for it instead.
22. **Reset.** In the creation flow (not a re-edit), hit "Randomize All", then
    "Reset": the ped must return to the look it had on open **and every slider,
    cycle row and swatch must match it** — if the ped reverts but the controls
    still show the randomized values, the clear/apply order in the `reset`
    handler has been inverted.

23. **The radial ring at 1280x720 — the one visual change nobody has seen
    rendered.** Two sizing fixes shipped from arithmetic, not from a
    screenshot, and both need eyes on them at a *small* window (720p, and
    1366x768 if you have it):
    - The centre hub is now `--radial-size * 176/460` instead of a fixed
      176px. It previously overhung the wedges by 27.5px at 720p, drawing its
      gold border across every one of them. **Check:** the hub's border must
      sit *inside* the wedge ring with a visible gap all the way round, at
      every window size.
    - Wedge labels went from 10.5 to 13.5 SVG units, with a 340px floor on the
      ring, because they were rendering at 6.9 real px at 720p. **Check:** the
      labels are readable AND do not collide with each other. Collision only
      becomes possible on a level with many wedges, so open the fullest submenu
      you have (register a few test items if the shipped tree is still the
      2-item example). If they do collide, lower `--radial-label-size` in
      `html/style.css` — the floor alone still gets you to 7.8px, so prefer
      shortening titles over dropping it back to 10.5.
24. **`qbx_radialmenu` is actually stopped.** `custom.cfg` now has
    `stop qbx_radialmenu` before `ensure palm6_radialmenu`. Confirm in the
    server console that palm6_radialmenu does **not** print its
    `WARN: qbx_radialmenu is STARTED` line at boot. If it does, the stop did
    not take (wrong resource name on this box?) and PageUp will open both
    menus with two owners fighting over NUI focus.
25. **The radial closes when you die.** Open it, then kill yourself
    (`/kill`, or any test method). The wedges must disappear and control must
    return — if they hang over the death screen, hold-E respawn will not
    register. Same check while cuffed, if that is easy to arrange.
26. **The bail-out, both branches.** `/palm6charselect_release <id>` now
    behaves differently depending on whether qbx_core has a character loaded,
    and the console confirmation says which it chose:
    - Aimed at a client sitting on the **select screen** (no character): it
      must reopen character select, and must **not** spawn them into the
      world.
    - Aimed at a client **mid-creation** (in the appearance editor): the
      editor must close cleanly and the player must end up spawned and in
      control — not holding a dead full-screen UI.
27. **A new character's first session counts.** Create a character, play for
    ~6 minutes (long enough to cross one periodic flush), disconnect, rejoin.
    Its card must now show a playtime line. Before this pass it banked as zero
    forever, so this is the check that the new `confirmCreate` round trip is
    actually landing. If creation now fails with "Character was not created",
    the round trip is being dropped — check the eventguard budget for
    `palm6_charselect:confirmCreate`.

## 5. Only after all of Step 4 passes clean

Open the server to normal play. Update `CHANGELOG.md`'s **📣 Public** blurb
(currently held back — see the 2026-08-04 entry) and post it once this has
actually been player-tested for a session or two, not the moment it boots
clean once.

## Rollback

If anything in Step 4 goes wrong: set `useExternalCharacters` back to
`false` in qbx_core's config, remove or comment the three `ensure` lines in
`custom.cfg`, restart. qbx_core's own default multichar UI takes back over
immediately — nothing about this rollout modifies qbx_core's own data
(character list, `players` table), only adds a new sibling table
(`palm6_charselect_hidden`) and a new column-free storage table
(`palm6_appearance_data`), both safe to leave in place unused.
