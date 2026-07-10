-- ============================================================================
-- gtarp_loanshark/shared/config.lua — engine-agnostic tunables (Tier 1).
-- Only Shark.coords is a Tier 3 Los Santos value.
--
-- DESIGN INTENT — credit for criminals, and the drama of stiffing it. Borrow
-- DIRTY cash (black_money) from a back-alley shark up to a cap; owe principal
-- plus a flat interest by a deadline; repay in CLEAN bank money at the shark.
-- Miss the deadline and you DEFAULT — the shark puts a warrant on you
-- (gtarp_mdt), which gtarp_bounty then auto-posts as a hunting contract. So the
-- real play isn't the loan economics (borrowing dirty to repay clean at
-- interest is a deliberately steep sink); it's the leverage: instant dirty
-- liquidity now, or take the money and run and become a wanted target.
--
-- Principal is paid DIRTY (black_money — needs laundering to spend clean, or
-- spends directly at the recipe's BlackMarketArms). NEVER counterfeit_cash
-- (gtarp_counterfeit's lane), NEVER the unregistered markedbills.
-- ============================================================================
Config = {}

Config.Debug = false

Config.DirtyItem = 'black_money'   -- the loan principal is handed over dirty

-- The shark's spot. Hidden — no blip, word-of-mouth RP. Server-side distance
-- check against the caller's REAL ped position. Tier 3 placeholder (a rail-yard
-- underpass, Cypress Flats) — retune in-game.
Config.Shark = {
    label  = 'the shark',
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    coords = vector3(94.2, -1291.9, 29.1),
    radius = 12.0,
}

-- Loan terms.
Config.MinPrincipal = 1000
Config.MaxPrincipal = 25000
Config.InterestBps  = 1500        -- 15% flat interest (owed = principal * 1.15)
Config.TermSec      = 10800       -- 3 hours to repay before default

-- Warrant issued on default (routed through gtarp_mdt → gtarp_bounty auto-posts
-- the contract). Officer label attributes the system warrant.
Config.DefaultWarrantReason = 'Outstanding debt to a known loan shark'
Config.DefaultOfficerLabel  = 'Loan Shark'

Config.DefaultSweepSec = 300      -- how often overdue loans are checked

-- /borrow, /repay, /loaninfo are chat commands, not net events — so (like
-- gtarp_chopshop/laundering/numbers) eventguard's Config.Events doesn't cover
-- them; the per-character cooldown + per-citizen borrow/repay locks + the
-- one-open-loan rule are the guard.
Config.CooldownSec = 3            -- per-character, between commands
