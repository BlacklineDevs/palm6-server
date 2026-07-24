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

Live keys (something selected): **LMB** carry · **Arrows** move · **Shift+Up/Dn**
height · **Q/E** rotate · **Space** snap · **Esc** exit.

## Architecture
- `bridge/cl_game.lua` — all GTA natives (spawn/transform, camera raycast, surface
  snap, model-hide, gizmo bridge). `client/*` call `Game.*` only.
- `client/main.lua` — editor core (spawn/select/undo/HUD/export).
- `client/browser.lua` — prop catalog + fuzzy search (`data/prop_groups.lua`).
- `client/tools.lua` — world eraser, mass grid, per-prop toggles, gizmo command.
- `server/main.lua` — writes export files (ACE-gated).
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
- Light editor (per-frame DrawSpotLight/WithRange over synced defs).
- MySQL persistence + client-replicated live sync (world-erase hides are currently
  client-local); named map library; area-delete; ped/vehicle placement.
