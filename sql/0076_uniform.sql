-- ============================================================================
-- 0076_uniform.sql - palm6_uniform captured police uniform sets.
--
-- PICKING THIS NUMBER: not from `ls sql/`. The authoritative namespace spans
-- BOTH sql/ and resources/[custom]/palm6_dbmigrate/server.lua, and dbmigrate
-- owns 0067 (racing) and 0068-0073 (business) with no sql/ file at all.
--
-- This file was FIRST WRITTEN AS 0075, which was genuinely the next free
-- number when this build started, and it collided anyway: sql/0075_insignia.sql
-- was created two minutes earlier by the parallel build of the name-and-badge
-- half. `node tools/audit/run.js migrations` caught the duplicate immediately
-- and this file yielded to 0076. Worth recording, because it means the audit's
-- "next free number" line is a reading taken at a moment in time, not a
-- reservation: on a tree with concurrent work, re-run the check after you
-- create the file, not only before.
--
-- WHAT IS IN HERE, AND WHY IT IS SAFE TO LOSE
--
-- One row per captured uniform. A row is a photograph of a ped: the twelve
-- component slots and the five prop slots as they were on the body of the
-- admin who ran /uniformcapture. Nothing in this table was authored by hand
-- and nothing in it can be, because the only writer is that command.
--
-- Losing the table costs the captured uniforms and nothing else. The resource
-- recreates it empty at boot, every officer keeps their own clothes, and the
-- fix is to re-run the captures. It grants nothing, holds no money and gates
-- no access.
--
-- THE KEY: (job, min_grade, model, season, weather)
--
--   job        always 'police' today. Column exists so a second department
--              (EMS, DOC) is a config change rather than a migration.
--
--   min_grade  an inclusive FLOOR, not an exact grade. An officer of grade G
--              wears the highest min_grade row that is <= G. Capturing ONE row
--              at grade 0 therefore dresses the whole department, and every
--              later capture is an override for the ranks above it. This is
--              the same idiom illenium-appearance uses for its own
--              management outfits, so it will read as familiar.
--
--   model      'mp_m_freemode_01' or 'mp_f_freemode_01', and it is part of the
--              key for a reason that is easy to get wrong: the two freemode
--              models have COMPLETELY DISJOINT drawable index spaces. The same
--              integer is a different garment on each body. A set captured on
--              one body renders as the wrong clothing, or as nothing, on the
--              other. So every uniform has to be captured twice, and the
--              resource refuses to apply a row whose model does not match the
--              wearer rather than guessing.
--
--   season     'any' | 'winter' | 'spring' | 'summer' | 'autumn'.
--              GTA V and FiveM have NO built-in concept of a season. This
--              value is matched against one DERIVED server-side from the real
--              date via a config schedule (palm6_uniform/shared/config.lua,
--              Config.SeasonByMonth). It is not read from the game, because
--              the in-game calendar is unmanaged: the weather-sync resources
--              only ever override the clock TIME, never the date.
--
--   weather    'any' | 'wet' | 'cold' | 'hot'. Fourteen GTA weather names
--              collapsed into three buckets plus a fallback, because keying on
--              all fourteen would mean fourteen captures per rank per body.
--              Derived server-side from the weather resource's server export;
--              with no weather resource on the box everyone resolves to 'any'.
--
-- 'any' is the fallback on both variant columns. A row stored as
-- (season='any', weather='any') matches every condition, so there is always a
-- sensible base uniform once one has been captured. When NOTHING matches, the
-- resource applies NOTHING and says so. It never dresses an officer in half a
-- set and never substitutes a different rank's uniform.
--
-- components_json / props_json are the captured arrays:
--   components  [{component_id, drawable, texture}, ...]  ids 0-11
--   props       [{prop_id, drawable, texture}, ...]       ids 0,1,2,6,7
-- A prop drawable of -1 means "clear that prop". Components 0 (face) and 2
-- (hair) are stored so the row is a complete record of the ped, and are never
-- written back: a uniform changes what an officer wears, not who they are.
--
-- captured_by is the citizenid of whoever ran the command, for audit. It is
-- nullable because a row is still valid if that character is later deleted.
--
-- RE-CAPTURE AFTER ANY CLOTHING PACK CHANGE. A drawable index is a position in
-- a mount-ordered list (base game + official DLC + every streamed addon pack).
-- Adding, removing or reordering a clothing pack on the box shifts every index
-- after it, and a stored set silently becomes a different garment. Nothing can
-- detect that from outside the game, so it is a human step.
--
-- SAFE TO RE-RUN (CREATE TABLE IF NOT EXISTS). The DDL below is duplicated
-- VERBATIM in palm6_uniform/server/main.lua's SCHEMA_SQL, which runs it at
-- boot. Keep the two copies identical.
--
-- palm6_uniform_sets is this resource's only table. It does not read or write
-- any table owned by palm6_insignia (0075) or by any other resource.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `palm6_uniform_sets` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    job VARCHAR(50) NOT NULL,
    min_grade INT NOT NULL DEFAULT 0,
    model VARCHAR(32) NOT NULL,
    season VARCHAR(16) NOT NULL DEFAULT 'any',
    weather VARCHAR(16) NOT NULL DEFAULT 'any',
    label VARCHAR(64) NOT NULL DEFAULT '',
    components_json TEXT NOT NULL,
    props_json TEXT NOT NULL,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_palm6_uniform_sets (job, min_grade, model, season, weather),
    KEY idx_palm6_uniform_sets_lookup (job, model, min_grade)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
