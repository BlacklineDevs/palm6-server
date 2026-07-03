-- ============================================================================
-- gtarp_eventguard/config.lua
--
-- Per-event ratelimits. Every guarded event has a (calls, window_seconds)
-- budget. Exceeding the budget drops the event AND increments the
-- violation counter; persistent offenders are auto-kicked at
-- KickThreshold breaches in a single session.
-- ============================================================================

Config = {}

Config.KickThreshold = 3

-- Only list events some resource actually registers as NET events
-- (RegisterNetEvent) — the guard hooks with AddEventHandler, so a name
-- nothing net-registers can never fire and its budget is dead weight.
-- The legacy qb-core names (QBCore:Server:UpdateMoney / SetMetaData /
-- OnJobUpdate) were removed 2026-07-03: Qbox never registers them as net
-- events (money is server-authoritative via qbx_core AddMoney/RemoveMoney;
-- OnJobUpdate is an internal TriggerEvent), so those guards were inert
-- since they shipped.
Config.Events = {
    -- gtarp custom layer events
    ['gtarp_courier:post']     = { calls = 5,  window_seconds = 60  },
    ['gtarp_courier:accept']   = { calls = 10, window_seconds = 60  },
    ['gtarp_courier:complete'] = { calls = 20, window_seconds = 60  },
    ['gtarp_courier:cancel']   = { calls = 10, window_seconds = 60  },

    -- ox_inventory shop purchase fan-out — recipe-shipped net event.
    -- ox_inventory does its own per-event data validation (Utils.LogExploit);
    -- this blunt call-count budget is defense-in-depth on top.
    ['ox_inventory:openInventory'] = { calls = 30, window_seconds = 30 },
}
