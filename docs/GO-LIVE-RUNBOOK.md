# PALM6 Go-Live Runbook

_Refreshed 2026-07-20. Supersedes the earlier 7-commit version — the branch has
grown to 18 commits and `main` has moved on independently (see the divergence
warning below, it is the most important section)._

Deploy = get the work onto `origin/main` → CI (SFTP mirror + FXServer restart) →
**hit Start in the RocketNode panel** (the restart stops the server; it does not
auto-start).

---

## 0. Current truth: what is LIVE vs what is pending

**LIVE in production now (`origin/main` @ `994f875`):**
- `palm6_business` **core** — `Config.Enabled = true`, the ultracode-hardened
  version. Register / deposit / hire / stock / serve / charge / payroll /
  withdraw / ledger all live. Migrations `0068` (+ pending-column ALTERs) applied.
- `palm6_founder` — in-game Founding Tester tag from `palm6_founding_grants`.

**Pending on `feat/defjam-fightclub-phase0` (18 commits, NOT on main):**

| Group | Commits | Ships as | Prod impact when deployed |
|---|---|---|---|
| Beta-readiness fixes | `12e6c6a` allowlist connect-gate hang + gang/fc griefing | **NOT dark** | Ships hardening — wanted. See ⚠️ convars. |
| /help accuracy | `dbd65f4` | NOT dark | Curated command list corrected |
| Allowlist role parity | `3f1613f` | NOT dark | Inert until convars set |
| **Storefronts** (Phase 1a) | `667daf6` `2fe2331` | **DARK** `Config.Phase1Enabled` | None (gated off) |
| **Per-type mechanics** (1b) | `882a3f1` | **DARK** `Config.PerTypeMechanics` | None |
| **Manager role** (1c) | `e6a5ebc` `de85f42` `a7a91aa` | **DARK** `Config.ManagerRole` | None |
| **Transfer / close** | `46bc4db` `84e98f7` `ec612db` `828950f` | **DARK** `Config.OwnershipLifecycle` | None |
| **Register robbery** | `92221f7` | **DARK** `Config.Robbery` | None |
| **Interiors** (Phase 1b — enterable buildings) | `feat/business-interiors` | **DARK** `Config.Interiors` | None (gated off) |
| **Extort owned biz** | (this session) | **DARK** `palm6_protection Config.ExtortOwned` | None |
| Docs | `802e992` `75a6131` this file + specs | docs only | None |

> The 🔴 **allowlist connect-gate-hang fix (`12e6c6a`) is NOT yet in production.**
> On a rebuilt/fresh prod DB the old code can hang every join on "Checking
> allowlist…". Shipping this batch is real hardening, not just new features.

---

## 1. ⚠️ DIVERGENCE — read before any merge to main

`main` and the feature branch split at `b902bf0` and **both added
`palm6_business` independently** (main took a snapshot of it via `994f875`; the
feature branch kept evolving it). A blind `git merge feat → main` therefore:

1. **add/add-conflicts every `palm6_business` file** (both "created" them) — git
   cannot auto-resolve; you get conflict markers in all 7 business files.
2. **Would flip `Config.Enabled` back to `false`** — the feature branch's
   `config.lua` still says `Config.Enabled = false`. Taking the wrong side
   **turns the live business system OFF in prod.**
3. **content-conflicts `palm6_dbmigrate/server.lua` and
   `palm6_eventguard/config.lua`** — both branches added entries. The resolution
   MUST keep **both** main's founder/business-activation entries **and** the
   feature branch's storefront/payroll migrations + new eventguard budgets.
   Dropping either side breaks a resource silently.

`palm6_founder` is safe — the feature branch never touched it, so a merge keeps
it. (A `git diff main..feat` shows it as "deleted" only because the branch
predates it; a *merge* does not delete it.)

**This is the exact class of landmine that caused the wrong-version deploy on
`994f875`.** Do NOT hand-merge under time pressure.

### Safe deploy strategy (recommended)
Have the merge done as a **reviewed 3-way merge in a throwaway worktree**, then
verify a hard invariant checklist before pushing `main`:

- [ ] `Config.Enabled = true` (business stays LIVE)
- [ ] `Config.Phase1Enabled / PerTypeMechanics / ManagerRole / OwnershipLifecycle`
      all `= false` (new features ship dark)
- [ ] `palm6_founder/` present and unchanged
- [ ] `palm6_dbmigrate/server.lua` contains **both** the founder-era entries AND
      `0070` (storefronts) + `0071` (payroll-day)
- [ ] `palm6_eventguard/config.lua` contains **both** sides' budgets
- [ ] `git diff main <resolved> -- resources/[custom]/palm6_business` reads as
      "the newer hardened business + new dark gates", nothing removed
- [ ] resolved tree builds a clean boot (0 SCRIPT ERROR) in a test start if possible

Kai can produce the resolved `main` in a worktree on request so you only review +
push.

---

## 2. Deploy order once merged

### Step A — ship the batch (business stays as-is: LIVE + new gates dark)
Push the resolved `main`, let CI run, **Start** in RocketNode. Nothing player-
visible changes except the beta-readiness hardening and corrected /help. Verify
boot (§4).

### Step B — (optional) real-time admit convars
The founding beta already admits @Whitelisted testers via the running
`HorizonAllowlistSync` (~10 min). Convars only add *instant* role-based admit. In
the panel's `server.cfg`, BEFORE `exec custom.cfg`:
```
set palm6:discord_bot_token "<DISCORD_TOKEN from palm6-bot/.env>"
set palm6:discord_guild_id  "1522465866837393418"
```
The `palm6_allowlist` boot banner prints `SET`/`UNSET` + the role count.

### Step C — light up the dark gates ONE AT A TIME (each after its feel-test)
Order is your call, but flip one, deploy, feel-test, then the next. Every gate is
independent and reverts by flipping back to `false` + redeploy.

| Gate | Feel-test | Migration it needs |
|---|---|---|
| `Config.Phase1Enabled = true` (storefronts) | Owner: menu → Storefront → Place → blip appears on map → walk away → mgmt gated → walk back → serve at shop → customize blip → passerby sees read-only card → Move / Remove | `0070` (auto-runs on boot) |
| `Config.PerTypeMechanics = true` | For each type (restaurant/bar/garage/retail/dealership): serve → confirm its own payout/cooldown/cap/supply numbers + themed wording | none |
| `Config.ManagerRole = true` | Owner promotes an employee → Manager. Manager CAN hire/fire-below/payroll-once-per-day/buy-supply/serve. Manager CANNOT withdraw / setWage / rename / promote / **pay themselves**. Demote back. | `0071` (auto-runs on boot) |
| `Config.OwnershipLifecycle = true` (transfer/close) | Transfer to an employee (they become owner, you drop to employee). Close a test business (balance refunds to owner bank, roster + business deleted). | none |
| `Config.Robbery = true` (`/robstore`) | At a **placed storefront** you don't own, `/robstore` → skill-check → up to 25% of the register (cap $5000) lands CLEAN in your bank → 45-min per-business + 10-min per-robber cooldown → police alert → owner notified if online. **Needs `Phase1Enabled` (a placed storefront).** | `0072` (auto-runs on boot) |
| `palm6_protection Config.ExtortOwned = true` (`/shakedown`) | Stand at a **placed storefront on a turf zone your gang controls** → `/shakedown` → up to 15% of its real account (never wipes) lands as `black_money` → 30-min cooldown → owner notified if online → ledger shows `extortion`. Off-turf shop / empty register → nothing. **Needs `Phase1Enabled` (storefront to stand at) + turf control.** | none (reuses `palm6_protection_collections`) |
| `Config.Interiors = true` (Phase 1b — enterable buildings) | **First, capture shells (admin, one-time):** stand INSIDE a base-game enterable interior (24/7, Ammu-Nation, clothing store, etc.) → `/bizshell shell_restaurant 24/7 Store` → repeat per `Config.Interior.TypeShell` key (`shell_restaurant/bar/garage/retail/dealership`). **Then feel-test:** owner places a storefront → an **Enter** target/`[G]` appears at the door → walk in (screen fades, you teleport into the shell, props dress the room) → **[E]/target Leave** returns you to the door → owner menu → Storefront → **Interior style** picks a layout (bare/stocked/lounge/workshop/upscale) → re-enter to see it change. **Instancing:** two players entering the SAME business share one room; two DIFFERENT businesses of the same type do NOT see each other (separate routing buckets). **Needs `Phase1Enabled` (a placed storefront) + at least one captured shell for that type.** | `0073` (auto-runs on boot) |

**Interiors gotcha:** a business type with NO captured shell simply has no interior — the storefront works exactly as Phase 1a (blip + walk-up), the **Enter** option never appears. So capture the shells BEFORE (or right after) flipping `Config.Interiors`, or the gate looks like it did nothing. `/bizshell` itself is inert until `Config.Interiors = true`. **Two balance calls to make before going live** (both stem from true routing-bucket isolation): (1) **admin spectate** of players inside interiors breaks unless you extend `palm6_staff` (`Config.Interior.AdminBucketFollow`, a follow-up); (2) with `Config.Interior.PublicEntry = true`, a wanted player can duck into any enterable shop and vanish from a **police pursuit** — set `PublicEntry = false` or gate entry on wanted-state if that's abused. Both are documented in the config header.

All **seven** business-side gates live in `palm6_business/shared/config.lua`; the extortion
gate lives in `palm6_protection/shared/config.lua`. Note that **Robbery** (any player,
clean-to-bank) and **Extortion** (gang-with-turf, dirty `black_money`) are distinct
mechanics that can BOTH hit the same storefront — enable them one at a time and feel
the combined drain pressure on a business before running both live.

To prove crash-recovery on any money path: start a large withdraw/payroll, kill +
restart the server mid-payout, confirm the boot reconcile re-pays or makes the
account whole.

### Step D — racing + fight club
Both currently enabled via feel-test toggles. Keep or re-dark per your call; if you
re-dark either, prune its /help category (commands self-gate meanwhile).

---

## 3. Rollback
Every new gate: flip its flag to `false`, push, restart, Start. No data migration
is destructive (all `ADD COLUMN IF NOT EXISTS`), so a revert never loses rows.
Business core rollback (`Config.Enabled = false`) only hides the system — accounts
and ledgers persist.

## 4. Boot verification (after each deploy + Start)
- `[palm6_business] ENABLED — player-owned businesses live.` (core is on).
- `[palm6_dbmigrate]` prints `OK` for `0068`, `0070`, `0071`, `0072`.
- `[palm6_allowlist] ===` banner with role count + convar SET/UNSET.
- `[palm6_founder]` boots without error.
- 0 SCRIPT ERROR (FiveM drops erroring resources → all-present = clean).
- A whitelisted account can connect.

## 5. Still needs you (not code)
- **Web `/business` page:** art approval + founding-fee copy + owner-display policy
  before flipping `site.business.page = true` on palm6-web (page is safe dark now).
- **Convars:** panel login is CAPTCHA/password-walled (human-only) — §Step B.
- **Storefront coords:** owners place their own in-game; the placeholder
  `palm6_protection` `Config.Businesses` coords still say "VERIFY IN-GAME".
- **The merge (§1):** the one thing that must not be rushed.
