fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_pd_life — living PBPD station. Client-local ambient scene NPCs (front-desk clerk, citizens on benches / in line, officer meetings, patrol) via GTA scenarios. brain-interactable. Includes /pdnpc live placement tool.'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game natives isolated here (bridge pattern)
    'client/main.lua',
    'client/duty.lua',      -- interactive posts / sit / duty (Phase B)
    'client/placer.lua',    -- /placeped in-game NPC placement tool
}

server_scripts {
    'bridge/sv_framework.lua',   -- qbx_core adapter (duty predicate + setter)
    'server/duty.lua',           -- authoritative post + duty registry
}

dependencies {
    'ox_lib',
}
