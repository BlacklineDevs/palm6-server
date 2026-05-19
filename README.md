# gtarp — Qbox Custom Resource Layer

This repository is the **custom layer** for a Qbox-based FiveM RP server. It
holds only the resources, config overrides, SQL migrations, and docs that are
specific to this server.

It is **not** a full FiveM server. The Qbox framework and the FXServer
artifacts themselves are provisioned separately by a txAdmin `qbox-lean`
recipe and must never be committed to this repo.

## What's in the box

Phases 1-10 of the build (see `docs/BUILD-ROADMAP.md`) ship:

- **[config_overrides]** — convar / config override resources for
  `qbx_core`, the economy, police, ambulance, civilian jobs, and
  `ox_inventory`.
- **server_identity** — dark loading screen, default spawn handler,
  Discord rich presence.
- **server_base** — startup banner, `playerConnecting` logger,
  `/serverinfo`, ACE-gated `/coords`.
- **gtarp_whitelist_jobs** — emergency-services job whitelist enforcement.
- **gtarp_courier** — signature feature: player-run delivery board with
  bounty escrow.
- **gtarp_staff** — staff command set + audit log + Discord webhook.
- **gtarp_eventguard** — server-side event ratelimit + amount validation.
- **gtarp_allowlist** — playerConnecting Discord-role + DB allowlist
  gate.
- **gtarp_perf** — server-thread hitch sampler + p95/p99 reports.

## Repo layout

```
/custom.cfg                                          # exec'd from server.cfg
/server.cfg.example                                  # hardened reference
/resources/[custom]/
    [config_overrides]/
        qbx_core_overrides/
        qbx_economy_overrides/
        qbx_police_overrides/
        qbx_ambulance_overrides/
        qbx_civilian_jobs_overrides/
        ox_inventory_overrides/
    server_identity/
    server_base/
    gtarp_whitelist_jobs/
    gtarp_courier/
    gtarp_staff/
    gtarp_eventguard/
    gtarp_allowlist/
    gtarp_perf/
/sql/                  # numbered migrations 0001..0009
/docs/                 # SETUP, DEVELOPMENT, BUILD-ROADMAP, STAFF, RULES,
                       # SECURITY, PERFORMANCE
```

## What does NOT live here

- FXServer artifacts (managed by the txAdmin recipe)
- The Qbox framework resources themselves (`qbx_core`, `qbx_*`, `ox_*`, …)
- Anything containing secrets

## Install workflow

1. Deploy the txAdmin **`qbox-lean`** recipe.
2. Copy `resources/[custom]/` into the live server's `resources/`.
3. Copy `custom.cfg` next to `server.cfg`.
4. Append `exec custom.cfg` to the bottom of `server.cfg`.
5. Apply every file in `sql/` to the database in numeric order.
6. Set secret-managed convars in txAdmin:
   - `gtarp:staff_webhook` (Phase 7)
   - `gtarp:discord_bot_token`, `gtarp:discord_guild_id` (Phase 9)
   - `gtarp:perf_webhook` (Phase 10, optional)
7. Start the server.

See `docs/SETUP.md` for the full walkthrough.
