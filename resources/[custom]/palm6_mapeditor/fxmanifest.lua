fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_mapeditor — in-game map/prop editor: spawn, gizmo move/rotate, snap, export to Lua/JSON/ymap. Admin dev tool.'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'data/prop_groups.lua', -- 5,295-prop catalog (Config.PropGroups)
}

client_scripts {
    'bridge/cl_game.lua',   -- all GTA natives isolated here
    'client/main.lua',      -- editor core
    'client/browser.lua',   -- prop catalog + fuzzy search
    'client/tools.lua',     -- world eraser / mass spawn / per-prop toggles
    'client/lights.lua',    -- light editor (point/spot, per-frame draw)
}

server_scripts {
    'server/main.lua',      -- export file writer (ACE-gated)
}

dependencies {
    'ox_lib',
}
