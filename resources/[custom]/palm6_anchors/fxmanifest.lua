fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_anchors - admin inspector for every world anchor in the custom layer. Draws a labelled marker at each registered anchor, lists them by distance in an ox_lib menu, teleports to them, and records "this anchor belongs where I am standing" with the exact config line to paste. Read and record only: it does not edit any other resource and nothing reads its overrides.'

-- ============================================================================
-- THIS RESOURCE CHANGES NOTHING ABOUT THE WORLD.
--
-- No stream/ folder, no data_file, no map, no props, no peds, no blips, no
-- targets. It draws markers for admins who ask for them and it writes one row
-- per corrected anchor into its own table. Every other resource on the box
-- behaves exactly as it did before this was installed, including the ones whose
-- anchors are listed in shared/registry.lua.
--
-- The registry is a TRANSCRIPTION of values that live in other resources'
-- configs. It is not an authority and nothing reads it as one. When a config
-- changes, the transcription goes stale and the marker will disagree with the
-- feature; that is a documented cost, written up in README.md under "KEEPING
-- THE REGISTRY HONEST".
-- ============================================================================

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/registry.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- natives, markers, ox_lib menu, teleport
    'client/main.lua',      -- the live view and the menu: pure logic
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',   -- qbx_core / ACE / server-side ped read
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}
