# server_identity

Palm6 identity layer: branded loadscreen, spawn placement, Discord rich presence.

## Loadscreen (v0.9.24)

High-tech cinematic chrome matched to the **P6 logo**. Edit [`html/config.js`](html/config.js).

| Feature | Notes |
|---------|--------|
| Plates | 19-image pool (Discord captures + FiveM stills), shuffled each login |
| Progress | Shimmer bar, phases, ETA, tip strip |
| Atmosphere | Soft matte, grain, spotlight, theme picker (P) |
| Dock | Start · Rules · News · Map · Staff · Jobs · Gallery · Updates · more |
| Music | Mixkit Bay playlist (legal free stock) — drop-in MP3s supported |
| Gates | First-visit rules acknowledge; Discord invite count |

**Preview:** `html/loading.html#preview` (hard refresh after edits)

## Spawn & Discord

[`config.lua`](config.lua) — `SpawnPoint`, `DiscordAppId`.
