-- ============================================================================
-- palm6_mapeditor/data/scene_models.lua
--
-- Curated, categorised catalogues of PED and VEHICLE models for the /propui
-- scene-entity browser (the Peds / Vehicles tabs). These let an admin place a
-- ped or vehicle by clicking a card instead of having to remember the exact
-- model name for /matped and /matveh. Not exhaustive (GTA V ships thousands) —
-- a solid, useful set of well-known models across the common categories. Unknown
-- or mistyped names fail gracefully (the entity just doesn't spawn), so this list
-- can be extended freely without risk.
--
-- Shape mirrors Config.PropGroups: { { category = 'X', models = { 'a', 'b' } } }.
-- ============================================================================

Config.PedGroups = {
    { category = 'Police & Security', models = {
        's_m_y_cop_01', 's_f_y_cop_01', 's_m_y_sheriff_01', 's_f_y_sheriff_01',
        's_m_y_swat_01', 's_m_m_fibsec_01', 's_m_y_ranger_01', 's_f_y_ranger_01',
        's_m_m_security_01', 's_m_y_prisguard_01', 's_m_m_prisguard_01', 's_m_m_marine_01',
        's_m_y_marine_01', 's_m_m_ciasec_01', 's_m_y_hwaycop_01',
    } },
    { category = 'Emergency', models = {
        's_m_m_paramedic_01', 's_m_y_fireman_01', 's_m_m_doctor_01', 's_f_y_scrubs_01',
        's_m_y_doctor_01', 's_m_m_lifeinvad_01',
    } },
    { category = 'Gangs', models = {
        'g_m_y_ballasout_01', 'g_m_y_ballaeast_01', 'g_m_y_ballaorig_01', 'g_f_y_ballas_01',
        'g_m_y_famca_01', 'g_m_y_famdnf_01', 'g_m_y_famfor_01', 'g_f_y_families_01',
        'g_m_y_lost_01', 'g_m_y_lost_02', 'g_f_y_lost_01', 'g_m_y_mexgoon_01',
        'g_m_m_chigoon_01', 'g_m_y_azteca_01', 'g_m_y_salvagoon_01', 'g_m_y_korean_01',
        'g_m_m_armboss_01', 'g_m_m_armgoon_01', 'g_m_y_pologoon_01',
    } },
    { category = 'Business', models = {
        'a_m_y_business_01', 'a_m_m_business_01', 'a_f_y_business_01', 'a_f_y_business_02',
        'a_f_m_business_02', 'a_m_y_hipster_01', 'a_m_y_hipster_02', 'a_f_y_hipster_01',
        'ig_bankman', 'a_m_m_business_01', 'a_m_y_stbla_01',
    } },
    { category = 'Civilians', models = {
        'a_m_y_skater_01', 'a_m_y_beach_01', 'a_f_y_beach_01', 'a_m_m_beach_01',
        'a_m_y_genstreet_01', 'a_f_y_genhot_01', 'a_m_y_downtown_01', 'a_f_y_hipster_02',
        'a_m_y_runner_01', 'a_f_y_runner_01', 'a_m_y_golfer_01', 'a_m_m_tramp_01',
        'a_f_m_downtown_01', 'a_m_y_vinewood_01', 'a_f_y_vinewood_01', 'a_m_m_farmer_01',
    } },
    { category = 'Workers', models = {
        's_m_y_construct_01', 's_m_y_construct_02', 's_m_m_gardener_01', 's_m_y_garbage_01',
        's_m_m_trucker_01', 's_m_y_dockwork_01', 's_m_m_dockwork_01', 's_m_y_valet_01',
        's_m_m_linecook_01', 's_m_y_waiter_01', 's_m_y_barman_01', 's_f_y_bartender_01',
        's_m_m_janitor', 's_m_y_pilot_01', 's_m_m_pilot_01', 's_m_y_chef_01',
        's_m_y_factory_01', 's_m_m_migrant_01',
    } },
    { category = 'Criminals', models = {
        's_m_y_dealer_01', 'a_m_m_hillbilly_01', 'a_m_m_hillbilly_02', 'mp_m_famdd_01',
        'g_m_m_cartelguards_01', 'g_m_m_cartelguards_02', 's_m_m_hairdress_01',
    } },
    { category = 'Animals', models = {
        'a_c_chop', 'a_c_rottweiler', 'a_c_pug', 'a_c_husky', 'a_c_cat_01', 'a_c_deer',
        'a_c_boar', 'a_c_coyote', 'a_c_rabbit_01', 'a_c_chickenhawk', 'a_c_cormorant',
        'a_c_cow', 'a_c_hen', 'a_c_pig', 'a_c_poodle', 'a_c_shepherd', 'a_c_retriever',
        'a_c_westy', 'a_c_mtlion', 'a_c_rhesus', 'a_c_chimp',
    } },
}

Config.VehGroups = {
    { category = 'Police & Emergency', models = {
        'police', 'police2', 'police3', 'police4', 'policet', 'sheriff', 'sheriff2',
        'fbi', 'fbi2', 'riot', 'pranger', 'ambulance', 'firetruk', 'lguard', 'polmav',
    } },
    { category = 'Sports', models = {
        'banshee', 'buffalo', 'buffalo2', 'comet2', 'feltzer2', 'jester', 'elegy2',
        'sultanrs', 'kuruma', 'futo', 'penumbra', 'ninef', 'rapidgt', 'massacro', 'coquette',
    } },
    { category = 'Super', models = {
        'adder', 'zentorno', 't20', 'entityxf', 'osiris', 'turismor', 'cheetah',
        'fmj', 'nero', 'tempesta', 'italigtb', 'reaper', 'vacca', 'bullet',
    } },
    { category = 'Sedans & Coupes', models = {
        'asea', 'intruder', 'premier', 'primo', 'stanier', 'warrener', 'washington',
        'tailgater', 'fugitive', 'stratum', 'schafter2', 'oracle', 'felon',
    } },
    { category = 'SUVs & Muscle', models = {
        'baller', 'baller2', 'cavalcade', 'granger', 'dubsta', 'dubsta2', 'mesa',
        'radi', 'xls', 'patriot', 'dominator', 'gauntlet', 'sabregt', 'phoenix', 'ruiner',
    } },
    { category = 'Motorcycles', models = {
        'akuma', 'bati', 'bati2', 'carbonrs', 'double', 'hakuchou', 'nemesis', 'pcj',
        'ruffian', 'sanchez', 'vader', 'faggio', 'hexer', 'daemon',
    } },
    { category = 'Off-Road', models = {
        'sandking', 'sandking2', 'rebel', 'rebel2', 'bifta', 'dune', 'blazer',
        'kalahari', 'dloader', 'guardian', 'bodhi2', 'trophytruck', 'brawler',
    } },
    { category = 'Vans & Trucks', models = {
        'rumpo', 'boxville', 'burrito', 'speedo', 'bison', 'phantom', 'hauler',
        'mule', 'pounder', 'benson', 'stockade', 'tiptruck', 'flatbed', 'packer',
    } },
    { category = 'Boats', models = {
        'dinghy', 'jetmax', 'marquis', 'seashark', 'squalo', 'suntrap', 'toro',
        'tropic', 'predator', 'speeder',
    } },
    { category = 'Air', models = {
        'buzzard', 'buzzard2', 'maverick', 'frogger', 'cargobob', 'swift', 'savage',
        'valkyrie', 'cuban800', 'duster', 'luxor', 'mammatus', 'velum', 'dodo', 'titan',
    } },
}
