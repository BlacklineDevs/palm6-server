-- ============================================================================
-- 0066_fightclub_defjam.sql — Def Jam Fight Club (Phase 0) schema.
--
-- Registers the BASE fightclub tables (mirror of 0028 — never added to
-- palm6_dbmigrate, so a fresh-DB rebuild had no fightclub layer and the 0054
-- settlement ALTERs FAILed against a missing table) PLUS the Phase-0 additive
-- columns and progression/unlock/daily/pve-cooldown tables.
--
-- All statements IF NOT EXISTS — dbmigrate re-runs them every boot (ledger-less).
-- rep_awarded DEFAULT 1 backfills existing resolved matches as already-awarded
-- so the T5 progression boot reconcile never re-grants rep on payment history.
-- entry_pot/entry_paid* DEFAULT 0 keep the entry-pot settle a no-op on legacy rows.
-- ============================================================================

-- Base tables (mirror of 0028_fightclub.sql).
CREATE TABLE IF NOT EXISTS `palm6_fightclub_matches` (
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
    INDEX idx_palm6_fightclub_matches_status (status),
    INDEX idx_palm6_fightclub_matches_f1 (fighter1_citizenid),
    INDEX idx_palm6_fightclub_matches_f2 (fighter2_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `palm6_fightclub_bets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    match_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    fighter TINYINT UNSIGNED NOT NULL,
    amount INT UNSIGNED NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_fightclub_bet (match_id, citizenid),
    INDEX idx_palm6_fightclub_bets_match (match_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Phase-0 additive columns on matches (each ADD COLUMN IF NOT EXISTS).
ALTER TABLE `palm6_fightclub_matches`
    ADD COLUMN IF NOT EXISTS `style1`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `style2`         VARCHAR(24) NULL,
    ADD COLUMN IF NOT EXISTS `fighter1_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `fighter2_model` VARCHAR(48) NULL,
    ADD COLUMN IF NOT EXISTS `method`         VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS `entry_pot`      INT     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid1`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `entry_paid2`    TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `rep_awarded`    TINYINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS `is_pve`         TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `cpu_tier`       TINYINT NULL,
    ADD COLUMN IF NOT EXISTS `cpu_fighter`    VARCHAR(48) NULL;

-- Progression / unlocks / daily caps / dark PvE cooldowns.
CREATE TABLE IF NOT EXISTS `palm6_fc_progression` (
    citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
    rep INT NOT NULL DEFAULT 0,
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    rank_tier INT NOT NULL DEFAULT 0,
    pve_wins INT NOT NULL DEFAULT 0,
    pve_losses INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `palm6_fc_unlocks` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    unlock_id VARCHAR(48) NOT NULL,
    unlocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_fc_unlock (citizenid, unlock_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `palm6_fc_daily` (
    citizenid VARCHAR(64) NOT NULL,
    day_bucket VARCHAR(10) NOT NULL,
    pvp_rep_wins INT NOT NULL DEFAULT 0,
    pve_rep_wins INT NOT NULL DEFAULT 0,
    distinct_opponents INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, day_bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `palm6_fc_pve_cooldowns` (
    citizenid VARCHAR(64) NOT NULL,
    cpu_tier TINYINT NOT NULL,
    beaten_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (citizenid, cpu_tier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
