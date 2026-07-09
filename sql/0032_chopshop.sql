-- 0032_chopshop.sql — tables for gtarp_chopshop. Apply after the qbx base schema.
-- gtarp_-prefixed per the table-naming convention (see docs/GTA6-READINESS.md
-- history — an unprefixed table silently collided with a recipe resource once).

-- Owner-reported stolen plates. `status='active'` is the live registry;
-- expiry is a WHERE-clause check at read time (expires_at), no sweep owed.
CREATE TABLE IF NOT EXISTS `gtarp_chopshop_stolen` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plate VARCHAR(15) NOT NULL,
    owner_citizenid VARCHAR(64) NOT NULL,
    status ENUM('active', 'resolved', 'expired') NOT NULL DEFAULT 'active',
    reported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_gtarp_chopshop_stolen_plate_status (plate, status),
    INDEX idx_gtarp_chopshop_stolen_owner (owner_citizenid)
);

-- Every chop-shop sale, stolen-linked or not (the ledger itself is neutral —
-- `evidence_case_id` is only ever populated when the plate matched an
-- active stolen report at sale time).
CREATE TABLE IF NOT EXISTS `gtarp_chopshop_sales` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    seller_citizenid VARCHAR(64) NOT NULL,
    plate VARCHAR(15) NOT NULL,
    vehicle_class TINYINT UNSIGNED NOT NULL,
    payout INT UNSIGNED NOT NULL,
    was_stolen TINYINT(1) NOT NULL DEFAULT 0,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    sold_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_chopshop_sales_seller (seller_citizenid)
);
