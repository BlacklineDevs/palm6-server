-- ============================================================================
-- palm6_perf/config.lua
--
-- A cheap server-thread hitch sampler. Spends one thread sleeping for
-- SamplePeriodMs and comparing the wallclock delta against the expected
-- delta. Any overshoot >= HitchThresholdMs is recorded; periodic p95/p99
-- summaries are printed and (optionally) pushed to a webhook.
--
-- This resource MUST be cheap to run; it should not itself become the
-- thing it is measuring.
--
-- Overlap note (audited 2026-07-03): no recipe resource duplicates this,
-- but txAdmin natively graphs server-thread tick health. What this adds on
-- top: the Discord webhook hitch alert (p95/p99 past a threshold) and the
-- GetSummary export for in-server consumption. It measures aggregate
-- main-thread stall, not per-resource cost — use resmon/profiler for that.
-- ============================================================================

Config = {}

-- Sleep target. 250ms gives ~240 samples / minute — plenty for stats.
Config.SamplePeriodMs = 250

-- Anything above this is a "hitch".
Config.HitchThresholdMs = 100

-- Report cadence.
Config.ReportEveryMinutes = 5

-- Hitch count in a single report period that triggers a webhook ping.
Config.WebhookHitchThreshold = 5

-- Convar with the perf webhook URL.
Config.WebhookConvar = 'palm6:perf_webhook'

-- Staff diagnostic command (ACE-restricted, needs `command.diag` — granted
-- to group.admin / group.mod in custom.cfg). One line each for: custom
-- resource states, the perf summary, and eventguard violations among online
-- players. Consumes the GetSummary export so the meter is readable in-game,
-- not just in the console report cadence. Set false to disable.
Config.DiagCommand = 'diag'

-- ---------------------------------------------------------------------------
-- Boot schema check (always on).
--
-- One read-only information_schema SELECT at boot, cross-referenced against
-- server/tables.lua, printing a single PASS/MISSING banner. It NEVER blocks
-- startup and NEVER writes: the whole point is to convert "half the economy
-- silently does nothing on this box" into one console line an operator can
-- actually see. Set false only if you have a reason to run blind.
--
-- DELIBERATE CONVENTION DEVIATION: new behaviour in this layer normally ships
-- defaulted OFF so an upgrade is a no-op. This one does not, and that is the
-- point. Its entire value is on a box nobody has diagnosed yet - a fresh
-- install or a restored backup - and an operator in that state has no reason
-- to go and enable a flag they have never heard of, so default-off would make
-- it dead code that only ever runs where it is not needed. The cost of being
-- wrong is bounded to a level a monitoring resource can carry: one SELECT
-- against information_schema, 20s after this resource starts, on its own
-- thread, wrapped in pcall, that prints and exits. No writes, no DDL, no
-- per-table queries, nothing blocked, nothing retried, and it never runs
-- again after boot.
Config.SchemaCheck = true

-- How long to wait after this resource starts before running the check. Must
-- comfortably clear the self-creating resources' own boot threads (palm6_ems,
-- palm6_heat, palm6_lottery, palm6_season, palm6_mapeditor all Wait(3000))
-- and palm6_dbmigrate's Wait(3000) applier, or their tables are reported
-- MISSING purely because we looked too early.
Config.SchemaCheckDelayMs = 20000
