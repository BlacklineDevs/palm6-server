-- ============================================================================
-- gtarp_evidence/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
--
-- The Phase 6 roadmap candidate "evidence-locker workflow extension for
-- police" (docs/BUILD-ROADMAP.md) — never built. Confirmed non-duplicative:
-- no evidence/case-log resource exists anywhere in the deployed recipe tree.
-- ============================================================================
Config = {}

Config.Debug = false

Config.InteractRadius = 2.0

-- Evidence locker location. Matches qbx_police's own Mission Row station
-- coords (config/shared.lua locations.duty[1]) — not our vestigial
-- qbx_police_overrides.Config.Armoury, which that resource's own comment
-- says goes unused ("Not currently used, use ox_inventory shops").
Config.LockerCoords = vector3(434.0, -983.0, 30.7)

Config.LockerSlots = 100
Config.LockerMaxWeight = 500000

-- How many recent entries `/evidence` shows.
Config.LogEntryLimit = 15

-- ---------------------------------------------------------------------------
-- v2 — case files + suspect linkage
-- ---------------------------------------------------------------------------

-- How many cases `/evidence cases` and `/evidence suspect <cid>` list.
Config.CaseListLimit = 15

-- How many entries a case detail view (`/evidence case <id>` / GetCase) returns.
Config.CaseEntryLimit = 30

-- Max lengths for player-supplied text (server-side clamps).
Config.CaseTitleMax = 100
Config.EntryMax = 1000

-- Server-side command cooldowns (ms) — evidence commands are spammable.
Config.WriteCooldownMs = 2000
Config.ReadCooldownMs = 1000
