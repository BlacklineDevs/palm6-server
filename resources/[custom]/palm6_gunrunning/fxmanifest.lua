fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 gunrunning'


-- Config is shared so the presentation-only client (dealer NPC + catalog menu)
-- can read Config.Catalog/DropPoint/Dealer directly. All money/sale logic stays
-- server-side; the client only fires palm6_gunrunning:dealer:buy with an index.
shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',       -- native / ox UI adapter, before client logic
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
    'ox_inventory',
}
