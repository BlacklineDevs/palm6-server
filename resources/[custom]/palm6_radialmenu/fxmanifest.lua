fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_radialmenu — trigonometric wedge-layout interaction menu replacing the default qbx radial.'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game/ox_lib adapter — must load before client logic
    'client/registry.lua',
    'client/main.lua',
}

-- v0.2.0, once qbx_core event names below are verified live — uncomment and add:
-- server_scripts {
--     'bridge/sv_framework.lua',
--     'server/main.lua',
-- }

dependencies { 'ox_lib', 'qbx_core' }

ui_page 'html/index.html'
files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}
