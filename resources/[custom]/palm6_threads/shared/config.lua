Config = {}

-- Prod-inert until the Phase 1 equip loop is proven in-game (Task 9, David's gate).
-- While false: the server serves NO designs and the client equip path is a no-op.
-- Flip to true ONLY for the controlled feel-test deploy, then revert.
Config.Enabled = false

-- Max simultaneously-equipped Threads items per player (Phase 1: one torso).
Config.MaxEquipped = 1

-- Reserved drawable-index bands (O2, LOCKED). A deployed design carries its own
-- drawable_index (allocated web-side inside the band) + the component comes from
-- its garment; this map mirrors the web RESERVED_BANDS so the client can sanity-
-- check an index falls in the expected band before applying it (defense-in-depth),
-- and documents the delivery abstraction (garment -> component + band).
-- ⚠️ These numbers are PERMANENT once web allocates against them — keep in lockstep
-- with palm6-web src/lib/threads/designs.ts RESERVED_BANDS.
Config.Bands = {
    -- component 11 = jbib (torso)
    [11] = { start = 4000, size = 1000 },
}

-- garment_id -> { component }. Seeded to mirror palm6_clothing_garments (Task 3 seed).
-- The server JOINs garments for the authoritative component_id; this is a client-side
-- convenience/validation map only. Extend as the curated catalog grows.
Config.Garments = {
    -- [1] = { component = 11 }, -- Male Torso Tee (ids assigned at seed time)
}
