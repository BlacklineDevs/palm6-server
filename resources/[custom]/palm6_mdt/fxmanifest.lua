fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.5.0'
description 'palm6 mdt — police mobile data terminal (BOLOs, warrants, bookings, case files, reports, 911 log, charge catalogue)'

-- Server-only historically: every command reads server state and replies in
-- chat. W4 Cylex-parity adds a minimal client tablet NUI scaffold (F5 / /mdt)
-- that does not yet replace chat authority — it opens the shell only.
ui_page 'web/index.html'

files {
    'web/index.html',
}

client_scripts {
    'shared/config.lua',
    'client/nui.lua',
    'client/positions.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'shared/config.lua',
    'shared/sentencing.lua',    -- pure calculator — reads Config, after it
    'bridge/sv_framework.lua',  -- framework adapter — before server logic
    'server/main.lua',
}

-- palm6_heat is NOT listed below on purpose. /calls reads its GetTier export
-- for dispatch priority (Config.CallPriority), but that read is optional and
-- soft-guarded; a hard dependency would stop the entire MDT booting when an
-- optional flag's sibling is missing, which is a far worse outcome than an
-- unflagged 911 board. Same reasoning the house rule gives for soft calls:
-- a manifest dependency asserts the sibling reached 'started', not that it
-- booted cleanly and registered its exports, so it would not even buy safety.
dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
    'palm6_evidence',
}
