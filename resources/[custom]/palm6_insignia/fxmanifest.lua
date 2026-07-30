fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Palm6'
version '0.1.0'
description 'palm6_insignia - server-authoritative officer NAME + BADGE NUMBER, rendered as a world-space name tape on the officer\'s chest for every nearby client. Ships NO streamed assets, so it cannot replace a base-game drawable.'

-- ============================================================================
-- SHIPS NO ASSETS. ON PURPOSE.
--
-- There is no stream/ folder here, no .ytd, no .ydd, and no
-- SHOP_PED_APPAREL_META_FILE. This resource cannot repeat the palm6_threads
-- incident (a REPLACEMENT-style pack whose stream/ folder overwrote the base
-- game's male jbib drawable 0 and made every police work outfit render as
-- nothing) because it adds no clothing asset of any kind and never calls a
-- clothing native.
--
-- The reason the identity is drawn in world space rather than printed on the
-- cloth is documented at length in README.md ("Why the text is not on the
-- garment"). Short version: the only FiveM mechanism that can put runtime text
-- on a garment is ADD_REPLACE_TEXTURE, which is keyed by texture NAME, is
-- global to the client and is not networked, so one officer's tape would
-- appear on every officer wearing the same garment. Cfx's own native docs call
-- it experimental and say not to use it in a live environment.
-- ============================================================================

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'bridge/cl_game.lua',   -- ALL client natives isolated here (bridge pattern)
    'client/main.lua',      -- roster cache + bounded render scheduler
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/sv_framework.lua',  -- qbx_core adapter - before server logic
    'server/main.lua',          -- badge registry + roster authority
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}
