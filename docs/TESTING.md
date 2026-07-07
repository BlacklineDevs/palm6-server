# TESTING — smoke-test runbook for the gtarp custom layer

Run this after a boot to confirm every custom resource works and that the
GTA VI bridge refactor left behaviour unchanged. It complements
`docs/SETUP.md` (fresh box) and `gtarp-server/LOCAL-SETUP.md` (local solo
box). Nothing here needs GTA VI — it validates the live GTA V server.

The custom layer is **bridge-clean**: every resource under
`resources/[custom]/` keeps its logic in `server/` / `client/` and all
framework/native calls in `bridge/`. These tests assert the *behaviour* is
identical to the pre-bridge version — if a bridged resource misbehaves, the
bug is almost always in that resource's `bridge/` adapter, not its logic.

---

## 0. Before you can join — allowlist

`gtarp_allowlist` ships secure-by-default: `Config.FailOpen = false` and
`Config.AllowedRoles = {}` (empty). **With those defaults nobody can join** —
every connect is denied unless the player is allowlisted. Pick one for a
tester:

- **Local solo box:** already handled — `gtarp-server/staging/custom.cfg`
  comments out `ensure gtarp_allowlist`, so the gate is off. Re-enable before
  going public.
- **DB allowlist (recommended for staging):** add your license identifier:
  ```sql
  INSERT INTO allowlist (identifier, enabled) VALUES ('license:XXXXXXXX', 1);
  ```
  Find your license in the console: connect once (you'll be denied), then read
  the `gtarp_allowlist` deny line in `audit_log` / console, or run `/coords`
  from console after adding a temporary row.
- **Discord role:** set `gtarp:discord_bot_token` + `gtarp:discord_guild_id`
  convars and add your role id to `Config.AllowedRoles` in
  `resources/[custom]/gtarp_allowlist/config.lua`.

---

## 1. Boot-time checks (server console — before joining)

- [ ] No red `SCRIPT ERROR` / `Failed to load` lines for any `[custom]`
      resource during startup.
- [ ] Banner prints: `server_base started — version 0.1.0`.
- [ ] All custom resources report started. Quick check from console:
      `ensure` lines in `custom.cfg` all resolve — run `resmon 1` and confirm
      each of these is listed and green:
      `qbx_core_overrides, qbx_economy_overrides, qbx_police_overrides,
      qbx_ambulance_overrides, qbx_civilian_jobs_overrides,
      ox_inventory_overrides, qbx_density_overrides, gtarp_whitelist_jobs,
      gtarp_staff, gtarp_eventguard, gtarp_allowlist (if enabled),
      gtarp_courier, gtarp_perf, server_identity, server_base`.
- [ ] `/serverinfo` typed in the **server console** prints the identity line.
- [ ] **Contract self-tests** (dev boots only): enable with
      `set gtarp:devtest 1` in a cfg (txAdmin does NOT forward `+set` from
      the FXServer command line to the inner server) and confirm the console
      prints `[gtarp_devtest] ✔ N passed, 0 failed, 3 skipped` (32/0/3 as of
      the items+tables groups). Any FAIL line means a cross-resource
      contract broke — evidence v2 API, staff log sink, export shapes,
      an ExtraItems name missing from ox_inventory's runtime table (run
      `tools/patch-ox-items.sh`), or a gtarp table missing from the DB
      (apply the matching `sql/` migration) — do not ship. Production
      leaves the convar unset; the resource then prints one "disabled"
      line and does nothing.

---

## 2. Identity & spawn — `server_identity` + `server_base`

- [ ] Dark loading screen appears on join (owned by `server_identity`).
- [ ] Multichar UI shows **2** character slots (`qbx:multichar_slots`).
- [ ] New character spawns at **Legion Square**
      `vector4(195.17, -933.77, 30.69, 144.0)` after selection (a brief fade
      covers the reposition — this is `Game.PlaceAtSpawn` in the bridge).
- [ ] Welcome notification fires **once**, only after the character is fully
      loaded — never on the character-select screen
      (`server_base` → `Game.OnPlayerLoaded`).
- [ ] Log out to character select and pick a slot again → repositioned to
      Legion Square again (the one-shot guard re-arms via
      `Game.OnPlayerLoggedOut`).
- [ ] Discord rich presence shows the server name (needs a real
      `DiscordAppId` in `server_identity/config.lua`; placeholder = no
      presence, not an error).

## 3. Admin commands — `server_base`

- [ ] As an `group.admin` principal: `/coords` prints your `vector4(...)` to
      chat and console (`Bridge.GetCoordsAndHeading`).
- [ ] `/coords <id>` for another online player prints their coords.
- [ ] As a non-admin: `/coords` is rejected (ACE gate).
- [ ] `/serverinfo` in chat replies with the identity line
      (`Bridge.ChatToPlayer`).

## 4. Allowlist gate — `gtarp_allowlist` (only if ensured)

- [ ] A non-allowlisted player is denied with a friendly message
      (`DenyNoRole` / `DenyNoLink` / `DenyTimeout`).
- [ ] An allowlisted player (DB row or Discord role) joins normally.
- [ ] Each deny writes an `allowlist_deny` row to `audit_log`
      (via the `gtarp_staff` export).
- [ ] Behaviour parity: the "Checking allowlist…" progress text still shows
      during connect (`Bridge.OnConnecting` → `gate.update`).

## 5. Signature feature — `gtarp_courier`

- [ ] Set a map waypoint, then `/courierpost <bounty> <label>` → escrow is
      debited from your **bank** by the bounty (affordability pre-check
      blocks if you can't cover it).
- [ ] A routed delivery blip + GPS route appears to the accepting player
      (`Game.CreateRouteBlip`).
- [ ] Driving within the delivery radius (~8 m) auto-completes the run and
      pays the courier (`gtarp_courier:complete`).
- [ ] Rows land in `courier_postings`; a cancelled/expired posting refunds
      the poster (online = live credit, offline = DB `players.money` write via
      the bridge).

## 6. Staff toolkit — `gtarp_staff` (audit sink) + recipe commands

gtarp_staff registers NO commands (its duplicates of recipe commands were
removed 2026-07-03) — the commands below are the recipe's own, extended to
mods by the ACE matrix in `custom.cfg`.

- [ ] `/tp`, `/tpm` (qbx_core), `/revive`, `/heal` (qbx_medical) work for
      `group.admin` AND `group.mod`; goto/bring work via qbx_adminmenu's
      `/admin` menu; a `group.trial` principal is limited to `/coords`.
- [ ] Boot log shows `[gtarp_staff] audit-log sink online`.
- [ ] Actions logged via `exports.gtarp_staff:Log` (e.g. an allowlist deny,
      an eventguard violation) write an `audit_log` row.
- [ ] If `gtarp:staff_webhook` is set, logged actions post to the Discord
      webhook.
- [ ] Non-staff cannot run the recipe staff commands (ACE denies).

## 7. Job whitelist — `gtarp_whitelist_jobs`

- [ ] A staff/EUP principal can `/setjob` a player into a whitelisted
      emergency-services job (police/ambulance).
- [ ] A non-whitelisted principal is blocked with a notify
      (`Bridge.Notify`).
- [ ] The job actually applies (grade/duty) via `Bridge.SetJob`.

## 8. Anti-abuse — `gtarp_eventguard`

- [ ] Triggering a guarded money/inventory event from an untrusted client
      path is rejected and logged to `event_violations`.
- [ ] Legitimate framework money updates still work (paychecks, courier
      payout, banking).

## 9. Performance sampler — `gtarp_perf`

- [ ] `gtarp_perf` runs without error; p95/p99 frame/tick numbers are
      sampled (`Bridge` wraps `GetGameTimer`).
- [ ] If a report webhook/convar is configured, a perf report posts on the
      configured cadence.
- [ ] `/diag` from the txAdmin console prints three `[gtarp_perf]` lines
      (resource states / perf summary / eventguard violations). In-game as
      admin or mod it prints the same three lines to chat; a citizen
      without `command.diag` gets the standard access-denied response.

## 10. Economy & world config — `[config_overrides]`

- [ ] New character starts with **$500 cash / $5000 bank**
      (`qbx:starting_cash` / `qbx:starting_bank`).
- [ ] On-duty paycheck fires roughly every **7 minutes**
      (`qbx:paycheck_interval_minutes`, on-duty only).
- [ ] Shops open and sell the overridden catalog
      (`ox_inventory_overrides/data/shops.lua` + `items.lua`).
- [ ] Police / ambulance / civilian job configs reflect the overrides
      (armouries, grades, salaries).
- [ ] Population density matches `qbx_density_overrides` (peds/traffic feel).

## 11. Housing — removed, use `qbx_properties` (recipe)

`gtarp_housing` was reverted before merge — it duplicated the recipe's own
`qbx_properties` (buy/rent/keyholders/stash/enter-exit, plus furniture
decorating and a realtor `/createproperty` flow it didn't have). Test housing
via `qbx_properties` directly; there is nothing custom to verify here.

## 12. Grind jobs — `gtarp_grind`

- [ ] Buy a Fishing Rod / Pickaxe / Hunting Knife at the Hardware Store
      (Sandy Shores / Paleto).
- [ ] At a gather spot, `[E]` runs a progress bar and grants the yield; doing
      it **without the tool** is refused; spamming hits the 8s cooldown.
- [ ] Selling at the matching buyer pays cash for the whole stack; the price
      rises as your activity XP climbs (check across several sells).
- [ ] XP persists across relog (`grind_skill` table).
- [ ] All three loops (fishing / mining / hunting) complete solo.

## 13. Robbery — `gtarp_robbery` (ATM only)

- [ ] With `Config.MinPolice = 0`, draw a weapon at an ATM → `[E]` starts the
      hold-up; unarmed is refused.
- [ ] Completing the hold pays cash; moving away cancels it.
- [ ] A robbed ATM is on cooldown (10 min); a cancelled attempt only locks it
      ~60s.
- [ ] With a second player set on-duty police (`/setjob police` + on duty),
      starting a robbery pushes a **dispatch blip + notify** to that officer.
- [ ] Raising `Config.MinPolice` blocks robberies when too few cops are on.
- [ ] Store-register robbery is the recipe's own `qbx_storerobbery` — test
      that separately, it's not part of this resource.

## 14. Mechanic — `gtarp_mechanic`

- [ ] `/setjob mechanic` (or via `gtarp_whitelist_jobs`/admin) + go on duty at
      Benny's.
- [ ] Damage a vehicle's engine/body (crash it or `/giveitem` a weapon and
      shoot it) — a repair prompt appears when a mechanic is nearby, with a
      **second player standing near the vehicle**.
- [ ] `[E]` starts the repair; with no second player nearby, it's refused
      ("No one nearby to invoice").
- [ ] Completing the repair bar charges the nearby player's bank
      `Config.RepairCost` and credits the mechanic the same amount; the
      vehicle's engine/body health and visible damage are fully restored.
- [ ] The repaired vehicle is on cooldown — re-`[E]`-ing it immediately is
      refused.
- [ ] Cancelling the progress bar (move away) charges no one and repairs
      nothing.
- [ ] A non-mechanic (or off-duty mechanic) gets "You need to be on duty..."
      and no repair happens.

## 15. Evidence — `gtarp_evidence`

- [ ] On boot the console prints `[gtarp_evidence] evidence locker
      registered`.
- [ ] `/setjob police` + go on duty, then `/logevidence Found a weapon at
      the docks` → "Logged." — works from anywhere, no proximity needed.
- [ ] `/evidence` shows that entry (officer name, description, timestamp)
      in a read-only dialog, newest first.
- [ ] At Mission Row PD (`vector3(434.0, -983.0, 30.7)`), `[E]` opens the
      evidence locker stash; items placed there persist across relog.
- [ ] Off duty (or not police), `/logevidence`, `/evidence`, and the
      locker prompt all refuse with "You need to be on duty...".

## 16. Turf — `gtarp_turf`

- [ ] On boot the console prints `[gtarp_turf] loaded 6 turf zone(s)`.
- [ ] All six zones show a blip (white/unclaimed by default on a fresh DB).
- [ ] `/setgang <name>` into a gang, walk to a zone → `[E]` starts tagging;
      completing it flips the zone's `owner_gang` and blip colour/label.
- [ ] Without a gang (`PlayerData.gang.name == 'none'`), the tag attempt
      is refused ("You need to be in a gang...").
- [ ] Re-tagging a zone your own gang already holds is refused ("Your
      gang already holds this turf.").
- [ ] A second player in a rival gang can flip an already-claimed zone —
      no defender-presence requirement in v1.
- [ ] `/turf` shows a leaderboard (gangs ranked by zones held) plus any
      unclaimed zones.
- [ ] Restarting the resource preserves ownership (seeded via
      `INSERT IGNORE`, not reset).

---

## 17. Pumpcoin exchange — `gtarp_pumpcoin`

- [ ] Boot banner: `[gtarp_pumpcoin] exchange online — N coin(s) on the board`.
- [ ] `[E]` at an exchange laptop opens the NUI; minting a coin costs $5,000
      and the board lists it as `anon-XXX`, never the creator's name.
- [ ] Buying moves the price UP along the curve; selling moves it DOWN; a
      big single buy visibly pays its own slippage (unit price after >
      before).
- [ ] `/shill TICKER` (creator only): buyer within 12m gets 5% off; a buyer
      far away does not; 5-min cooldown enforced.
- [ ] Rug: dev-dump ≥80% of the premine in one clip → sale executes, buys
      halt, 🚨 RUGGED broadcast, and ~10 min later the creator is named
      server-wide + a fraud entry appears in `/evidence`.
- [ ] Economy sink check: mint + buy + immediate sell nets the player LESS
      than they put in (2% fee per fill; buys round up, payouts down).
- [ ] Boot warning fires if config makes the premine worth ≥ MintCost.

## 18. Replay black-box — `gtarp_replay`

- [ ] Boot banner: `[gtarp_replay] black-box online — 4 Hz ring, 90s
      window, 7d retention`.
- [ ] Gunshot damage between two players fires an incident; nearby clients
      upload (console shows accepted uploads); uninvited/duplicate/late
      uploads are refused.
- [ ] On-duty investigator at the scene: `/replayscenes` lists the scene,
      `/replay <id>` spawns alpha ghost peds re-enacting it; SPACE pauses,
      arrows scrub/speed, X stops.
- [ ] `/replay <id>` AWAY from the scene coords is refused (server-side
      proximity gate).
- [ ] `/replayattach <id>` files a REPLAY EXHIBIT into the evidence log.
- [ ] `/record`, `/clip`, `/editor` (qbx_smallresources) still work —
      zero interaction with the Rockstar Editor.

## 19. Streamer clout — `gtarp_clout`

- [ ] Boot banner: `[gtarp_clout] on air — 5 milestones, donations capped
      at $3000/hr`.
- [ ] `/golive` without a `streamer_phone` is refused; with one, LIVE head
      tag appears (visible to OTHER players) + overlay opens.
- [ ] Viewer math reacts: gunfire within 30m spikes viewers; standing
      still bleeds them; dying live spikes once then resets the stream.
- [ ] Donations arrive as in-game cash and stop at the hourly cap.
- [ ] Holding a milestone 3 ticks unlocks a brand deal; `[E]` at the
      pawnshop broker pays it exactly once.
- [ ] On-duty cop `/subpoena <id>` within 15m: streamer's last-24h VOD
      lands in the evidence log; out-of-range or off-duty is refused.
- [ ] `/clout` and `/streamers` render without errors.

## 20. Flash drops — `gtarp_flashdrop`

- [ ] Boot banner: `[gtarp_flashdrop] ready — 5 catalog entries, 6
      locations, scheduler ON`.
- [ ] `/flashdrop arm` (admin ACE): riddle broadcast → T-5 map blip →
      claim table spawns; per-player 8s checkout; **one pair per citizen**
      enforced on a second claim attempt.
- [ ] Serial supply is hard-capped: claim N+1 when cap is N is refused.
- [ ] Consignment boutique: list a pair, second player buys it, house
      takes 10%, provenance shows both owners.
- [ ] Report a serial stolen → boutique refuses it; fence (Sandy Shores)
      takes it at 40% retail; fakes fence at 5%.
- [ ] Counterfeit bench clones a PAST drop for $300; fake passes casual
      inspection but fails the boutique legit check.
- [ ] Self-disable check: remove its ox item registration → resource
      disables loudly at boot instead of half-working (re-run
      `tools/patch-ox-items.sh` to restore).

## 21. NPC witnesses — `gtarp_witnesses`

- [ ] Boot banner: `[gtarp_witnesses] ready — ... alerts off (default)`.
- [ ] Fire a gun near ambient peds → suspect gets the "someone saw that"
      notification; in the desert (no peds in 40m) no witnesses spawn.
- [ ] On-duty police see witness markers; `[E]` canvass writes the
      statement into a `gtarp_evidence` case file (facts match the
      suspect's REAL top colour / mask / vehicle / 3-char partial plate).
- [ ] Suspect (only) sees their own witnesses; holding a weapon on one
      ~5s corrupts future canvass facts; $750 payoff silences entirely.
- [ ] Intimidating a witness in view of ANOTHER witness spawns a fresh
      witness-intimidation incident against the suspect.
- [ ] Double-dispatch guard: with `Config.FirePoliceAlerts=true`
      (default), a store robbery produces exactly ONE police alert (the
      recipe's own — the policeAlert hook is qbxAlerts=true and can never
      re-alert), while unwitnessed gunfire produces none and witnessed
      gunfire produces exactly one bystander alert per suspect per 120s.
- [ ] Markers survive a resource restart (~30 min persistence).

## 22. Counterfeit cash — `gtarp_counterfeit`

- [ ] Boot banners: `restored N placed printer(s)` and `ready — items OK,
      evidence bags OK, 6 districts, 3 sinks, 2 fences`.
- [ ] Press placement: refused outside configured districts, refused
      within 50m of another press, 1 per character max.
- [ ] Print cycle (paper + ink, 20s, stay at the press) yields 4
      serialized `counterfeit_cash` wads (`CF-XXXXXX-NN`); wads never
      stack.
- [ ] Wads cannot be deposited, laundered, or bulk-exchanged — only
      sinks/fences/confiscation/evidence-bag remove them.
- [ ] Each ox_inventory transfer adds a provenance hop; hop 7 pushes the
      oldest off (trail caps at 6).
- [ ] Heavy printing raises district heat → police get a WIDE jittered
      area ping (never a pinpoint); `/counterfeitraid` within 15m of a
      press clears it.
- [ ] `marker_pen` on a wad reveals serial/wear/hands-passed.
- [ ] `/seizefake` consumes a qbx_police `empty_evidence_bag`, bags the
      wad, and `/runserial` at the evidence locker opens the lead cascade
      into the batch's network.
- [ ] Distinctness check: recipe `markedbills` from a store robbery still
      launder normally — the two systems never interact.

---

## 23. Discord announcer — `gtarp_discord`

- [ ] Boot banner lists live vs off feeds and matches the
      `gtarp:discord_*` convars actually set in `custom.cfg`.
- [ ] With no convars set: banner says `live: (none)`, gameplay in every
      producer (flashdrop, pumpcoin, clout, evidence, counterfeit) is
      unaffected, and no HTTP traffic leaves the server.
- [ ] With a feed configured: arm a flashdrop (`/flashdrop` admin path) —
      one "DROP INCOMING" embed lands in the channel with **no location**;
      mint a pumpcoin — one "NEW LISTING" embed with **no creator name**;
      `/golive` — one going-live embed only when the in-city announce also
      fires; open a new evidence case — one "CASE #N OPENED" embed in the
      police channel; push a district over the counterfeit heat threshold —
      one Weazel bulletin per ping cooldown, district label only.
- [ ] Rug pull: "RUG PULL" embed immediately (holder count, no identity),
      then "RUG REVEALED" embed with the name only after the in-city
      reveal fires.
- [ ] Flood clamp: >10 posts to one feed inside a minute drops the excess
      with a `[gtarp_discord]` console line; other feeds keep delivering.
- [ ] Bad webhook URL: console shows `delivery failed (HTTP 4xx)` lines,
      queue keeps draining, server stays healthy.
- [ ] devtest boot (`set gtarp:devtest 1`): GetStats/Announce contract
      PASSes; with a configured feed, exactly one `[devtest] contract
      probe` embed lands.

## 24. Insurance — `gtarp_insurance`

- [ ] Boot banner: `Mors Mutual open — N active policy(ies), N claim(s)
      processing; replay forensics ONLINE` (says `offline` if
      `gtarp_replay` is stopped — the no-scene fraud signal must disable,
      not fire).
- [ ] `/insure [plate]` away from the Little Seoul desk → "insurance
      desk" error. At the desk, on a vehicle you own → premium charged
      from bank, policy row in `gtarp_insurance_policies`, second
      `/insure` on the same plate → "already carries an active policy".
- [ ] `/insure` on a plate you don't own → rejected (server reads
      `player_vehicles`, not the client).
- [ ] Damage claim: `/fileclaim [plate] damage` with the vehicle absent →
      "bring the damaged vehicle into the city". With the vehicle present
      but <25% damaged → adjuster floor error. Damage it hard →
      claim files, payout = coverage × damage − deductible, lands in
      bank ~10 min later (sweep marks `paid` BEFORE crediting).
- [ ] Theft claim on a vehicle the DB says is stored → "stored, not
      stolen". On an out vehicle that is spawned in the world → "on the
      street right now". Out + nowhere in the world → files at full
      coverage minus deductible.
- [ ] Fraud: insure a vehicle and claim within the hour with no replay
      scene near it → claim `flagged_paid`, `gtarp_evidence` case opened
      (visible via `/mdtcase`), payout still lands.
- [ ] `/policy` lists active policies with hours left + processing claims.
- [ ] devtest boot: `insurance.GetSummary` shape PASSes; both
      `gtarp_insurance_*` tables present.

## 25. Police MDT — `gtarp_mdt`

- [ ] Boot banner: `desk online — N active BOLO(s), N report(s) on file;
      contract qbx_police_overrides, case system ONLINE` (contract says
      `built-in defaults` if the override resource is stopped).
- [ ] Every command refuses off-duty/civilian sources AND on-duty police
      not carrying `mdt_tablet` (buy it at the armoury shop).
- [ ] `/bolo test unit theft red sultan` → every on-duty officer gets the
      notify; row in `gtarp_mdt_bolos` expiring per the contract
      (default 60 min); with the police Discord feed configured, one
      "BOLO #N issued" embed.
- [ ] `/bolos` lists it with minutes left; `/boloclear [#]` resolves it;
      `/bolos` again → "no active BOLOs" once expired or cleared.
- [ ] `/mdtcases` lists open evidence cases (insurance fraud flags,
      witness canvasses, counterfeit leads all appear here);
      `/mdtcase [#]` prints status, opener, suspects, recent entries.
- [ ] `/mdtreport 0 [20+ chars]` files standalone paperwork;
      `/mdtreport [case#] [text]` also lands the text in the case file
      (check `/mdtcase` shows a `[report/gtarp_mdt]` entry). Short text →
      "write it up properly" error.
- [ ] `/warrant [citizenid] 0 [reason]` on a real citizen (grab a
      citizenid from `/mdtcase` suspects or the players table) → officers
      notified, row in `gtarp_mdt_warrants`; repeat on the same citizen →
      "already has active warrant" error. Fake citizenid → "no citizen
      with that id".
- [ ] `/warrants` lists it with age; `/mdtcase` on a case whose suspect
      has one shows `ACTIVE WARRANT #N` on the suspect line.
- [ ] `/book [citizenid] [case#] [charges]` → booking row filed, the
      citizen's active warrants flip to `served`, the case file gains a
      `[booking/gtarp_mdt]` entry, and the booked player (if online) gets
      the notify. `/warrantclear [#]` flips one to `dropped` instead.
- [ ] Physical side unaffected: recipe `/cuff` `/jail` `/unjail` still
      work exactly as before (this layer never touches them).
- [ ] `enabled = false` in `qbx_police_overrides` `Config.MDT` → boot
      prints the disabled line, no MDT commands exist.
- [ ] devtest boot: `mdt.GetSummary` + `evidence.ListCases` PASS; all
      four `gtarp_mdt_*` tables present.

## 26. Triage — common failures

| Symptom | Likely cause |
| --- | --- |
| Can't join at all | `gtarp_allowlist` enabled with empty allowlist — see §0. |
| `attempt to index nil (global 'Bridge'/'Game')` | Bridge script not loaded before logic — check `fxmanifest.lua` load order (bridge line above the logic line). |
| Welcome / spawn never fires | Framework loaded-event not reaching the bridge — confirm `qbx_core` started before `server_base`/`server_identity`. |
| `/coords` "access denied" for admin | Missing `add_ace group.admin command.coords allow` (in `custom.cfg`) or principal not mapped to `group.admin`. |
| Courier escrow not charged | oxmysql not connected, or `qbx_economy_overrides` not started before `gtarp_courier`. |
| A `[custom]` resource missing | Its `ensure` line missing from `custom.cfg`, or the folder wasn't copied into the live `resources/` tree. |
| DB errors on boot | SQL migrations in `sql/` not applied — run `tools/apply-migrations.sh` (on a DB that pre-dates the tool, `--baseline` ONCE first; see DEPLOY.md). |
| Custom items "don't exist" / flashdrop self-disables | Deployed `ox_inventory/data/items.lua` missing the GTARP block — run `tools/patch-ox-items.sh <resources-dir>` (CI does this for production deploys). |
