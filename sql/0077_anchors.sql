-- ============================================================================
-- 0077_anchors.sql - palm6_anchors captured world-anchor corrections.
--
-- PICKING THIS NUMBER: not from `ls sql/`. The authoritative namespace spans
-- BOTH sql/ and resources/[custom]/palm6_dbmigrate/server.lua, and dbmigrate
-- owns 0067 (racing) and 0068-0073 (business) with no sql/ file at all. This
-- number is the "next free migration number across BOTH authorities" line
-- printed by `node tools/audit/run.js`, read while this file was being written.
-- That is a reading taken at a moment in time, not a reservation: on a tree with
-- concurrent work, re-run the audit AFTER creating the file as well as before.
-- 0076_uniform.sql records the collision that taught this repo that lesson.
--
-- ----------------------------------------------------------------------------
-- WHAT IS IN HERE
-- ----------------------------------------------------------------------------
-- One row per anchor an admin has stood on and captured. A row says: this
-- feature belongs HERE, and here is who said so and when.
--
-- READ THIS BEFORE ASSUMING THE TABLE DOES ANYTHING:
--
--   NOTHING ON THE BOX READS THIS TABLE TO DECIDE WHERE A FEATURE GOES.
--
-- palm6_anchors reads it to colour its own markers and to print a paste-ready
-- config line. Every other resource still reads its own config, exactly as it
-- did before. A capture becomes real when a human pastes the printed line into
-- the owning config file and the server restarts that resource.
--
-- That is deliberate and it is the whole safety argument. An override table
-- that silently outvoted fifteen audited config files would mean the feature
-- moved while the config still said otherwise, and the next person to read that
-- config would be misled by a file that used to be true. The tool exists to end
-- mystery placements, not to create a second hidden source of them.
--
-- palm6_anchors ships an unused export, GetAnchor(key), returning this row or
-- nil. That is the migration path: one resource at a time can opt in later and
-- be tested on its own.
--
-- ----------------------------------------------------------------------------
-- THE KEY: anchor_key
-- ----------------------------------------------------------------------------
-- The stable key from palm6_anchors/shared/registry.lua. ONE ROW PER ANCHOR: a
-- re-capture REPLACES the previous row, because this table answers "where should
-- this anchor be", not "where has anybody ever stood". The history lives in the
-- server console line printed on every capture.
--
-- RENAMING A REGISTRY KEY ORPHANS ITS ROW. palm6_anchors reports orphans at
-- boot and KEEPS them rather than deleting them: the captured position is the
-- expensive half of the pair, because it took a person walking to the right
-- spot, and it cannot be regenerated from anything in the repo.
--
-- ----------------------------------------------------------------------------
-- THE COLUMNS
-- ----------------------------------------------------------------------------
--   x, y, z     the admin's position, read SERVER-SIDE off their ped at capture
--               time (OneSync makes that authoritative). No value in this table
--               was ever sent by a game client, and palm6_anchors has no net
--               event that accepts a coordinate. A client-supplied number
--               pasted into a config file would be an invented coordinate with
--               extra steps, and inventing coordinates is the rule this project
--               does not break.
--
--   heading     the admin's facing at capture time. Stored for every row and
--               used only by the anchors whose own config writes a vector4
--               (today that is exactly one: palm6_clout Config.PawnshopCoords).
--               For a vector3 or a plain {x,y,z} anchor it is recorded and
--               ignored, which is cheaper than discovering later that it was
--               needed and never kept.
--
--   captured_by   citizenid of whoever captured it, for audit. Nullable: a row
--                 is still valid if that character is later deleted.
--   captured_name a display name at capture time, so a console line and a menu
--                 row can name a person without a second lookup. It is a
--                 SNAPSHOT and is not kept in step with later renames.
--
-- ----------------------------------------------------------------------------
-- SAFE TO LOSE, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- Losing this table costs the captured corrections and nothing else. Every
-- feature keeps working from its own config, because that is what they were
-- reading anyway. palm6_anchors recreates the table empty at boot and the
-- markers fall back to the transcribed config values. Nothing here grants
-- anything, holds money, or gates access.
--
-- The DDL below is duplicated VERBATIM in palm6_anchors/server/main.lua's
-- SCHEMA_SQL, which runs it at boot. Keep the two copies identical.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `palm6_anchor_overrides` (
    anchor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL DEFAULT 0,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_name VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
