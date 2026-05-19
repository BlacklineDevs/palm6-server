# gtarp — Qbox Custom Resource Layer

This repository is the **custom layer** for a Qbox-based FiveM RP server. It
holds only the resources, config overrides, SQL migrations, and docs that are
specific to this server.

It is **not** a full FiveM server. The Qbox framework and the FXServer
artifacts themselves are provisioned separately by a txAdmin Qbox recipe and
must never be committed to this repo.

## What lives here

```
/custom.cfg                       # exec'd from the live server.cfg
/server.cfg.example               # hardened reference server.cfg
/resources/[custom]/              # all custom resources live under [custom]
    server_base/                  # minimal starter resource (template)
        fxmanifest.lua
        config.lua
        client/main.lua
        server/main.lua
/sql/                             # numbered SQL migrations (0001_*, 0002_*, …)
/docs/                            # SETUP and DEVELOPMENT docs
```

## What does NOT live here

- FXServer artifacts (managed by the txAdmin recipe)
- The Qbox framework resources themselves (`qbx_core`, `qbx_*`, `ox_*`, …)
- Anything containing secrets (license keys, API keys, DB credentials, …)

## Install workflow

1. Deploy a fresh server with the txAdmin **Qbox recipe**. Let the recipe
   finish — it produces a `resources/` folder containing the framework and a
   recipe-generated `server.cfg`.
2. Copy the contents of this repo's `resources/[custom]/` into the live
   server's `resources/` folder so the live tree contains
   `resources/[custom]/server_base/`.
3. Copy `custom.cfg` to the server root next to the recipe-generated
   `server.cfg`.
4. Append the following line to the **bottom** of the recipe-generated
   `server.cfg`:

   ```
   exec custom.cfg
   ```

5. Apply any new migrations from `sql/` to the database in numeric order.
6. Restart the server. The `server_base` resource will start and print a
   banner.

See `docs/SETUP.md` for the full step-by-step and `docs/DEVELOPMENT.md` for
conventions when adding new resources.
