-- ============================================================================
-- gtarp_numbers/shared/config.lua — engine-agnostic tunables (Tier 1, carries
-- to VI). Only Bookie.coords is a Tier 3 Los Santos value.
--
-- DESIGN INTENT — the neighbourhood numbers racket. You stake CLEAN cash on a
-- two-digit number (00-99) with a back-alley bookie; every DrawIntervalSec the
-- house draws a winning number and pays hits a fixed multiple of their stake —
-- but the winnings come out DIRTY (`black_money`), so a win still has to be
-- run through gtarp_laundering before it spends clean. The stake is the sink;
-- the payout multiple is deliberately below true odds (a house edge), so this
-- is a money sink over time, never a printer.
--
-- NOT gtarp_fightclub. Fightclub is PARIMUTUEL wagering on a live PvP fight's
-- outcome (bettors split a pool by picking the real winner). This is a
-- FIXED-ODDS random draw against a staked number (house picks a number, pays a
-- set multiple). Different mechanic, different lane — kept distinct on purpose.
--
-- Winnings pay in `black_money` (ox_inventory stock "Dirty Money", plain
-- count == dollars — the same item qbx_bankrobbery pays and gtarp_laundering
-- washes). NEVER counterfeit_cash (fake money, gtarp_counterfeit's lane) and
-- NEVER markedbills (not a registered item on this server).
-- ============================================================================
Config = {}

Config.Debug = false

-- Stake account (clean money in) and win item (dirty money out).
Config.StakeAccount = 'cash'          -- you bet clean cash
Config.WinItem      = 'black_money'   -- you win dirty money (needs laundering)

-- The bookie / runner spot. Hidden — no blip, word-of-mouth RP (same as
-- gtarp_chopshop/gtarp_laundering). Server-side distance check against the
-- caller's REAL ped position. Tier 3 placeholder (a corner store back room,
-- Strawberry) — verify/retune in-game.
Config.Bookie = {
    label  = 'the bookie',
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    coords = vector3(88.5, -1958.4, 20.8),  -- Grove Street cul-de-sac, Davis
    radius = 12.0,
}

-- Number space + odds. Numbers 0..MaxNumber inclusive (00-99 = 100 outcomes).
-- PayoutMultiple is the multiple of stake a hit pays. True fair odds would pay
-- (MaxNumber+1)x; paying less is the house edge. 60x on 100 outcomes ≈ 40%
-- edge (expected return 0.60 per staked dollar) — a realistic numbers-racket
-- margin. NEVER set PayoutMultiple >= outcomes or it becomes +EV (a printer).
Config.MaxNumber      = 99
Config.PayoutMultiple = 60

-- Stakes (clean dollars).
Config.MinStake        = 100
Config.MaxStake        = 5000
Config.MaxBetsPerDraw  = 10     -- per character, per draw (spam bound)
Config.BetCooldownSec  = 3      -- per-character, between /numbers submissions

-- Draw cadence. Every interval the open draw resolves and a fresh one opens.
Config.DrawIntervalSec = 600    -- 10 minutes

-- /numbers and /collectnumbers are chat commands, not net events — so (like
-- gtarp_chopshop/laundering) eventguard's Config.Events doesn't cover them;
-- the per-character cooldown + per-draw cap + claim lock are the guard.
