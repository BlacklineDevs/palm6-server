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

    -- gtarp_robbery — ATM two-phase flow. `complete` is the money-touching
    -- event (Bridge.AddCash payout); `start`/`cancel` are budgeted too since
    -- they drive the police dispatch fan-out and the per-ATM cooldown
    -- reservation. ensure order in custom.cfg puts gtarp_eventguard before
    -- gtarp_robbery, so these guards register first in the handler chain.
    ['gtarp_robbery:start']    = { calls = 10, window_seconds = 60 },
    ['gtarp_robbery:complete'] = { calls = 10, window_seconds = 60 },
    ['gtarp_robbery:cancel']   = { calls = 10, window_seconds = 60 },

    -- gtarp_mechanic — repair-invoice two-phase flow. `complete` charges the
    -- customer's bank and credits the mechanic (Bridge.ChargeBank /
    -- Bridge.CreditBank). Budget sized generously so a busy on-duty
    -- mechanic working multiple vehicles isn't throttled.
    ['gtarp_mechanic:start']    = { calls = 20, window_seconds = 60 },
    ['gtarp_mechanic:complete'] = { calls = 20, window_seconds = 60 },
    ['gtarp_mechanic:cancel']   = { calls = 10, window_seconds = 60 },

    -- gtarp_turf — territory capture two-phase flow. `complete` writes
    -- gtarp_turf (owner_gang flip = the reputation payout). `requestSync`
    -- is read-only but fans a full zone snapshot out per call — same
    -- "blunt budget as defense-in-depth" reasoning as ox_inventory below.
    ['gtarp_turf:requestSync'] = { calls = 20, window_seconds = 30 },
    ['gtarp_turf:requestTag']  = { calls = 10, window_seconds = 60 },
    ['gtarp_turf:complete']    = { calls = 10, window_seconds = 60 },
    ['gtarp_turf:cancel']      = { calls = 10, window_seconds = 60 },

    -- ox_inventory shop purchase fan-out — recipe-shipped net event.
    -- ox_inventory does its own per-event data validation (Utils.LogExploit);
    -- this blunt call-count budget is defense-in-depth on top.
    ['ox_inventory:openInventory'] = { calls = 30, window_seconds = 30 },

    -- gtarp_onboarding — the accept event writes gtarp_onboarding and
    -- (first time only) credits starter cash. A real accept only ever
    -- fires once per citizen; the budget just bounds retry/replay spam
    -- from a modified client on top of the resource's own UNIQUE(citizenid)
    -- guard and its own tighter Config.AcceptCooldownSec.
    ['gtarp_onboarding:acceptRules'] = { calls = 3, window_seconds = 60 },

    -- gtarp_onboarding:checkStatus — fires once per normal player load
    -- (client-side Game.OnPlayerLoaded) but is a bare client-addressable
    -- net event with NO in-resource rate limit (unlike acceptRules, which
    -- has its own Config.AcceptCooldownSec on top of this). It does a real
    -- DB read every call. Found during the independent harden pass on
    -- gtarp_onboarding — same "blunt budget as defense-in-depth" reasoning
    -- as ox_inventory:openInventory above.
    ['gtarp_onboarding:checkStatus'] = { calls = 10, window_seconds = 60 },

    -- evidence:server:CreateCasing — recipe-shipped net event (qbx_police).
    -- gtarp_gunrunning registers a second handler on it to cross-reference
    -- fired-weapon serials against its black-market sales registry. The
    -- handler only writes to gtarp_evidence on a real serial match (a cheap
    -- read-only lookup otherwise), same "blunt budget as defense-in-depth"
    -- reasoning as ox_inventory:openInventory above — normal gunfire can
    -- legitimately fire this often, so the budget is sized generously.
    ['evidence:server:CreateCasing'] = { calls = 60, window_seconds = 60 },
}
