fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_charselect - premium character selection / spawn screen, replaces qbx_core multichar UI.'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game adapter - must load before client logic
    'client/main.lua',
}

server_scripts {
    -- Owns two of its own tables (palm6_charselect_hidden for the soft-delete,
    -- palm6_charselect_playtime for playtime qbx_core does not track), plus
    -- Bridge.OwnsCharacter's READ-ONLY check against qbx_core's players table.
    -- This resource never writes to `players`.
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',       -- framework adapter - before server logic
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}
