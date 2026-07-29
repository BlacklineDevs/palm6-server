-- ============================================================================
-- palm6_courier/shared/config.lua
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

-- Enables `/courier cancel <id>` (cancel your own OPEN posting, escrow
-- refunded). false = current behaviour: the cancel path exists in
-- server/main.lua but nothing reaches it, so postings only ever clear on the
-- Config.PostingLifetimeMinutes sweep. The refund logic itself is unchanged
-- either way; this flag only decides whether players can trigger it.
Config.EnableCancelCommand = false

-- Distance in metres at which a delivery is considered completed when
-- the courier arrives at the dropoff. Client-side detection uses this
-- directly; the server re-checks it against its OWN read of the courier's
-- position (see palm6_courier:complete) with a small extra allowance
-- below for the gap between the client's 1.5s poll and the network
-- round-trip — never the raw client claim.
Config.DeliveryRadiusMeters = 8.0
Config.DeliveryArrivalSlack = 6.0

-- Deliveries left in status='taken' longer than this are treated as
-- abandoned (courier disconnected, went idle, or never intended to
-- finish) and swept the same way expired 'open' postings are: bounty
-- refunded to the poster, row marked 'expired'. Without this an
-- accept-and-vanish permanently locks another player's escrowed money —
-- 'taken' rows have no other expiry path.
Config.AcceptedLifetimeMinutes = 60

-- Blip colour for accepted delivery destination on the courier's map.
Config.DeliveryBlipColor = 5
-- Blip colour for the pickup leg (courier routes to pickup before dropoff).
Config.PickupBlipColor = 3
