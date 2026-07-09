-- 0033_laundering.sql — table for gtarp_laundering. Apply after the qbx base schema.
-- gtarp_-prefixed per the table-naming convention (see docs/GTA6-READINESS.md
-- history — an unprefixed table silently collided with a recipe resource once).

-- One row per wash. dirty_in/clean_out are whole dollars; fee_bps records the
-- fee applied (basis points) so the ledger stays auditable even if Config.Cut
-- is retuned later. The daily ceiling is enforced by SUM(dirty_in) over
-- created_at >= CURDATE(), so (citizenid, created_at) is the hot index.
-- evidence_case_id is populated only for flagged runs (gtarp_evidence v2).
CREATE TABLE IF NOT EXISTS `gtarp_laundering_runs` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    dirty_in INT UNSIGNED NOT NULL,
    clean_out INT UNSIGNED NOT NULL,
    fee_bps SMALLINT UNSIGNED NOT NULL,
    flagged TINYINT(1) NOT NULL DEFAULT 0,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_laundering_citizen_day (citizenid, created_at)
);
