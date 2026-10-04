fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_appearance — bone-indexed orbit-camera character creation and re-edit screen. Capture-and-reapply wardrobe only; ships zero streamed assets.'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game adapter — must load before client logic
    'client/camera.lua',
    'client/headblend.lua',
    'client/wardrobe.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',         -- resource owns its own appearance table, see server/migrations.sql
    'bridge/sv_framework.lua',        -- framework adapter — before server logic
    'server/main.lua',
}

dependencies { 'ox_lib', 'oxmysql', 'qbx_core' }

ui_page 'html/index.html'
files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}
