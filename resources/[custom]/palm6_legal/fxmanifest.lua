fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.2.0'
description 'palm6 legal — rap sheets, expungement petitions, sentencing review (the lawyer job, employed at last)'

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
    'palm6_mdt',
}
