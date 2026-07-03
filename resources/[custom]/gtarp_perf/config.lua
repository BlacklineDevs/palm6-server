-- ============================================================================
-- gtarp_perf/config.lua
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
Config.WebhookConvar = 'gtarp:perf_webhook'
