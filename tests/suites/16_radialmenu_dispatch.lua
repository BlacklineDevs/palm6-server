-- ============================================================================
-- 16_radialmenu_dispatch.lua — palm6_radialmenu's dispatch, lifecycle and ring
--
-- The resource shipped with an allowlist that correctly rejected an event name
-- it had never shown the client. Everything pinned here is a defect on the
-- other side of that gate: the allowlist was right about forgery and wrong
-- about identity.
--
-- 1. THE ALLOWLIST WAS KEYED BY EVENT NAME. The qb idiom is one event with
--    different positional args per item — which shared/config.lua documents
--    `args` for — so three leaves on `palm6_shop:buy` collapsed into one map
--    entry and the last one won. Clicking Bandage bought a medkit. Silently:
--    the "forged NUI callback?" diagnostic cannot fire when the name is real.
--
-- 2. THE OUTGOING LEVEL STAYED CLICKABLE for the whole 180ms transition, so a
--    second click on the same pixel corrupted the breadcrumb, killed the next
--    Back press, or fired a leaf event for a level that was already closing.
--
-- 3. NOTHING CLOSED THE MENU ONCE OPEN. CanOpenRadial() was consulted at open
--    and never again, and the forceClose event has no senders anywhere.
--
-- 4. THE HUB WAS SIZED IN PX WHILE THE RING SCALES WITH VMIN, so below a
--    1048px minor viewport dimension the hub overhung the wedges and drew its
--    border across every one of them.
-- ============================================================================

T.begin('palm6_radialmenu — dispatch identity, transition safety, lifecycle')

local R_MAIN     = 'resources/[custom]/palm6_radialmenu/client/main.lua'
local R_REGISTRY = 'resources/[custom]/palm6_radialmenu/client/registry.lua'
local R_SERVER   = 'resources/[custom]/palm6_radialmenu/server/main.lua'
local R_BRIDGE   = 'resources/[custom]/palm6_radialmenu/bridge/cl_game.lua'
local R_JS       = 'resources/[custom]/palm6_radialmenu/html/script.js'
local R_CSS      = 'resources/[custom]/palm6_radialmenu/html/style.css'

--- Full-line comments stripped before asserting. Same helper, same reason, as
--- suites 14 and 15: the comments in these files quote the exact expressions
--- under test, so a notcontains over the raw text matches the documentation of
--- a bug instead of the bug. The comment token is a parameter because passing
--- the wrong one silently strips nothing.
local function codeOnly(source, commentPrefix)
    local pattern = '^%s*' .. commentPrefix:gsub('%p', '%%%0')
    local out = {}
    for line in (source .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match(pattern) then out[#out + 1] = line end
    end
    return table.concat(out, '\n')
end

local mainLua     = T.source(R_MAIN)
local mainCode    = codeOnly(mainLua, '--')
local registryLua = codeOnly(T.source(R_REGISTRY), '--')
local serverLua   = codeOnly(T.source(R_SERVER), '--')
local bridgeLua   = codeOnly(T.source(R_BRIDGE), '--')
local js          = T.source(R_JS)
local jsCode      = codeOnly(js, '//')
local css         = T.source(R_CSS)

-- ---------------------------------------------------------------------------
T.section('dispatch identity — a leaf is its PATH, not its event name')
-- ---------------------------------------------------------------------------

T.contains('the allowlist is keyed by the node path built on the way down',
    mainCode, 'map[path] = { event = node.event, eventType = node.eventType, args = node.args }')
T.contains('...and that path is stamped onto the node so it reaches the NUI',
    mainCode, 'node.nodeKey = path')
T.contains('...built from the child INDEX as well as its id, so siblings sharing an id still differ',
    mainCode, "('%s/%d:%s'):format(path, i, childId)")

-- The regression this replaces: keying the map on the event name. Two leaves
-- differing only in `args` were one entry, and the survivor's args went out
-- under both labels.
T.notcontains('the event name is no longer the map key',
    mainCode, 'map[node.event] = ')

local selectBody = T.slice(R_MAIN,
    "RegisterNUICallback('select', function(data, cb)",
    "RegisterNUICallback('close', function(_, cb)")
T.contains('the lookup uses the echoed key', selectBody, 'local node = key and AllowedEvents[key] or nil')
T.contains('the event NAME dispatched is our stored one, not the payload (client branch)',
    selectBody, 'TriggerEvent(node.event, table.unpack(node.args or {}))')
T.contains('...and the server branch too',
    selectBody, 'TriggerServerEvent(node.event, table.unpack(node.args or {}))')
T.notcontains('the payload event name is never dispatched directly',
    codeOnly(selectBody, '--'), 'TriggerEvent(data.event')
T.notcontains('...on either branch',
    codeOnly(selectBody, '--'), 'TriggerServerEvent(data.event')
T.contains('a payload whose event disagrees with the tree is refused, not run',
    selectBody, 'if data.event ~= nil and data.event ~= node.event then')

-- eventType/args are the two fields an earlier review already established must
-- never come off the wire. The NUI no longer even sends them.
T.contains('the NUI sends the key', jsCode, 'key: item.nodeKey,')

-- THE PREVIEW STUB MUST AGREE WITH THE CONTRACT, NOT WITH THE CODE.
-- A stub missing nodeKey previews a menu whose every click posts
-- `key: undefined` while looking entirely correct - the same shape as the
-- charselect stub that kept three non-existent qbx_core fields alive through a
-- build and two adversarial reviews.
local sampleTree = T.slice(R_JS, '  const SAMPLE_TREE = {', '  if (new URLSearchParams(location.search)')
local _, keyedLeaves = sampleTree:gsub('nodeKey: "', '')
local _, stubLeaves = sampleTree:gsub('event: "', '')
T.eq('every leaf in the preview stub carries a nodeKey', keyedLeaves, stubLeaves)
T.contains('...and they are the paths collectEvents would build',
    sampleTree, 'nodeKey: "root/1:vehicle/1:vehicle_lock"')
T.notcontains('...and does not send eventType any more', jsCode, 'eventType: item.eventType')
T.notcontains('...nor args', jsCode, 'args: item.args')

-- ---------------------------------------------------------------------------
T.section('the closing level cannot be clicked')
-- ---------------------------------------------------------------------------

-- CSS half: p6-wedge-out animates opacity, not visibility, and ends at
-- scale(0.85) — the wedge is under the cursor for the whole transition.
local leavingRule = css:match('%.radial%-wedge%.is%-leaving%s*{(.-)}')
T.istrue('the is-leaving rule exists', leavingRule ~= nil)
T.contains('...and it stops taking clicks', leavingRule or '', 'pointer-events: none;')

-- JS half, which also closes the keyboard route (Enter over currentWedges).
T.contains('activateWedge refuses during a transition', jsCode, 'function activateWedge(wedge) {\n    if (isTransitioning) return;')
T.contains('onSelect refuses too', jsCode, 'function onSelect(item) {\n    if (isTransitioning) return;')
T.contains('onBack refuses too', jsCode, 'function onBack() {\n    if (isTransitioning) return;')

-- The corrupted breadcrumb came from pushing to `stack` and THEN calling a
-- transition that bailed, leaving the push behind: the level became its own
-- ancestor and Back needed two presses.
T.contains('transitionToLevel reports whether it accepted', jsCode, 'if (isTransitioning) return false;')
T.contains('a refused descend un-pushes the stack', jsCode, 'if (!transitionToLevel(item)) stack.pop();')
T.contains('a refused Back re-pushes what it popped', jsCode, 'if (!transitionToLevel(stack[stack.length - 1])) stack.push(popped);')

-- ---------------------------------------------------------------------------
T.section('the menu closes itself when the player stops being allowed it')
-- ---------------------------------------------------------------------------
--
-- Dying with the menu up left the wedges over the death screen holding NUI
-- focus, so hold-E respawn and the ambulance controls got nothing.

T.contains('a watchdog re-checks state while open',
    mainCode, 'if isOpen and (not Game.CanOpenRadial() or Game.IsPlayerDead()) then')
T.contains('...and closes on it', mainCode, 'CloseRadial()')
T.contains('...on a config interval, not a per-frame thread',
    mainCode, 'Wait(isOpen and Config.StateWatchdogIntervalMs or 500)')
T.contains('the interval is configured',
    T.source('resources/[custom]/palm6_radialmenu/shared/config.lua'), 'Config.StateWatchdogIntervalMs')
T.contains('death is a bridge predicate, not a native called from client code',
    bridgeLua, 'function Game.IsPlayerDead()')
T.notcontains('client/main.lua still calls no natives directly',
    mainCode, 'IsEntityDead(')

-- ---------------------------------------------------------------------------
T.section('qbx_radialmenu must be stopped, not merely expected to be absent')
-- ---------------------------------------------------------------------------
--
-- Both resources bind the command AND the keymapping `radialmenu`, and FiveM
-- invokes every handler registered under a name.

local cfg = T.source('custom.cfg')
T.contains('custom.cfg stops it', cfg, 'stop qbx_radialmenu')

local stopAt   = cfg:find('stop qbx_radialmenu', 1, true)
local ensureAt = cfg:find('ensure palm6_radialmenu', 1, true)
T.istrue('...BEFORE ensuring ours', stopAt ~= nil and ensureAt ~= nil and stopAt < ensureAt)

T.contains('and the resource says so out loud if it is still running',
    mainCode, 'if Game.QbxRadialIsRunning() then')
T.contains('...via the bridge, not a bare native', bridgeLua, "GetResourceState('qbx_radialmenu')")

-- ---------------------------------------------------------------------------
T.section('the registry replaces by id and cleans up after a stopped owner')
-- ---------------------------------------------------------------------------
--
-- A plain table.insert meant `restart palm6_police` duplicated every wedge it
-- registers and shrank angleStep for the whole level.

T.contains('re-registering the same id replaces it', registryLua, 'if list[i].id == item.id then')
T.notcontains('...instead of appending blindly',
    registryLua, 'table.insert(Registry.extra[parentId], item)')
T.contains('the registering resource is recorded', registryLua, 'local owner = GetInvokingResource()')
T.contains('...outside the item, so it never ships to the NUI',
    registryLua, 'Registry.owner[parentId][item.id] = owner')
T.contains('a stopped resource loses its entries', registryLua, "AddEventHandler('onResourceStop', function(resource)")
T.contains('...and this resource stopping is not that case',
    registryLua, 'if resource == GetCurrentResourceName() then return end')

-- ---------------------------------------------------------------------------
T.section('the deferred server file, before anyone uncomments it')
-- ---------------------------------------------------------------------------
--
-- RegisterNetEvent on a qbx_core SERVER-INTERNAL name does not just subscribe:
-- it promotes that name to the network for every listener on the box.
-- palm6_uniform and palm6_insignia are listening on this class of name today.

T.notcontains('neither qbx_core-internal name is net-registered',
    serverLua, "RegisterNetEvent('qbx_core:server:")
T.contains('playerLoaded is a plain AddEventHandler',
    serverLua, "AddEventHandler('qbx_core:server:playerLoaded'")
T.contains('onJobUpdate too', serverLua, "AddEventHandler('qbx_core:server:onJobUpdate'")

-- The second handler read the server id off ARGUMENT 1. Once the name is
-- net-registered, TriggerServerEvent(..., -1, {name='police'}) rewrote
-- currentJob for every connected player at once.
T.notcontains('the source is not read from the argument list',
    serverLua, 'function(src, job)')
T.contains('...it comes from `source`', serverLua, 'local src = source')

-- ---------------------------------------------------------------------------
T.section('the hub scales with the ring it sits inside')
-- ---------------------------------------------------------------------------
--
-- --radial-inner is a viewBox coordinate (JS mirrors it as INNER_R = 92) that
-- the SVG scales; the hub is an HTML div that was sized in real px at
-- 92*2-8 = 176px. They agreed only at a >=1048px minor viewport dimension.
-- 27.5px of overhang at 1280x720, 2.7px of clearance at 1920x1080.

T.contains('the hub is a fraction of the ring', css, 'width: calc(var(--radial-size) * 176 / var(--radial-view));')
T.contains('...in both axes', css, 'height: calc(var(--radial-size) * 176 / var(--radial-view));')
T.notcontains('the fixed-px hub is gone', css, 'width: calc(var(--radial-inner) * 2 - 8px);')
T.contains('the viewBox extent is declared once, where the ratio can read it',
    css, '--radial-view: 460;')
T.contains('the hub padding scales too', css, 'padding: calc(var(--radial-size) * 12 / var(--radial-view));')

-- JS and CSS both hold the inner radius; they must not drift apart.
T.contains('JS still mirrors --radial-inner', js, 'const INNER_R = 92;')
T.contains('...and CSS still declares it', css, '--radial-inner: 92px;')

-- SVG text scales with the viewBox, so the ring having a floor is what keeps
-- the labels readable: at 42vmin the ring was 302px on a 720p client, a 0.657
-- scale rendering a 10.5-unit label at 6.9 real px.
T.contains('the ring has a size floor', css, '--radial-size: clamp(340px, 42vmin, 460px);')
T.contains('the label size is a variable, not a literal', css, 'font-size: var(--radial-label-size);')
T.notcontains('...and not the old 10.5px', css, 'font-size: 10.5px;')

T.done()
