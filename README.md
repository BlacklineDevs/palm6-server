# palm6 - Qbox Custom Resource Layer

This repository is the **custom layer** for a Qbox-based FiveM RP server. It
holds only the resources, config overrides, SQL migrations, and docs that are
specific to this server.

It is **not** a full FiveM server. The Qbox framework and the FXServer
artifacts themselves are provisioned separately by a txAdmin `qbox-lean`
recipe and must never be committed to this repo.

## What's in the box

Phases 1-10 of the build (see `docs/BUILD-ROADMAP.md`) ship:

- **[config_overrides]** - convar / config override resources for
  `qbx_core`, the economy, police, ambulance, civilian jobs, and
  `ox_inventory`.
- **server_identity** - dark loading screen, default spawn handler,
  Discord rich presence.
- **server_base** - startup banner, `playerConnecting` logger,
  `/serverinfo`, ACE-gated `/coords`.
- **palm6_whitelist_jobs** - emergency-services job whitelist enforcement.
- **palm6_courier** - signature feature: player-run delivery board with
  bounty escrow.
- **palm6_staff** - staff command set + audit log + Discord webhook.
- **palm6_eventguard** - server-side event ratelimit + amount validation.
- **palm6_allowlist** - playerConnecting Discord-role + DB allowlist
  gate.
- **palm6_perf** - server-thread hitch sampler + p95/p99 reports.

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
    palm6_whitelist_jobs/
    palm6_courier/
    palm6_staff/
    palm6_eventguard/
    palm6_allowlist/
    palm6_perf/
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
   - `palm6:staff_webhook` (Phase 7)
   - `palm6:discord_bot_token`, `palm6:discord_guild_id` (Phase 9)
   - `palm6:perf_webhook` (Phase 10, optional)
7. Start the server.

See `docs/SETUP.md` for the full walkthrough.

## Palm6 Creative System (Governance)

This repository is aligned with the approved **Palm6 Creative System**. Creative,
brand, and structural decisions follow the governance defined there.

- **Start here:** [`00-START-HERE.md`](00-START-HERE.md)
- **Foundation docs:** [`00-FOUNDATION/`](00-FOUNDATION/) - Design Manifesto,
  Dual Visual System, Brand Pyramid, Quality Standards, Color System, Design Bible.
- **Decisions are logged:** [`00-FOUNDATION/09-DECISION-LOG.md`](00-FOUNDATION/09-DECISION-LOG.md)
  and entries in [`00-FOUNDATION/DECISION-LOG/`](00-FOUNDATION/DECISION-LOG/).

Non-trivial creative/brand changes go through the RFC + Decision Log process.
Nothing is treated as final/production-ready without an **Approved** status in the
Decision Log. This governance layer is additive - it does not change how the server
resources above are built, deployed, or run.

