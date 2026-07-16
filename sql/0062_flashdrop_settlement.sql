-- ============================================================================
-- 0062_flashdrop_settlement.sql — recoverable consignment settlement.
--
-- palm6_flashdrop:consign:buy flips a listing to terminal status='sold' and
-- then, across several separate yielding steps, charges the buyer, hands over
-- the pair, and credits the SELLER's bank. A crash after the 'sold' flip but
-- before the seller credit stranded the seller's proceeds forever (the seller
-- had already surrendered the pair at list time), with no boot reconcile.
--
-- Two flags make the SELLER payout recoverable without ever minting:
--   buyer_paid — the buyer's cash was actually taken (set only after ChargeCash).
--   settled    — the seller credit + serial owner-flip completed.
-- The boot reconcile credits the seller ONLY for listings where buyer_paid=1
-- (so it can never pay out a sale whose buyer was never charged), claiming
-- settled=1 before the credit so a replay can't double-pay. The buyer's ITEM
-- delivery (GivePair) is deliberately NOT reconciled — ox_inventory autosaves
-- asynchronously, so re-giving a serialized pair could double-mint the item.
-- Both ALTERs are IF NOT EXISTS — safe to re-run every boot.
-- ============================================================================

-- FIRST-BOOT SAFETY: both flags default to 1 so EXISTING sold listings (already
-- settled under the old code) are treated as paid+settled and the boot reconcile
-- neither re-pays the seller NOR releases the sale back to 'active'. The buy path
-- resets buyer_paid=0 + settled=0 at the active->sold reserve flip, so sales made
-- AFTER this deploy are still recoverable. ADD COLUMN IF NOT EXISTS backfills once.
ALTER TABLE `palm6_flashdrop_listings`
    ADD COLUMN IF NOT EXISTS `buyer_paid` TINYINT NOT NULL DEFAULT 1;

ALTER TABLE `palm6_flashdrop_listings`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1;
