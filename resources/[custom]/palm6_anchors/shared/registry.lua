-- ============================================================================
-- palm6_anchors/shared/registry.lua - THE ANCHOR REGISTRY.
--
-- One row per world anchor in the custom layer. A row says: what the anchor is
-- called, which resource owns it, which file and config path the number lives
-- at, and WHAT THAT NUMBER CURRENTLY READS.
--
-- ----------------------------------------------------------------------------
-- THE ONE RULE THIS FILE OBEYS
-- ----------------------------------------------------------------------------
-- Every `ref` below is a TRANSCRIPTION. Each one was copied out of the config
-- file named on its own row. Not one of them was chosen, rounded, averaged,
-- nudged or derived. If a number here disagrees with the config it cites, the
-- config is right and this file has a transcription bug, which is a bug worth
-- reporting because the whole tool rests on these two agreeing.
--
-- `ref` is a REFERENCE READING, not an authority. It exists so an admin can see
-- a marker where the anchor is TODAY. Nothing reads this file to decide where a
-- feature actually goes; the owning resource still reads its own config.
--
-- ----------------------------------------------------------------------------
-- HOW THIS LIST WAS BUILT
-- ----------------------------------------------------------------------------
-- By grepping resources/[custom] for vector3(, vector4( and for `x = <number>,
-- y =` table literals, then reading every hit and deciding whether it is a real
-- interaction anchor (a locker, a shop, a board, a dealer, a jail point, a
-- kiosk, a drop) or something else. What was deliberately LEFT OUT, and why, is
-- listed at the bottom of this file and in README.md. Read that before
-- concluding an anchor is missing.
--
-- ----------------------------------------------------------------------------
-- FIELDS
-- ----------------------------------------------------------------------------
--   key       stable identifier. NEVER renamed: it is the primary key of the
--             capture table, so renaming one orphans a capture.
--   label     what a human calls it.
--   resource  the resource whose config owns the number.
--   file      path to that config, relative to the resource folder.
--   path      the Lua path to the value inside that file. It is the real path,
--             not always a literal substring of the file: shops.lua declares
--             `ExtraShops = { general_store = { ... } }`, so
--             'ExtraShops.general_store.locations[1]' is correct and yet only
--             its SEGMENTS are searchable. Every segment of every path here was
--             checked against its file.
--   form      how the number is WRITTEN in that file: 'vector3', 'vector4' or
--             'table' ({ x = , y = , z = }). The capture tool prints a
--             replacement line in the SAME form, so what it prints is
--             paste-ready rather than a shape the file does not use.
--   kind      'interaction' = a point you walk up to and use.
--             'zone'        = a centre with a radius around it. Correcting one
--                             is a different job (it moves a whole area), so
--                             the menu says so on the row.
--   ref       the current value, transcribed. h is present only where the
--             source line carries a fourth component (a heading).
-- ============================================================================

Anchors = {

    -- ------------------------------------------------------------------
    -- MISSION ROW PD. The cluster behind all three incidents this week.
    -- ------------------------------------------------------------------
    {
        key = 'evidence_locker', label = 'Evidence locker',
        resource = 'palm6_evidence', file = 'shared/config.lua',
        path = 'Config.LockerCoords', form = 'vector3', kind = 'interaction',
        ref = { x = 434.0, y = -983.0, z = 30.7 },
    },
    {
        key = 'counterfeit_serial_terminal', label = 'Counterfeit serial terminal (police)',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Police.TerminalCoords', form = 'vector3', kind = 'interaction',
        -- palm6_counterfeit's own comment says to keep this in step with
        -- palm6_evidence Config.LockerCoords. They are two separate config
        -- values in two separate files, so they are two separate anchors here.
        ref = { x = 434.0, y = -983.0, z = 30.7 },
    },
    {
        key = 'bounty_board', label = 'Bounty board',
        resource = 'palm6_bounty', file = 'shared/config.lua',
        path = 'Config.Board.coords', form = 'table', kind = 'interaction',
        ref = { x = 434.60, y = -981.30, z = 30.71 },
    },
    {
        key = 'uniform_wardrobe', label = 'Station uniform wardrobe',
        resource = 'palm6_uniform', file = 'shared/config.lua',
        path = 'Config.Wardrobe.Coords', form = 'vector3', kind = 'interaction',
        ref = { x = 455.56, y = -991.74, z = 30.24 },
    },
    {
        key = 'police_duty_toggle', label = 'Mission Row PD duty toggle',
        resource = 'qbx_police_overrides', file = 'config.lua',
        path = 'Config.DutyToggle.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 442.32, y = -988.43, z = 30.69 },
    },
    {
        key = 'police_armoury', label = 'Mission Row PD armoury point',
        resource = 'qbx_police_overrides', file = 'config.lua',
        path = 'Config.Armoury[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 461.79, y = -983.04, z = 30.69 },
    },
    {
        key = 'shop_police_armoury', label = 'Shop: Mission Row PD Armoury',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.police_armoury.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 461.79, y = -983.04, z = 30.69 },
    },
    {
        key = 'pdlife_station_center', label = 'Living-station footprint centre',
        resource = 'palm6_pd_life', file = 'shared/config.lua',
        path = 'Config.Station.center', form = 'vector3', kind = 'zone',
        ref = { x = 459.3, y = -975.0, z = 30.0 },
    },
    {
        key = 'ransom_droppoint', label = 'Ransom drop point',
        resource = 'palm6_ransom', file = 'shared/config.lua',
        path = 'Config.DropPoint.coords', form = 'table', kind = 'interaction',
        ref = { x = 442.80, y = -1017.30, z = 28.46 },
    },

    -- ------------------------------------------------------------------
    -- EMS
    -- ------------------------------------------------------------------
    {
        key = 'ems_duty_toggle', label = 'Pillbox Hill duty toggle',
        resource = 'qbx_ambulance_overrides', file = 'config.lua',
        path = 'Config.DutyToggle.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 311.5, y = -1432.0, z = 30.0 },
    },
    {
        key = 'ems_hospital_pillbox', label = 'Pillbox Hill Medical',
        resource = 'qbx_ambulance_overrides', file = 'config.lua',
        path = 'Config.Hospitals[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 307.7, y = -1433.4, z = 29.9 },
    },
    {
        key = 'shop_ems_medical', label = 'Shop: Pillbox Hill Medical Supply',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.ems_medical.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 307.7, y = -1433.4, z = 29.9 },
    },

    -- ------------------------------------------------------------------
    -- CIVILIAN JOB STARTER NPCs
    -- ------------------------------------------------------------------
    {
        key = 'job_trucker_npc', label = 'Trucker Dispatch',
        resource = 'qbx_civilian_jobs_overrides', file = 'config.lua',
        path = 'Config.Jobs.trucker.starter_npc.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 150.95, y = -3040.0, z = 7.04 },
    },
    {
        key = 'job_taxi_npc', label = 'Downtown Cab Co.',
        resource = 'qbx_civilian_jobs_overrides', file = 'config.lua',
        path = 'Config.Jobs.taxi.starter_npc.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 903.13, y = -174.83, z = 73.97 },
    },
    {
        key = 'job_garbage_npc', label = 'LS Sanitation',
        resource = 'qbx_civilian_jobs_overrides', file = 'config.lua',
        path = 'Config.Jobs.garbage.starter_npc.coords', form = 'vector3', kind = 'interaction',
        ref = { x = -322.65, y = -1545.13, z = 27.79 },
    },
    {
        key = 'job_mechanic_npc', label = "Benny's / LS Customs job start",
        resource = 'qbx_civilian_jobs_overrides', file = 'config.lua',
        path = 'Config.Jobs.mechanic.starter_npc.coords', form = 'vector3', kind = 'interaction',
        ref = { x = -205.45, y = -1311.66, z = 31.30 },
    },

    -- ------------------------------------------------------------------
    -- ox_inventory SHOPS (public)
    -- ------------------------------------------------------------------
    {
        key = 'shop_general_1', label = 'Shop: General Store, Innocence Blvd',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 24.47, y = -1346.62, z = 29.50 },
    },
    {
        key = 'shop_general_2', label = 'Shop: General Store, Pacific Bluffs',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[2]', form = 'vector3', kind = 'interaction',
        ref = { x = -3038.94, y = 585.95, z = 7.91 },
    },
    {
        key = 'shop_general_3', label = 'Shop: General Store, Banham Canyon',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[3]', form = 'vector3', kind = 'interaction',
        ref = { x = -3242.47, y = 1001.46, z = 12.83 },
    },
    {
        key = 'shop_general_4', label = 'Shop: General Store, Paleto Bay',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[4]', form = 'vector3', kind = 'interaction',
        ref = { x = 1728.66, y = 6414.16, z = 35.04 },
    },
    {
        key = 'shop_general_5', label = 'Shop: General Store, Mirror Park',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[5]', form = 'vector3', kind = 'interaction',
        ref = { x = 1163.37, y = -323.80, z = 69.21 },
    },
    {
        key = 'shop_general_6', label = 'Shop: General Store, Tataviam Mtns',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[6]', form = 'vector3', kind = 'interaction',
        ref = { x = 2557.94, y = 382.05, z = 108.62 },
    },
    {
        key = 'shop_general_7', label = 'Shop: General Store, Downtown',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.general_store.locations[7]', form = 'vector3', kind = 'interaction',
        ref = { x = 373.87, y = 325.89, z = 103.57 },
    },
    {
        key = 'shop_ammunation_1', label = 'Shop: Ammu-Nation, Innocence Blvd',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.ammu_nation.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 21.7, y = -1106.42, z = 29.80 },
    },
    {
        key = 'shop_ammunation_2', label = 'Shop: Ammu-Nation, El Burro Heights',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.ammu_nation.locations[2]', form = 'vector3', kind = 'interaction',
        ref = { x = 810.25, y = -2157.6, z = 29.62 },
    },
    {
        key = 'shop_ammunation_3', label = 'Shop: Ammu-Nation, Sandy Shores',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.ammu_nation.locations[3]', form = 'vector3', kind = 'interaction',
        ref = { x = 1693.4, y = 3760.6, z = 34.71 },
    },
    {
        key = 'shop_hardware_1', label = 'Shop: Hardware Store, Sandy Shores',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.hardware.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 2748.4, y = 3473.4, z = 55.66 },
    },
    {
        key = 'shop_hardware_2', label = 'Shop: Hardware Store, Paleto Bay',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.hardware.locations[2]', form = 'vector3', kind = 'interaction',
        ref = { x = -422.7, y = 6136.0, z = 31.86 },
    },
    {
        key = 'shop_clothing_1', label = 'Shop: Suburban',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.clothing.locations[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 127.0, y = -223.4, z = 54.56 },
    },
    {
        key = 'shop_garden_1', label = 'Shop: Garden & Hydro Supply, Sandy Shores',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.garden_supply.locations[1]', form = 'vector3', kind = 'interaction',
        -- carries an inline VERIFY IN-GAME marker in shops.lua
        ref = { x = 1391.5, y = 3605.5, z = 38.9 },
    },
    {
        key = 'shop_garden_2', label = 'Shop: Garden & Hydro Supply, Grapeseed nursery',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.garden_supply.locations[2]', form = 'vector3', kind = 'interaction',
        -- carries an inline VERIFY IN-GAME marker in shops.lua
        ref = { x = 2001.5, y = 4636.5, z = 41.0 },
    },
    {
        key = 'shop_black_market_1', label = 'Shop: Black Market, warehouse district',
        resource = 'ox_inventory_overrides', file = 'data/shops.lua',
        path = 'ExtraShops.black_market.locations[1]', form = 'vector3', kind = 'interaction',
        -- carries an inline VERIFY IN-GAME marker in shops.lua
        ref = { x = 717.0, y = -962.0, z = 24.9 },
    },

    -- ------------------------------------------------------------------
    -- CITY SERVICES
    -- ------------------------------------------------------------------
    {
        key = 'citations_paydesk', label = 'City Hall citation pay desk',
        resource = 'palm6_citations', file = 'shared/config.lua',
        path = 'Config.PayDesk.coords', form = 'table', kind = 'interaction',
        ref = { x = -265.0, y = -963.6, z = 31.2 },
    },
    {
        key = 'legal_courthouse', label = 'Rockford Hills courthouse',
        resource = 'palm6_legal', file = 'shared/config.lua',
        path = 'Config.Courthouse.coords', form = 'table', kind = 'interaction',
        ref = { x = -544.67, y = -204.44, z = 38.65 },
    },
    {
        key = 'insurance_office', label = 'Insurance office',
        resource = 'palm6_insurance', file = 'shared/config.lua',
        path = 'Config.Office.coords', form = 'table', kind = 'interaction',
        ref = { x = -815.09, y = -1078.97, z = 11.13 },
    },
    {
        key = 'insurance_agent', label = 'Insurance agent desk',
        resource = 'palm6_insurance', file = 'shared/config.lua',
        path = 'Config.Agent.coords', form = 'table', kind = 'interaction',
        ref = { x = -815.09, y = -1078.97, z = 11.13 },
    },
    {
        key = 'lottery_kiosk', label = 'City Lottery kiosk',
        resource = 'palm6_lottery', file = 'shared/config.lua',
        path = 'Config.Kiosk.coords', form = 'table', kind = 'interaction',
        ref = { x = 25.7, y = -1347.3, z = 29.5 },
    },

    -- ------------------------------------------------------------------
    -- CRIMINAL ECONOMY: dealers, fronts, drops
    -- ------------------------------------------------------------------
    {
        key = 'numbers_bookie', label = 'The bookie',
        resource = 'palm6_numbers', file = 'shared/config.lua',
        path = 'Config.Bookie.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 88.5, y = -1958.4, z = 20.8 },
    },
    {
        key = 'loanshark', label = 'The loan shark',
        resource = 'palm6_loanshark', file = 'shared/config.lua',
        path = 'Config.Shark.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 94.2, y = -1291.9, z = 29.1 },
    },
    {
        key = 'laundering_front', label = 'The laundromat front',
        resource = 'palm6_laundering', file = 'shared/config.lua',
        path = 'Config.Front.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 127.4, y = -1298.9, z = 29.2 },
    },
    {
        key = 'gunrunning_droppoint', label = 'Gunrunning scrapyard lot',
        resource = 'palm6_gunrunning', file = 'shared/config.lua',
        path = 'Config.DropPoint.coords', form = 'table', kind = 'interaction',
        ref = { x = -477.0, y = -1717.0, z = 18.6 },
    },
    {
        key = 'chopshop_droppoint', label = 'Chop shop drop point',
        resource = 'palm6_chopshop', file = 'shared/config.lua',
        path = 'Config.DropPoint.coords', form = 'table', kind = 'interaction',
        ref = { x = 730.9, y = -3193.8, z = 5.9 },
    },
    {
        key = 'fightclub_ring', label = 'Fight club ring (palm6_fightclub)',
        resource = 'palm6_fightclub', file = 'shared/config.lua',
        path = 'Config.Ring.coords', form = 'table', kind = 'interaction',
        ref = { x = 108.0, y = -1305.0, z = 29.19 },
    },
    {
        key = 'fc_core_ring', label = 'Fight club ring (palm6_fc_core, canonical)',
        resource = 'palm6_fc_core', file = 'config.lua',
        path = 'Config.Ring.coords', form = 'table', kind = 'interaction',
        ref = { x = 146.64, y = -1279.0, z = 28.98 },
    },
    {
        key = 'fc_arena_promoter', label = 'Fight club promoter ped',
        resource = 'palm6_fc_arena', file = 'shared/config.lua',
        path = 'Config.Promoter.coords', form = 'table', kind = 'interaction',
        ref = { x = 149.5, y = -1281.0, z = 28.98 },
    },
    {
        key = 'racing_meet', label = 'Street racing meet point',
        resource = 'palm6_racing', file = 'shared/config.lua',
        path = 'Config.Meet.coords', form = 'table', kind = 'interaction',
        ref = { x = -438.84, y = -657.85, z = 30.0 },
    },
    {
        key = 'racing_organizer', label = 'Street racing organizer ped',
        resource = 'palm6_racing', file = 'shared/config.lua',
        path = 'Config.Organizer.coords', form = 'table', kind = 'interaction',
        ref = { x = -434.5, y = -662.5, z = 30.0 },
    },
    {
        key = 'smuggling_pickup', label = 'Smuggling docks contact',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Pickup.coords', form = 'vector3', kind = 'interaction',
        ref = { x = -119.0, y = -2489.0, z = 6.0 },
    },
    {
        key = 'smuggling_dropoff_sandy_road', label = 'Smuggling drop: Sandy Shores lay-by',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1470.0, y = 3260.0, z = 40.0 },
    },
    {
        key = 'smuggling_dropoff_paleto_lot', label = 'Smuggling drop: Paleto lumber lot',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -540.0, y = 5320.0, z = 74.0 },
    },
    {
        key = 'smuggling_dropoff_catfish_boat', label = 'Smuggling drop: boat off Catfish View',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[3].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 3860.0, y = 4460.0, z = 1.0 },
    },
    {
        key = 'smuggling_dropoff_paleto_pier', label = 'Smuggling drop: Paleto cove buoy',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[4].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1600.0, y = 5260.0, z = 1.0 },
    },
    {
        key = 'smuggling_dropoff_grapeseed_air', label = 'Smuggling drop: Grapeseed airstrip',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[5].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 2130.0, y = 4790.0, z = 41.0 },
    },
    {
        key = 'smuggling_dropoff_sandy_air', label = 'Smuggling drop: Sandy airfield apron',
        resource = 'palm6_smuggling', file = 'shared/config.lua',
        path = 'Config.Dropoffs[6].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1720.0, y = 3290.0, z = 41.0 },
    },
    {
        key = 'market_exchange', label = 'Palm6 Commodity Exchange',
        resource = 'palm6_market', file = 'shared/config.lua',
        path = 'Config.Exchange.coords', form = 'vector3', kind = 'interaction',
        ref = { x = -40.00, y = -2530.00, z = 6.00 },
    },
    {
        key = 'market_refine_station', label = 'Palm6 Refinery',
        resource = 'palm6_market', file = 'shared/config.lua',
        path = 'Config.RefineStation.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1075.00, y = -2005.00, z = 32.00 },
    },
    {
        key = 'pumpcoin_exchange_1', label = 'Pumpcoin exchange: Pillbox Hill back alley',
        resource = 'palm6_pumpcoin', file = 'shared/config.lua',
        path = 'Config.Exchanges[1]', form = 'vector3', kind = 'interaction',
        ref = { x = 287.4, y = -1000.7, z = 29.4 },
    },
    {
        key = 'pumpcoin_exchange_2', label = 'Pumpcoin exchange: Vespucci canals alley',
        resource = 'palm6_pumpcoin', file = 'shared/config.lua',
        path = 'Config.Exchanges[2]', form = 'vector3', kind = 'interaction',
        ref = { x = -1179.5, y = -1483.5, z = 4.4 },
    },
    {
        key = 'pumpcoin_exchange_3', label = 'Pumpcoin exchange: Mirror Park side street',
        resource = 'palm6_pumpcoin', file = 'shared/config.lua',
        path = 'Config.Exchanges[3]', form = 'vector3', kind = 'interaction',
        ref = { x = 1195.0, y = -472.0, z = 66.2 },
    },
    {
        key = 'clout_pawnshop', label = 'Clout pawnshop',
        resource = 'palm6_clout', file = 'shared/config.lua',
        path = 'Config.PawnshopCoords', form = 'vector4', kind = 'interaction',
        -- The only vector4 in the registry: the source line carries a heading.
        ref = { x = -1179.5, y = -1483.5, z = 4.4, h = 125.0 },
    },
    {
        key = 'flashdrop_consignment', label = 'Flashdrop consignment bench',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Consignment.Coords', form = 'vector3', kind = 'interaction',
        ref = { x = -165.6, y = -302.4, z = 39.7 },
    },
    {
        key = 'flashdrop_fence', label = 'Flashdrop fence',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Fence.Coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1391.4, y = 3605.5, z = 34.9 },
    },
    {
        key = 'flashdrop_counterfeit', label = 'Flashdrop counterfeiter',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Counterfeit.Coords', form = 'vector3', kind = 'interaction',
        ref = { x = 716.8, y = -962.1, z = 30.4 },
    },
    {
        key = 'flashdrop_legion_underpass', label = 'Flashdrop site: Legion Square underpass',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 158.9, y = -985.7, z = 30.1 },
    },
    {
        key = 'flashdrop_vespucci_basketball', label = 'Flashdrop site: Vespucci Beach courts',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1289.2, y = -1387.8, z = 4.6 },
    },
    {
        key = 'flashdrop_mirror_park_gazebo', label = 'Flashdrop site: Mirror Park lakeside',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[3].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1091.5, y = -675.3, z = 58.1 },
    },
    {
        key = 'flashdrop_grove_cul_de_sac', label = 'Flashdrop site: Grove Street cul-de-sac',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[4].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 107.1, y = -1938.5, z = 20.8 },
    },
    {
        key = 'flashdrop_delperro_pier', label = 'Flashdrop site: Del Perro Pier entrance',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[5].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1682.9, y = -1069.3, z = 13.2 },
    },
    {
        key = 'flashdrop_rancho_ballas', label = 'Flashdrop site: Rancho, Roy Lowenstein Blvd',
        resource = 'palm6_flashdrop', file = 'shared/config.lua',
        path = 'Config.Locations[6].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 324.4, y = -2050.5, z = 20.9 },
    },
    {
        key = 'counterfeit_sink_liquor_backdoor', label = 'Counterfeit sink: Backdoor Liquor',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Sinks[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1224.6, y = -906.8, z = 12.3 },
    },
    {
        key = 'counterfeit_sink_chop_counter', label = 'Counterfeit sink: La Mesa Parts Counter',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Sinks[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 731.9, y = -1088.8, z = 22.2 },
    },
    {
        key = 'counterfeit_sink_paleto_bait', label = 'Counterfeit sink: Paleto Bait & Tackle',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Sinks[3].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -275.6, y = 6635.2, z = 7.5 },
    },
    {
        key = 'counterfeit_fence_pawn_sandy', label = 'Counterfeit fence: Sandy Pawn Back Room',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Fences[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1697.5, y = 3757.8, z = 34.7 },
    },
    {
        key = 'counterfeit_fence_arcade_straw', label = 'Counterfeit fence: Strawberry Arcade Office',
        resource = 'palm6_counterfeit', file = 'shared/config.lua',
        path = 'Config.Fences[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 232.6, y = -1385.8, z = 30.5 },
    },
    {
        key = 'drugs_mix', label = 'Drugs: mixing trailer',
        resource = 'palm6_drugs', file = 'shared/config.lua',
        path = 'Config.Mix.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1391.2, y = 3605.5, z = 38.9 },
    },
    {
        key = 'drugs_dry', label = 'Drugs: drying rack',
        resource = 'palm6_drugs', file = 'shared/config.lua',
        path = 'Config.Dry.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1388.5, y = 3608.2, z = 38.9 },
    },
    {
        key = 'drugs_cook', label = 'Drugs: cook lab',
        resource = 'palm6_drugs', file = 'shared/config.lua',
        path = 'Config.Cook.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1391.2, y = 3608.5, z = 38.9 },
    },
    {
        key = 'drugs_sell', label = 'Drugs: street sale point',
        resource = 'palm6_drugs', file = 'shared/config.lua',
        path = 'Config.Sell.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1980.5, y = 3053.0, z = 47.2 },
    },
    {
        key = 'drugs_dealer', label = 'Drugs: dealer corner',
        resource = 'palm6_drugs', file = 'shared/config.lua',
        path = 'Config.Dealer.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 106.4, y = -1922.6, z = 21.3 },
    },

    -- ------------------------------------------------------------------
    -- PRISON YARD (Bolingbroke)
    -- ------------------------------------------------------------------
    {
        key = 'yard_labor', label = 'Prison labour point',
        resource = 'palm6_yard', file = 'shared/config.lua',
        path = 'Config.Coords.Labor', form = 'vector3', kind = 'interaction',
        ref = { x = 1800.00, y = 2600.00, z = 46.00 },
    },
    {
        key = 'yard_commissary', label = 'Prison commissary',
        resource = 'palm6_yard', file = 'shared/config.lua',
        path = 'Config.Coords.Commissary', form = 'vector3', kind = 'interaction',
        ref = { x = 1780.00, y = 2600.00, z = 46.00 },
    },
    {
        key = 'yard_bail', label = 'Prison bail desk',
        resource = 'palm6_yard', file = 'shared/config.lua',
        path = 'Config.Coords.Bail', form = 'vector3', kind = 'interaction',
        ref = { x = 1690.00, y = 2560.00, z = 45.00 },
    },

    -- ------------------------------------------------------------------
    -- LEGAL GRIND BUYERS
    -- ------------------------------------------------------------------
    {
        key = 'grind_sell_fishing', label = 'Fish Market buyer',
        resource = 'palm6_grind', file = 'shared/config.lua',
        path = 'Config.Activities.fishing.sell.coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1817.30, y = -1193.20, z = 14.30 },
    },
    {
        key = 'grind_sell_mining', label = 'Ore Buyer',
        resource = 'palm6_grind', file = 'shared/config.lua',
        path = 'Config.Activities.mining.sell.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1109.60, y = -2007.90, z = 31.00 },
    },
    {
        key = 'grind_sell_hunting', label = 'Butcher',
        resource = 'palm6_grind', file = 'shared/config.lua',
        path = 'Config.Activities.hunting.sell.coords', form = 'vector3', kind = 'interaction',
        ref = { x = 85.20, y = 6410.30, z = 31.30 },
    },

    -- ------------------------------------------------------------------
    -- ROBBERY ATMs
    -- ------------------------------------------------------------------
    {
        key = 'robbery_atm_legion', label = 'ATM: Legion Square',
        resource = 'palm6_robbery', file = 'shared/config.lua',
        path = 'Config.ATMs.locations[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 147.43, y = -1035.79, z = 29.34 },
    },
    {
        key = 'robbery_atm_delperro', label = 'ATM: Del Perro',
        resource = 'palm6_robbery', file = 'shared/config.lua',
        path = 'Config.ATMs.locations[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -1205.35, y = -325.24, z = 37.87 },
    },
    {
        key = 'robbery_atm_sandy', label = 'ATM: Sandy Shores',
        resource = 'palm6_robbery', file = 'shared/config.lua',
        path = 'Config.ATMs.locations[3].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1822.51, y = 3683.11, z = 34.28 },
    },

    -- ------------------------------------------------------------------
    -- PROTECTION-RACKET STOREFRONTS
    -- ------------------------------------------------------------------
    {
        key = 'protection_ls_liquor', label = 'Protection: Legion Square Liquor',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[1].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 25.7, y = -1347.3, z = 29.49 },
    },
    {
        key = 'protection_gs_grocery', label = 'Protection: Grove Street Grocery',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[2].coords', form = 'vector3', kind = 'interaction',
        ref = { x = -48.52, y = -1757.51, z = 29.42 },
    },
    {
        key = 'protection_mp_deli', label = 'Protection: Mirror Park Deli',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[3].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1163.87, y = -323.86, z = 69.21 },
    },
    {
        key = 'protection_vw_pawn', label = 'Protection: Vinewood Pawn',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[4].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 373.87, y = 325.9, z = 103.57 },
    },
    {
        key = 'protection_ss_diner', label = 'Protection: Sandy Shores Diner',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[5].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1961.48, y = 3740.57, z = 32.34 },
    },
    {
        key = 'protection_pb_market', label = 'Protection: Paleto Market',
        resource = 'palm6_protection', file = 'shared/config.lua',
        path = 'Config.Businesses[6].coords', form = 'vector3', kind = 'interaction',
        ref = { x = 1727.99, y = 6416.66, z = 35.04 },
    },

    -- ------------------------------------------------------------------
    -- PAYPHONES (anonymous tips)
    -- ------------------------------------------------------------------
    {
        key = 'tips_payphone_legion', label = 'Payphone: Legion Square',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[1]', form = 'table', kind = 'interaction',
        ref = { x = 195.17, y = -933.77, z = 30.69 },
    },
    {
        key = 'tips_payphone_grove', label = 'Payphone: Davis, Grove St corner',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[2]', form = 'table', kind = 'interaction',
        ref = { x = 79.5, y = -1749.0, z = 29.3 },
    },
    {
        key = 'tips_payphone_vespucci', label = 'Payphone: Vespucci canals',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[3]', form = 'table', kind = 'interaction',
        ref = { x = -1389.0, y = -585.0, z = 30.2 },
    },
    {
        key = 'tips_payphone_mirror_park', label = 'Payphone: Mirror Park',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[4]', form = 'table', kind = 'interaction',
        ref = { x = 1163.0, y = -323.0, z = 69.2 },
    },
    {
        key = 'tips_payphone_vinewood', label = 'Payphone: Downtown Vinewood',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[5]', form = 'table', kind = 'interaction',
        ref = { x = 289.0, y = 176.5, z = 104.2 },
    },
    {
        key = 'tips_payphone_la_puerta', label = 'Payphone: La Puerta',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[6]', form = 'table', kind = 'interaction',
        ref = { x = -722.0, y = -1108.0, z = 11.0 },
    },
    {
        key = 'tips_payphone_sandy', label = 'Payphone: Sandy Shores',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[7]', form = 'table', kind = 'interaction',
        ref = { x = 1361.0, y = 3591.0, z = 34.9 },
    },
    {
        key = 'tips_payphone_paleto', label = 'Payphone: Paleto Bay',
        resource = 'palm6_tips', file = 'shared/config.lua',
        path = 'Config.Payphones[8]', form = 'table', kind = 'interaction',
        ref = { x = -110.0, y = 6421.0, z = 31.5 },
    },
}

-- ============================================================================
-- WHAT WAS DELIBERATELY LEFT OUT, AND WHY.
--
-- Every one of these was found by the same grep and read before being dropped.
-- They are listed here rather than in a commit message so the next person does
-- not have to re-derive the decision.
--
--   palm6_pd_life  Config.Scene            45 creator-placed ped scenario spots
--                                          (where an idle NPC stands). Not
--                                          interaction points, and palm6_pd_life
--                                          already ships /placeped for them.
--   palm6_brain    Config.Scenes (3),      ambient NPC spawn areas and named
--                  Config.NamedNpcs (3)    NPC spawn points. /brainscene already
--                                          captures those in game.
--   palm6_counterfeit Config.Districts (6) 550m-800m heat districts. A radius
--                                          bucket, not a place you stand.
--   palm6_clout    Config.DangerZones (6)  the SAME six zone centres appear in
--   palm6_protection Config.Zones (6)      three resources with 80m+ radii.
--   palm6_turf     Config.Zones (6)        Moving one is an area-design change
--                                          across three files, not a walk-up fix.
--   palm6_grind    .spots arrays (9)       gather nodes found by radius search,
--                                          not single walk-up points.
--   palm6_drugs    Config.Grow.plots       an array of grow plots in one field.
--   palm6_racing   Config.Routes           race checkpoint geometry; palm6_racing
--                                          already ships /racecp to re-home it.
--   server_base    Config.DefaultSpawn     the character spawn point, deliberately
--   server_identity Config.SpawnPoint      mirrored between two files. A spawn
--                                          position, not an interaction anchor.
--   palm6_uniform  Config.Wardrobe.        documented as a VERBATIM COPY of
--                  FallbackCoords          qbx_police_overrides Config.DutyToggle,
--                                          which IS registered here as
--                                          'police_duty_toggle'. Correcting the
--                                          copy on its own would silently break
--                                          the citation it is written to carry.
--   Config.Blip / Config.DropBlip          blip sprite and colour tables. No
--                                          coordinate in them at all.
--   bob74_ipl, cfx-nteam-mrpd,             vendored third-party map, prop and
--   mystudio_props, object_gizmo,          gizmo resources. Their coordinates
--   prop_spawn                             belong to upstream, not to the custom
--                                          feature layer this tool is for.
-- ============================================================================
