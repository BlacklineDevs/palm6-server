-- ============================================================================
-- 0063_pumpcoin_delist_settlement.sql — recoverable coin-delist settlement.
--
-- delistCoin() used to flip the coin status='delisted' AND DELETE every
-- holdings row BEFORE paying holders their curve-reserve share in a yielding
-- loop. A crash mid-loop stranded the unpaid holders forever: the coin is
-- excluded from the boot reload (status='delisted') and the holdings rows were
-- already gone, so there was no record of who was owed and no recovery path.
--
-- These flags make the delist payout recoverable WITHOUT the double-pay the
-- delete-first design was avoiding:
--   holdings.settled       — per-holder claim flag (claimed before the credit).
--   coins.delist_pool      — curve-reserve pool snapshot at delist (share basis).
--   coins.delist_supply    — supply snapshot at delist (share denominator).
-- Holdings are no longer deleted at delist; each holder's row is claimed
-- (settled 0 -> 1) before its bank credit, and the boot reconcile re-drives
-- only still-unsettled holders of a delisted coin using the persisted
-- pool/supply, so shares are identical on replay and no holder is ever paid
-- twice. All ALTERs are IF NOT EXISTS — safe to re-run every boot.
-- ============================================================================

ALTER TABLE `palm6_pumpcoin_holdings`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 0;

ALTER TABLE `palm6_pumpcoin_coins`
    ADD COLUMN IF NOT EXISTS `delist_pool` BIGINT NULL DEFAULT NULL;

ALTER TABLE `palm6_pumpcoin_coins`
    ADD COLUMN IF NOT EXISTS `delist_supply` INT UNSIGNED NULL DEFAULT NULL;
