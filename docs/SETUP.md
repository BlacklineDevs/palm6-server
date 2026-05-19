# SETUP — deploying gtarp on a fresh box

This document covers a clean install of the server from scratch. It assumes
you have an empty Linux host (or Windows box) with txAdmin installed and a
MySQL/MariaDB instance reachable from the server.

## 1. Provision FXServer and txAdmin

1. Install the latest recommended FXServer artifact for Linux (or Windows)
   following the official Cfx instructions.
2. Start txAdmin and complete the initial owner setup in the browser.

## 2. Deploy the `qbox-lean` recipe via txAdmin

1. In txAdmin, create a new server profile.
2. When prompted for a recipe, choose **`qbox-lean`** (the official lean
   Qbox recipe).
3. Provide a database the recipe can write to. The recipe will create the
   Qbox schema automatically.
4. Let the recipe run to completion. It will produce:
   - a `resources/` folder containing `ox_lib`, `oxmysql`, `ox_target`,
     `ox_inventory`, `qbx_core`, and the rest of the Qbox framework
     resources;
   - a generated `server.cfg` at the server root.

Do **not** start the server yet.

## 3. Drop the custom layer in

From a checkout of this repo:

1. Copy `resources/[custom]/` into the live server's `resources/` folder so
   the live tree contains:
   - `resources/[custom]/server_base/`
   - `resources/[custom]/server_identity/`

   The `[custom]` bracketed folder is treated by FXServer as a resource
   category and is scanned recursively.
2. Copy `custom.cfg` to the server root, next to the recipe-generated
   `server.cfg`.
3. Open the recipe-generated `server.cfg` and append at the very bottom:

   ```
   exec custom.cfg
   ```

   This is the single hook the custom layer needs. `custom.cfg` itself
   `ensure`s `server_identity` then `server_base` in the correct order and
   grants the `command.coords` ACE.

4. Compare the recipe-generated `server.cfg` against `server.cfg.example`
   in this repo and reconcile drift — particularly `sv_maxclients`,
   `sv_endpointprivacy`, `sv_enforceGameBuild`, and `set onesync on`.

## 4. Apply SQL migrations

Apply every file in `sql/` to the Qbox database in numeric order:

```
mysql -u <user> -p <database> < sql/0001_init.sql
```

Migration `0001_init.sql` is intentionally empty; it exists so subsequent
migrations have a starting point.

## 5. Secrets and environment-specific values

Configure these in txAdmin's secret-managed convars, **never** in this repo:

- `sv_licenseKey` — your Cfx server key
- `steam_webApiKey` — Steam Web API key
- the database connection string passed to `oxmysql`

These need to be edited in the repo (they are not secrets, but they are
environment-specific):

- `resources/[custom]/server_identity/config.lua` — `Config.DiscordAppId`
  (replace the all-zeros placeholder with your Discord application id)
- `resources/[custom]/server_identity/config.lua` and
  `resources/[custom]/server_base/config.lua` — `Config.ServerName`
  (currently `Los Santos Roleplay`)
- the `add_principal identifier.license:CHANGEME group.admin` line in your
  recipe-generated `server.cfg` (see `server.cfg.example`)

## 6. First boot

Start the server from txAdmin. Then verify, in order:

1. **Loading screen.** Join the server from a FiveM client. You should see
   the dark gtarp loading screen with the server name and a tip line.
2. **Server console banner.** The txAdmin live console should contain the
   `server_base started — version 0.1.0` banner block.
3. **`/serverinfo` command.** Once spawned in, type `/serverinfo` in chat.
   You should see a line like
   `Los Santos Roleplay — locale=en debug=false`.
4. **Welcome notification.** A `Welcome to the city.` ox_lib notification
   should fire once your character finishes loading. (This is the
   `QBCore:Client:OnPlayerLoaded` event firing from qbx_core.)
5. **Default spawn.** Your character should be placed at Legion Square
   (`195.17, -933.77, 30.69` heading 144) on first spawn.

If any of those are missing, check:

- `exec custom.cfg` is the last non-blank line of `server.cfg`.
- `ensure server_identity` and `ensure server_base` both appear in
  `custom.cfg`.
- `ox_lib`, `oxmysql`, and `qbx_core` ensured **before** the `exec
  custom.cfg` line so the dependencies declared in our fxmanifests are
  satisfied.

## 7. Updates

- Framework updates (Qbox, `ox_*`) are applied by re-running or updating
  the txAdmin recipe — never by editing files in this repo.
- Custom changes are made here, committed, pulled to the host, and
  reloaded with `restart server_base` (or the relevant custom resource)
  from the console.
