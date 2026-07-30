fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_uniform - rank and season driven police uniforms. Captures the outfit an admin is actually wearing in game and reapplies it on duty, on promotion and on a season/weather change. Capture-and-reapply only: no streamed assets, no base-game replacement.'

-- ============================================================================
-- THIS RESOURCE STREAMS NOTHING AND REPLACES NOTHING.
--
-- There is deliberately no `stream/` folder, no `data_file` line and no
-- SHOP_PED_APPAREL_META_FILE here. palm6_threads is the cautionary tale that
-- this resource was written against: its stream/ folder overwrites the BASE
-- GAME's male jbib drawable 0 (mp_m_freemode_01^jbib_000_u.ydd), which made
-- every police work outfit built on that torso render as nothing, for
-- everyone, on the live box. custom.cfg force-stops it and says so at length.
--
-- Everything below is runtime only and touches the LOCAL player's own ped:
-- read the drawable/texture the player is already wearing, store it, push it
-- back later. Component variation is in the OneSync sync tree, so setting it
-- on the owning client is what makes every other client see it. No custom
-- sync, no new assets, nothing that can repaint a garment for anyone else.
--
-- If custom clothing is ever added to Palm6, it must be an ADDON-DLC pack in
-- its OWN resource with its own SHOP_PED_APPAREL_META_FILE, never a
-- replacement, and never in this one.
-- ============================================================================

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- game natives + illenium soft calls isolated here
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',   -- qbx_core / ACE / weather adapter
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}
