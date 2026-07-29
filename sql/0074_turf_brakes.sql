-- ============================================================================
-- 0074_turf_brakes.sql — palm6_turf per-gang contest brakes (TURF CONFLICT v2).
--
-- ⚠️ PICKING THE NEXT MIGRATION NUMBER: do NOT use `ls sql/` and take max+1.
-- The authoritative namespace is resources/[custom]/palm6_dbmigrate/server.lua,
-- which owns numbers that have NO file in sql/ at all (0067 racing, 0068-0069
-- business, 0070-0073 business phase 1/1b). This file was first written as 0067
-- and collided with the racing migrations for exactly that reason. Grep BOTH
-- sql/ and palm6_dbmigrate/server.lua before choosing.
--
-- Closes the last persistence gap in the conflict engine. Three of its four
-- brakes lived only in RAM, so a restart cleared them: a gang that had just
-- started a contest (OpenCooldownSec), a gang that had just been driven off a
-- zone (RepelCooldownSec) and a gang that had just been pinged
-- (NotifyCooldownSec) all got their remaining cooldown cut short by a reboot.
-- The fourth brake, FlipCooldownSec, never had this problem: it is derived from
-- palm6_turf.captured_at, which every flip already writes.
--
-- One row per (brake, gang). `scope` is which brake it is, `gang_key` is who it
-- applies to, `set_at` is the unix second the brake was stamped. The resource
-- computes the remaining cooldown as set_at + <the configured window> - now, so
-- retuning a Config window takes effect immediately on rows already stored
-- rather than being frozen at write time.
--
-- gang_key holds TWO different identities on purpose, told apart by `scope`:
--   open   -> palm6_gangs.id   (immutable; swapping characters inside the gang
--                               must not reset the attacker's own cooldown)
--   repel  -> palm6_gangs.id   (same reason: the LOSING attacker gang pays)
--   notify -> palm6_gangs.name (the notify budget is keyed on the DEFENDING
--                               gang, and turf ownership itself is keyed on the
--                               name, so this side matches what it throttles)
-- They can never collide because `scope` is part of the primary key.
--
-- Rows are DISPOSABLE. Expired rows are swept by the resource, and losing this
-- whole table only costs the brakes their restart-proofing — it can never lock
-- a zone, because nothing here grants anything, it only withholds.
--
-- Named palm6_-prefixed like every other table this layer owns (0013_turf,
-- 0041_gangs), so it cannot collide with a QBCore-ecosystem resource.
--
-- SAFE TO RE-RUN (CREATE TABLE IF NOT EXISTS). The DDL below is duplicated
-- VERBATIM in palm6_turf/server/main.lua's ensureBrakeSchema(), which runs it
-- at boot ONLY when Config.Conflict.Enabled is true, so a box that never turns
-- the feature on never grows the table. Keep the two copies identical.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `palm6_turf_brakes` (
    scope VARCHAR(16) NOT NULL,
    gang_key VARCHAR(64) NOT NULL,
    set_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (scope, gang_key),
    KEY idx_palm6_turf_brakes_scope_set_at (scope, set_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
