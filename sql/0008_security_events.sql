-- ============================================================================
-- 0008_security_events.sql — event_violations table for gtarp_eventguard
-- ============================================================================

CREATE TABLE IF NOT EXISTS `event_violations` (
    `id`         INT AUTO_INCREMENT PRIMARY KEY,
    `player_src` INT NOT NULL,
    `identifier` VARCHAR(100) DEFAULT NULL,
    `event_name` VARCHAR(100) NOT NULL,
    `reason`     VARCHAR(255) NOT NULL,
    `created_at` DATETIME NOT NULL,
    KEY `idx_event_time` (`event_name`, `created_at`),
    KEY `idx_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
