fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_racing — Palm6 street racing (Phase 0: rep-only sprint races, ships dark)'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- native / ox UI adapter, before client logic
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',  -- framework adapter, before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
    'ox_target',
}
