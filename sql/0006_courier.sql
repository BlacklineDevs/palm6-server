-- ============================================================================
-- 0006_courier.sql — player-run delivery board (Phase 6 signature feature)
--
-- Numbered 0006 to leave room for Phase-4 / Phase-5 migrations later.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `courier_postings` (
    `id`                 INT AUTO_INCREMENT PRIMARY KEY,
    `poster_citizenid`   VARCHAR(50) NOT NULL,
    `courier_citizenid`  VARCHAR(50) DEFAULT NULL,
    `bounty`             INT NOT NULL,
    `pickup_x`           DOUBLE NOT NULL,
    `pickup_y`           DOUBLE NOT NULL,
    `pickup_z`           DOUBLE NOT NULL,
    `dropoff_x`          DOUBLE NOT NULL,
    `dropoff_y`          DOUBLE NOT NULL,
    `dropoff_z`          DOUBLE NOT NULL,
    `label`              VARCHAR(100) DEFAULT 'Package',
    `status`             ENUM('open','taken','complete','cancelled','expired') NOT NULL DEFAULT 'open',
    `created_at`         DATETIME NOT NULL,
    `accepted_at`        DATETIME DEFAULT NULL,
    `completed_at`       DATETIME DEFAULT NULL,
    KEY `idx_status_created` (`status`, `created_at`),
    KEY `idx_poster`         (`poster_citizenid`),
    KEY `idx_courier`        (`courier_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
