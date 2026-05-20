fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp ox_inventory overrides — shops catalog, items, price ladder'

shared_scripts {
    '@ox_lib/init.lua',
    'data/items.lua',
    'data/shops.lua',
}

server_scripts {
    'server/apply.lua',
}

dependencies {
    'ox_lib',
    'ox_inventory',
    'qbx_economy_overrides',
}
