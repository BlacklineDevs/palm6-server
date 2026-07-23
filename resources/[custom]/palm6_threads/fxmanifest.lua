fx_version 'cerulean'
game 'gta5'

name 'palm6_threads'
description 'PALM6 Threads - player custom clothing (Phase 1 curated core loop, inert)'
author 'MGT'
version '0.1.0'

shared_script 'shared/config.lua'

-- Server: framework bridge (identity) + read-only deliverable-design fetch.
server_scripts {
    'bridge/sv_framework.lua',
    'server/main.lua',
}

-- Client: illenium game adapter + equip path.
client_scripts {
    'bridge/cl_game.lua',
    'client/main.lua',
}

dependency 'oxmysql'

-- stream/ is intentionally EMPTY for prod. The Phase-0 Stage A spike assets
-- (mp_m_freemode_01^jbib_*.ydd/.ytd) were REMOVED because they are REPLACEMENT-style
-- (they overwrite a BASE-GAME torso texture globally for every player) — unsafe on a
-- live server. They remain in git history (commit 331833b) for a test-server render
-- proof if ever wanted.
--
-- Phase 1 delivery abstraction: the equip path applies whatever {component, drawable,
-- texture} a deployed design row declares. Stage B (the addon-DLC generator) will append
-- ADDON-style .ytd/.ydd/.ymt (a SHOP_PED_APPAREL_META_FILE at the reserved index 4000+)
-- into stream/ + meta/ — additive, so it is prod-safe (adds a drawable, never replaces a
-- base one). That generator is out of scope for Phase 1.
