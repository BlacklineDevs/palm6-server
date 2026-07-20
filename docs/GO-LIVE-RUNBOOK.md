# PALM6 Go-Live Runbook (2026-07-20 session)

Consolidates the unpushed work on `feat/defjam-fightclub-phase0` (7 commits ahead
of `origin/main`) into a clean deploy sequence. Deploy = push to `origin/main` →
CI (SFTP mirror + FXServer restart) → **hit Start in the RocketNode panel** (the
restart stops the server; it does not auto-start).

## What's in the batch (7 commits)
| Commit | What | Live impact on deploy |
|---|---|---|
| `510b13e` | palm6_business built | **DARK** (Config.Enabled=false) — inert |
| `0155c5b` `63a0d46` | palm6_business audit + re-verify hardening | DARK — inert |
| `802e992` | docs: BETA-CONTENT-PACK.md | docs only |
| `12e6c6a` | **beta-readiness fixes** (allowlist hang, gang/fc griefing) | **LIVE** — ships the fixes |
| `dbd65f4` | /help accuracy (dead fc commands, +/market +racing) | LIVE — curated data |
| `3f1613f` | allowlist AllowedRoles = sync-parity roles | inert until convars set |

**dbmigrate lands on boot:** `0068` (palm6_business tables) + `0009` (the
`allowlist` table — closes the connect-gate-hang risk on a rebuilt DB).

## Recommended sequencing

### Step 1 — deploy the beta-readiness fixes NOW (independent of the dark feature)
The connect-gate-hang fix, the gang/fc griefing guards, and the /help accuracy are
real beta hardening and are safe to ship (business stays dark). Merge `feat` →
`main`, push, let CI run, **Start** in RocketNode. Verify boot (below).

### Step 2 — (optional) real-time admit convars
The founding beta ALREADY admits @Whitelisted testers via the running
`HorizonAllowlistSync` (~10 min). The convars only add *instant* role-based admit.
If you want them, in the panel's `server.cfg` editor add these BEFORE
`exec custom.cfg`:
```
set palm6:discord_bot_token "<paste DISCORD_TOKEN from C:\Users\Mgtda\Projects\Active\palm6-bot\.env>"
set palm6:discord_guild_id  "1522465866837393418"
```
Then restart. The `palm6_allowlist` boot banner will print `SET`/`UNSET` for both
and the configured role count. NB: this only takes effect once Step 1 is deployed
(the updated AllowedRoles ships in `3f1613f`).

### Step 3 — enable palm6_business (AFTER your in-game feel-test)
Flip `resources/[custom]/palm6_business/shared/config.lua` → `Config.Enabled = true`,
push, restart, Start. Feel-test: `/business` → register → deposit → hire → buy
stock → serve → charge a nearby player → run payroll → withdraw → view ledger.
To prove crash-recovery: withdraw a large sum, kill/restart the server mid-payout,
confirm the boot reconcile re-pays (or the account is made whole). Revert = flip false.

### Step 4 — racing + fight club
Both are currently enabled via feel-test toggles (`Config.Enabled=true`). If you
keep them, the /help entries added in `dbd65f4` are correct. If you re-dark either,
prune its /help category (commands self-gate meanwhile).

## Boot verification (after each deploy + Start)
- Console shows `[palm6_business] loaded DARK ...` (until Step 3) and the
  `[palm6_allowlist] ===` banner with role count + convar SET/UNSET.
- `[palm6_dbmigrate]` prints `OK` for `0068 ...` + `0009 allowlist`.
- 0 SCRIPT ERROR (FiveM drops erroring resources → all-present = clean).
- A whitelisted account can connect (allowlist admits).

## Still needs you (not code)
- **Mockup:** generate `/business` page art from the brief (chat) → then I build the
  web `/business` directory against the final design + real data.
- **Convars:** panel login is CAPTCHA/password-walled (human-only) — Step 2 above.
- **Coords:** physical business storefronts + real race routes need `/coords` in-game.
</content>
