fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.4.0'
description 'palm6 mdt — police mobile data terminal (BOLOs, warrants, bookings, case files, reports, 911 log, charge catalogue)'

-- Server-only on purpose: every command reads server state and replies in
-- chat. There is nothing for a client script to do and therefore nothing
-- for a modified client to abuse (palm6_discord precedent).
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'shared/config.lua',
    'shared/sentencing.lua',    -- pure calculator — reads Config, after it
    'bridge/sv_framework.lua',  -- framework adapter — before server logic
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
    'palm6_evidence',
}
