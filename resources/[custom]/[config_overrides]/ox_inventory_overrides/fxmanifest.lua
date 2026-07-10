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
    'bridge/sv_framework.lua',
    'server/apply.lua',
}

client_scripts {
    'bridge/cl_game.lua',
    'client/render.lua',
}

dependencies {
    'ox_lib',
    'ox_inventory',
    'qbx_economy_overrides',
}

-- ox_target is optional: when started, the client renderer uses ox_target
-- sphere/box/model zones; otherwise it falls back to a lib.points marker
-- with an E prompt.
