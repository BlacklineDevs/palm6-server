fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'gtarp fightclub — underground bare-knuckle ring with parimutuel spectator betting'

-- Server-only on purpose: every command reads server state and replies in
-- chat/notify, and both fighters' health/position/weapon are server-derived
-- off the live synced peds (gtarp_bounty precedent). There is nothing for a
-- client script to do and therefore nothing for a modified client to abuse
-- (gtarp_citations/gtarp_mdt/gtarp_bounty precedent) — no shared_scripts
-- block, so nothing here ships to clients.
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
}
