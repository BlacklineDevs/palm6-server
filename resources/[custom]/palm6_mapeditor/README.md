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
| `/propui` | **visual thumbnail browser** — 5,295 props with images, category rail, search, favorites, recent, a **Props / Peds / Vehicles catalogue switcher** (click a ped/vehicle card to place it at your aim — no need to memorise model names), **blueprint kits** (prefabs), a **scene outliner** (jump to / delete / multi-select / save-as-kit), a **live-map outliner** (jump to / grab / delete committed props, **filter by named map**, **rename a map**, **one-click export** of a map to .lua/.json/.ymap.xml/.py), an **entities outliner** (jump to / delete / multi-select placed peds + vehicles), a **performance panel** (budget meters vs the prop/light/erase/entity caps + density-cluster warnings), and a click-through detail view (preview + description + Spawn) |
| `/maphelp` (key **H**) | **in-game controls & commands sheet** — every keybind and slash command, overlaid on the browser |
| `/maplog` (key **L**) | **activity log** — searchable history of every action the editor reported this session |
| `/mapcam` (key **B**) | **freecam** — detach a smooth camera: WASD fly, mouse look, Shift fast, mouse-wheel FOV zoom, Backspace exit |
| `/props` / `/propsearch <q>` | ox_lib catalog browse / fuzzy search (5,295 props) |
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
| `/matgrid <rows> <cols> <spacing>` | mass grid-spawn the selected model — **ghost preview** first (Enter place / Backspace cancel) |
| `/matscatter <count> <radius>` | scatter N copies of the selected model with random yaw — **ghost preview** first |
| `/matcopy` | copy the selected prop's coords (vector4) to clipboard |
| `/mattp` | teleport yourself to the selected prop |
| `/materase` / `/materaseundo` | hide the vanilla world prop you look at / restore |
| `/mapexport [name]` | export your **session** to Lua + JSON + CodeWalker ymap.xml + Blender/Sollumz .py |
| `/mapexportlive <mapname>` | export the accumulated **live map** (built across sessions) to Lua/JSON/ymap.xml/.py |
| `/mapload <file>` | reload a saved export back into the editor (sessions) |
| `/matlight [point\|spot]` | place a point/spot light at your aim |
| `/matlightcolor <r> <g> <b>` `/matlightrange <n>` `/matlightint <n>` | tune the selected light |
| `/matlightpick` / `/matlightdel` | select the light nearest aim / delete the selected light |
| `/matareadel <radius>` | delete placed props within radius of aim |
| `/mapcommit [map]` | **publish your session (props + lights) to a live map** (persisted, all players see it) |
| `/maplist` | list live maps and their prop/erase/light counts |
| `/maplivedel` | remove the LIVE prop you aim at (everywhere, from the DB) |
| `/maplivegrab` | grab the LIVE prop you aim at back into your session to reposition/edit it |
| `/maplightdel` | remove the LIVE light nearest your aim (everywhere, from the DB) |
| `/mapwipe <map>` | delete an entire live map — props + lights (everywhere, from the DB) |
| `/mapworlderase` | erase the vanilla world prop you aim at **for everyone** (persisted) |
| `/mapworldrestore` | restore the nearest persisted world-erase (everywhere) |
| `/mapprefabsave <name>` | save your session props + lights as a reusable **prefab** |
| `/mapprefabstamp <name> [yaw]` | stamp a prefab at your aim, rotated by yaw° (one undo group) |
| `/mapprefablist` / `/mapprefabdel <name>` | list / delete prefabs |
| `/matped <model> [scenario]` | place a **scene ped** at your aim (persisted, all players) |
| `/matveh <model>` | place a **scene vehicle** at your aim (persisted, all players) |
| `/matentdel` | remove the scene ped/vehicle you aim at |
| `/mapworkmap <name>` | set which map scene entities place onto |
| `/mapentwipe [map]` / `/mapentlist` | wipe / count scene entities |

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
per map. **Lights are published too**: `/mapcommit` sends your session's lights (`/matlight`)
alongside its props; they persist (`palm6_mapeditor_lights`) and every player sees them, drawn
each frame and distance-culled to `Config.LiveLightDist`. `/maplightdel` removes the nearest
live light; `/mapwipe` clears a map's lights with its props. Caps: `Config.LiveMaxLights`.

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
- `client/nui.lua` + `html/` — the visual thumbnail prop browser (`/propui`) and the
  controls sheet (`/maphelp`, key **H**). Self-contained NUI (no build step); thumbnails load
  from the RAGE odb CDN, addressed by `joaat(name)` computed in-page, so nothing is bundled
  (~93%+ coverage, clean fallback tile otherwise). The browser has **Favorites** (star any
  prop; pinned view) and **Recent** (auto-tracked spawns), both persisted in localStorage, plus
  **smart search** — conceptual keyword aliases ("trash"→bins/dumpsters, "seat"→chairs/benches)
  layered over fuzzy substring/subsequence matching.
- `client/live.lua` — live-map streaming (spawns/syncs the persisted props on each client).
- `server/main.lua` — writes export files (ACE-gated).
- `server/live.lua` — MySQL persistence + authoritative live sync (owns `palm6_mapeditor_props`).
- `object_gizmo` (separate vendored resource) — the visual DrawGizmo handles.

## Export formats
- **Lua** — `{ model, coords vector3, rot vector3 }` table + a runtime loader shape.
- **JSON** — same data, `[{model,x,y,z,rx,ry,rz}]`.
- **CodeWalker `.ymap.xml`** — full `CMapData` with `CEntityDef` per prop (rotation =
  the object's live quaternion **inverted**, the CEntityDef convention). Import in
  CodeWalker RPF Explorer → Import XML → binary ymap FiveM streams.
- **Blender / Sollumz `.py`** — a Blender script (Scripting tab → Run) that rebuilds the
  map as one Empty per prop, named by archetype, at the exact GTA transform (position +
  world quaternion; GTA and Blender are both Z-up so it maps directly). Each empty carries
  an `archetypeName` custom property for authoring a Sollumz YMAP. Stock `bpy` only.

**Editing a committed prop:** `/maplivegrab` (aim at it) checks that one prop out of the live
map — it's removed for everyone and dropped back into your session as a normal editable prop;
reposition it and `/mapcommit` republishes. Only one prop is ever checked out at a time.

**Prefabs = Blueprint Kits:** saved prefabs also surface in `/propui` under the **Blueprint kits**
rail view — click a kit to see its prop/light counts and a **Stamp at aim** button (same as
`/mapprefabstamp`, stamped at your crosshair). `/mapprefabsave <name>` stores your current session props as a reusable group,
centred on their centroid (in `palm6_mapeditor_prefabs`). `/mapprefabstamp <name> [yaw]` drops
the whole group at your crosshair, rotated by `yaw` degrees, as one undo group — then reposition
and `/mapcommit`. Great for repeating a furnished room, checkpoint, or barrier layout.

**Scene entities (peds / vehicles):** `/matped <model> [scenario]` and `/matveh <model>` place a
frozen NPC or parked vehicle at your crosshair; they persist (`palm6_mapeditor_entities`) and
stream to every player. Ambient peds take an optional scenario (e.g. `WORLD_HUMAN_GUARD_STAND`).
`/mapworkmap <name>` picks the map they belong to; `/matentdel` removes one; `/mapentwipe [map]`
clears a map's entities. This is a self-contained subsystem — it never touches the prop/light
live map, so it can't regress it.

## Roadmap (not yet built)
- Scene-entity editing/grab (currently place + delete); prefab support for entities.
