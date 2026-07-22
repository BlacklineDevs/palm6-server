fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'palm6'
description 'palm6_brain — Phase 0 of the AI-NPC living world: curated ambient NPC life (no AI yet). Ships DARK. See docs/AI-NPC-ROADMAP.md.'
version '0.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

dependencies {
    'ox_lib',
}
