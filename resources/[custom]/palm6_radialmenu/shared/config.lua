Config = {}

-- VERIFY: confirm against qbx_radialmenu's live RegisterKeyMapping before locking this in
-- (see README.md "Before First Ensure" checklist / design spec §8). 'pageup' is the
-- qb-ecosystem convention default and is used here as the starting assumption only.
Config.Keybind = 'pageup'

-- How often, in ms, the open menu re-checks that the player is still allowed to
-- have it open (client/main.lua's watchdog: ragdolled / cuffed / parachuting /
-- dead). Only ticks at this rate WHILE open; idle is a slow 500ms poll.
-- 250ms is under a quarter second of a menu that should not be there, and is
-- three orders of magnitude cheaper than the per-frame thread this replaces
-- the absence of.
Config.StateWatchdogIntervalMs = 250

--[[
    Node schema (every entry in an `items` array, including the root, follows this shape):

        id        string   required, unique among siblings
        title     string   required, shown as wedge label + breadcrumb segment
        icon      string   required, must match a <symbol id="icon-<icon>"> defined in
                            html/index.html
        items     table?   nested submenu — if present, node is a FOLDER, `event` is ignored
        event     string?  Lua event name — if `items` is absent, node is a LEAF, `event`
                            is required
        eventType string?  'client' | 'server', default 'client'
        args      table?   positional args passed to the event on select
        job       string|table?  optional job-gate, checked client-side against the synced
                            job name. v0.1.0 ships without server/main.lua (see §7 / README),
                            so this field is currently INERT — every job-gated node stays
                            visible until the qbx_core event names are verified and v0.2.0
                            wires syncJob.

    INVARIANT enforced at resource start (client/main.lua validates and warns per malformed
    node): exactly one of `items` / `event` must be set on any given node. Never both,
    never neither.
]]

Config.MenuTree = {
    id = 'root',
    title = 'Interactions',
    icon = 'grid',
    items = {
        {
            id = 'vehicle', title = 'Vehicle', icon = 'car',
            items = {
                { id = 'vehicle_lock', title = 'Lock/Unlock', icon = 'lock', event = 'palm6_radialmenu:vehicleLock', eventType = 'client' },
                { id = 'vehicle_hood', title = 'Hood', icon = 'wrench', event = 'palm6_radialmenu:vehicleHood', eventType = 'client' },
            },
        },
        {
            id = 'player', title = 'Player', icon = 'user',
            items = {
                { id = 'player_emotes', title = 'Emotes', icon = 'emote', event = 'palm6_radialmenu:openEmoteMenu', eventType = 'client' },
                { id = 'player_id', title = 'Show ID', icon = 'badge', event = 'palm6_radialmenu:showId', eventType = 'client' },
            },
        },
    },
}

-- This shipped tree is deliberately minimal/example-only — vehicle seatbelt/engine/etc.
-- belong to whichever resource already owns that feature; palm6_radialmenu just needs to
-- prove the tree shape and dispatch path. Other resources should register additional items
-- at runtime via exports('palm6_radialmenu').RegisterRadialItem(parentId, item) — see
-- client/registry.lua and README.md.
