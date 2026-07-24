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
