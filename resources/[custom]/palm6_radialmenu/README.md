# palm6_radialmenu

Premium in-world interaction/radial menu replacing the default qbx radial. Declarative
Lua menu-tree config (id/title/icon/event/items), nested-submenu breadcrumb state
machine, vanilla JS/CSS with real trigonometry for wedge layout, CSS easing/stagger,
PALM6 brand tokens (`--p6-*`). No build step, no framework, self-contained NUI.

Status: **v0.1.0, client-only.** Job-gating (`Config.MenuTree`'s `job` field) is inert
until v0.2.0 — see "Server-side job-gating" below.

## Node schema

Every entry in a `Config.MenuTree.items` array (and the root itself) follows this shape:

| field | type | required | notes |
|---|---|---|---|
| `id` | string | yes | unique among siblings |
| `title` | string | yes | wedge label + breadcrumb segment |
| `icon` | string | yes | must match a `<symbol id="icon-<icon>">` in `html/index.html`; unknown names fall back to `icon-dot` |
| `items` | table | no | nested submenu — if present, node is a FOLDER and `event` is ignored |
| `event` | string | conditional | Lua event name — required if `items` is absent (LEAF node) |
| `eventType` | `'client'` \| `'server'` | no | default `'client'` |
| `args` | table | no | positional args passed to the event on select |
| `job` | string or table | no | job-gate, checked client-side against the synced job name. **Inert in v0.1.0** — see below |

Invariant, enforced (with a warning per malformed node, not a hard error) at resource
start in `client/main.lua`: exactly one of `items` / `event` must be set on any given
node. Never both, never neither.

## Runtime registration API — for other resources

```lua
exports('palm6_radialmenu'):RegisterRadialItem(parentId, item)
exports('palm6_radialmenu'):RemoveRadialItem(parentId, itemId)
```

Example — a mechanic resource adding a "Diagnostics" option under the `vehicle` folder:

```lua
exports('palm6_radialmenu'):RegisterRadialItem('vehicle', {
    id = 'vehicle_diagnostics',
    title = 'Diagnostics',
    icon = 'wrench',
    event = 'mymechanic:openDiagnostics',
    eventType = 'client',
})
```

**Closure-boundary constraint (important):** item tables cross the export boundary as
data, not live references. A Lua closure (e.g. a `canShow()` condition function) cannot
be passed as a field and used later — it will either error or silently be unusable.
Callers that need conditional visibility must call `RemoveRadialItem` /
`RegisterRadialItem` themselves whenever their condition changes (job change, zone
enter/exit, vehicle state changes, etc). palm6_radialmenu does not accept
function-valued fields in registered items — only the static per-open `job`
string/table gate documented above.

Registrations are spliced into the tree fresh on every menu open (`BuildTree()` in
`client/registry.lua`), so anything registered while the menu was closed is picked up
immediately on the next open — no restart needed.

## Server-side job-gating — deferred to v0.2.0

`bridge/sv_framework.lua` and `server/main.lua` are written but **not loaded** by
`fxmanifest.lua` in v0.1.0 (the `server_scripts` block is commented out). The exact
qbx_core event names they assume — `qbx_core:server:playerLoaded` and
`qbx_core:server:onJobUpdate` — are **MEDIUM/LOW confidence**, compiled from documented
qbx_core conventions, not a direct read of the live resource on this box (qbx_core isn't
vendored in this repo).

Until verified and enabled, every `job`-gated menu node is treated as always-visible
(safe default — worst case is an extra visible menu item, never a broken resource).

To enable v0.2.0:
1. Grep the live `qbx_core` resource files on the actual FiveM box for the literal
   event name strings above. If they differ, update `server/main.lua` to match. If no
   such events exist, poll `exports.qbx_core:GetPlayer(source)` on a coarse timer
   instead.
2. **Verify the SHAPE, not only the name** — which primitive raises each event,
   and whether the payload carries a source at all. Both handlers used to be
   `RegisterNetEvent`, which does not merely subscribe: on a qbx_core
   *server-internal* name it promotes that name to the network for **every**
   listener on the box, letting any client raise it at every handler any
   resource has registered. `palm6_eventguard/config.lua` records that exact
   failure as already found and fixed twice in this repo, and palm6_uniform and
   palm6_insignia listen on this class of name today. They are now
   `AddEventHandler`, and the job handler reads `source` rather than argument 1
   (as written, `TriggerServerEvent('qbx_core:server:onJobUpdate', -1, {name='police'})`
   would have rewritten `currentJob` for every connected player at once). Do
   not revert either while enabling this.
3. Uncomment the `server_scripts` block in `fxmanifest.lua`.

## Before First Ensure — required checklist

`palm6_radialmenu` is intended to **replace** the default qbx radial menu, not run
alongside it. Before the first `ensure palm6_radialmenu` on the live server:

1. Grep the live server's actual `qbx_radialmenu` / `qbx_smallresources` resource files
   (wherever they physically live on the box — not this git repo) for:
   - `RegisterKeyMapping(` — to get the exact live keybind **command name** and default
     key. `client/main.lua` currently binds the command `'radialmenu'` and
     `Config.Keybind = 'pageup'` (`shared/config.lua`) as a starting assumption — **if
     the live grep shows a different command name, rename both the
     `RegisterCommand`/`RegisterKeyMapping` string in `client/main.lua` to match.** Do
     not leave it bound to a private name like `'palm6_radialmenu:open'` — that breaks
     the "any third-party script calling `ExecuteCommand('radialmenu')` still reaches
     this menu" guarantee.
   - `exports.qbx_radialmenu:AddOption(` and `registerRadial(` (ox_lib pattern), across
     the **entire** `resources/` tree — any hits are third-party call sites that inject
     items into the default radial today. Those call sites must keep working after
     cutover: either `RegisterRadialItem` (see above) satisfies an equivalent call
     shape, or those specific resources get migrated to call the new export.

2. **Do not fork or edit `qbx_radialmenu`.** Lock it out the same way `palm6_threads`
   is locked, not by deleting it — `custom.cfg` now carries this line (added
   2026-08-06; it was documented as required here but had never actually been
   written into the only cfg in the repo):
   ```
   stop qbx_radialmenu
   ```
   so only one radial owns the keybind. Without it, FiveM's command manager
   invokes **every** handler registered under the name `radialmenu`, so PageUp
   opens both menus, two owners call `SetNuiFocus(true, true)`, and only
   palm6's `CloseRadial()` ever releases it. `RegisterKeyMapping` also refuses
   to re-default an already-bound name, so `Config.Keybind` gets silently
   overridden on top of that. If the stop line is ever lost, the resource
   prints a `WARN: qbx_radialmenu is STARTED` line at boot — check the console
   on first ensure.

   **palm6_radialmenu replacing the default radial is DELIBERATE. Do not
   `ensure qbx_radialmenu` to "fix" a missing menu — check the `stop` line first.**

3. Re-run `node tools/audit/run.js` before and after — must stay at whatever baseline
   pass rate it was at before this resource was added (8/8, or the documented 7/8
   baseline). Do not flag a pre-existing failure as caused by this resource.

4. First ensure: quiet server only, David + one other person present — same
   first-ensure discipline as any new resource in this repo. This resource is lower
   risk than clothing/appearance work (see "Safety notes" below) but still gets the
   same discipline.

## Safety notes

palm6_radialmenu ships **zero** `stream/` assets, calls **zero** ped-component/
streaming natives. Its only game-state reads are `PlayerPedId`, `IsPedRagdoll`,
`IsPedCuffed`, `IsPedInParachuteFreeFall` (all confined to `bridge/cl_game.lua`) — none
of the clothing-resource danger class documented in `docs/CUSTOM-CLOTHING.md` applies
here.

This menu is a 2D HUD overlay synced to cursor position, **not** a 3D scene synced to
the game camera — there are no camera native calls anywhere in this resource, including
`bridge/cl_game.lua`, and none should be added. If a future feature needs
camera-synced behavior, that belongs to a different, dedicated resource.

**NUI callback event allowlist.** `RegisterNUICallback('select', ...)` is a plain HTTP
endpoint (`https://palm6_radialmenu/select`) — a modified client can POST to it directly,
bypassing the real menu entirely, with any `event`/`eventType`/`args` it wants. To stop
that becoming "trigger any registered event in any resource by name," `OpenRadial()`
walks the tree it just built (`client/registry.lua`'s `BuildTree()`, after job-gating and
runtime-registered items are spliced in) into a per-open `AllowedEvents` map
(`client/main.lua`), keyed by event name, storing the node's REAL `eventType`/`args`.

**Adversarial review (2026-08-05) found the original version only validated the event
NAME**, not `eventType` or `args` — a forged POST could pair a legitimate event with
`eventType:'server'` on a client-only node (crossing a boundary the tree never declared)
or with attacker-chosen `args`, and `select`/`close` never checked `isOpen` or cleared
`AllowedEvents`, so a forged POST worked even when no menu had ever been opened. Fixed:
`data.event` from the client is now used ONLY as a lookup key into `AllowedEvents` — the
actual `eventType`/`args` dispatched always come from OUR stored tree, never from the
client payload; `select`/`close` both route through `CloseRadial()`, which now also
checks `isOpen` first and clears `AllowedEvents` on every close, not just on the next
open.

## File layout

```
palm6_radialmenu/
├── fxmanifest.lua
├── README.md
├── bridge/
│   ├── cl_game.lua          -- ONLY file calling GTA natives / ox_lib UI exports
│   └── sv_framework.lua     -- v0.2.0, deferred, NOT loaded by fxmanifest.lua yet
├── client/
│   ├── registry.lua         -- runtime item registration (exports), tree merge + job filter
│   └── main.lua              -- keybind, NUI lifecycle, RegisterNUICallback, open/close state
├── server/
│   └── main.lua              -- v0.2.0, deferred, NOT loaded by fxmanifest.lua yet
├── shared/
│   └── config.lua            -- declarative menu-tree table, Config.Keybind
└── html/
    ├── index.html
    ├── style.css
    └── script.js
```

## NUI message contract

| Direction | Channel | Payload |
|---|---|---|
| Lua -> JS | `SendNUIMessage({ action: 'open', ... })` | `{ tree, accent }` |
| Lua -> JS | `SendNUIMessage({ action: 'close' })` | `{}` — forced close (e.g. player cuffed mid-menu) |
| JS -> Lua | `fetch https://${RESOURCE_NAME}/select` | `{ key, id, event }` — see below |
| JS -> Lua | `fetch https://${RESOURCE_NAME}/close` | `{}` |
| Lua callbacks | `RegisterNUICallback('select', ...)`, `RegisterNUICallback('close', ...)` | must `cb('ok')` or CEF's fetch hangs |

`key` is the leaf's **path in the tree** (`root/1:vehicle/2:vehicle_hood`),
stamped onto every leaf as `nodeKey` by `collectEvents` when the tree is built,
and it is the only field the select callback dispatches from. `event` rides
along purely as a cross-check Lua verifies against its own stored node;
`eventType` and `args` are deliberately **not sent at all** — Lua reads them off
its own tree so a forged POST cannot choose them.

> **Why a path and not `id`, and not the event name.** `id` is only unique among
> *siblings* (see the node schema above). The event name is not unique at all:
> the qb idiom is one event with different `args` per item, which is exactly
> what this menu's `args` field is for — three leaves on `palm6_shop:buy` with
> `{'bandage'}` / `{'water'}` / `{'medkit'}` collapsed into one allowlist entry
> when the map was keyed by name, and the survivor's args went out under all
> three labels. Clicking Bandage bought a medkit, with no diagnostic, because
> the event name genuinely *was* in the allowlist.

Preview the NUI standalone in a regular browser (icons/layout only, no game context) by
opening `html/index.html?preview=1`. **Its `SAMPLE_TREE` must carry `nodeKey` on
every leaf**, because the real tree does — a stub that omits it previews a menu
whose every click posts `key: undefined` while looking entirely correct. There
is a test asserting the stub and the contract agree.

## Sizing: two numbers live in two places

`--radial-inner: 92px` in `html/style.css` and `const INNER_R = 92` in
`html/script.js` are the same number in SVG **user units**, and they must be
changed together. The hub (`.radial-hub`) is an HTML `<div>` — not part of the
SVG, so it does **not** scale with the viewBox — and is therefore sized as an
explicit ratio of `--radial-size`. It was previously a fixed `176px`, which only
matched the scaled dead zone when the viewport's minor dimension was at least
1048px; below that the hub overhung the wedges and drew its border across every
one of them (27.5px of overhang at 1280x720).

Wedge labels DO live inside the SVG and so shrink with it. `--radial-size` has a
340px floor and `--radial-label-size` is 13.5 user units for that reason; at the
original `min(42vmin, 460px)` and 10.5 units they rendered at 6.9 real px on a
720p client.
