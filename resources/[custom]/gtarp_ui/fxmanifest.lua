fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
description 'gtarp shared UI renderer - civic/economy command output as a branded Palm6 NUI panel (single lines fall back to an ox_lib toast)'
version '2.0.0'

-- ox_lib provides the single-line toast (lib.notify). The multi-line panel is a
-- self-contained NUI page under web/ (no external assets). The nine server-only
-- civic resources send their output here as ONE payload via TriggerClientEvent.
dependency 'ox_lib'

ui_page 'web/index.html'

client_scripts {
    '@ox_lib/init.lua',
    'client/main.lua',
}

files {
    'web/index.html',
    'web/style.css',
    'web/script.js',
}
