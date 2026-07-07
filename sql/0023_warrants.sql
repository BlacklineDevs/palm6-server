-- ============================================================================
-- 0023_warrants.sql — gtarp_mdt v0.2.0 warrant + booking paperwork.
--
-- `gtarp_`-prefixed per the defensive convention. No FK constraints
-- (house style).
--
-- The recipe's qbx_police owns the PHYSICAL side (/cuff /jail /unjail) and
-- records nothing — these tables are the paper trail: a warrant is an
-- open order naming a citizen, a booking is the paperwork filed when the
-- arrest actually happens (which auto-serves that citizen's active
-- warrants). Warrants don't expire — they end served or dropped.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gtarp_mdt_warrants` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    citizen_name VARCHAR(100) NOT NULL DEFAULT '',
    issued_by VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    reason VARCHAR(200) NOT NULL,
    status ENUM('active','served','dropped') NOT NULL DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    resolved_by VARCHAR(64) DEFAULT NULL,
    INDEX idx_gtarp_mdt_warrants_citizen (citizenid, status),
    INDEX idx_gtarp_mdt_warrants_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `gtarp_mdt_bookings` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    citizen_name VARCHAR(100) NOT NULL DEFAULT '',
    booked_by VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    case_id INT UNSIGNED DEFAULT NULL,
    warrant_id INT UNSIGNED DEFAULT NULL,
    charges TEXT NOT NULL,
    booked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_gtarp_mdt_bookings_citizen (citizenid),
    INDEX idx_gtarp_mdt_bookings_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
