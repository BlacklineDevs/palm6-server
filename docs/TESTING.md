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

## 6. Staff toolkit — `gtarp_staff`

- [ ] `/tp`, `/tpm`, `/bring`, `/goto`, `/revive`, `/heal`, `/giveitem`
      behave for `group.admin` / `group.mod` per the ACE matrix in
      `custom.cfg`; a `group.trial` principal is limited to `/coords`.
- [ ] Each staff action writes an `audit_log` row.
- [ ] If `gtarp:staff_webhook` is set, actions post to the Discord webhook.
- [ ] Non-staff cannot run staff commands (ACE denies).

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

## 12. Housing — `gtarp_housing`

- [ ] On boot the console prints `[gtarp_housing] loaded N properties`
      (N ≥ 4 from the seeded catalog).
- [ ] For-sale property doors show a blip (Config.ShowForSaleBlips) and a
      `[E] to buy ($price)` prompt in range.
- [ ] Buying with enough bank charges the price and flips the door to owned;
      buying without funds is refused.
- [ ] Owner `[E]` menu offers Enter / Give key to nearest / Manage keys /
      Sell back; **Enter** fades you into the shell interior, `/exithome`
      returns you to the door.
- [ ] `/stash` inside opens the per-property stash; items persist on relog.
- [ ] Give a key to a second player → they get an Enter prompt; revoke removes
      it. **Sell back** refunds 50% and re-lists the property.
- [ ] Two people entering the same home share one instance; different homes
      don't overlap (routing buckets).

## 13. Grind jobs — `gtarp_grind`

- [ ] Buy a Fishing Rod / Pickaxe / Hunting Knife at the Hardware Store
      (Sandy Shores / Paleto).
- [ ] At a gather spot, `[E]` runs a progress bar and grants the yield; doing
      it **without the tool** is refused; spamming hits the 8s cooldown.
- [ ] Selling at the matching buyer pays cash for the whole stack; the price
      rises as your activity XP climbs (check across several sells).
- [ ] XP persists across relog (`grind_skill` table).
- [ ] All three loops (fishing / mining / hunting) complete solo.

---

## 11. Triage — common failures

| Symptom | Likely cause |
| --- | --- |
| Can't join at all | `gtarp_allowlist` enabled with empty allowlist — see §0. |
| `attempt to index nil (global 'Bridge'/'Game')` | Bridge script not loaded before logic — check `fxmanifest.lua` load order (bridge line above the logic line). |
| Welcome / spawn never fires | Framework loaded-event not reaching the bridge — confirm `qbx_core` started before `server_base`/`server_identity`. |
| `/coords` "access denied" for admin | Missing `add_ace group.admin command.coords allow` (in `custom.cfg`) or principal not mapped to `group.admin`. |
| Courier escrow not charged | oxmysql not connected, or `qbx_economy_overrides` not started before `gtarp_courier`. |
| A `[custom]` resource missing | Its `ensure` line missing from `custom.cfg`, or the folder wasn't copied into the live `resources/` tree. |
| DB errors on boot | SQL migrations in `sql/` not applied in order to the Qbox DB. |
