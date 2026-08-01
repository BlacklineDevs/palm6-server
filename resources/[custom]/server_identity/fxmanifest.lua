fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.2.0'
description 'palm6 server_identity - loading screen, spawn handler, Discord rich presence'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game adapter - must load before client logic
    'client/main.lua',
}

loadscreen 'html/loading.html'
loadscreen_manual_shutdown 'no'
loadscreen_cursor 'yes'

files {
    'html/**',
}

dependencies {
    'ox_lib',
}
