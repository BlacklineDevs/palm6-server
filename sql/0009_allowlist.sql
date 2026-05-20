-- ============================================================================
-- 0009_allowlist.sql — manual allowlist for gtarp_allowlist
--
-- Rows here bypass the Discord-role check. Identifiers should be the
-- canonical license:... or discord:... form returned by GetPlayerIdentifiers.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `allowlist` (
    `id`         INT AUTO_INCREMENT PRIMARY KEY,
    `identifier` VARCHAR(100) NOT NULL UNIQUE,
    `note`       VARCHAR(255) DEFAULT NULL,
    `enabled`    TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
