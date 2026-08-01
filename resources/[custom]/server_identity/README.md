# server_identity

Palm6 identity layer: branded loadscreen, spawn placement, Discord rich presence.

## Loadscreen

Edit **[`html/config.js`](html/config.js)** for all player-facing loadscreen content:

| Key | Purpose |
|-----|---------|
| `logo` / `serverName` | System A mark + wordmark |
| `socials` | Discord / YouTube / TikTok / Facebook / X / GitHub (`enabled` + `url`) |
| `staff` | Roster (`name`, `role`, optional `avatar` under `assets/staff/`) |
| `tips` | Rotating lines under the progress bar |
| `rules` | Compact city-rules panel (starts collapsed) |
| `music` | Set `enabled: true` and drop an mp3 under `html/assets/music/` |

Background art: `html/palm6_screen.jpg`. Cursor is on so controls are clickable.

**Local preview:** open `html/loading.html#preview` in a browser (progress bar animates without FiveM).

**Music:** Space toggles play/pause when music is enabled. Autoplay may require a click in CEF.

## Spawn & Discord

Lua config: [`config.lua`](config.lua) — `SpawnPoint`, `DiscordAppId`, presence text.
