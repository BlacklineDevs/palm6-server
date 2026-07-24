# palm6_mapeditor — in-game map / prop editor

An advanced in-game map/prop editor (target: the paid cfx.re "Advanced Map & Prop
Editor"). Spawn props, manipulate them with keyboard **or** a visual gizmo, snap to
surfaces, erase vanilla world props, mass-place, and **export to Lua / JSON /
CodeWalker `.ymap.xml`**. Admin dev tool, ACE-gated (`command.mapedit`).

## Quick start
1. `/mapedit` — toggle the editor (you're planted; camera stays free).
2. `/props` (browse 5,295 props by category) or `/propsearch barrel` (fuzzy) — pick
   one and it spawns at your crosshair, selected.
3. Position it: **hold Left-Click** to carry to where you aim, **arrows** to nudge,
   **Shift+Up/Down** for height, **Q/E** to rotate (`/mataxis` cycles yaw/pitch/roll),
   **Space** to snap onto the surface below. Or `/matgizmo` for visual handles.
4. `/mapexport mymap` — writes `data/exports/mymap_<ts>.{lua,json,ymap.xml}` and puts
   the Lua on your clipboard. Import the `.ymap.xml` in CodeWalker → binary ymap.

## Commands
| Command | Does |
|---|---|
| `/mapedit` | toggle editor |
| `/props` / `/propsearch <q>` | catalog browse / fuzzy search (5,295 props) |
| `/prop <model>` | spawn a specific model at aim |
| `/matnext` `/matprev` `/matcat` | cycle the quick-prop catalog |
| `/matpick` | select the object nearest your aim |
| `/matgizmo` | grab selected with visual handles (W move, R rotate, S scale, Q world/local, LAlt ground, Enter confirm) |
| `/mataxis` | cycle keyboard rotate axis (yaw/pitch/roll) |
| `/matdup` | duplicate selected |
| `/matundo` | undo last spawn/delete |
| `/matdel` `/mapclear` | delete selected / all |
| `/matrot <rx> <ry> <rz>` | set exact rotation |
| `/matfreeze` `/matcollision` | toggle freeze / collision on selected |
| `/matgrid <rows> <cols> <spacing>` | mass grid-spawn the selected model |
| `/materase` / `/materaseundo` | hide the vanilla world prop you look at / restore |
| `/mapexport [name]` | export Lua + JSON + CodeWalker ymap.xml |
| `/mapload <file>` | reload a saved export back into the editor (sessions) |
| `/matlight [point\|spot]` + `/matlightcolor/range/int` | light editor |
| `/matareadel <radius>` | delete placed props within radius of aim |
| `/mapcommit [map]` | **publish your session to a live map** (persisted, all players see it) |
| `/maplist` | list live maps and their prop counts |
| `/maplivedel` | remove the LIVE prop you aim at (everywhere, from the DB) |
| `/mapwipe <map>` | delete an entire live map (everywhere, from the DB) |
| `/mapworlderase` | erase the vanilla world prop you aim at **for everyone** (persisted) |
| `/mapworldrestore` | restore the nearest persisted world-erase (everywhere) |

Live keys (something selected): **LMB** carry · **Arrows** move · **Shift+Up/Dn**
height · **Q/E** rotate · **Space** snap · **Esc** exit.

## Live maps (persistence + networked sync)
`/mapexport` writes files for CodeWalker; **`/mapcommit` makes a placement real on the
live server**. A committed map is stored in MySQL (`palm6_mapeditor_props`, self-created
at boot) and streamed to **every** connected player, surviving restarts. Model names and
coords are re-validated server-side before any insert — the server is the sole authority.

Workflow: build a session in the editor → `/mapcommit downtown` publishes it and clears
your session (the props come back as live objects everyone sees). Commit **appends**, so
`/mapcommit downtown` again grows the map. `/maplivedel` removes one prop, `/mapwipe
downtown` clears the map. Bounds: `Config.LiveMaxCommit` per commit, `Config.LiveMaxProps`
per map. Lights remain client-local (session/export only) for now.

**World-erase sync:** `/materase` is a personal, session-local suppression of a vanilla map
prop; **`/mapworlderase` makes it real** — the hide is stored (`palm6_mapeditor_hides`) and
replayed on every client and every future joiner, so you can carve out vanilla geometry to
drop a custom build in and everyone sees the same world. `/mapworldrestore` undoes the
nearest one everywhere. On resource stop the client re-shows all hidden props (re-applied on
next sync), so a restart never leaves vanilla geometry permanently gone.

## Architecture
- `bridge/cl_game.lua` — all GTA natives (spawn/transform, camera raycast, surface
  snap, model-hide, gizmo bridge). `client/*` call `Game.*` only.
- `client/main.lua` — editor core (spawn/select/undo/HUD/export).
- `client/browser.lua` — prop catalog + fuzzy search (`data/prop_groups.lua`).
- `client/tools.lua` — world eraser, mass grid, per-prop toggles, gizmo command.
- `client/live.lua` — live-map streaming (spawns/syncs the persisted props on each client).
- `server/main.lua` — writes export files (ACE-gated).
- `server/live.lua` — MySQL persistence + authoritative live sync (owns `palm6_mapeditor_props`).
- `object_gizmo` (separate vendored resource) — the visual DrawGizmo handles.

## Export formats
- **Lua** — `{ model, coords vector3, rot vector3 }` table + a runtime loader shape.
- **JSON** — same data, `[{model,x,y,z,rx,ry,rz}]`.
- **CodeWalker `.ymap.xml`** — full `CMapData` with `CEntityDef` per prop (rotation =
  the object's live quaternion **inverted**, the CEntityDef convention). Import in
  CodeWalker RPF Explorer → Import XML → binary ymap FiveM streams. Also imports into
  Sollumz (Blender) directly.

## Roadmap (not yet built)
- React NUI prop browser with thumbnail grid (ox_lib browser works today).
- Networked light sync + world-erase sync (currently session/export-local).
- Per-prop live editing after commit (adopt/check-out round-trip); ped/vehicle placement.
