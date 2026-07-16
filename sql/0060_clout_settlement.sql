-- ============================================================================
-- 0060_clout_settlement.sql — crash-recoverable brand-deal payouts for
-- palm6_clout (the IRL-streamer mechanic).
--
-- Adds one claim-before-credit idempotency flag to palm6_clout_deals:
--
--   * paid TINYINT — claimed 0->1 BEFORE the actual bank credit moves (never
--                    credit-then-mark). A replay (boot reconcile) skips any
--                    deal already flagged paid=1, so it can never double-pay.
--
-- WHY DEFAULT 1 (not 0): the boot reconcile re-drives deals sitting at
-- `claimed_at IS NOT NULL AND paid = 0`. EVERY brand deal claimed under the old
-- code already has claimed_at set (and was already credited). If the new column
-- defaulted to 0, the very first reconcile would match all of that history and
-- RE-PAY it — a mass mint. Defaulting the column to 1 marks every pre-existing
-- row as already-paid in the single, one-time ADD COLUMN (the IF NOT EXISTS
-- makes later boots a no-op, so this never clobbers a genuinely crash-stranded
-- row created after the migration). New deals are inserted with an EXPLICIT
-- paid = 0 by server/main.lua's milestone unlock, so only they are ever
-- reconcilable. This fails SAFE: a mistake here can only under-pay (a deal
-- stuck at paid=1 never re-credits), never mint.
--
-- `claimed_at` keeps its existing meaning (the broker-claim gate that /clout
-- and the broker read as "claimed"). A deal stranded by a crash — or by an
-- offline-mid-loop CreditBank returning false — sits at claimed_at IS NOT NULL
-- AND paid = 0, which the palm6_clout boot reconcile re-drives idempotently.
--
-- Registered centrally by palm6_dbmigrate (idempotent, safe to re-run every
-- boot). Do NOT add a standalone backfill UPDATE here: dbmigrate re-runs its
-- statements on every start, so a repeating "SET paid=1 WHERE claimed_at IS NOT
-- NULL" would clobber post-crash strands before the 8s reconcile can pay them.
-- ============================================================================

ALTER TABLE `palm6_clout_deals`
    ADD COLUMN IF NOT EXISTS `paid` TINYINT NOT NULL DEFAULT 1;

-- Boot reconcile scans (claimed_at IS NOT NULL AND paid = 0) — index it.
ALTER TABLE `palm6_clout_deals`
    ADD INDEX IF NOT EXISTS `idx_clout_deals_unpaid` (`paid`, `claimed_at`);
