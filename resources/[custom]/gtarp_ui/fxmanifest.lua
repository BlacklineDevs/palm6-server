fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
description 'gtarp shared UI renderer - civic/economy command output as ox_lib panels instead of chat spam'
version '1.0.0'

-- ox_lib owns the NUI focus + ESC-to-close for context menus and notifies, so
-- this resource adds no custom NUI / focus-trap surface. The nine server-only
-- civic resources send their output here as ONE payload via TriggerClientEvent
-- instead of dumping lines into chat.
dependency 'ox_lib'

client_scripts {
    '@ox_lib/init.lua',
    'client/main.lua',
}
