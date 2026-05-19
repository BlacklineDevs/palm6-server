-- ============================================================================
-- 0002_economy_seed.sql
--
-- Seeds society account rows so phase 3+ jobs have a place to land payroll
-- the moment they go live. Idempotent: uses INSERT … ON DUPLICATE KEY
-- UPDATE so re-running is a no-op.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `management_funds` (
    `job_name`   VARCHAR(50) NOT NULL,
    `amount`     INT NOT NULL DEFAULT 0,
    `type`       VARCHAR(20) NOT NULL DEFAULT 'job',
    PRIMARY KEY (`job_name`, `type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `management_funds` (`job_name`, `amount`, `type`) VALUES
    ('police',    50000, 'job'),
    ('ambulance', 50000, 'job'),
    ('mechanic',  10000, 'job'),
    ('taxi',       5000, 'job'),
    ('trucker',    5000, 'job'),
    ('garbage',    5000, 'job')
ON DUPLICATE KEY UPDATE `amount` = VALUES(`amount`);
