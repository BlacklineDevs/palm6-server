# gtarp — Qbox Custom Resource Layer

This repository is the **custom layer** for a Qbox-based FiveM RP server. It
holds only the resources, config overrides, SQL migrations, and docs that are
specific to this server.

It is **not** a full FiveM server. The Qbox framework and the FXServer
artifacts themselves are provisioned separately by a txAdmin `qbox-lean`
recipe and must never be committed to this repo.

## What lives here

```
/custom.cfg                                          # exec'd from the live server.cfg
/server.cfg.example                                  # hardened reference server.cfg
/resources/[custom]/
    [config_overrides]/qbx_core_overrides/           # recipe-overrides via convars
    server_identity/                                 # loading screen, spawn, presence
    server_base/                                     # commands, banner, welcome notify
/sql/                                                # numbered SQL migrations
/docs/                                               # SETUP, DEVELOPMENT, BUILD-ROADMAP
```

## What does NOT live here

- FXServer artifacts (managed by the txAdmin recipe)
- The Qbox framework resources themselves (`qbx_core`, `qbx_*`, `ox_*`, …)
- Anything containing secrets

## Install workflow

1. Deploy the txAdmin **`qbox-lean`** recipe. Let it finish.
2. Copy `resources/[custom]/` into the live server's `resources/` folder.
3. Copy `custom.cfg` next to the recipe-generated `server.cfg`.
4. Append `exec custom.cfg` to the bottom of `server.cfg`.
5. Apply migrations from `sql/` in numeric order.
6. Restart the server.

See `docs/SETUP.md` for the full walkthrough, `docs/BUILD-ROADMAP.md` for
the phased build plan, and `docs/DEVELOPMENT.md` for conventions.
