-- ============================================================================
-- 0026_legal.sql — gtarp_legal expungement petitions + the additive
-- sealed_at column on gtarp_mdt_bookings it operates on.
--
-- `gtarp_`-prefixed per the defensive convention. No FK constraints
-- (house style). ADD COLUMN IF NOT EXISTS is MariaDB-safe and additive —
-- no existing column is altered (evidence-v2 precedent).
--
-- A sealed booking stays in the table (desk stats still count it) but
-- leaves the rap-sheet surface (gtarp_mdt GetBookingsFor). Petitions
-- charge the FILER at filing; the fee is court costs, kept on denial.
-- ============================================================================

ALTER TABLE `gtarp_mdt_bookings`
    ADD COLUMN IF NOT EXISTS sealed_at TIMESTAMP NULL DEFAULT NULL;

CREATE TABLE IF NOT EXISTS `gtarp_legal_petitions` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    booking_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,          -- the subject of the booking
    filed_by VARCHAR(64) NOT NULL,           -- who filed (subject or lawyer)
    filed_by_name VARCHAR(100) NOT NULL DEFAULT '',
    fee INT UNSIGNED NOT NULL,
    status ENUM('processing','granted','denied') NOT NULL DEFAULT 'processing',
    denial_reason VARCHAR(120) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    due_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_gtarp_legal_petitions_status_due (status, due_at),
    INDEX idx_gtarp_legal_petitions_booking (booking_id),
    INDEX idx_gtarp_legal_petitions_citizen (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
