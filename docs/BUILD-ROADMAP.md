# BUILD-ROADMAP — gtarp Qbox RP server

This document is the ordered plan for taking the gtarp server from its
current basic state to a complete general-purpose roleplay server. It is
scoped to a small (48-slot) community and is meant to be dispatched
phase-by-phase to Claude Code on the web.

## Section 1 — Current State

> NOTE (Phase 1 update): the prior "complete basic" custom layer
> (`server_identity`, expanded `server_base`, hardened `custom.cfg` /
> `server.cfg.example` / `docs/SETUP.md`) was reverted from `main` before
> this build started. Phase 1 re-establishes it as the foundation for the
> multichar override resource that Phase 1 owns. From Phase 2 onward the
> description below is accurate against the phase branch.

What is already done and committed in this repo:

- **txAdmin-deployable Qbox base.** A `qbox-lean` recipe deploy produces a
  working FXServer + Qbox framework (`ox_lib`, `oxmysql`, `ox_target`,
  `ox_inventory`, `qbx_core`, and the Qbox jobs/vehicles/banking/garage
  resources). That deploy is out of scope for this repo.
- **Custom layer scaffold.** `resources/[custom]/` holds two custom
  resources:
  - `server_base` — startup banner, `playerConnecting` join logger,
    `/serverinfo` command, ACE-gated `/coords` admin command, ox_lib
    welcome notification wired to `QBCore:Client:OnPlayerLoaded`.
  - `server_identity` — dark-themed self-contained loading screen
    (HTML + CSS, no external assets), default spawn handler placing
    characters at Legion Square (`vector4(195.17, -933.77, 30.69,
    144.0)`), Discord rich presence with placeholder app id.
- **Config entry point.** `custom.cfg` ensures both custom resources in
  load order and grants `command.coords` to `group.admin`. The recipe's
  `server.cfg` is expected to `exec custom.cfg` at the bottom.
- **Reference hardened cfg.** `server.cfg.example` documents 48 slots,
  endpoint privacy, OneSync, MySQL placeholder, framework load order, ACE
  example. Drift from the recipe-generated cfg is reconciled by hand.
- **Migrations.** `sql/0001_init.sql` is an empty header for the numbered
  migration convention; no schema changes yet.
- **Docs.** `README.md`, `docs/SETUP.md`, `docs/DEVELOPMENT.md` describe
  the install workflow and conventions.

What is **not** done: every gameplay-shaping choice. Multichar limits,
paychecks, emergency-services rosters, civilian jobs, shop catalogs,
admin tooling beyond `/coords`, allowlist, anticheat, and performance
budgets are all still at recipe defaults.

## Section 2 — Recipe vs Custom

The `qbox-lean` recipe is not a starter kit you need to extend — it is a
**working server**. Specifically, the recipe already provides:

- **Framework core** (`qbx_core`) — identifiers, sessions, player data,
  character lifecycle events.
- **Inventory** (`ox_inventory`) — slot-based inventory, items table,
  shop API, stash API, weapon handling, drops, durability.
- **Targeting** (`ox_target`) — interaction system used by every Qbox
  job and most community resources.
- **Multichar / character selection** (built into `qbx_core`) — character
  creation UI, slot cap, spawn flow hooks.
- **Jobs framework** (`qbx_core` + `qbx_management`) — job data, grades,
  on/off duty, payroll plumbing.
- **Vehicles** (`qbx_vehicles`, `qbx_garages`) — owned vehicles, garage
  store/retrieve flow, vehicle keys, impound.
- **Banking** (`qbx_management`/`qbx_banking` depending on recipe pin) —
  personal and society accounts, transfers, payroll dispenser.
- **Emergency-services bases** (`qbx_police`, `qbx_ambulancejob`) —
  cuff/escort/MDT, revive/heal, on-duty rosters.

The implication for this roadmap: **most remaining work is configuring
recipe-provided resources, not building new ones.** Each phase is tagged:

- **(configure)** — edit config/SQL of a recipe resource. No new code.
  Often delivered as a `config_overrides/` resource that ships override
  config files or `set/setr` convars from `custom.cfg`.
- **(build)** — a genuinely new custom resource under
  `resources/[custom]/` that the recipe does not provide.

Prefer **(configure)** wherever possible. Vendoring a recipe resource to
patch its config is forbidden — overrides only.

## Section 3 — Build Phases

Phases are ordered by dependency. Each phase is one dispatch and produces
one PR.

### Phase 1 — Character & spawn flow

- **Goal:** lock in the multichar experience (slot count, character
  creation gates) and align the spawn flow with `server_identity`.
- **Type:** configure (recipe-provided `qbx_core` multichar + character
  selection).
- **Scope:**
  - `custom.cfg` convars for `qbx_core` multichar: max character slots
    (recommend 2 for a 48-slot server), starting cash/bank, identifier
    requirements (`license`, `discord`).
  - New `resources/[custom]/config_overrides/qbx_core/` resource that
    re-exports the upstream character-creation config with our values
    (allowed nationalities, default DOB bounds, name regex).
  - Confirm `server_identity` spawn handler stays the single source of
    truth for spawn coordinates; document the override path in
    `docs/DEVELOPMENT.md`.
- **Depends on:** none beyond the merged scaffold.
- **Verifiable by Claude Code:**
  - `luac -p` clean on the new config resource.
  - `fxmanifest.lua` has all required keys; declares deps on `ox_lib`
    and `qbx_core`.
  - `custom.cfg` ensures the new override resource before `server_base`.
  - Convar names match the keys read by upstream `qbx_core` (grep
    upstream source to confirm).
- **Needs in-game check:** character creation UI shows the configured
  slot count; new character spawns at Legion Square via
  `server_identity`; rejoining picks up the same character.

### Phase 2 — Core economy & paycheck config

- **Goal:** set the baseline money supply — starting funds, paycheck
  cadence, payroll amounts per job grade.
- **Type:** configure (`qbx_core` + `qbx_management`/`qbx_banking`).
- **Scope:**
  - Paycheck interval and amounts via convars or an override config
    resource (recommend 7-minute paycheck cycle, starting cash $500 /
    bank $5,000 — small-server defaults).
  - SQL migration `sql/0002_economy_seed.sql` for any seeded society
    balances or starting items (use `INSERT … ON DUPLICATE KEY UPDATE`).
  - Document the `Config.Money` source-of-truth file in
    `docs/DEVELOPMENT.md`.
- **Depends on:** Phase 1 (character creation funnels through these
  starting amounts).
- **Verifiable by Claude Code:**
  - Migration is idempotent and `mysql --syntax-check`-clean (or parsed
    by a Python SQL grammar if no MySQL available).
  - Convars resolve to numeric values, not strings, in any Lua that
    reads them.
  - Numbers stay within sane bounds (no negative paychecks, no
    starting-cash above $50k).
- **Needs in-game check:** paycheck arrives at the configured interval;
  starting cash and bank balance match config on a brand-new character;
  ATM/bank UI reflects the configured currency symbol.

### Phase 3 — Whitelisted emergency-services jobs (police, EMS)

- **Goal:** make `police` and `ambulance` whitelisted, with grade
  rosters, equipment loadouts, and society pay configured.
- **Type:** configure (`qbx_police`, `qbx_ambulancejob`, `qbx_core` job
  registry).
- **Scope:**
  - `resources/[custom]/config_overrides/qbx_police/config.lua` — grades
    1–5, salaries, allowed weapons, allowed vehicles, MDT defaults,
    armoury locations (default Mission Row).
  - `resources/[custom]/config_overrides/qbx_ambulancejob/config.lua` —
    grades, salaries, hospital locations, revive timer, death timer.
  - SQL migration `sql/0003_emergency_jobs.sql` to register the jobs in
    `jobs` table if not already provided by the recipe; seed an `admin`
    grade for staff who need on-duty access.
  - ACE: `group.admin` and a new `group.eup` allowed to use
    `/setjob police` and `/setjob ambulance` via `custom.cfg`.
  - Whitelist enforcement: a small **(build)** addition,
    `resources/[custom]/gtarp_whitelist_jobs/`, listening to
    `QBCore:Server:OnPlayerLoaded` and rejecting `setjob` for non-allowed
    discord roles or license identifiers. Source of truth is a
    `Config.Allowed = { police = { 'license:CHANGEME' } }` table.
- **Depends on:** Phase 1, Phase 2.
- **Verifiable by Claude Code:**
  - All override configs `luac -p` clean.
  - The whitelist resource's manifest declares deps on `qbx_core`.
  - Grade numbers in police/ems configs match the grades referenced in
    the seed SQL migration.
  - Salary ladders are monotonically non-decreasing.
- **Needs in-game check:** non-whitelisted player cannot `/setjob
  police`; whitelisted player can go on duty, draw issued weapon from
  armoury, revive a downed player as EMS.

### Phase 4 — Civilian jobs configuration

- **Goal:** turn on the recipe-provided civilian jobs and ship a small
  curated lineup suitable for 48 slots.
- **Type:** mostly configure (`qbx_truckerjob`, `qbx_taxi`,
  `qbx_garbagejob`, `qbx_mining` or equivalents in the lean recipe), plus
  one **(build)** glue resource if any are missing.
- **Scope:**
  - Override configs for each civilian job: payout per delivery/run,
    cooldowns, NPC locations.
  - Decide and document the curated lineup (recommend: trucker, taxi,
    garbage, mechanic) — anything else is deferred.
  - If a chosen job is not in the recipe, **build** a minimal version
    under `resources/[custom]/gtarp_<job>_<short>/` rather than
    vendoring.
- **Depends on:** Phase 2 (paychecks/economy), Phase 3 (job framework
  proven).
- **Verifiable by Claude Code:**
  - All override configs `luac -p` clean and load order in `custom.cfg`
    is correct.
  - Payouts per run stay within a documented range so no single job
    dominates the economy.
- **Needs in-game check:** each curated job can be started from the NPC
  starter, a run completes, payout lands in the bank.

### Phase 5 — Shops & economy balancing

- **Goal:** populate `ox_inventory` shops with a curated catalog and
  price ladder consistent with paycheck/job income.
- **Type:** configure (`ox_inventory` `data/shops.lua`,
  `data/items.lua`).
- **Scope:**
  - `resources/[custom]/config_overrides/ox_inventory/` — replacement
    `data/shops.lua` and any additions to `data/items.lua`.
  - Price ladder: a 7-minute paycheck of $X should buy roughly Y of
    item Z — document the formula at the top of the override file.
  - Add general store, ammunition (license-gated via society account),
    24/7, hardware, and one clothing-store entry.
  - Society pricing for `qbx_police` and `qbx_ambulancejob` armouries
    (zero-cost issue, but logged).
- **Depends on:** Phase 2, Phase 4.
- **Verifiable by Claude Code:**
  - Override config syntax is valid Lua and uses the keys
    `ox_inventory`'s loader expects.
  - Every referenced item exists in `data/items.lua` (cross-resource
    grep).
  - No negative prices and no zero-price items outside society shops.
- **Needs in-game check:** each shop opens at its world location; buying
  an item deducts cash; selling stacks correctly; ammo gating works.

### Phase 6 — Signature custom feature (placeholder)

- **Goal:** one community-defining custom resource that distinguishes
  gtarp from a stock Qbox install. Concept TBD per server.
- **Type:** build (custom resource under
  `resources/[custom]/gtarp_<feature>/`).
- **Scope:**
  - One new resource: fxmanifest, config, client/server entry points,
    optional SQL migration `sql/0005_<feature>.sql`.
  - Stays inside the conventions in `docs/DEVELOPMENT.md`.
  - Suggested placeholder candidates (pick one): faction reputation
    tracker, dynamic weather + radio program, courier-style player-run
    delivery boards, evidence-locker workflow extension for police.
- **Depends on:** Phases 1–5 (need a working economy, jobs, and shops
  before layering signature mechanics on top).
- **Verifiable by Claude Code:**
  - `luac -p` clean; manifest correct; migration idempotent.
  - No duplication of capabilities already provided by the recipe.
  - Resource cleanly handles `onResourceStop` (no leaked threads,
    blips, or state-bags).
- **Needs in-game check:** the feature's golden-path user story works
  end-to-end with a real player session.

### Phase 7 — Admin & staff tooling

- **Goal:** give staff the minimum toolkit a small server needs without
  vendoring a heavyweight admin menu.
- **Type:** mostly configure (`txAdmin`, ACE permissions); one optional
  **build** for an in-game thin wrapper.
- **Scope:**
  - Expand `custom.cfg` ACE block: `command.tp`, `command.tpm`,
    `command.bring`, `command.goto`, `command.revive`, `command.heal`,
    `command.giveitem`, `command.setjob` (most map to existing
    qbx_core/ox commands; ACE grants make them callable).
  - Document the staff matrix (owner / admin / moderator / trial) in
    `docs/STAFF.md`.
  - Optional **build** `resources/[custom]/gtarp_staff/`: small chat
    commands that log staff actions to a Discord webhook (webhook URL
    via convar — secret-managed).
  - SQL migration `sql/0006_staff_log.sql` for an `audit_log` table.
- **Depends on:** Phase 3 (whitelist groundwork) for the principal
  groupings; Phases 4–5 for the commands to act on real entities.
- **Verifiable by Claude Code:**
  - Every ACE line in `custom.cfg` has a matching command in either
    framework code or our `gtarp_staff` resource (grep).
  - Audit-log migration is idempotent.
  - Webhook URL is read from a convar, never hardcoded.
- **Needs in-game check:** admin can `/tp` to a player; mod cannot;
  every staff action shows up in the audit log and the Discord webhook
  channel.

### Phase 8 — Security & anticheat hardening

- **Goal:** block the most common abuse vectors for a small public RP
  server.
- **Type:** configure (FXServer convars, `ox_inventory` purchase guards,
  `qbx_core` event guards); one small **build** for a server-side event
  ratelimit shim.
- **Scope:**
  - `custom.cfg` convars: `sv_filterRequestControl 2`,
    `sv_scriptHookAllowed 0`, `onesync_distanceCullVehicles true`,
    plus `sv_authMaxVariance 1` / `sv_authMinTrust 5`.
  - `resources/[custom]/gtarp_eventguard/` — server-side ratelimit
    around `QBCore:Server:UpdateMoney`, `qb-inventory:server:*` (if any
    remain), and any custom money/inventory events introduced in
    earlier phases. Drops + logs offenders.
  - SQL migration `sql/0007_security_events.sql` for an
    `event_violations` table.
  - Document the threat model in `docs/SECURITY.md`.
- **Depends on:** Phase 6, Phase 7 (we want every event we will be
  guarding to already exist).
- **Verifiable by Claude Code:**
  - Every guarded event name actually exists in earlier code (grep).
  - Ratelimits are realistic (per-player, per-second budgets >0 and
    <100).
  - No event handler trusts client-provided amounts without server
    re-validation.
- **Needs in-game check:** spamming a money-change event from a hacked
  client gets the player kicked and logged; legitimate gameplay
  triggers no false positives over a 30-minute play session.

### Phase 9 — Allowlist, rules & Discord integration

- **Goal:** restrict joins to approved players, surface rules to
  joiners, and tie staff/whitelist actions to Discord roles.
- **Type:** build (`resources/[custom]/gtarp_allowlist/`) + configure
  (txAdmin Discord bot if used).
- **Scope:**
  - `gtarp_allowlist/`: `playerConnecting` deferral that calls Discord
    API with a bot token (convar) and checks the joining user's roles
    against `Config.AllowedRoles`. Deny with a friendly message
    otherwise. Cache role lookups for 60s.
  - SQL migration `sql/0008_allowlist.sql` for an `allowlist` table for
    manual additions outside Discord.
  - Update the `server_identity` loading screen footnote to point to
    the rules channel.
  - Document the allowlist workflow in `docs/SETUP.md` and the rules
    pinned-message in `docs/RULES.md`.
  - Wire whitelist-job role grants (Phase 3) to read the same Discord
    role source so there is one allowlist source of truth.
- **Depends on:** Phase 3 (whitelist plumbing), Phase 7 (staff role
  matrix), Phase 8 (we want the allowlist behind anticheat too).
- **Verifiable by Claude Code:**
  - Bot token comes from a convar, not a literal in code.
  - Allowlist resource gracefully handles Discord API timeouts (deny
    fast with a clear message; never hang the deferral).
  - Migration idempotent.
- **Needs in-game check:** account without the role is denied at the
  deferral with the configured message; account with the role joins;
  removing the role and rejoining denies access.

### Phase 10 — Performance & stability optimization

- **Goal:** measure and tune so a full 48-slot session stays within a
  defensible server-thread budget and client FPS floor.
- **Type:** configure (per-resource convars, OneSync settings,
  `ox_target` polling); small **build** for a metrics scraper if
  needed.
- **Scope:**
  - Run `resmon` and `txAdmin`'s perf panel under a 30-player synthetic
    load (deferred to staff before launch; this phase ships the
    instrumentation).
  - `resources/[custom]/gtarp_perf/`: lightweight thread-hitch logger
    that samples `GetGameTimer()` deltas in critical loops and prints
    p95/p99 to console every 5 minutes; pushes to a webhook on
    threshold breach.
  - Document the perf budget (resmon target <1.5ms total custom layer,
    client FPS floor 50 on mid-spec) in `docs/PERFORMANCE.md`.
  - Audit every `CreateThread { while true … Wait(0) }` in earlier
    phases; convert to event-driven or increase `Wait` to >=250ms
    where possible.
  - Disable unused recipe resources in `custom.cfg` via `set
    sv_disableresource <name>` to free overhead.
- **Depends on:** all earlier phases — you cannot tune what is not
  built.
- **Verifiable by Claude Code:**
  - No `Wait(0)` in our custom layer outside explicitly justified spots
    (commented).
  - Perf-logger resource is itself cheap (one thread, `Wait(5000)`
    minimum).
  - Webhook URL via convar.
- **Needs in-game check:** under 30 active players, total custom-layer
  resmon is under budget; no client-side hitches above 32ms; the
  webhook receives expected periodic samples.

## Section 4 — Dispatch Notes

Each phase above is a single scoped task for Claude Code on the web.
The dispatch pattern:

1. **One phase = one prompt = one PR.** Do not bundle phases. Each PR
   should be small enough to review in 15 minutes.
2. **Run phases in order.** Later phases assume earlier phases are
   merged. Phase 5 expects the jobs from Phases 3–4 to exist; Phase 8
   expects the events from Phases 6–7 to guard; Phase 10 expects the
   whole stack so it can be measured.
3. **Before dispatching a phase**, confirm in this repo that the
   previous phase's PR is merged to `main` and the migrations have been
   applied to the deployed server. The roadmap is a hard sequence, not
   a suggested grouping.
4. **Each prompt should include**:
   - "Read `docs/BUILD-ROADMAP.md` Phase N and execute exactly that
     phase."
   - The same verification rigor used in the scaffold tasks: `luac -p`
     on every Lua file, manifest key check, load-order check, SQL
     migration idempotency check.
   - Explicit instruction to **prefer configure over build**: do not
     create a new resource where a recipe override or a convar can do
     the job.
   - A note that the dispatcher will do the in-game verification;
     Claude Code does the script-level verification.
5. **Branch per phase.** Use `claude/phase-NN-<short-name>` to keep
   PR history sortable. Merge to `main` before the next dispatch.
6. **The roadmap is a living document.** If a phase reveals a missing
   prerequisite, edit this file in the same PR and renumber downstream
   phases. Keep the "Depends on" lines accurate — they are the
   contract.
