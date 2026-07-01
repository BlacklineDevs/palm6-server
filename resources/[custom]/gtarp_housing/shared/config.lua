-- ============================================================================
-- gtarp_housing/shared/config.lua
--
-- Engine-agnostic tunables for the housing system. The DESIGN (prices,
-- sell-back rate, access model, shell catalog) is Tier 1 and carries to
-- GTA VI. The COORDS below (door + interior positions) are Tier 3 — they are
-- Los Santos map points and get re-authored for the GTA VI map (they are
-- also mirrored in docs/GTA6-TIER3-RETUNE.md once this ships).
-- ============================================================================

Config = {}

Config.Debug = false

-- How close (metres) a player must be to a property door to interact.
Config.InteractRadius = 2.0

-- Fraction of purchase price returned when selling a property back to the
-- market (owner -> for_sale). 0.5 = 50% refund.
Config.SellBackRate = 0.5

-- Show a blip for every for-sale property (in addition to owned/keyed ones).
Config.ShowForSaleBlips = true

-- Blip styling (Tier 3 — GTA V sprite/colour ids).
Config.Blips = {
    owned   = { sprite = 40, colour = 2, scale = 0.8, label = 'My Property' },
    keyed   = { sprite = 40, colour = 3, scale = 0.7, label = 'Shared Property' },
    forsale = { sprite = 374, colour = 46, scale = 0.7, label = 'For Sale' },
}

-- Shell interiors. Each property references a shell by key; entering teleports
-- the player to the shell's interior coords inside a per-property routing
-- bucket so homes never overlap. (v1 uses fixed GTA V interior coords; a real
-- MLO/shell resource can replace these in v2 without touching the logic.)
-- Tier 3 coords.
Config.Shells = {
    apartment = { label = 'Apartment', interior = vector4(266.09, -1007.98, -101.01, 0.0) },
    mid       = { label = 'Mid House', interior = vector4(346.20, -1013.10, -99.20, 0.0) },
    trailer   = { label = 'Trailer',   interior = vector4(1973.30, 3818.40, 33.43, 60.0) },
}

-- Starter for-sale catalog. On resource start the server ensures a DB row
-- exists for each entry (keyed by `apartment`), so the market has homes to buy
-- on a fresh database. Owner/for_sale/price then live in the DB. Door coords
-- are Tier 3.
Config.Properties = {
    {
        apartment = 'integrity_1',
        street    = 'Integrity Way',
        region    = 'Downtown',
        shell     = 'apartment',
        price     = 45000,
        door      = vector4(-47.24, -585.35, 36.96, 340.0),
    },
    {
        apartment = 'delperro_1',
        street    = 'Del Perro Heights',
        region    = 'Del Perro',
        shell     = 'apartment',
        price     = 60000,
        door      = vector4(-1447.06, -538.79, 34.74, 145.0),
    },
    {
        apartment = 'mirror_1',
        street    = 'Mirror Park Blvd',
        region    = 'Mirror Park',
        shell     = 'mid',
        price     = 120000,
        door      = vector4(1148.90, -1521.30, 34.90, 100.0),
    },
    {
        apartment = 'sandy_1',
        street    = 'Alhambra Dr',
        region    = 'Sandy Shores',
        shell     = 'trailer',
        price     = 25000,
        door      = vector4(1972.40, 3815.20, 33.43, 120.0),
    },
}
