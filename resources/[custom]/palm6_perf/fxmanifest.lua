fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 performance monitor — server thread-hitch sampler + webhook'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_game.lua',   -- game/runtime adapter — must load before logic
    'server/tables.lua',    -- REQUIRED-TABLE authority (server-only data)
    'server/main.lua',
}

-- oxmysql is deliberately NOT a hard dependency. This resource is the always-on
-- hitch sampler, /diag and the "eventguard NOT RUNNING" alarm; a dependencies
-- entry would stop it starting whenever the DB layer fails to start, which is
-- exactly when /diag is most needed. The only DB work here is the schema check
-- and it is fully pcall-guarded, so it degrades to one printed line instead.
dependencies {
    'ox_lib',
    'palm6_staff',
}
