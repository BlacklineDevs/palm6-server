-- 0040_drugs_drying.sql — the gtarp_drugs_processes timer table for gtarp_drugs
-- (Phase-2 drying rack → Heavenly quality). Deferred out of the MVP schema
-- (0039_drugs.sql, spec §11) and added here — do NOT edit the committed 0039.
--
-- One row per LIVE processing run at a station (kind='dry' for the drying rack;
-- 'cook'/'mix' reserved for later phases). Timers are wall-clock UNIX epoch
-- seconds (BIGINT), resolved on interaction in server/main.lua — restart-safe,
-- no client ticks, relog-dupe resistant. The buds hung on the rack are consumed
-- at load time and stored in input_json; they are handed back (bumped to
-- Heavenly, dried=true) on collect. status is 'running' (or briefly
-- 'collecting' during the atomic collect claim; a crash-stranded 'collecting'
-- row is reverted to 'running' at boot so the owner never loses their buds).
--
-- UNIQUE(kind, station_id) enforces one live run per rack slot: a race to load
-- the same slot fails the second INSERT (which the server refunds), so the slot
-- can never hold two runs. A finished run is DELETEd on collect, freeing the
-- slot for the next batch.
CREATE TABLE IF NOT EXISTS `gtarp_drugs_processes` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    station_id INT UNSIGNED NOT NULL,
    kind VARCHAR(16) NOT NULL DEFAULT 'dry',
    input_json JSON NULL,
    started_at BIGINT UNSIGNED NOT NULL,
    finish_at BIGINT UNSIGNED NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'running',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_drugs_processes_slot (kind, station_id),
    INDEX idx_drugs_processes_owner (owner_cid)
);
