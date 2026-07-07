-- ============================================================================
-- 0022_mdt.sql — gtarp_mdt BOLO + written-report storage.
--
-- `gtarp_`-prefixed per the defensive convention adopted after the
-- 0010_properties.sql collision. No FK constraints (house style).
--
-- BOLOs expire passively (active = resolved_at IS NULL AND expires_at >
-- NOW()) — no sweep thread needed, nothing is owed on expiry. Reports may
-- link a gtarp_evidence case (case_id NULL = standalone paperwork); the
-- evidence file itself gets the same text via the frozen AppendEntry
-- export, never by writing evidence tables from here.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gtarp_mdt_bolos` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    body VARCHAR(160) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    resolved_by VARCHAR(64) DEFAULT NULL,
    INDEX idx_gtarp_mdt_bolos_active (resolved_at, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `gtarp_mdt_reports` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    body TEXT NOT NULL,
    filed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_mdt_reports_cid (citizenid),
    INDEX idx_gtarp_mdt_reports_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
