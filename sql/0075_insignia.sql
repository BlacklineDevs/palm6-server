-- ============================================================================
-- 0075_insignia.sql — palm6_insignia officer badge registry.
--
-- 0075 is the next free number across BOTH migration authorities (sql/ and
-- palm6_dbmigrate/server.lua), as reported by `node tools/audit/run.js
-- migrations`. Do NOT number a migration by `ls sql/` alone: 0067 and
-- 0068-0073 exist only inside palm6_dbmigrate/server.lua and have no file
-- here, so the directory listing reads as though 0067 were free.
--
-- palm6_insignia also creates this table itself at boot (server/main.lua,
-- ensureSchema) so a fresh box or a restored backup is never silently missing
-- it. The DDL below and the DDL there are the SAME statement, kept byte-for-
-- byte identical apart from the trailing semicolon, which oxmysql cannot take.
--
-- WHY THIS TABLE EXISTS AT ALL, rather than reusing something:
--   * qbx_police registers /callsign with no gate whatsoever - any officer can
--     set their own metadata.callsign to any string. That makes it unusable as
--     an authoritative badge number.
--   * Nothing in the palm6 custom layer stored a badge or a callsign before
--     this. palm6_mdt keys on citizenid, palm6_pd_life on post ids.
-- So this is the FIRST badge authority on the box, and palm6_insignia exports
-- it (GetBadge / GetBadgeByCitizenId / GetInsignia) so nothing has a reason to
-- invent a second one.
--
-- The UNIQUE key on `badge` is the uniqueness guarantee. The resource keeps an
-- in-memory allocation set for speed, but the database is what actually stops
-- two officers holding the same number.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `palm6_officer_badges` (
    citizenid VARCHAR(64) NOT NULL,
    badge INT UNSIGNED NOT NULL,
    job VARCHAR(50) NOT NULL DEFAULT 'police',
    assigned_by VARCHAR(64) NOT NULL DEFAULT 'system',
    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (citizenid),
    UNIQUE KEY uniq_palm6_officer_badges_badge (badge)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
