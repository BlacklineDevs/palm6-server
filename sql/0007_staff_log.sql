-- ============================================================================
-- 0007_staff_log.sql — audit log table for gtarp_staff
-- ============================================================================

CREATE TABLE IF NOT EXISTS `audit_log` (
    `id`                INT AUTO_INCREMENT PRIMARY KEY,
    `action`            VARCHAR(50) NOT NULL,
    `actor_name`        VARCHAR(100) DEFAULT NULL,
    `actor_identifier`  VARCHAR(100) DEFAULT NULL,
    `target_name`       VARCHAR(100) DEFAULT NULL,
    `target_identifier` VARCHAR(100) DEFAULT NULL,
    `detail`            TEXT,
    `created_at`        DATETIME NOT NULL,
    KEY `idx_action_time` (`action`, `created_at`),
    KEY `idx_actor`       (`actor_identifier`),
    KEY `idx_target`      (`target_identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
