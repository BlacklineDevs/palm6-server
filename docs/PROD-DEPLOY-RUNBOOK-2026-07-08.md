# Prod deploy runbook — 2026-07-08

Turnkey steps to get the merged custom layer actually live on the
production game server.

**Updated 2026-07-08 afternoon**: the original draft below was written
against `ship`/`origin/main` (`dade10e`, 26 sql migrations, 25
`gtarp_*` resources). Since then, four rounds of independent security
audits (10 real bugs found+fixed) and two new signature resources
(`gtarp_bounty`, `gtarp_fightclub`) landed on local branch
`claude/integration-2026-07-08` — now **28 sql migrations, 26
`gtarp_*` resources**, fully boot-verified clean, but **NOT YET pushed
to `main`**. Nothing code-side is blocking; this is waiting on David's
explicit push approval. Check `git log main` / `git log claude/
integration-2026-07-08` to see which state is actually live before
following the steps below — the SQL file list and resource count in
this doc reflect the integration branch, which may be ahead of
whatever's really on `main` at execution time. Three things need doing
on the live box, in order.

## ⚠️ SUPERSEDING UPDATE (read this first) — host was rebuilt 7/7, new IP

Two emails from Ward (Operations, LaunchWise — `info@launchwisebc.com`),
sent 7/7 5:31pm and 5:53pm ET, found in David's inbox after this runbook's
first draft (written from GitHub Actions Variables, below, which point at
the OLD host):

- **The old RocketNode/apollopanel box (`SERVER_ID 9524616c`,
  `fx-dtx-10.apollopanel.com`) was terminated for non-payment** — wiped,
  not just suspended. That's why the server was down.
- **Rebuilt from scratch on a new "Platinum FXServer" box in Dallas.**
  Live connect address: **`193.31.31.27:30149`**. Fresh auto-provisioned
  MySQL DB, reused the existing Cfx.re license key, txAdmin re-linked.
- Ward says the deploy pipeline was fixed by **re-pointing the GitHub
  Actions host/user/server-id/remote-base variables to the new box** —
  but the values this runbook's Step 0 verified via `gh secret list` /
  repo Variables still show the OLD `9524616c`/`fx-dtx-10.apollopanel.com`
  values as of this writing. Not independently reconciled — could mean
  Ward's fix hasn't landed in the repo yet, or the panel/SERVER_ID naming
  is unrelated to the connect IP (same panel, different display). **David
  confirmed 7/8: trust the email, target the new IP going forward.**
  Re-check the actual repo Variables at the time you execute Step 3 below
  — if they still say `9524616c`/apollopanel, the deploy workflow may be
  SFTPing to a dead box while the real server lives at `193.31.31.27:30149`
  with no CI pipeline actually reaching it yet. If so, ask Ward directly
  for the new host/user/server-id/remote-base values before running
  Step 3, rather than guessing.
- **New GitHub org: `BlacklineDevs`.** Two repos moved in: `gtarp` (this
  one) and a second repo, **`GTARPScripts`**, not previously known to
  this session. You've been granted **Admin** on both — **two pending org
  invites are sitting in your GitHub notifications/email, not yet
  accepted.**
- **New: an AI NPC system is now live** — "CivCore NPC Pro" (installed
  from the `GTARPScripts` repo), extended by Ward with Groq (Llama 3.3
  70B, primary) → GitHub Models GPT-4o (fallback), using keys "reused
  from our Syndicate stack" (Ev's own infra — see
  `project_syndicate_bridge` memory: previously a "never copy without
  ownership sign-off" boundary, now apparently sharing credentials the
  other direction into gtarp). This is unaudited by anyone on David's
  side — no code review, no dup-gate, no bridge-pattern check. Treat as
  out of scope for this session's hardening/build tracks (they only
  touch `resources/[custom]/gtarp_*`) but flag to David as something to
  eventually look at, especially the credential-sharing angle.
- txAdmin backup login + AI provider keys are being sent by Ward
  **directly, not by email** — not yet in David's hands as of the email.

## Confirmed current config (read live from GitHub, not memory)

Repo: `BlacklineDevs/gtarp` (the old `EvThatGuy/gtarp` URL redirects here —
an org transfer happened, not a rename you need to chase).

Effective deploy target (repo Variables override the workflow file's
hardcoded fallback defaults, which are stale placeholders from an older
template — ignore the values written directly in
`.github/workflows/deploy-custom-layer.yml`, these repo Variables are what
actually apply):

| Variable | Value |
|---|---|
| `PANEL_URL` | `https://control.rocketnode.com` |
| `SERVER_ID` | `9524616c` |
| `SFTP_HOST` | `fx-dtx-10.apollopanel.com` |
| `SFTP_PORT` | `2022` |
| `SFTP_USERNAME` | `w8bh16e6.9524616c` |
| `REMOTE_BASE` | `.` |
| `UPLOAD_CUSTOM_CFG` | `true` |

`REMOTE_BASE = "."` looks unusual next to the workflow's own default
(`txData/QboxLeanPack_0DF2F5.base`), but it's plausible and likely correct:
the SFTP username is server-scoped (`w8bh16e6.9524616c` matches
`SERVER_ID`), which is the RocketNode/Pterodactyl pattern for an SFTP
account chrooted to that one server's file root — in that case `.` **is**
the server root and no extra path prefix is needed. Not independently
verified; if a deploy run's "Upload custom layer over SFTP" step 404s on
the mirror path, this is the first thing to check.

**Both required secrets exist**: `PTERO_API_KEY` and `SFTP_PASSWORD` are
both set on the repo (confirmed via `gh secret list` — names only, not
values). **This contradicts the 7/7 handoff note that said `PTERO_API_KEY`
was missing** — either Ev added it after that failed run, or the run that
found it missing predates these repo Variables being configured (the
Variables were set 2026-07-07 15:15 EDT; the "PTERO_API_KEY not set" run
was logged at roughly 16:45 EDT, i.e. after — so the secret really does
look absent at the time, then added since). Bottom line: **don't assume
either way — the first successful deploy run's summary will say
`restarted: true` or `false` under "Server restart triggered," check that
line to know for certain.**

Ev has not posted anything new since merging PR #21 on 7/7. No open PRs or
issues need a bump.

## Step 1 — Fix the corrupted live `items.lua`

Prod's live `resources/[ox]/ox_inventory/data/items.lua` has a stray
backtick (hand-edited, line ~79) that fails the deploy's Lua 5.4 syntax
gate, so the automatic ox-items sync step has been silently skipping itself
on every deploy run since.

1. Log into `https://control.rocketnode.com` (use "LOGIN VIA BILLING" if
   the plain login form doesn't recognize the account).
2. Open server `9524616c` → **File Manager** →
   navigate to `resources/[ox]/ox_inventory/data/items.lua`.
3. Open it in the panel's built-in editor, find the stray backtick
   (search for `` ` `` — it should not appear anywhere in a `.lua` file;
   there should be exactly one match, near line 79), delete it, save.
4. Sanity check: the file should still open/reload without the editor
   flagging an unterminated string.

You do not need to hand-run `tools/patch-ox-items.sh` against prod
yourself — once the corruption above is fixed, the deploy workflow's own
"Upload custom layer over SFTP" step re-downloads this file, re-patches
the GTARP marker block into it automatically, syntax-checks it, and
re-uploads it, every time it runs. Step 1 just removes the thing that's
been making that automatic step fail.

## Step 2 — Apply SQL migrations to the prod DB

**CI never touches the production database — this has always been a
manual step**, and per the 7/7 handoff notes, prod has likely never had
`tools/apply-migrations.sh` run against it at all (unlike the local test
DB, which was baselined on 7/3). Do not assume the state — check first.

1. Get MySQL/MariaDB connection details for the game server's database.
   On a Pterodactyl-family panel this is usually under the server's
   **Databases** tab (host, port, database name, username, password) —
   check there first. If RocketNode instead only exposes a web SQL client
   (phpMyAdmin/Adminer) under the panel, use that for the one-time check
   in step 2a and ask Kai to translate the file-based commands into
   paste-able SQL if direct `MYSQL_CMD` access isn't available.

2a. **Check what's already there before running anything**, from a
   terminal with access to the DB (either RocketNode's own SSH/console if
   offered, or connecting out from your machine if the DB host is
   reachable — RocketNode game DBs are frequently only reachable from
   inside the panel's network, so the panel's own console/SQL tool may be
   required instead of a local client):

   ```sql
   SHOW TABLES LIKE 'gtarp_%';
   ```

   - **If this returns zero rows** (most likely per the 7/7 handoff):
     prod has nothing yet. Run the full plain migration set (not
     baseline) — this creates every table and replays every seed insert,
     which is correct and desired for a from-scratch DB.
   - **If this returns some rows** (an earlier partial hand-applied
     state): do NOT run the plain script — it would replay seed
     `INSERT`s into tables that already have real player data. Instead
     hand-apply only the specific `sql/000N_*.sql` files whose tables are
     missing from the `SHOW TABLES` output, one at a time, checking each
     file's own idempotency guards first.

2b. **If you have a direct MySQL client path to the prod DB** (host/port/
   user/pass from the panel's Databases tab, reachable from your machine
   or a jump host), the fastest correct route is running the existing
   tool with that target:

   ```bash
   cd /c/Users/Mgtda/Projects/Active/gtarp
   MYSQL_CMD="mysql -h<PROD_DB_HOST> -P<PROD_DB_PORT> -u<PROD_DB_USER> -p<PROD_DB_PASS> <PROD_DB_NAME>" \
     bash tools/apply-migrations.sh --dry-run
   ```

   Review the dry-run output (it will say `would apply: 0001_init.sql`
   etc. for every one of the 26 files listed below if the DB is empty —
   confirm that matches your step 2a finding), then re-run without
   `--dry-run` to actually apply:

   ```bash
   MYSQL_CMD="mysql -h<PROD_DB_HOST> -P<PROD_DB_PORT> -u<PROD_DB_USER> -p<PROD_DB_PASS> <PROD_DB_NAME>" \
     bash tools/apply-migrations.sh
   ```

   **Never pass `--baseline` on prod unless step 2a proved tables already
   exist for those specific files** — baselining an empty DB marks
   migrations as "done" without ever creating the tables, which silently
   leaves prod broken while the tracking table claims everything is fine.

2c. **If no direct DB client access exists** (panel-console-only), paste
   the contents of each file below into the panel's SQL tool, in this
   exact order, top to bottom. Every file is idempotent
   (`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS`) so
   re-running one that already applied is safe, but do them in order —
   later files sometimes `ALTER`/reference tables earlier files create.

   The full ordered list — **24 files as of 2026-07-08 afternoon**
   (numbering has gaps at 0004, 0005, 0010; those were reverted
   features, see repo history — this is the complete real
   `ls sql/*.sql | sort` output, not retyped from memory; re-run that
   command yourself before executing step 2 in case a later session
   added more):

   ```
   sql/0001_init.sql
   sql/0002_economy_seed.sql
   sql/0003_emergency_jobs.sql
   sql/0006_courier.sql
   sql/0007_staff_log.sql
   sql/0008_security_events.sql
   sql/0009_allowlist.sql
   sql/0011_grind.sql
   sql/0012_evidence.sql
   sql/0013_turf.sql
   sql/0014_pumpcoin.sql
   sql/0015_replay.sql
   sql/0016_clout.sql
   sql/0017_flashdrop.sql
   sql/0018_evidence_v2.sql
   sql/0019_witnesses.sql
   sql/0020_counterfeit.sql
   sql/0021_insurance.sql
   sql/0022_mdt.sql
   sql/0023_warrants.sql
   sql/0024_citations.sql
   sql/0025_calls.sql
   sql/0026_legal.sql
   sql/0027_bounty.sql
   sql/0028_fightclub.sql
   ```

   **`0027_bounty.sql` and `0028_fightclub.sql` are new since this
   runbook was first written** — they ship the two signature features
   (`gtarp_bounty`, `gtarp_fightclub`) built later in the same session,
   currently sitting on local branch `claude/integration-2026-07-08`,
   NOT YET merged to `main`. Prod cannot have these two applied until
   that branch is pushed — check `git log main` for the actual deployed
   commit before assuming these are relevant to your current prod state.
   `0025`–`0028` are the ones LEAST likely to have ever been hand-applied
   to prod.

3. After applying, re-run the `SHOW TABLES LIKE 'gtarp_%';` check — you
   should see one table per resource that ships SQL (evidence, mdt,
   mdt_warrants, mdt_bookings, citations, legal (petitions), insurance,
   turf, grind, pumpcoin, replay, clout, flashdrop, witnesses,
   counterfeit, allowlist, security_events, staff audit_log, courier,
   bounty, fightclub, plus `gtarp_schema_migrations` itself if you used
   the script).

## Step 3 — Redeploy and verify

1. In the repo, go to **Actions → Deploy custom layer → Run workflow**
   (this is `workflow_dispatch`, no need to push a new commit — the
   `main` branch is already current at `dade10e`).
2. Watch the run. Read the **Deploy summary** at the bottom of the run
   page — it will explicitly say:
   - `ox_inventory items: synced` (confirms Step 1 worked — if it still
     says the failed-sync warning, the backtick fix didn't take or there's
     a second syntax issue; re-check the file).
   - `Server restart triggered: true` (confirms `PTERO_API_KEY` is valid
     and the restart actually fired) or `false` (means the key is missing
     or invalid — restart manually via the panel's **Console** tab,
     Restart button, in that case).
   - `SQL migrations pending manual apply: 0` (should read 0 if Step 2
     already covered everything — if it's nonzero, go back to Step 2 for
     the newly-flagged files; this counter is a diff against the last
     *successful* deploy run, so it won't know about migrations you
     applied by hand outside CI, only about ones added to the repo since
     the last green run).
3. Once the server restarts, open the panel's **Console** tab and watch
   the boot log. Confirm:
   - Zero lines containing `SCRIPT ERROR`.
   - Each `gtarp_*` resource prints its boot banner (same banners
     verified locally all session: e.g. `gtarp_eventguard` "guarding N
     events" printed exactly once — not twice, or the double-registration
     bug is back; `gtarp_mdt` "case system ONLINE"; `gtarp_legal` "court
     open"; `gtarp_citations` "escalation ONLINE"; `gtarp_insurance`,
     `gtarp_discord` "announcer online"; `gtarp_devtest` prints a
     "disabled" line on a normal prod boot, which is correct — devtest is
     convar-gated off by default).
   - `ox_inventory_overrides` does NOT print any `FATAL` line naming a
     missing item — that would mean Step 1's re-sync didn't actually
     register the custom items.

## Summary for David

1. Panel login → File Manager → delete the stray backtick in
   `ox_inventory/data/items.lua` (line ~79), save.
2. Find the prod DB's real connection details (panel Databases tab or
   console) → run `SHOW TABLES LIKE 'gtarp_%';` to see what's already
   there → apply the missing `sql/*.sql` files in numeric order (26
   total, list via `ls sql/*.sql | sort` in the repo — don't hand-type
   the list) via either `tools/apply-migrations.sh` (if you get a direct
   client connection) or pasting each file into the panel's SQL tool.
3. Actions tab → run the "Deploy custom layer" workflow manually
   (`workflow_dispatch`) — no new commit needed, `main` is already
   current.
4. Read the run's Deploy summary: confirm `ox_inventory items: synced`
   and check whether `Server restart triggered` is `true` — if `false`,
   restart manually from the panel Console.
5. Watch the Console boot log for zero `SCRIPT ERROR` lines and all 25
   `gtarp_*` resource banners present — that's the finish line.
