fx_version 'cerulean'
game 'gta5'

name 'gtarp_dbmigrate'
description 'ONE-SHOT: applies pending idempotent SQL migrations (0040 + 0042-0047) via the server DB connection, because the prod DB is not reachable externally and CI never touches the DB. All statements are IF NOT EXISTS, so it is a no-op after the first successful run. REMOVE this resource once the tables are confirmed.'
version '0.0.1'
lua54 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
}
