# DEVELOPMENT — conventions for the gtarp custom layer

## Scope

This repo holds **only** custom code, config overrides, SQL migrations, and
docs for the gtarp server. The Qbox framework and FXServer artifacts are
provisioned by the txAdmin Qbox recipe and live outside version control. If
something belongs to the framework, do not vendor it here — extend it via a
new resource under `resources/[custom]/` instead.

## The `[custom]` folder convention

FiveM treats any folder whose name is wrapped in square brackets as a
**category** and recurses into it when discovering resources. We use a
single category, `[custom]`, for every resource that originates in this
repo. The benefits:

- It is immediately obvious in a deployed `resources/` tree which resources
  came from this repo vs. from the recipe.
- The recipe is free to add or move framework resources without colliding
  with us.
- Server admins can `ensure`/`restart` the whole layer by name without
  touching framework resources.

A single nested bracket category, `[config_overrides]`, is allowed inside
`[custom]` to group recipe-override resources (e.g.
`[custom]/[config_overrides]/qbx_core_overrides`). These resources publish
convars and ship config files that the recipe-deployed resource reads — they
never vendor or rebuild the recipe resource itself.

Do not nest deeper than that.

## Resource naming

- Lowercase, snake_case: `server_base`, `gtarp_hud`, `gtarp_jobs_courier`.
- Prefix server-specific resources with `gtarp_` so they sort together and
  are unambiguous next to `qbx_*` and `ox_*` resources.
- The single exception is `server_base`, which is the template/bootstrap
  resource and is intentionally unprefixed.
- Match the resource folder name to the value used in `ensure` lines in
  `custom.cfg`.

## Resource layout

Every resource under `resources/[custom]/` should follow:

```
<resource_name>/
    fxmanifest.lua       # fx_version 'cerulean', lua54 'yes', deps declared
    config.lua           # shared Config table; no secrets
    client/              # client_scripts
    server/              # server_scripts
    shared/              # optional; shared_scripts beyond config.lua
    locales/             # optional; if using ox_lib locale
```

Declare every cross-resource dependency in `fxmanifest.lua`'s
`dependencies` block so FXServer can refuse to start the resource if a
dependency is missing.

## Money source-of-truth

`[custom]/[config_overrides]/qbx_economy_overrides/config.lua` is the
single source of truth for paycheck cadence, currency, and per-job/per-grade
payroll. Downstream job-config resources read it via the exports:

```lua
local pays = exports.qbx_economy_overrides:GetJobPaychecks()
local mins = exports.qbx_economy_overrides:GetPaycheckInterval()
```

Do not hardcode money values in individual job resources — extend the
ladder in `qbx_economy_overrides/config.lua` instead.

## SQL migrations

- One change per file where practical.
- Numbered: `0001_init.sql`, `0002_add_courier_jobs.sql`, …
- Never edit a migration that has already been applied anywhere. Add a new
  numbered file instead.
- Use `IF NOT EXISTS` / `IF EXISTS` guards so re-running a migration on a
  partially-applied database is a no-op.

## Secrets

Nothing in this repo may contain a real secret. License keys, API tokens,
DB credentials, and webhook URLs are all managed by txAdmin's secret store
and injected via convars at runtime. `.gitignore` blocks `.env`, `*.env`,
and `secrets.cfg` for defence in depth.

## Verification policy

Every change must be verified by running scripts in this repo — the Lua
syntax check (`luac -p`) on changed `.lua` files, SQL lint on changed
migrations, and any future per-resource test scripts we add. Do not rely
on manual in-game testing as a substitute. If a change cannot be exercised
by a script, add a script that exercises it before merging.

## Commits

- One logical change per commit.
- Imperative subject line, scoped where useful: `server_base: …`,
  `sql: …`, `docs: …`.
- Never commit generated cache files, logs, or anything matched by
  `.gitignore`.
