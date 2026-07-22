-- ============================================================================
-- palm6_laundering/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). Only Front.coords (a Los Santos spot) is a Tier 3 value to
-- retune when the VI map lands (see docs/GTA6-TIER3-RETUNE.md).
--
-- DESIGN INTENT — the missing SINK for the crime economy's dirty cash.
-- qbx_bankrobbery pays hauls out as `black_money` (ox_inventory's stock
-- "Dirty Money" item, plain count == dollars) — a stackable item you can
-- hold and hand around but never bank or spend as clean money. Nothing in
-- the recipe or the custom layer converts it. This resource is the wash:
-- a hidden laundromat front takes `black_money`, skims a fee, and returns
-- CLEAN bank funds — with a daily ceiling, an internal heat model that can
-- summon police, and an evidence trail (palm6_evidence v2) so a laundering
-- run can become a case.
--
-- NOT counterfeit. palm6_counterfeit's `counterfeit_cash` is FAKE money that
-- gets PASSED (fenced/spent), and its own README states it "can never be
-- laundered". The two systems deliberately never interact: this resource
-- touches ONLY `black_money` and never `counterfeit_cash`.
--
-- NOTE on the item name (verified against the REAL deployed recipe, not the
-- custom layer's stale comments): the dirty-money item actually registered
-- and in circulation on this server is `black_money` (ox_inventory stock,
-- given by qbx_bankrobbery). The `markedbills` name referenced in some older
-- custom-layer comments is NOT a registered item here (qbx_storerobbery's
-- marked-bills reward no-ops, qbx_drugs runs useMarkedBills=false) — do not
-- wire against it.
-- ============================================================================
Config = {}

Config.Debug = false

-- The dirty-money item this resource consumes. Plain count-based ($count ==
-- dollars, no per-item worth metadata), so laundering math is exact.
Config.DirtyItem = 'black_money'

-- Where dirty money becomes clean. A hidden front — no blip, word-of-mouth
-- RP, same as palm6_chopshop's drop point. Server-side distance check against
-- the player's REAL ped position (never a client-supplied coordinate).
-- Tier 3 placeholder (a coin laundromat, El Burro Heights) — verify/retune
-- in-game with a coords tool.
Config.Front = {
    label  = 'the laundromat',
    -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
    coords = vector3(127.4, -1298.9, 29.2),
    radius = 12.0,
}

-- Laundering fee. Clean payout to bank = floor(dirty * (1 - Cut)). 0.30 = you
-- keep 70%. Recorded per run in basis points for auditability.
Config.Cut = 0.30

-- Ceilings. Dirty dollars, per character.
-- /launder and /dirtymoney are chat commands, not net events — so (like
-- palm6_chopshop/gunrunning/ransom) eventguard's Config.Events doesn't cover
-- them; the per-character CooldownSec below + the DailyCap are the guard.
Config.MinPerRun  = 500     -- below this there's nothing worth washing
Config.MaxPerRun  = 25000   -- most dirty $ a single run will take
Config.DailyCap   = 75000   -- most dirty $ a character can wash per calendar day
Config.CooldownSec = 45     -- per-character, between runs

-- Refuse to wash for a player with an ACTIVE warrant (palm6_mdt). Closes the
-- loanshark "borrow dirty, default, launder it clean while wanted" cash-out and
-- makes wanted status meaningful: settle the law before you wash. Soft — if
-- palm6_mdt is absent the check is a no-op. Set false to disable.
Config.BlockWhileWanted = true

-- ---------------------------------------------------------------------------
-- Heat / risk. Washing warms the front. There is NO custom client here (this
-- is a server-only resource) — so heat never draws a map blip; instead it
-- gates whether a run trips a NATIVE police dispatch alert
-- (police:server:policeAlert, which qbx_police renders on its own) plus an
-- evidence case. Heat decays every sweep; laundering small and slow is the
-- safe play, laundering a whole bank haul at once is loud.
-- ---------------------------------------------------------------------------
Config.Heat = {
    PerThousand   = 3.0,     -- heat added per $1000 laundered
    DecayPerMin   = 2.0,     -- linear decay
    AlertThreshold = 60.0,   -- front heat at/above which a run may trip an alert
    AlertChanceMax = 0.60,   -- bust probability once heat is well past threshold
    BigRunAlways  = 20000,   -- a single run this large ALWAYS trips an alert
    SweepSec      = 60,      -- decay cadence (server thread)
}

-- Persistent PLAYER heat (palm6_heat) — distinct from the front heat above.
-- Config.Heat is this front's transient bust-probability; PlayerHeat is the
-- durable, per-character police attention that follows the launderer after they
-- log (drives the /heat board, season Most-Wanted, dispatch priority). A quiet
-- wash adds Base; a run the law flagged (police alerted + evidence filed) adds
-- Base + FlaggedBonus. Soft-dep — if palm6_heat is stopped this is a no-op.
Config.PlayerHeat = { Base = 5, FlaggedBonus = 8 }

-- ---------------------------------------------------------------------------
-- Evidence (palm6_evidence v2 frozen exports). A flagged run opens/updates a
-- case bucketed to a 5-minute window so a burst of runs shares one case.
-- ---------------------------------------------------------------------------
Config.Evidence = {
    IncidentKeyPrefix = 'laundering:',
    CaseTitle         = 'Money laundering',
}
