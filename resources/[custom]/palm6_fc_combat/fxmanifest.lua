fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 fc_combat — Def Jam fight lifecycle (challenge/select/betting/countdown/live/resolve + DC)'

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'bridge/cl_game.lua',       -- native / ox UI adapter, before client logic
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
    'palm6_fc_core',
    'palm6_fightclub',
}
