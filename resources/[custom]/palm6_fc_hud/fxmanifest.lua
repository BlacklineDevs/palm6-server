fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'EvThatGuy'
version '0.1.0'
description 'palm6 fc_hud — Def Jam fight HUD: two health bars, stamina, Blazin meter + client-rendered sportsbook odds board. Display-only, zero authority (RFC-001, palm6_clout NUI mirror).'

ui_page 'html/index.html'

files {
    'html/index.html',
}

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game/NUI/statebag/export adapter — before client logic
    'client/main.lua',
}

server_scripts {
    'server/main.lua',      -- read-only career callback only
}

dependencies {
    'ox_lib',
    'palm6_fc_core',        -- shared_scripts Config()/StateKeys(); ensure-order guarantees it loads first
}
