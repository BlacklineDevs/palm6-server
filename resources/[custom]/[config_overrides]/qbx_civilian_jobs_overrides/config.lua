-- ============================================================================
-- qbx_civilian_jobs_overrides/config.lua
--
-- Curated civilian-jobs lineup for a 48-slot server:
--   - trucker  (recipe-provided)
--   - taxi     (recipe-provided)
--   - garbage  (recipe-provided)
--   - mechanic (recipe-provided)
--
-- Payouts here are PER-RUN bonuses on top of the per-cycle paycheck that
-- comes from qbx_economy_overrides.JobPaychecks. Bonuses are bounded so no
-- single job dominates: a 7m paycheck cycle should clear roughly 1-2
-- finished runs at most.
-- ============================================================================

Config = {}

Config.PayoutBounds = {
    min = 50,
    max = 800,
}

Config.Jobs = {
    trucker = {
        label = 'Trucker',
        starter_npc = {
            label = 'Trucker Dispatch',
            coords = vector3(150.95, -3040.0, 7.04),
            radius = 1.5,
        },
        runs = {
            { route = 'short',  payout = 250, cooldown_seconds = 30 },
            { route = 'medium', payout = 450, cooldown_seconds = 60 },
            { route = 'long',   payout = 700, cooldown_seconds = 90 },
        },
    },

    taxi = {
        label = 'Taxi',
        starter_npc = {
            label = 'Downtown Cab Co.',
            coords = vector3(903.13, -174.83, 73.97),
            radius = 1.5,
        },
        runs = {
            { route = 'short',  payout = 200, cooldown_seconds = 20 },
            { route = 'medium', payout = 380, cooldown_seconds = 40 },
            { route = 'long',   payout = 600, cooldown_seconds = 60 },
        },
    },

    garbage = {
        label = 'Sanitation',
        starter_npc = {
            label = 'LS Sanitation',
            coords = vector3(-322.65, -1545.13, 27.79),
            radius = 1.5,
        },
        runs = {
            { route = 'route_a', payout = 220, cooldown_seconds = 30 },
            { route = 'route_b', payout = 380, cooldown_seconds = 45 },
            { route = 'route_c', payout = 550, cooldown_seconds = 60 },
        },
    },

    mechanic = {
        label = 'Mechanic',
        starter_npc = {
            label = 'Benny\'s — LS Customs',
            coords = vector3(-205.45, -1311.66, 31.30),
            radius = 1.5,
        },
        -- Mechanic is paid mostly by repair invoices to other players;
        -- on-call payouts are kept low to discourage farming.
        runs = {
            { route = 'oncall_basic',    payout = 120, cooldown_seconds = 60 },
            { route = 'oncall_advanced', payout = 280, cooldown_seconds = 120 },
        },
    },
}
