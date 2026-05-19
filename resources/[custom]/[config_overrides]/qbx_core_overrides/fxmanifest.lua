fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp config override layer for qbx_core (multichar, identifiers, starting funds)'

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
}
