-- ============================================================================
-- palm6_pd_life/shared/config.lua
--
-- The living PBPD (Palm Bay Police Department) station. Engine-agnostic tunables.
-- Scene positions are the only Tier-3 values; refine live with /pdnpc then bake
-- the printed vector4s into Config.Scene below.
-- ============================================================================

Config = {}

Config.Brand = 'PBPD'          -- Palm Bay Police Department
Config.DevPlacement = true      -- enable the /pdnpc live-placement tool (dev)

-- Role presets: a model pool (randomised per spawn) + the GTA scenario that
-- gives the ped its activity, and whether it's frozen in place.
--   clerk   = front-desk staff (clipboard)
--   cop     = standing patrol / guard
--   meeting = officers clustered talking (phone/mobile idle)
--   bencher = citizen sat on a bench (PROP_HUMAN_SEAT_BENCH snaps to a bench prop)
--   waiting = citizen stood in line, impatient
Config.Types = {
    clerk   = { models = { 's_f_y_cop_01', 's_m_y_cop_01' },                       scenario = 'WORLD_HUMAN_CLIPBOARD',       freeze = true },
    cop     = { models = { 's_m_y_cop_01', 's_f_y_cop_01' },                       scenario = 'WORLD_HUMAN_GUARD_STAND',     freeze = true },
    meeting = { models = { 's_m_y_cop_01', 's_f_y_cop_01' },                       scenario = 'WORLD_HUMAN_STAND_MOBILE',    freeze = true },
    bencher = { models = { 'a_m_y_business_01', 'a_f_y_business_02', 'a_m_m_business_01', 'a_f_m_business_02' }, scenario = 'PROP_HUMAN_SEAT_BENCH', freeze = false },
    waiting = { models = { 'a_m_y_hipster_01', 'a_f_y_hipster_02', 'a_m_m_eastsa_01', 'a_f_y_soucent_01' },     scenario = 'WORLD_HUMAN_STAND_IMPATIENT', freeze = true },
}

-- The permanent scene. SEEDED near David's lobby anchor (451.46,-952.64,30.24 h153)
-- so life shows on first boot; positions are rough — walk the lobby with /pdnpc to
-- drop each NPC exactly, then replace this list with the logged vector4s.
Config.Scene = {
    { type = 'clerk',   coords = vector4(451.5, -955.8, 30.24, 330.0) },  -- behind reception
    { type = 'waiting', coords = vector4(449.6, -953.4, 30.24, 150.0) },  -- in line
    { type = 'waiting', coords = vector4(448.9, -952.6, 30.24, 150.0) },  -- in line (behind)
    { type = 'bencher', coords = vector4(453.6, -953.6, 30.24, 200.0) },  -- on a bench
    { type = 'bencher', coords = vector4(454.6, -954.4, 30.24, 200.0) },  -- on a bench
    { type = 'meeting', coords = vector4(449.4, -950.4, 30.24,  90.0) },  -- officer huddle
    { type = 'meeting', coords = vector4(450.7, -950.1, 30.24, 270.0) },  -- officer huddle
    { type = 'cop',     coords = vector4(452.3, -951.2, 30.24, 180.0) },  -- patrol
}
