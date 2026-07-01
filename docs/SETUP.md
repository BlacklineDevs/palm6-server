# SETUP — deploying gtarp on a fresh box

## 1. Provision FXServer + txAdmin

Install the latest recommended FXServer artifact and complete txAdmin owner
setup in the browser.

## 2. Deploy the `qbox-lean` recipe

In txAdmin, create a new server profile and choose the **`qbox-lean`**
recipe. Provide a database; the recipe creates the Qbox schema
automatically. The recipe produces:

- a `resources/` tree with `ox_lib`, `oxmysql`, `ox_target`, `ox_inventory`,
  `qbx_core`, and the rest of the Qbox framework resources;
- a generated `server.cfg` at the server root.

Do not start the server yet.

## 3. Drop the custom layer in

From a checkout of this repo:

1. Copy the **entire** `resources/[custom]/` tree into the live server's
   `resources/` — all `[config_overrides]/*` override resources plus the
   `gtarp_*`, `server_identity`, and `server_base` resources, each with its
   `bridge/` folder. `custom.cfg`'s `ensure` list is the authoritative set of
   what must be present.
2. Copy `custom.cfg` next to the recipe-generated `server.cfg`.
3. Append `exec custom.cfg` to the bottom of `server.cfg`. This is the
   single hook the custom layer needs — `custom.cfg` itself `ensure`s every
   override resource and every `gtarp_*` resource in dependency order, then
   `server_identity` and `server_base`, and grants the command ACEs.
4. Diff your `server.cfg` against `server.cfg.example`. Reconcile
   `sv_maxclients`, `sv_endpointprivacy`, `sv_enforceGameBuild`, and
   `set onesync on`.

## 4. Apply SQL migrations

Apply every file in `sql/` to the Qbox database in numeric order:

```
mysql -u <user> -p <database> < sql/0001_init.sql
```

## 5. Secrets and environment-specific values

Secrets in txAdmin's secret store, never in this repo:

- `sv_licenseKey`
- `steam_webApiKey`
- the `oxmysql` connection string
- `gtarp:staff_webhook` — Discord webhook for staff actions (Phase 7)
- `gtarp:discord_bot_token` and `gtarp:discord_guild_id` — used by
  `gtarp_allowlist` (Phase 9) to read Discord role membership

Edit in the repo (not secrets, but per-environment):

- `resources/[custom]/server_identity/config.lua` — `DiscordAppId`
- `resources/[custom]/[config_overrides]/qbx_core_overrides/config.lua` —
  multichar slots, starting funds, identifier requirements

## 6. First boot

Start the server. Verify:

1. Dark gtarp loading screen appears on join.
2. Console banner: `server_base started — version 0.1.0`.
3. `/serverinfo` responds in chat.
4. Welcome notification fires once the character finishes loading
   (`QBCore:Client:OnPlayerLoaded`).
5. Character spawns at Legion Square.

If anything is missing, check `exec custom.cfg` is the last non-blank line
of `server.cfg`, that all three `ensure` lines appear in `custom.cfg`, and
that `ox_lib`/`oxmysql`/`qbx_core` are ensured before `exec custom.cfg`.

## 7. Updates

- Framework updates: re-run the txAdmin recipe; never edit those files
  here.
- Custom changes: commit here, pull on the host, `restart <resource>` from
  the console.
