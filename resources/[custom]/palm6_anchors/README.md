# palm6_anchors

An admin tool that makes every world anchor in the custom layer **visible** and
**correctable in game**.

---

## WHAT IT DOES NOT DO. READ THIS FIRST.

**palm6_anchors does not rewrite any other resource's config, and no other
resource reads its captures.**

It is a capture-and-reporting tool. A capture produces two things:

1. a row in `palm6_anchor_overrides`, and
2. a printed config line, in chat and in the server console, e.g.

```
palm6_evidence/shared/config.lua  Config.LockerCoords = vector3(455.56, -991.74, 30.24)
```

**A capture becomes real when a human pastes that line into the owning config
file.** Until then, the feature is still exactly where its own config says it is.

That restraint is the design, not an unfinished corner. A half-wired override
system, where this table silently disagreed with fifteen audited config files,
would be strictly worse than the placeholders it replaces: the feature would
move, the config would still say otherwise, and the next person to read that
config would be misled by a file that used to be true. The tool exists to end
mystery placements, not to add a second hidden source of them.

There is an **unused** export for the later phase. See "Phase 2" below.

---

## WHY IT EXISTS

Three real incidents in one week, all with the same misleading symptom: *the
feature looks broken*.

1. Pressing `E` at the evidence room got a kick. `palm6_evidence` registers its
   locker at the qbx_police **duty** point, not the evidence room.
2. The uniform wardrobe drew its marker at the duty toggle while the clothing
   room David actually uses is about 13m away. He saw nothing and reasonably
   concluded it was broken.
3. Roughly three dozen more anchors across the custom layer carry an inline
   `VERIFY IN-GAME` marker, meaning nobody ever confirmed them. Every one is a
   future "it doesn't work" report.

None of these can be fixed by working out the right numbers, because **no
coordinate in this project may ever be invented** (a guessed one once put a
location on an airport runway). The fix has to be a tool that shows where every
anchor currently *is* and lets a human correct it by standing in the right
place.

---

## THE TEN-MINUTE WALK

1. `/anchormarkers` to turn markers on.
2. Walk into Mission Row. Every registered anchor within 75m is a floating
   chevron with its key above it. **Amber** = still the config value.
   **Green** = a capture is already on file.
3. See `evidence_locker` glowing in the duty room? Walk to where the evidence
   room actually is.
4. Press **F7** (or `/anchors`). The list opens, nearest first, each row showing
   the label, the owning resource and how far away it is.
5. Pick `Evidence locker` → **"This anchor belongs where I am standing"**.
6. Copy the config line out of chat. Repeat for the next one.
7. Paste the lines into the real configs, restart those resources, walk it again
   and confirm every marker is green and in the right room.

Nothing in steps 1-6 requires typing a number.

---

## COMMANDS AND KEYS

| Route | Realm | What it does |
|---|---|---|
| `F7` (rebindable) | client | Opens the anchor list |
| `/anchors` | client | Same thing, for when the key is cleared or taken |
| `/anchormarkers` | client | Toggles the live markers |
| `/anchorlist [filter]` | server | Prints every anchor to chat: key, resource, current reading, and whether that reading is the config value or a capture |
| `/anchorline <key>` | server | Prints the paste-ready config line for one anchor |
| `/anchorstatus` | server | The meter: registered count, captured count, schema state, ACE state |

The client and server command names are deliberately different. Registering the
same name in both realms runs both handlers off one keypress.

`F7` was chosen because nothing in `resources/[custom]` binds it: the taken keys
are `E`, `Q`, `LMENU` (palm6_fc_combat), `U` (palm6_brain), `F5` (palm6_mdt),
and `B`, `H`, `L` (palm6_mapeditor).

---

## PERMISSION

One ACE gates everything: the menu, the markers, the teleport and the capture.

**custom.cfg needs this line** (this resource does not edit custom.cfg):

```
add_ace group.admin command.anchors allow
```

Every command here is `RegisterCommand(..., restricted = false)` with the check
inside the handler, which is the shape `custom.cfg` already uses for
`/placeped`, `/bizshell` and the `/uniform*` family. That means the audit's
`command-aces` check **structurally cannot** catch a missing grant here: it only
reconciles *restricted* registrations. So the resource checks the grant itself
at boot with `IsPrincipalAceAllowed` and prints the exact missing line in red.

A non-admin who presses `F7` gets a menu whose single row names the missing
permission. It does not fail silently.

---

## custom.cfg: THE LINES NEEDED

This resource does not edit `custom.cfg`. Add, in the resource block:

```
# palm6_anchors - admin inspector for every world anchor in the custom layer.
# Draws a labelled marker at each registered anchor, lists them by distance, and
# records "this anchor belongs where I am standing" with the config line to
# paste. It does NOT rewrite any other resource's config and nothing reads its
# captures: a correction becomes real when a human pastes the printed line.
# Markers are OFF by default and admin-gated, so it costs nothing until used.
ensure palm6_anchors
```

and, in the ACE block:

```
# palm6_anchors admin tool. The resource checks this ace itself and prints the
# exact missing line in red at boot if the grant is absent, because the audit's
# command-aces check only reconciles RESTRICTED registrations and every command
# here is unrestricted, so it structurally cannot catch a missing grant.
add_ace group.admin command.anchors allow
```

---

## palm6_eventguard: THE BUDGETS WANTED

Three net events, all admin-gated and all cheap. Requested budgets for
`palm6_eventguard/config.lua`:

```lua
-- palm6_anchors, the admin anchor inspector. Every one of these is refused
-- server-side for a source without command.anchors, so these budgets bound a
-- flood rather than an escalation. menuAction is the highest because correcting
-- a station is a burst: open, pick, capture, open, pick, capture.
['palm6_anchors:menuAction']    = { calls = 40, window_seconds = 60 },
['palm6_anchors:requestPoints'] = { calls = 10, window_seconds = 60 },
['palm6_anchors:toggleMarkers'] = { calls = 20, window_seconds = 60 },
```

The resource also carries its own per-source limiter (`Config.RateLimits`) that
runs *inside* the handler. Neither replaces the other, and every refusal says so
out loud with the seconds remaining.

---

## THE REGISTRY

`shared/registry.lua`. One row per anchor:

| field | meaning |
|---|---|
| `key` | stable identifier, and the primary key of the capture table. **Never rename one**: it orphans the capture. |
| `label` | what a human calls it |
| `resource` / `file` / `path` | exactly where the number lives. `path` is the real Lua path, which is not always a literal substring of the file: `shops.lua` declares `ExtraShops = { general_store = { ... } }`, so `ExtraShops.general_store.locations[1]` is correct but only its segments are greppable. |
| `form` | `vector3`, `vector4` or `table`: how the number is *written* in that file |
| `kind` | `interaction` (a point you walk up to) or `zone` (a centre with a radius) |
| `ref` | the current value, **transcribed verbatim** from that config |

`form` matters. The capture prints a replacement line in the **same form** the
file uses, so it is paste-ready. A `vector3(...)` line pasted where the file
writes `{ x = , y = , z = }` would break that config on the next restart, which
is worse than the misplaced anchor it was meant to fix.

`ref` is a **reference reading**, not an authority. Nothing reads it to decide
where a feature goes; the owning resource still reads its own config. If a `ref`
ever disagrees with the config it cites, the config is right and this is a
transcription bug worth reporting, because the whole tool rests on those two
agreeing.

### How the registry was built

By grepping `resources/[custom]` for `vector3(`, `vector4(` and `x = <number>,
y =` table literals, then reading every hit and deciding whether it is a real
interaction anchor or something else. **102 anchors** are registered across 26
owning files.

What was deliberately left out, and why, is written at the bottom of
`shared/registry.lua`. In short: ped scenario spots (`palm6_pd_life
Config.Scene`, 45 of them, already served by `/placeped`), ambient NPC spawn
areas (`palm6_brain`, already served by `/brainscene`), the 550-800m heat
districts, the six zone centres triplicated across `palm6_clout` /
`palm6_protection` / `palm6_turf`, gather-node arrays, race checkpoint geometry
(already served by `/racecp`), the character spawn point, blip tables, and the
vendored third-party map and prop resources.

### KEEPING THE REGISTRY HONEST

This is the cost of the design and it is worth stating plainly.

`ref` is a copy. **When somebody edits a config, this copy goes stale**, and the
marker will sit at the old value while the feature sits at the new one. Nothing
detects that automatically, because these files have no shared schema to read.

Three things keep the damage small:

- The menu and `/anchorlist` always say which source a reading came from
  (`config` or `capture`), so a disagreement is at least attributable.
- A capture makes the anchor **green** on the marker, and the menu row says the
  owning config has not been updated yet.
- The intended workflow ends with a paste. An anchor that has been pasted and
  re-transcribed reads amber again and matches its config.

If a marker and a feature disagree and there is no capture on file, **the config
is right and `shared/registry.lua` needs re-transcribing.**

---

## HOW THE POSITION IS READ

The client can say exactly three things: *show me the list from where I am
standing*, *take me to anchor `<key>`*, and *anchor `<key>` belongs where I am
standing*.

It **cannot say where it is standing**. Every captured position is read on the
server off the player's ped (`Bridge.GetCoords`, authoritative under OneSync),
and every teleport destination comes out of the registry on the server. There is
no net event in this resource that accepts a coordinate, and there must never be
one: a client-sent number pasted into a config file is an invented coordinate
with extra steps.

The position the client *does* send (with the menu request) is used only to sort
rows by distance and to label them "12.4m away". It is never stored and never
appears in a config line.

---

## COST WHEN NOBODY IS USING IT

Markers are **off by default** and admin-gated. With them off, the client thread
sleeps one second at a time and makes no native calls. The server pushes the
point list only to sources that hold the ACE, so a normal player never receives
it.

With markers on: only anchors within `Config.Markers.Radius` (75m) are
considered, the nearest `MaxDrawn` (30) are drawn, and the cull that decides
*which* runs on a 500ms timer rather than every frame. The key text is only
drawn inside `TextDistance` (20m), because thirty floating strings is a wall of
text.

---

## THE TABLE

`palm6_anchor_overrides`, created at boot by `server/main.lua` and by
`sql/0077_anchors.sql` (textually equivalent; keep the two copies identical).

One row per anchor key. A re-capture **replaces** the row: this table answers
"where should this anchor be", not "where has anybody ever stood". The history is
the console line printed on every capture.

Renaming a registry key orphans its row. palm6_anchors reports orphans at boot
and **keeps** them: the captured position took a person walking to the right
spot and cannot be regenerated from anything in the repo.

Losing the table costs the captured corrections and nothing else. Every feature
keeps working from its own config, because that is what it was reading anyway.

---

## PHASE 2: THE OPT-IN EXPORT

Shipped **unused**, on purpose.

```lua
exports.palm6_anchors:GetAnchor(key)  --> { x, y, z, heading }  or  nil
```

`nil` is the honest answer for "not corrected": the caller must fall back to its
own config, which is the value it is using today.

When a resource is ready to opt in, one at a time and testable on its own:

```lua
local pt
if GetResourceState('palm6_anchors') == 'started' then
    local ok, res = pcall(function() return exports.palm6_anchors:GetAnchor('evidence_locker') end)
    if ok then pt = res end
end
local coords = pt and vector3(pt.x, pt.y, pt.z) or Config.LockerCoords
```

Wiring fifteen audited configs to it in one go is how a placement bug becomes a
placement outage. That is why nothing is wired today.

There is also `exports.palm6_anchors:ListAnchors()`, a read-only view of the
registry with each anchor's current reading and where it came from, for a future
tool or test that should not have to re-parse the data file.

---

## FILES

```
palm6_anchors/
  fxmanifest.lua
  shared/config.lua        tunables. Holds NO world coordinate.
  shared/registry.lua      THE REGISTRY. 102 anchors, transcribed.
  bridge/cl_game.lua       every native, marker draw, ox_lib menu, teleport
  bridge/sv_framework.lua  qbx_core, ACE, the server-side ped read
  client/main.lua          the live view and the menu. Pure logic.
  server/main.lua          schema, menu model, capture, the exports
sql/0077_anchors.sql
```
