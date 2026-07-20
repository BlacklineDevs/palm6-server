fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.2.0'
description 'palm6 business — player-owned businesses: registry, pooled account, employees, payroll, capped walk-in income, a full ledger, and Phase-1 physical storefronts (ships DARK)'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',       -- game/UI adapter — must load before client logic
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',  -- framework adapter — before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}
