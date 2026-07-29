-- ============================================================================
-- palm6_mapeditor/shared/config.lua
--
-- In-game map/prop editor (like the paid "Advanced Map & Prop Editor"): spawn
-- props, move/rotate them with a live gizmo, snap to surfaces, then export to
-- Lua / JSON / CodeWalker ymap. Admin dev tool, ACE-gated.
-- ============================================================================

Config = {}

Config.Command = 'mapedit'          -- /mapedit toggles the editor
Config.Ace = 'command.mapedit'      -- ACE the command is gated on (server checks)

-- Live map (MySQL persistence + networked sync). A committed map streams to
-- every player and survives a restart. Limits bound how much one /mapcommit
-- (and one map) can push into the DB and every client's object pool.
Config.LiveDefaultMap = 'default'   -- map name used when /mapcommit gets no arg
Config.LiveMaxCommit  = 1000        -- max props published in a single /mapcommit
Config.LiveMaxProps   = 6000        -- max total props a single live map may hold
Config.LiveMaxHides   = 2000        -- max total persisted world-erases (all maps)
Config.LiveMaxLights  = 256         -- max total persisted live lights (all maps)
Config.LiveLightDist  = 120.0       -- only draw a live light within this many m of you
-- Snapshots/revisions: keep only the newest N per map. Every /maprestore also
-- writes a "before restore" snapshot, so without a bound the LONGTEXT blobs grow
-- forever. Set to 0 to disable pruning entirely (unbounded, the old behaviour).
Config.RevisionsPerMap = 20

-- Prefabs: named, reusable groups of props (a furnished room, a checkpoint…)
-- saved relative to their centre so they can be stamped anywhere at any angle.
Config.PrefabMaxProps = 500         -- max props in a single prefab
Config.PrefabMaxCount = 200         -- max saved prefabs

-- Scene entities (peds / vehicles) — placed live, persisted, synced to all.
Config.EntityMax      = 1500        -- max total persisted scene entities

-- Leave a scene ped with an ambient scenario UNFROZEN (bridge/cl_game.lua).
-- Scene peds have always been frozen, which pins them to their placed coords but
-- also blocks the small reposition the sit/lie scenarios (SEAT_LEDGE, SUNBATHE)
-- ask for. Ships OFF because unfreezing changes what every player sees: the ped
-- becomes subject to gravity and to player/vehicle collision, so it can be shoved
-- off its post or fall through a custom floor that has not streamed in, while the
-- outliner, /matentdel and the map export keep using its authored DB coords.
-- Flip it on only after looking at a map of scenario peds in-game.
Config.ScenePedScenarioUnfreeze = false

-- Live-prop distance ring (client/live.lua). With this OFF the client spawns
-- EVERY live prop of EVERY map, so a map at the LiveMaxProps cap is 6000
-- permanent client objects for every player, not just admins. Turning it on
-- spawns only what is near you and despawns the rest.
--
-- Ships OFF because it changes what every player sees (props appear/disappear
-- around you) and pop-in is only judgeable in-game. Flip it on after walking a
-- large map. It culls PROPS ONLY: scene peds/vehicles are untouched, and the
-- outliner, the Performance panel and the map export still see the whole map.
Config.LiveCull        = false
Config.EntityDrawDist  = 300.0      -- ring radius (m): a prop this close is spawned
Config.LiveCullPad     = 60.0       -- extra m before a spawned prop is culled again
                                    -- (hysteresis, stops flicker on the boundary)
Config.LiveCullTickMs  = 750        -- how often the ring is re-evaluated
Config.LiveCullPerTick = 25         -- max props spawned per tick, so a teleport
                                    -- across the map cannot hitch the frame

-- Nudge steps (fine value used while Shift is held).
Config.Step = {
    move = 0.05, moveFine = 0.01,
    rot = 1.5,  rotFine = 0.25,
}

-- Starter prop catalog (categorised). The full GTA prop DB loads from
-- data/props.json (DurtyFree dump) into the NUI browser; this is the quick
-- keyboard-cycle set so the editor is usable before the browser opens.
Config.QuickProps = {
    ['Street'] = {
        'prop_barrier_work05', 'prop_barrier_work06a', 'prop_mp_barrier_02b',
        'prop_roadcone02a', 'prop_worklight_03b', 'prop_barrier_work06b',
    },
    ['Interior'] = {
        'prop_off_chair_05', 'prop_off_desk_01', 'prop_table_03', 'v_res_tre_couch',
        'prop_ff_shelf_01', 'p_cs_office_chair', 'prop_filedrawer_01',
    },
    ['Lights'] = {
        'prop_wall_light_09a', 'prop_wall_light_10a', 'prop_streetlight_01',
    },
    ['Containers'] = {
        'prop_container_01a', 'prop_boxpile_07d', 'prop_barrel_02a', 'prop_dumpster_02a',
    },
}
