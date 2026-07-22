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

-- Client: illenium game adapter + equip path + the Stage A spike debug command.
-- client/debug.lua (the /threads_spike Stage A visual check) is KEPT until David's
-- Stage A in-game gate passes; it is inert while Config.Enabled = false. The Phase 1
-- equip path lives in client/main.lua and is likewise inert until the flip.
client_scripts {
    'bridge/cl_game.lua',
    'client/main.lua',
    'client/debug.lua',
}

dependency 'oxmysql'

-- Stage A stream/ contents (auto-mounted, no manifest entry needed):
--   mp_m_freemode_01^jbib_000_u.ydd           -- known-good Rockstar torso geometry
--   mp_m_freemode_01^jbib_diff_000_a_uni.ytd  -- OUR YtdBuild-generated texture
--
-- Phase 1 delivery abstraction: the equip path applies whatever {component, drawable,
-- texture} a deployed design row declares; it does NOT care whether the .ytd arrived
-- via the Stage A base-drawable replacement or a future Stage B addon-DLC. The Stage B
-- generator (which appends addon .ytd/.ydd/.ymt into stream/ at the reserved index) is
-- out of scope for Phase 1 (gated on the un-passed in-game render test).
