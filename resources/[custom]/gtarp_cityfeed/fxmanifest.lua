fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp cityfeed — game->palm6-bot civic event feed (the third leg of the Palm6 sync)'

shared_scripts {
    'shared/config.lua',        -- Tier-1 tunables — must load before server logic
}

server_scripts {
    'bridge/sv_framework.lua',  -- runtime adapter — before server logic
    'server/main.lua',
}
