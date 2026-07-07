fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp mdt — police mobile data terminal (BOLOs, case files, reports)'

-- Server-only on purpose: every command reads server state and replies in
-- chat. There is nothing for a client script to do and therefore nothing
-- for a modified client to abuse (gtarp_discord precedent).
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'shared/config.lua',
    'bridge/sv_framework.lua',  -- framework adapter — before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
    'gtarp_evidence',
}
