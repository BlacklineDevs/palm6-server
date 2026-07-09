-- ============================================================================
-- gtarp_economy/shared/config.lua — engine-agnostic tunables (Tier 1).
--
-- DESIGN INTENT — the operator's-eye view of the crime economy. Every crime
-- resource exposes a GetSummary() export; this resource aggregates them into
-- one staff readout so David/staff can see, live, whether the dirty-money
-- economy is healthy: how much dirty money each source has minted, how much
-- the laundromat has washed and police have forfeited, and the rough net still
-- in circulation. The "ship the meter" rule applied at the ECOSYSTEM level.
--
-- Read-only. Calls only sibling GetSummary() exports — no DB, no writes, no new
-- table. Tuning the economy happens in each resource's own config; this just
-- shows you the scoreboard.
-- ============================================================================
Config = {}

-- Staff command (ACE-restricted — needs `command.economy`, granted to
-- group.admin + group.mod in custom.cfg, same as gtarp_perf's /diag).
Config.Command = 'economy'
