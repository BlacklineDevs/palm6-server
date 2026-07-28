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
-- /dirtymoney is read-only but costs two DB round-trips (today's washed sum +
-- the palm6_heat tier read that makes the quoted fee honest), so it carries its
-- own light spam guard rather than riding CooldownSec, which would make the
-- quote unusable between washes.
Config.QuoteCooldownSec = 3

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
-- log (drives the /heat board, season Most-Wanted, dispatch priority).
--
-- BALANCE CHANGE, default-on. This used to be a FLAT charge per run
-- (Base = 5, +8 flagged). Flat per run means per-run heat does not move with
-- the size of the wash, so a $500 wash and a $25,000 wash scored identically
-- and the cheapest way to move a haul was the FEWEST, LARGEST runs. Against
-- Config.DailyCap = 75000: three $25,000 runs cost 15 heat total, while the
-- same $75,000 pushed through 150 minimum-size runs cost 750. That is the exact
-- inverse of the design intent stated above ("laundering small and slow is the
-- safe play, laundering a whole bank haul at once is loud"): under the flat
-- charge, dumping the whole haul in one go was the QUIET play.
--
-- The size of the wash is what makes it loud, so the charge is now
-- amount-proportional:
--
--   heat = min(MaxPerRun, floor(Base + dirty/1000 * PerThousand))
--          + (flagged and FlaggedBonus or 0)
--
-- A $25,000 run now scores 13 where a $500 run scores 1, so a haul dumped in
-- one go finally registers as the loud act the text above describes. Splitting
-- is still not free (the Base floor means 150 small runs total 150 heat against
-- 39 for three big ones). The goal was never to make splitting cheap, it was
-- to stop a single enormous wash being as quiet as a pocket-change one.
--
-- Base is a floor so any wash at all registers; MaxPerRun keeps a single wash
-- from jumping a launderer more than one tier; FlaggedBonus rides ON TOP of the
-- cap because "the law actually noticed this one" is a separate fact from size.
-- KNOCK-ON: a minimum $500 wash now scores 1 where the flat charge scored 5.
-- To restore the old flat behaviour exactly, set Base = 5 and PerThousand = 0
-- (MaxPerRun and FlaggedBonus already match the old numbers).
-- Soft-dep: if palm6_heat is stopped the whole block is a no-op.
Config.PlayerHeat = {
    Base         = 1,
    PerThousand  = 0.5,
    MaxPerRun    = 15,
    FlaggedBonus = 8,
}

-- Persistent-heat SCRUTINY at the front (palm6_heat GetTier). palm6_heat's own
-- Config.DispatchPriorityTier has always documented that palm6_laundering would
-- treat a HOT/WANTED citizen as priority ("extra launder scrutiny"); this is
-- that promise, wired. A hot launderer is a liability to the front, so the
-- front takes a bigger skim off them. ExtraCut is ADDED to Config.Cut for the
-- run (total cut is clamped to 0.90 so a wash can never pay out nothing), and a
-- tier listed in Refuse is turned away at the door instead.
--
-- Soft-dep: if palm6_heat is stopped, or GetTier errors, the surcharge is 0 and
-- the flat Config.Cut applies exactly as before. Set Enabled = false to restore
-- the old flat-cut behaviour wholesale.
Config.HeatScrutiny = {
    Enabled  = true,
    ExtraCut = { WARM = 0.0, HOT = 0.10, WANTED = 0.20 },
    Refuse   = {},   -- e.g. { WANTED = true } to have the front turn them away
}

-- ---------------------------------------------------------------------------
-- Evidence (palm6_evidence v2 frozen exports). A flagged run opens/updates a
-- case bucketed to a 5-minute window so a burst of runs shares one case.
-- ---------------------------------------------------------------------------
Config.Evidence = {
    IncidentKeyPrefix = 'laundering:',
    CaseTitle         = 'Money laundering',
}
