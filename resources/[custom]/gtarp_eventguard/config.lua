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

-- Maximum amount we trust from the client on money-mutating events. The
-- server should always re-validate against authoritative state, but this
-- is a cheap upper bound for sanity.
Config.MaxClientMoneyDelta = 5000

Config.Events = {
    -- gtarp custom layer events
    ['gtarp_courier:post']     = { calls = 5,  window_seconds = 60  },
    ['gtarp_courier:accept']   = { calls = 10, window_seconds = 60  },
    ['gtarp_courier:complete'] = { calls = 20, window_seconds = 60  },
    ['gtarp_courier:cancel']   = { calls = 10, window_seconds = 60  },

    -- qbx money / inventory hot events. If your recipe pins different
    -- names, edit here.
    ['QBCore:Server:UpdateMoney']  = { calls = 30, window_seconds = 30 },
    ['QBCore:Server:SetMetaData']  = { calls = 30, window_seconds = 30 },
    ['QBCore:Server:OnJobUpdate']  = { calls = 10, window_seconds = 30 },

    -- ox_inventory shop purchase fan-out — recipe-shipped name.
    ['ox_inventory:openInventory'] = { calls = 30, window_seconds = 30 },
}
