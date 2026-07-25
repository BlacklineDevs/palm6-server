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
    'client/live.lua',      -- live map streaming (persisted props, all players)
    'client/nui.lua',       -- thumbnail prop-browser NUI controller (/propui)
    'client/thumbs.lua',    -- NUI thumbnail proxy (CDN -> data URI, CSP bypass)
    'client/prefabs.lua',   -- prefab save/stamp (reusable prop groups)
    'client/entities.lua',  -- scene peds/vehicles (persisted, synced)
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',   -- must load before server/live.lua
    'server/main.lua',      -- export file writer (ACE-gated)
    'server/live.lua',      -- MySQL persistence + authoritative live sync
    'server/prefabs.lua',   -- prefab storage (own table, ACE-gated)
    'server/entities.lua',  -- scene ped/vehicle storage (own table, ACE-gated)
    'server/thumbs.lua',    -- NUI thumbnail proxy (fetch CDN -> base64 data URI)
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'ox_lib',
    'oxmysql',
}
