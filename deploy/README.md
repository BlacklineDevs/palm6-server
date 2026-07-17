# Deploy pipeline

> **Deploy hub.** This folder is the deploy-documentation home for gtarp (Phase 2
> structure). The CI itself stays in `../.github/workflows/` — GitHub requires workflows
> to live under `.github/`, so they are referenced here, not moved.

This repo auto-deploys the Qbox custom layer to the live FiveM server (RocketNode /
ApolloPanel, FiveM + txAdmin, Qbox lean recipe).

The pipeline is the GitHub Actions workflow
[`../.github/workflows/deploy-custom-layer.yml`](../.github/workflows/deploy-custom-layer.yml).

## What it does

1. **Uploads** `resources/[custom]/` over SFTP to the server's custom-layer path.
2. **Optionally uploads** `custom.cfg` to the server base.
3. **Patches custom ox_inventory items** into the deployed
   `resources/[ox]/ox_inventory/data/items.lua`: downloads the live file, runs
   `tools/patch-ox-items.sh` (idempotent marker block; never shadows
   recipe-defined names), syntax-checks it with `lua5.4`, and uploads it back.
   ox_inventory only reads its own `data/items.lua` at boot — a runtime merge
   can never register items — so without this step every custom item silently
   fails to exist. If any part fails, the live file is left untouched and the
   run warns loudly; run the script manually against the server's resources
   dir in that case (`ox_inventory_overrides` prints FATAL boot lines naming
   each unregistered item either way).
4. **Patches Palm6 vehicle prices** into the deployed
   `resources/[qbx]/qbx_core/shared/vehicles.lua`: downloads the live file, runs
   `tools/patch-vehicle-prices.sh` (rewrites ONLY the `price` field for
   `palm6_dealership` catalog models to their tier price; idempotent; never
   touches coords, categories, hashes, or non-catalog models), syntax-checks it
   with `lua5.4` (backticks flattened for the check), and uploads it back.
   `qbx_vehicleshop` reads prices from this file, so without this step the
   dealership shows stock prices. If any part fails (e.g. the `[qbx]/qbx_core`
   path differs), the live file is left untouched and the run warns loudly; run
   the script manually against the server's resources dir in that case.
5. **Restarts** the FXServer via the Pterodactyl power API.
6. **Flags pending SQL migrations**: diffs `sql/*.sql` against the commit of
   the last *successful* deploy run and, if anything is new or changed, puts a
   warning + checklist in the run summary. **CI never touches the production
   DB** — apply migrations manually on the game host. Because the diff basis
   is the last successful deploy (not the previous push), sql-only pushes that
   don't trigger this workflow are still caught by the next deploy that does.

## Applying SQL migrations (`tools/apply-migrations.sh`)

The safe way to run the manual migration step. Tracks applied files in a
`palm6_schema_migrations` table (filename + sha256), so re-running is a no-op
and a migration edited *after* being applied fails loudly (exit 2) instead of
silently re-running.

```bash
# local test DB (default: docker exec into palm6-mariadb)
bash tools/apply-migrations.sh --dry-run   # show what would run
bash tools/apply-migrations.sh             # apply anything new

# any other DB (e.g. production on the game host)
MYSQL_CMD="mysql -h<host> -u<user> -p<pw> <db>" bash tools/apply-migrations.sh
```

**First run on a database that already had migrations applied by hand**
(both the local test DB and production as of 2026-07-03): run
`bash tools/apply-migrations.sh --baseline` ONCE first — it records every
current `sql/*.sql` as applied without executing anything. Skipping the
baseline on such a DB would replay seed data. The local test DB was
baselined 2026-07-03; production has NOT been baselined yet.

> **Why the restart matters:** writing files to the server does **not** apply them.
> FXServer only loads new/changed resource code on (re)start, so the deploy restarts
> the server after a successful upload. If the restart is skipped (no API key), you
> must restart the server manually from the panel for changes to take effect.

## When it runs

- **Automatically** on every push to `main` that touches `resources/**` (any resource
  group, not only `[custom]`) or `custom.cfg` (i.e. merges to main).
- **Manually** via the **Run workflow** button (workflow_dispatch) in the
  **Actions** tab.

Deploys are serialized with a `concurrency` group, so overlapping runs don't collide.

## Paths

| What | Local (repo) | Remote (server, SFTP-relative) |
| --- | --- | --- |
| Custom layer | `resources/[custom]/` | `resources/[custom]/` |
| Server config | `custom.cfg` | `custom.cfg` |

The SFTP root is the server container root, so remote paths are relative to it.
The `[custom]` / `[config_overrides]` folders contain literal square brackets; the
workflow passes these paths to `lftp` as plain double-quoted strings so the literal
bracketed directory names resolve correctly.

## Required GitHub configuration

Create these under **Settings → Secrets and variables → Actions**.

### Secrets (encrypted — required)

| Name | Value | Where to get it |
| --- | --- | --- |
| `SFTP_SSH_KEY` | _the PRIVATE half of the deploy SSH keypair_ (preferred) | The full Ed25519 private key (`-----BEGIN OPENSSH PRIVATE KEY-----` … `-----END OPENSSH PRIVATE KEY-----`). Paste the **whole** key, including the BEGIN/END lines and trailing newline. Its matching public key goes on the RocketNode account (see below). |
| `SFTP_PASSWORD` | _your RocketNode SFTP/panel password_ (fallback) | Your panel account's SFTP password (same login used for the panel / file manager SFTP). Still required as a fallback until SSH key auth is confirmed. |
| `PTERO_API_KEY` | _your Pterodactyl client API key_ | Create one under the RocketNode account **API credentials** page (`control.rocketnode.com` → Account → API Credentials). |

#### SFTP authentication: SSH key preferred, password fallback

The upload step picks its auth automatically:

- If `SFTP_SSH_KEY` is **set**, the workflow writes the private key to a temporary
  `0600` file and lftp authenticates with it (`ssh -i <keyfile>`). The key file is
  removed when the step finishes and is never printed in logs.
- If `SFTP_SSH_KEY` is **empty**, it falls back to password auth using `SFTP_PASSWORD`.

So you can roll the key out with zero downtime: add `SFTP_SSH_KEY` (and the public key
on the panel), confirm a deploy succeeds with `auth mode: ssh-key`, then optionally
remove the now-unused `SFTP_PASSWORD` secret.

**Add the PUBLIC key to RocketNode:** open the panel → **Account → SSH Keys** and paste
the public key (`deploy_key.pub`, the `ssh-ed25519 …` one line). This authorizes the
keypair for SFTP logins on your account. (Keep the **private** key only in the
`SFTP_SSH_KEY` GitHub secret — never put the private key on the panel or in the repo.)

**Removing the password after validation:** once a deploy run shows
`SFTP auth mode: ssh-key` and succeeds, you may delete the `SFTP_PASSWORD` secret. The
guard step accepts **either** credential, so a key-only configuration (just
`SFTP_SSH_KEY`) deploys normally — just keep `SFTP_SSH_KEY` set.

### Variables (non-secret — optional overrides)

The workflow already defaults to the verified values below, so you normally only need
to add the two secrets above. Add a repo **Variable** of the same name only if you want
to override a default (e.g. if the recipe base folder is redeployed under a new name).

| Name | Value |
| --- | --- |
| `SFTP_HOST` | `fx-dtx-10.apollopanel.com` |
| `SFTP_PORT` | `2022` |
| `SFTP_USERNAME` | `w8bh16e6.9524616c` |
| `PANEL_URL` | `https://control.rocketnode.com` |
| `SERVER_ID` | `9524616c` |
| `REMOTE_BASE` | `.` |

> `REMOTE_BASE` is `.` because the SFTP account is rooted at the server's base
> folder, so uploads land directly under it. Set a `REMOTE_BASE` repo Variable only
> if that ever stops being true (e.g. the SFTP root changes).

The SFTP host / port / username can also be read off the panel **File Manager →
Launch SFTP** link.

## First-time setup checklist

1. Add an SFTP credential secret — `SFTP_SSH_KEY` (preferred) and/or `SFTP_PASSWORD` —
   plus `PTERO_API_KEY`.
2. If using key auth, add the matching **public** key to the panel
   (**Account → SSH Keys**).
3. (Optional) Add any **variables** you need to override.
4. Merge a change to `main` (or use **Actions → Deploy custom layer → Run workflow**).
5. Watch the run in the **Actions** tab and confirm the **Deploy summary** shows the
   upload (and the **Upload** step log shows `SFTP auth mode: ssh-key`) and that a
   restart was triggered.

Until at least one SFTP credential (`SFTP_SSH_KEY` or `SFTP_PASSWORD`) is set, the
workflow runs but **skips** the deploy with a clear "secrets not configured" message
instead of failing — so adding the workflow won't break CI before you've configured it.

## Toggles

These are controlled by repo **Variables** (Settings → Secrets and variables →
Actions → Variables).

### Disable the `custom.cfg` upload

Set variable `UPLOAD_CUSTOM_CFG` = `false`.

> **Caveat:** `custom.cfg` lives at the server base, not inside `resources/[custom]/`.
> Uploading it overwrites the server's `custom.cfg`. If the server's copy has been
> edited directly on the host (e.g. via txAdmin) and diverges from the repo, that
> drift will be overwritten on the next deploy. Disable this toggle if you manage
> `custom.cfg` on the server instead of in the repo.

### Strict (exact) mirror with deletion

By default the upload is **additive**: it never deletes server-side files that aren't
in the repo (so resources present only on the server are left alone). To make the
server's `resources/[custom]/` an **exact** copy of the repo — deleting anything
server-side that isn't committed — set variable `MIRROR_DELETE` = `true`.

> **Warning:** strict mirroring permanently removes server-side files under
> `resources/[custom]/` that aren't in the repo. Only enable it if the repo is the
> single source of truth for the entire custom layer.

## Security

Server credentials live **only** in GitHub Actions encrypted secrets and are never
echoed by the workflow. **Never commit** `SFTP_SSH_KEY`, `SFTP_PASSWORD`, `PTERO_API_KEY`,
or any other credential to the repo. The SSH **private** key belongs only in the
`SFTP_SSH_KEY` secret; only its **public** half goes on the panel. The deploy private
key is written to a temporary `0600` file at runtime and deleted when the step ends.
Only the non-secret connection details (host, port, username, panel URL, server id,
remote base) appear as workflow defaults / in this doc.
