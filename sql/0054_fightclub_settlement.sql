-- ============================================================================
-- 0054_fightclub_settlement.sql — recoverable payout settlement for palm6_fightclub.
--
-- palm6_fightclub resolves a match by (1) an atomic guarded UPDATE flipping the
-- match to status='resolved', then (2) a multi-step yielding payout loop (purse +
-- one credit per winning bet). Before this migration, a server crash/restart in
-- the window between (1) and the last credit left the match 'resolved' but some
-- payouts never landed — money stranded forever, no recovery on the next boot.
-- This server restarts on every deploy, so that window is a real latent bug.
--
-- These three flags make settlement RECOVERABLE and IDEMPOTENT:
--   palm6_fightclub_bets.paid        — per-bet: this bet's payout/refund was credited.
--   palm6_fightclub_matches.purse_paid — the winner's purse was credited.
--   palm6_fightclub_matches.settled  — every payout for this match completed.
-- Each flag is CLAIMED (UPDATE ... WHERE flag=0 returns 1) BEFORE the money moves,
-- so a boot reconcile that re-drives a match with status='resolved' AND settled=0
-- can never double-pay: an already-credited step's flag is 1 and is skipped.
-- All ALTERs are IF NOT EXISTS — safe to re-run every boot (palm6_dbmigrate has
-- no ledger). See resources/[custom]/palm6_fightclub/server/main.lua settleMatch.
-- ============================================================================

-- FIRST-BOOT SAFETY: `settled` defaults to 1 so that EXISTING resolved matches
-- (already paid out under the old code) are backfilled as settled and the boot
-- reconcile skips them — otherwise the first restart after this deploy would
-- re-pay every historical match (a money printer). resolveMatch resets settled
-- to 0 at the live->resolved flip, so matches resolving AFTER this deploy are
-- still recoverable. `purse_paid` and `paid` default 0 (new matches/bets start
-- unpaid); existing rows are inert because their match's settled=1 blocks the
-- reconcile entirely. ADD COLUMN IF NOT EXISTS runs the backfill exactly once.
ALTER TABLE `palm6_fightclub_bets`
    ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 0;

ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `purse_paid` TINYINT NOT NULL DEFAULT 0;

ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1;
