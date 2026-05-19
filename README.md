# gtarp — Qbox Custom Resource Layer

This repository is the **custom layer** for a Qbox-based FiveM RP server. It
holds only the resources, config overrides, SQL migrations, and docs that are
specific to this server.

It is **not** a full FiveM server. The Qbox framework and the FXServer
artifacts themselves are provisioned separately by a txAdmin Qbox recipe
(`qbox-lean`) and must never be committed to this repo.

## What's in the box

The layer is a complete drop-in package for a freshly deployed Qbox server:

- **server_identity** — dark-themed loading screen, default spawn handler
  (Legion Square), Discord rich presence with editable app id.
- **server_base** — startup banner, `playerConnecting` join logger, in-game
  `/serverinfo` command, ACE-gated `/coords` admin command, ox_lib welcome
  notification wired to `QBCore:Client:OnPlayerLoaded`.
- **custom.cfg** — single entry point ensured from the recipe's
  `server.cfg`, ensures both custom resources in the right order and grants
  the `command.coords` ACE.
- **server.cfg.example** — hardened reference for the recipe-generated
  `server.cfg`: 48 slots, endpoint privacy, OneSync, MySQL placeholder,
  framework load order, ACE example.
- **sql/** — numbered migration files for any custom schema changes.
- **docs/** — setup and development guides.

## Repo layout

```
/custom.cfg                       # exec'd from the live server.cfg
/server.cfg.example               # hardened reference server.cfg
/resources/[custom]/              # all custom resources live under [custom]
    server_base/
        fxmanifest.lua
        config.lua
        client/main.lua
        server/main.lua
    server_identity/
        fxmanifest.lua
        config.lua
        client/main.lua
        html/loading.html
        html/loading.css
/sql/                             # numbered SQL migrations (0001_*, 0002_*, …)
/docs/                            # SETUP and DEVELOPMENT docs
```

## What does NOT live here

- FXServer artifacts (managed by the txAdmin recipe)
- The Qbox framework resources themselves (`qbx_core`, `qbx_*`, `ox_*`, …)
- Anything containing secrets (license keys, API keys, DB credentials, …)

## Install (TL;DR)

1. Deploy the `qbox-lean` recipe in txAdmin and let it finish.
2. Copy `resources/[custom]/` into the live server's `resources/` folder.
3. Copy `custom.cfg` next to the recipe-generated `server.cfg`.
4. Append `exec custom.cfg` to the bottom of `server.cfg`.
5. Apply migrations from `sql/` to the database in numeric order.
6. Restart the server.

Confirm:

- The dark-themed loading screen appears on join.
- `/serverinfo` responds in chat.
- The welcome notification fires once your character finishes loading.

See `docs/SETUP.md` for the full walkthrough and `docs/DEVELOPMENT.md` for
the conventions used when adding new resources.
