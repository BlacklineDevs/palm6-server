-- ============================================================================
-- palm6_pd_life/shared/config.lua
--
-- The living PBPD (Palm Bay Police Department) station. Config.Scene is NTeam's
-- OWN creator-designed scenario points, extracted headless from the MLO's
-- mission_row.ymt via tools/threads-pipeline/ScenarioDump (CodeWalker.Core).
-- Each ped stands at the exact spot + heading the creator placed, doing the
-- exact activity (on phone, drinking coffee, hanging out, clipboard, cop idle).
-- No scatter, no guessing, correct orientation.
-- ============================================================================

Config = {}

Config.Brand = 'PBPD'
Config.DevPlacement = true

-- Model pools per role. cop = uniformed; civ = mixed public.
Config.Peds = {
    cop = { 's_m_y_cop_01', 's_f_y_cop_01' },
    civ = {
        'a_m_y_business_01', 'a_f_y_business_02', 'a_m_m_business_01', 'a_f_m_business_02',
        'a_m_y_hipster_01', 'a_f_y_hipster_02', 'a_m_m_eastsa_01', 'a_f_y_soucent_01',
        'a_m_y_genstreet_01', 'a_f_m_soucent_01', 'a_m_y_stwhi_01', 'a_f_y_business_01',
    },
}

-- 45 creator-placed points (scenario, role, vector4(x,y,z,heading)) from NTeam.
Config.Scene = {
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(445.20, -982.49, 29.25, -90.1) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(436.36, -986.26, 28.40, 63.1) },
    { scen='WORLD_HUMAN_SMOKING', ped='civ', coords=vector4(437.75, -995.08, 28.40, 144.6) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(439.39, -997.68, 28.54, -169.4) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(437.94, -998.34, 28.46, -78.6) },
    { scen='WORLD_HUMAN_GUARD_PATROL', ped='cop', coords=vector4(467.34, -1013.19, 28.38, 59.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(476.76, -996.19, 28.29, -108.7) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(466.63, -1014.73, 27.98, 41.3) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(477.32, -998.87, 28.38, 2.9) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(471.25, -999.12, 28.43, 51.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(464.55, -1014.22, 28.46, -31.6) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(437.70, -962.27, 28.35, 94.2) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(445.21, -960.58, 29.20, 57.2) },
    { scen='WORLD_HUMAN_CLIPBOARD', ped='cop', coords=vector4(445.28, -978.67, 29.26, -118.5) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(436.19, -990.56, 28.48, 20.7) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(437.77, -973.68, 28.45, 27.8) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(441.21, -961.00, 29.23, -22.8) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(461.93, -965.56, 29.20, -23.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(453.96, -963.67, 29.24, 21.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(452.50, -988.87, 29.19, 134.2) },
    { scen='WORLD_HUMAN_CLIPBOARD', ped='cop', coords=vector4(463.27, -985.53, 29.29, -8.2) },
    { scen='WORLD_HUMAN_CLIPBOARD', ped='cop', coords=vector4(468.78, -972.40, 29.34, 76.9) },
    { scen='WORLD_HUMAN_AA_COFFEE', ped='civ', coords=vector4(462.46, -965.06, 33.32, 6.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(463.31, -965.42, 29.23, 57.7) },
    { scen='WORLD_HUMAN_SMOKING', ped='civ', coords=vector4(450.17, -988.24, 29.17, -164.7) },
    { scen='WORLD_HUMAN_SMOKING', ped='civ', coords=vector4(457.94, -988.27, 29.18, 161.8) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(458.36, -990.44, 29.23, 11.3) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(450.47, -990.21, 29.19, -14.1) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(459.50, -989.93, 29.19, 61.9) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(476.96, -991.55, 28.96, -120.7) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(444.48, -957.81, 29.21, 112.3) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(446.95, -943.43, 29.21, -166.8) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(443.53, -958.95, 29.13, -45.7) },
    { scen='WORLD_HUMAN_AA_COFFEE', ped='civ', coords=vector4(447.85, -944.82, 29.17, 88.4) },
    { scen='WORLD_HUMAN_COP_IDLES', ped='cop', coords=vector4(445.40, -949.17, 29.23, 102.5) },
    { scen='WORLD_HUMAN_SMOKING', ped='civ', coords=vector4(441.37, -945.78, 28.46, 103.4) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(447.92, -953.28, 29.18, -39.1) },
    { scen='WORLD_HUMAN_COP_IDLES', ped='cop', coords=vector4(449.24, -958.53, 29.21, 48.0) },
    { scen='WORLD_HUMAN_CLIPBOARD', ped='cop', coords=vector4(455.11, -951.68, 29.28, -127.0) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(454.94, -944.04, 33.30, 178.6) },
    { scen='WORLD_HUMAN_HANG_OUT_STREET', ped='civ', coords=vector4(457.28, -947.34, 29.27, -131.4) },
    { scen='WORLD_HUMAN_CLIPBOARD', ped='cop', coords=vector4(456.25, -951.47, 29.26, 160.3) },
    { scen='WORLD_HUMAN_TOURIST_MAP', ped='civ', coords=vector4(463.62, -945.17, 29.22, 86.7) },
    { scen='WORLD_HUMAN_DRINKING', ped='civ', coords=vector4(449.09, -951.90, 29.22, 122.5) },
    { scen='WORLD_HUMAN_STAND_MOBILE', ped='civ', coords=vector4(463.42, -947.96, 29.22, 149.7) },
}
