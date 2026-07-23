-- ============================================================================
-- palm6_pd_life/shared/config.lua
--
-- The living PBPD (Palm Bay Police Department) station. Zone-based auto-fill:
-- each zone scatters `count` scenario NPCs across a radius so the station reads
-- BUSY without hand-placing. Refine zone centers/counts from the screenshot loop.
-- ============================================================================

Config = {}

Config.Brand = 'PBPD'          -- Palm Bay Police Department
Config.DevPlacement = true      -- keep /pdnpc for spot-adding one-offs

-- Role presets: model pool (randomised) + GTA scenario + frozen-in-place flag.
Config.Types = {
    clerk   = { models = { 's_f_y_cop_01', 's_m_y_cop_01' },                     scenario = 'WORLD_HUMAN_CLIPBOARD',       freeze = true },
    cop     = { models = { 's_m_y_cop_01', 's_f_y_cop_01' },                     scenario = 'WORLD_HUMAN_GUARD_STAND',     freeze = true },
    copidle = { models = { 's_m_y_cop_01', 's_f_y_cop_01' },                     scenario = 'WORLD_HUMAN_COP_IDLES',       freeze = true },
    meeting = { models = { 's_m_y_cop_01', 's_f_y_cop_01' },                     scenario = 'WORLD_HUMAN_STAND_MOBILE',    freeze = true },
    bencher = { models = { 'a_m_y_business_01', 'a_f_y_business_02', 'a_m_m_business_01', 'a_f_m_business_02', 'a_m_y_hipster_01' }, scenario = 'PROP_HUMAN_SEAT_BENCH', freeze = false },
    waiting = { models = { 'a_m_y_hipster_01', 'a_f_y_hipster_02', 'a_m_m_eastsa_01', 'a_f_y_soucent_01', 'a_m_y_genstreet_01' },   scenario = 'WORLD_HUMAN_STAND_IMPATIENT', freeze = true },
    phone   = { models = { 'a_m_y_business_02', 'a_f_y_business_01', 'a_m_y_hipster_02' },                                          scenario = 'WORLD_HUMAN_STAND_MOBILE',    freeze = true },
}

-- ZONES scatter STANDING peds only (sitting scenarios float without a chair under
-- them, so benchers are placed explicitly below / via /pdnpc). Flat-floor: every
-- ped uses center.z (lobby ~30.24, mezzanine ~33.6). No ground-snap.
Config.Zones = {
    {   name = 'waiting_left',  center = vector3(451.0, -953.0, 30.24), radius = 5.0, count = 5,
        mix = { waiting = 2, phone = 1, cop = 1, meeting = 1 } },

    {   name = 'waiting_right', center = vector3(459.5, -957.0, 30.24), radius = 5.0, count = 4,
        mix = { waiting = 2, phone = 2 } },

    {   name = 'lobby_center',  center = vector3(447.0, -961.0, 30.24), radius = 8.0, count = 6,
        mix = { waiting = 2, cop = 2, phone = 1, meeting = 1 } },

    {   name = 'reception',     center = vector3(442.0, -969.0, 30.24), radius = 4.5, count = 4,
        mix = { clerk = 2, waiting = 2 } },

    {   name = 'mezzanine',     center = vector3(455.0, -963.0, 33.6),  radius = 7.0, count = 5,
        mix = { copidle = 2, meeting = 2, phone = 1 } },
}

-- Explicit fixed placements — known-good SEATED spots (a scattered bencher floats;
-- these two sat correctly in the first test). Add more with /pdnpc bencher on a
-- real chair, then paste the logged lines here.
Config.Fixed = {
    { type = 'bencher', coords = vector4(453.6, -953.6, 30.24, 200.0) },
    { type = 'bencher', coords = vector4(454.6, -954.4, 30.24, 200.0) },
}

Config.SpawnZOffset = 0.0
