fx_version 'cerulean'
game 'gta5'

name 'palm6_threads'
description 'PALM6 Threads - player custom clothing (Phase 0 spike)'
author 'MGT'
version '0.0.1'

shared_script 'shared/config.lua'
client_script 'client/debug.lua'

-- Stage A spike is REPLACEMENT-style, not addon-DLC, so NO SHOP_PED_APPAREL_META_FILE
-- is needed: we overwrite the base game's existing male-torso jbib drawable 0. The base
-- game's own shop meta already declares that slot, so it stays selectable at a fixed,
-- deterministic index (component 11, drawable 0, texture 0) with no appended-index guessing.
--
-- stream/ contents (auto-mounted, no manifest entry needed):
--   mp_m_freemode_01^jbib_000_u.ydd           -- known-good Rockstar torso geometry (base .ydd)
--   mp_m_freemode_01^jbib_diff_000_a_uni.ytd  -- OUR YtdBuild-generated texture (internal
--                                                name 'jbib_diff_000_a_uni', the exact name
--                                                the base .ydd looks up -> hash 0x7CDD0A9B)
--
-- Phase 1 (real per-character addon delivery via illenium-appearance) will switch to a true
-- addon-DLC pack with its own SHOP_PED_APPAREL_META_FILE; that scaffold is intentionally
-- omitted here to keep the spike's only variable "does our .ytd render".
