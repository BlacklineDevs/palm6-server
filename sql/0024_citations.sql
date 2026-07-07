-- ============================================================================
-- 0024_citations.sql — gtarp_citations fine ledger.
--
-- `gtarp_`-prefixed per the defensive convention. No FK constraints
-- (house style).
--
-- A citation is debt with memory: unpaid past due_at escalates ONCE to a
-- gtarp_mdt warrant (warrant_id backlink) and the row flips to
-- 'escalated' — still owed, still payable. The recipe's instant billing
-- records nothing; this table is the record.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gtarp_citations` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    citizen_name VARCHAR(100) NOT NULL DEFAULT '',
    issued_by VARCHAR(64) NOT NULL,
    officer_name VARCHAR(100) NOT NULL DEFAULT '',
    amount INT UNSIGNED NOT NULL,
    reason VARCHAR(160) NOT NULL,
    status ENUM('unpaid','paid','escalated') NOT NULL DEFAULT 'unpaid',
    warrant_id INT UNSIGNED DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    due_at TIMESTAMP NOT NULL,
    paid_at TIMESTAMP NULL DEFAULT NULL,
    escalated_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_gtarp_citations_citizen (citizenid, status),
    INDEX idx_gtarp_citations_due (status, due_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
