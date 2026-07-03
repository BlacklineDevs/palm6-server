-- ============================================================================
-- 0018_evidence_v2.sql — gtarp_evidence v2: case files + suspect linkage.
--
-- Additive only. The v1 `gtarp_evidence` table (0012_evidence.sql) keeps
-- working unchanged: every new column is nullable or defaulted, so the
-- existing insert paths — `/logevidence` and gtarp_pumpcoin's rug-reveal
-- fraud entry, both of which INSERT only (citizenid, officer_name,
-- description[, coords]) — continue to work with zero changes. Uncased
-- (case_id NULL) entries stay legal forever.
--
-- Tables are `gtarp_`-prefixed per the defensive convention adopted after
-- the 0010_properties.sql collision (see 0012_evidence.sql notes).
--
-- `IF NOT EXISTS` on ADD COLUMN / ADD INDEX is MariaDB syntax — the Qbox
-- recipe stack this server runs on is MariaDB (qbx_core supports MariaDB
-- only), same assumption as the rest of this migration chain.
--
-- No framework tables are touched here. Apply after 0012_evidence.sql.
-- ============================================================================

-- One row per case file. `incident_key` is the idempotency handle for the
-- EnsureCase export: sibling systems (NPC witnesses, counterfeit-cash
-- serial traces) pass a stable per-incident key so concurrent appends for
-- the same incident converge on one case instead of forking duplicates.
-- NULL for officer-opened cases (`/casenew`), which are never auto-merged.
CREATE TABLE IF NOT EXISTS `gtarp_evidence_cases` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    incident_key VARCHAR(80) DEFAULT NULL,
    title VARCHAR(150) NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'open',
    created_by VARCHAR(64) NOT NULL DEFAULT 'system',
    created_by_name VARCHAR(100) NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_gtarp_evidence_cases_incident (incident_key),
    INDEX idx_gtarp_evidence_cases_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Suspect linkage. Either a known `citizenid`, or an "unknown suspect"
-- placeholder: citizenid NULL + `descriptor` holding partial descriptors
-- (clothing colour, mask y/n, vehicle class, partial plate, ...).
CREATE TABLE IF NOT EXISTS `gtarp_evidence_suspects` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    case_id INT UNSIGNED NOT NULL,
    citizenid VARCHAR(64) DEFAULT NULL,
    descriptor TEXT DEFAULT NULL,
    added_by VARCHAR(100) NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Race-safe dedupe for known suspects: linkSuspect uses INSERT IGNORE
    -- against this key so concurrent LinkSuspect calls for the same
    -- (case, citizenid) converge on one row — same pattern as incident_key
    -- above. NULL citizenid (unknown-suspect descriptor rows) is exempt:
    -- MariaDB unique keys permit multiple NULLs.
    UNIQUE KEY uq_gtarp_evidence_suspects_case_cid (case_id, citizenid),
    INDEX idx_gtarp_evidence_suspects_case (case_id),
    INDEX idx_gtarp_evidence_suspects_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Additive columns on the v1 log table. NO existing column is altered.
--   case_id — NULL = uncased v1-style flat entry (still fully legal).
--   kind    — entry taxonomy: 'note' (default, all v1/legacy rows),
--             'fact' (NPC-witness partials), 'lead' (serial traces), ...
--   source  — which system wrote the row ('police' for officer commands;
--             a resource name for export consumers). Legacy rows default
--             to 'police', which is what they all were.
ALTER TABLE `gtarp_evidence`
    ADD COLUMN IF NOT EXISTS case_id INT UNSIGNED DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS kind VARCHAR(32) NOT NULL DEFAULT 'note',
    ADD COLUMN IF NOT EXISTS source VARCHAR(64) NOT NULL DEFAULT 'police';

ALTER TABLE `gtarp_evidence`
    ADD INDEX IF NOT EXISTS idx_gtarp_evidence_case (case_id);

-- Backfill for databases that already ran an earlier 0018 (CREATE TABLE
-- IF NOT EXISTS above won't touch an existing table). No-op on fresh
-- installs thanks to IF NOT EXISTS. If this ever fails with a duplicate-key
-- error, dedupe first:
--   DELETE s1 FROM gtarp_evidence_suspects s1
--   JOIN gtarp_evidence_suspects s2
--     ON s1.case_id = s2.case_id AND s1.citizenid = s2.citizenid
--    AND s1.id > s2.id;
ALTER TABLE `gtarp_evidence_suspects`
    ADD UNIQUE INDEX IF NOT EXISTS uq_gtarp_evidence_suspects_case_cid (case_id, citizenid);
