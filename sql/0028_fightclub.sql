-- ============================================================================
-- 0028_fightclub.sql — gtarp_fightclub ring matches + parimutuel bets.
--
-- `gtarp_`-prefixed per the defensive convention. No FK constraints (house
-- style — this repo's other gtarp_* tables don't use them either).
--
-- gtarp_fightclub_bets.UNIQUE(match_id, citizenid) is the load-bearing
-- concurrency guard for /fcbet — it is what stops two racing bet commands
-- from the same citizen on the same match both landing (the DB constraint
-- itself is the atomic check, not a Lua read-then-insert). See
-- resources/[custom]/gtarp_fightclub/server/main.lua's module header.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gtarp_fightclub_matches` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    fighter1_citizenid VARCHAR(64) NOT NULL,
    fighter1_name VARCHAR(100) NOT NULL DEFAULT '',
    fighter2_citizenid VARCHAR(64) NOT NULL,
    fighter2_name VARCHAR(100) NOT NULL DEFAULT '',
    status ENUM('betting','live','resolved') NOT NULL DEFAULT 'betting',
    winner_citizenid VARCHAR(64) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    betting_ends_at TIMESTAMP NULL DEFAULT NULL,
    live_started_at TIMESTAMP NULL DEFAULT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_gtarp_fightclub_matches_status (status),
    INDEX idx_gtarp_fightclub_matches_f1 (fighter1_citizenid),
    INDEX idx_gtarp_fightclub_matches_f2 (fighter2_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `gtarp_fightclub_bets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    match_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    fighter TINYINT UNSIGNED NOT NULL,
    amount INT UNSIGNED NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_gtarp_fightclub_bet (match_id, citizenid),
    INDEX idx_gtarp_fightclub_bets_match (match_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
