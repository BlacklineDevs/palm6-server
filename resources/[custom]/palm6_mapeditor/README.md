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
| `/propui` | **visual thumbnail browser** — 5,295 props with images, category rail, search, favorites, recent, a **Props / Peds / Vehicles catalogue switcher** (click a ped/vehicle card to place it at your aim — no need to memorise model names; a **ped behaviour picker** makes placed peds guard / lean / smoke / work instead of standing frozen), **blueprint kits** (prefabs), a **scene outliner** (jump to / delete / multi-select / save-as-kit), a **live-map outliner** (jump to / grab / delete committed props, **filter by named map**, **rename a map**, **merge a map into another**, **snapshots / rollback** (checkpoint a map and restore any snapshot; restore auto-saves the current state first) with a **snapshot diff** (pick a snapshot, compare it to another one or to the live map, and see exactly which props a restore would delete, bring back, and move — grouped by model, before you press Restore), **one-click export** of a map to .lua/.json/.ymap.xml/.py), an **entities outliner** (jump to / **move (grab-to-reposition)** / delete / multi-select placed peds + vehicles), a **performance panel** (budget meters vs the prop/light/erase/entity caps + density-cluster warnings), and a click-through detail view (preview + description + Spawn) |
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
| `/mapexportlive <mapname>` | export the accumulated **live map** (built across sessions) to Lua/JSON/ymap.xml/.py — now includes **scene peds + vehicles** (as a spawn list in the .lua/.json; the ymap stays props-only) |
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

## Snapshots, and what a snapshot diff can (and cannot) tell you
A snapshot serialises a map's props + lights into `palm6_mapeditor_revisions`. The
**Diff** button in the Snapshots view compares two of them — or one of them against the
live map — and reports props **added**, **removed** and **moved**, grouped by model. When
the target is the live map the sections are labelled by consequence ("deleted by a
restore", "brought back by a restore"), because that is the question being asked next to
a Restore button.

Matching (`shared/diff.lua`, a pure module with no natives and no DB) runs three passes:
by **row id** where both snapshots carry one, then by **exact position** for the same
model, then by **nearest same-model prop within 25 m**, which is what turns a
remove+add pair into a "moved". The screen states which of the three did the work,
because the answer is only as exact as its weakest pass:

- Ids are **not** stable across an edit. `/maplivegrab` deletes the row and `/mapcommit`
  re-inserts it, and a restore re-inserts every prop, so a moved prop gets a NEW id and is
  only found positionally. Snapshots taken before ids were recorded have none at all.
- The nearest-neighbour pass is greedy, so two identical models close together can be
  paired the wrong way round. The counts stay conserved; *which* prop moved where can be
  wrong.
- A prop moved more than 25 m reads as one removed + one added, deliberately.
- Scene peds/vehicles are not in snapshots and are therefore not compared.
- A very dense map can exhaust the comparison budget; the diff then says so instead of
  quietly reporting a partial answer.

Nothing here adds a table or a column — it re-reads the snapshot blobs that already exist.

## Distance culling and export (`Config.LiveCull` / `Config.ExportRotationProbe`)
`Config.LiveCull` spawns only the live props near you and despawns the rest. It ships OFF,
and the thing that has kept it off is export: the `.ymap.xml` and Blender writers read each
prop's world **quaternion** off the live object, so a culled prop would export flat, and
`/mapexportlive` refuses outright rather than write that.

`Config.ExportRotationProbe` (also OFF) removes that blocker. A culled prop never lost its
rotation — the DB row's euler is on the record — so the only missing step is euler ->
quaternion. That step is **not** hand-rolled: one hidden scratch object is spawned at the
player and the game is asked to do the conversion with the same `SetEntityRotation(...,2,true)`
call the editor uses on real props. Before any rotation is exported the probe must pass two
checks on your client: round-trip three rotations without a stale read, **and** reproduce
the exact quaternion of at least one prop of this map that is actually spawned. If either
check fails the export refuses exactly as it does today. (The `.lua` and `.json` writers
never needed the entity at all — they write the euler straight off the record — but a
culled prop is dropped from the record list before it reaches them, so today it is missing
from all four formats, not just the two that need a quaternion.)

Turn both flags on together, restart the resource, and export from inside the map (the
probe needs one streamed prop of that map to check itself against).

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
- `shared/diff.lua` — the snapshot-diff matcher (`MapDiff`). Pure functions: no natives, no
  MySQL, no events, so it can be reasoned about and tested outside the game.
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

### Assessed and deliberately NOT built: "shell builder"
A room/building shell generator (walls + floor + ceiling from a size) would be a thin
wrapper over two tools that already exist and are already wired into undo, the NUI and
`/mapcommit`:

- **Repetition** is `/matgrid <rows> <cols> <spacing>` (`client/tools.lua`) — a wall run is
  a 1xN grid, a floor is an NxM grid, both with a ghost preview and one undo group.
- **Reuse** is the prefab / Blueprint-kit system (`server/prefabs.lua` stores a group
  relative to its centroid, `client/prefabs.lua` stamps it at your aim at any yaw, lights
  included). Build one shell by hand, save it as a kit, and stamp it forever.

The only thing a shell builder would genuinely add is knowing each wall prop's real
dimensions so tiles butt up without gaps. The editor has no model-size data anywhere
(`data/prop_groups.lua` is names only, and nothing calls `GetModelDimensions`), and wall
prop origins are not consistently centred, so the spacing has to be measured in-game per
model — which is exactly what `/matgrid`'s `spacing` argument already takes. Building it
blind would mean authoring dozens of offsets that can only be judged by standing in the
room, which is the one thing this project cannot currently do.

The single non-wrapper gap, if it is ever wanted: `/matgrid` grids on X/Y only (it reuses
`r.z` for every copy, `client/tools.lua`), so it cannot stack vertically. A 4th optional
`layers` argument defaulting to 1 would make walls possible and leave every existing call
byte-identical. Not built here, because it is a change to a working command that nobody can
verify in game yet.
