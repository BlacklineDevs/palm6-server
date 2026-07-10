-- 0039_drugs.sql — tables for gtarp_drugs (Schedule I MVP, weed).
-- Apply after the qbx base schema. gtarp_-... wait: these tables use the
-- drugs_ prefix that the resource's SQL references directly (gtarp_drugs_plants /
-- gtarp_drugs_recipes / gtarp_drugs_progression / gtarp_drugs_sales). Finished-product STATE
-- lives entirely in ox_inventory metadata, never in a table (spec §11).
--
-- Timers are wall-clock UNIX epoch seconds (BIGINT), resolved on interaction
-- in server/main.lua — restart-safe, no client ticks, relog-dupe resistant.
-- The Phase-2 tables (gtarp_drugs_processes cook/dry timers, drugs_dealers,
-- drugs_customers) are intentionally NOT created here.

-- One row per LIVE cannabis plant at a grow plot. coord_x/y/z pin it to a
-- Config.Grow.plots slot (matched on stored coords). water_level (0-100)
-- decays by wall-clock from watered_at; neglect is remembered for a harvest
-- quality penalty. additives is a JSON list of grow additives applied at
-- plant time. stage is 'growing' (or briefly 'harvested' during the atomic
-- harvest claim; a crash-stranded 'harvested' row is swept at boot).
CREATE TABLE IF NOT EXISTS `gtarp_drugs_plants` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    coord_x DOUBLE NOT NULL,
    coord_y DOUBLE NOT NULL,
    coord_z DOUBLE NOT NULL,
    strain VARCHAR(32) NOT NULL,
    soil_tier TINYINT UNSIGNED NOT NULL DEFAULT 2,
    planted_at BIGINT UNSIGNED NOT NULL,
    ready_at BIGINT UNSIGNED NOT NULL,
    water_level TINYINT UNSIGNED NOT NULL DEFAULT 100,
    watered_at BIGINT UNSIGNED NOT NULL,
    additives JSON NULL,
    neglected TINYINT(1) NOT NULL DEFAULT 0,
    stage VARCHAR(16) NOT NULL DEFAULT 'growing',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_drugs_plants_owner (owner_cid),
    INDEX idx_drugs_plants_plot (coord_x, coord_y, coord_z)
);

-- Saved named recipes for one-click repeat at the mixing station. steps_json
-- is the ordered list of additive item names; effects_json is the resolved
-- effect list at save time (display only — the server re-resolves on every
-- mix). UNIQUE(owner_cid, brand) so re-saving a brand updates it.
CREATE TABLE IF NOT EXISTS `gtarp_drugs_recipes` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    owner_cid VARCHAR(64) NOT NULL,
    brand VARCHAR(48) NOT NULL,
    base VARCHAR(32) NOT NULL,
    steps_json JSON NULL,
    effects_json JSON NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_drugs_recipes_owner_brand (owner_cid, brand)
);

-- Per-character grow XP + derived rank tier (gates strains via unlock_rank).
CREATE TABLE IF NOT EXISTS `gtarp_drugs_progression` (
    owner_cid VARCHAR(64) NOT NULL PRIMARY KEY,
    xp INT UNSIGNED NOT NULL DEFAULT 0,
    rank_tier INT UNSIGNED NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Sales ledger. channel = 'npc' for the street-buyer faucet (real-player
-- hand-to-hand trades go through ox_inventory and are not booked here). gross
-- == net_dirty for the NPC (no dealer cut in the MVP; cut_paid stays 0 for
-- the Phase-2 dealer split). flagged=1 tripped a police alert; evidence_case_id
-- links a gtarp_evidence v2 case. (citizenid, created_at) is the hot index for
-- the per-character daily faucet cap.
CREATE TABLE IF NOT EXISTS `gtarp_drugs_sales` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    channel VARCHAR(16) NOT NULL DEFAULT 'npc',
    brand VARCHAR(48) NULL,
    base VARCHAR(32) NULL,
    quality TINYINT UNSIGNED NOT NULL DEFAULT 2,
    units INT UNSIGNED NOT NULL,
    gross INT UNSIGNED NOT NULL,
    cut_paid INT UNSIGNED NOT NULL DEFAULT 0,
    net_dirty INT UNSIGNED NOT NULL,
    region VARCHAR(48) NULL,
    flagged TINYINT(1) NOT NULL DEFAULT 0,
    evidence_case_id INT UNSIGNED NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_drugs_sales_citizen_day (citizenid, created_at)
);
