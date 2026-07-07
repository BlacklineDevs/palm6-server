fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp legal — rap sheets + expungement petitions (the lawyer job, employed at last)'

-- Server-only on purpose: records are server reads, petitions are ledger
-- rows, and the courthouse check is a server-side position read.
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
    'gtarp_mdt',
}
