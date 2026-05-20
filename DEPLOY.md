# Deploy pipeline

This repo auto-deploys the Qbox custom layer to the live FiveM server (RocketNode /
ApolloPanel, FiveM + txAdmin, Qbox lean recipe).

The pipeline is the GitHub Actions workflow
[`.github/workflows/deploy-custom-layer.yml`](.github/workflows/deploy-custom-layer.yml).

## What it does

1. **Uploads** `resources/[custom]/` over SFTP to the server's custom-layer path.
2. **Optionally uploads** `custom.cfg` to the server base.
3. **Restarts** the FXServer via the Pterodactyl power API.

> **Why the restart matters:** writing files to the server does **not** apply them.
> FXServer only loads new/changed resource code on (re)start, so the deploy restarts
> the server after a successful upload. If the restart is skipped (no API key), you
> must restart the server manually from the panel for changes to take effect.

## When it runs

- **Automatically** on every push to `main` that touches `resources/[custom]/**` or
  `custom.cfg` (i.e. merges to main).
- **Manually** via the **Run workflow** button (workflow_dispatch) in the
  **Actions** tab.

Deploys are serialized with a `concurrency` group, so overlapping runs don't collide.

## Paths

| What | Local (repo) | Remote (server, SFTP-relative) |
| --- | --- | --- |
| Custom layer | `resources/[custom]/` | `txData/QboxLeanPack_0DF2F5.base/resources/[custom]/` |
| Server config | `custom.cfg` | `txData/QboxLeanPack_0DF2F5.base/custom.cfg` |

The SFTP root is the server container root, so remote paths are relative to it.
The `[custom]` / `[config_overrides]` folders contain literal square brackets; the
workflow passes these paths to `lftp` as plain double-quoted strings so the literal
bracketed directory names resolve correctly.

## Required GitHub configuration

Create these under **Settings → Secrets and variables → Actions**.

### Secrets (encrypted — required)

| Name | Value | Where to get it |
| --- | --- | --- |
| `SFTP_PASSWORD` | _your RocketNode SFTP/panel password_ | Your panel account's SFTP password (same login used for the panel / file manager SFTP). |
| `PTERO_API_KEY` | _your Pterodactyl client API key_ | Create one under the RocketNode account **API credentials** page (`control.rocketnode.com` → Account → API Credentials). |

### Variables (non-secret — optional overrides)

The workflow already defaults to the verified values below, so you normally only need
to add the two secrets above. Add a repo **Variable** of the same name only if you want
to override a default (e.g. if the recipe base folder is redeployed under a new name).

| Name | Value |
| --- | --- |
| `SFTP_HOST` | `fx-dtx-12.apollopanel.com` |
| `SFTP_PORT` | `2022` |
| `SFTP_USERNAME` | `w8bh16e6.221eea0c` |
| `PANEL_URL` | `https://control.rocketnode.com` |
| `SERVER_ID` | `221eea0c` |
| `REMOTE_BASE` | `txData/QboxLeanPack_0DF2F5.base` |

> `REMOTE_BASE` changes if the Qbox lean recipe base folder is ever redeployed under a
> new name — update this variable if that happens.

The SFTP host / port / username can also be read off the panel **File Manager →
Launch SFTP** link.

## First-time setup checklist

1. Add the two **secrets** (`SFTP_PASSWORD`, `PTERO_API_KEY`).
2. (Optional) Add any **variables** you need to override.
3. Merge a change to `main` (or use **Actions → Deploy custom layer → Run workflow**).
4. Watch the run in the **Actions** tab and confirm the **Deploy summary** shows the
   upload and that a restart was triggered.

Until `SFTP_PASSWORD` is set, the workflow runs but **skips** the deploy with a clear
"secrets not configured" message instead of failing — so adding the workflow won't
break CI before you've configured it.

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
echoed by the workflow. **Never commit** `SFTP_PASSWORD`, `PTERO_API_KEY`, or any
other credential to the repo. Only the non-secret connection details (host, port,
username, panel URL, server id, remote base) appear as workflow defaults / in this doc.
