fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp qbx_police overrides — grades, salaries, armoury, vehicles, MDT'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    'server/overrides.lua',
}

dependencies {
    'ox_lib',
    'qbx_core',
    'qbx_economy_overrides',
}
