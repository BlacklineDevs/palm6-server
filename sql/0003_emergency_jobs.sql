-- ============================================================================
-- 0003_emergency_jobs.sql
--
-- Registers / upserts emergency-services jobs in the qbx jobs table. The
-- recipe-deployed qbox-lean already seeds the canonical schema; this
-- migration is idempotent and only ensures the rows we expect with our
-- per-grade salary ladder. The actual paycheck values are sourced at
-- runtime from qbx_economy_overrides.
-- ============================================================================

-- Belt-and-suspenders schema guard. Real schema comes from qbx_core; the
-- IF NOT EXISTS keeps this migration safe to apply on a clean DB before
-- the recipe has installed its own job tables in development setups.
CREATE TABLE IF NOT EXISTS `jobs` (
    `name`     VARCHAR(50) NOT NULL,
    `label`    VARCHAR(50) NOT NULL,
    `type`     VARCHAR(20) NOT NULL DEFAULT 'civilian',
    `whitelist` TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `jobs` (`name`, `label`, `type`, `whitelist`) VALUES
    ('police',    'Los Santos Police Department', 'leo', 1),
    ('ambulance', 'Pillbox Hill Medical',         'ems', 1)
ON DUPLICATE KEY UPDATE
    `label` = VALUES(`label`),
    `type`  = VALUES(`type`),
    `whitelist` = VALUES(`whitelist`);

-- Optional `admin` grade row for staff who need on-duty access for testing.
CREATE TABLE IF NOT EXISTS `job_grades` (
    `job`     VARCHAR(50) NOT NULL,
    `grade`   INT NOT NULL,
    `name`    VARCHAR(50) NOT NULL,
    `salary`  INT NOT NULL DEFAULT 0,
    `isboss`  TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (`job`, `grade`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `job_grades` (`job`, `grade`, `name`, `salary`, `isboss`) VALUES
    ('police',    0, 'Cadet',      350,  0),
    ('police',    1, 'Officer',    480,  0),
    ('police',    2, 'Sergeant',   620,  0),
    ('police',    3, 'Lieutenant', 780,  0),
    ('police',    4, 'Chief',      940,  1),
    ('ambulance', 0, 'Trainee',    350,  0),
    ('ambulance', 1, 'Paramedic',  480,  0),
    ('ambulance', 2, 'EMT',        620,  0),
    ('ambulance', 3, 'Doctor',     780,  0),
    ('ambulance', 4, 'Chief',      940,  1)
ON DUPLICATE KEY UPDATE
    `name`   = VALUES(`name`),
    `salary` = VALUES(`salary`),
    `isboss` = VALUES(`isboss`);
