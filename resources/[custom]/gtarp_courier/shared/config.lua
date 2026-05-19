-- ============================================================================
-- gtarp_courier/shared/config.lua
-- ============================================================================

Config = {}

-- Minimum and maximum posting bounty. Held in escrow on the poster's
-- bank balance when the posting is created, paid to the courier on
-- delivery, refunded on cancel/expire.
Config.BountyBounds = {
    min = 50,
    max = 2500,
}

-- Posting lifetime (minutes). Posts older than this are auto-cancelled
-- and the bounty refunded on the next sweep.
Config.PostingLifetimeMinutes = 30

-- Maximum simultaneous postings per player. Prevents spam.
Config.MaxPostingsPerPlayer = 3

-- Distance in metres at which a delivery is considered completed when
-- the courier arrives at the dropoff.
Config.DeliveryRadiusMeters = 8.0

-- Blip colour for accepted delivery destination on the courier's map.
Config.DeliveryBlipColor = 5
