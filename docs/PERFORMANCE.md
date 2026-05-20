# PERFORMANCE — gtarp budget and tuning

## Targets (48-slot, mid-spec client)

| Metric                        | Target            |
|-------------------------------|-------------------|
| Total custom-layer resmon     | < 1.5 ms          |
| Per-resource resmon           | < 0.30 ms         |
| Server p95 frame              | < 50 ms           |
| Server p99 frame              | < 80 ms           |
| Client FPS floor (mid-spec)   | >= 50 FPS         |
| Hitches per 30 minutes        | < 5               |

A breach of the p95/p99 numbers across two consecutive sample windows is
a regression — open a ticket against whichever resource is the loudest in
resmon at the time of the breach.

## Resmon snapshot (under load — verified pre-launch)

Staff runs the following before opening the server:

1. Spin up ~30 player slots via stress test (or scheduled invite event).
2. Open `resmon` in the F8 console.
3. Sort by tick; screenshot.
4. Compare against the table below. Adjust budgets only if a change here
   is committed alongside the resource change.

| Resource                | Budget    |
|-------------------------|-----------|
| qbx_core_overrides      | < 0.05 ms |
| qbx_economy_overrides   | < 0.05 ms |
| qbx_police_overrides    | < 0.05 ms |
| qbx_ambulance_overrides | < 0.05 ms |
| qbx_civilian_jobs_overrides | < 0.05 ms |
| ox_inventory_overrides  | < 0.05 ms |
| gtarp_whitelist_jobs    | < 0.05 ms |
| gtarp_staff             | < 0.05 ms |
| gtarp_eventguard        | < 0.10 ms |
| gtarp_allowlist         | < 0.05 ms |
| gtarp_courier           | < 0.20 ms |
| gtarp_perf              | < 0.05 ms |
| server_identity         | < 0.10 ms |
| server_base             | < 0.05 ms |

## Self-imposed rules

- No `CreateThread { while true; Wait(0) ... }` anywhere in the custom
  layer. `Wait(0)` is only acceptable as a single yield during a
  blocking section (e.g. waiting for `IsScreenFadedOut`). Document each
  exception with a comment that includes the word "Wait(0)" and "yield".
- `gtarp_perf` itself uses `Wait(250)` for sampling and `Wait(5*60_000)`
  for reporting.
- The eventguard `now()` table is pruned synchronously inside `prune()`
  rather than swept on a background thread.

## Disabling unused recipe resources

Add to `custom.cfg` (commented examples):

```
# set sv_disableresource old_phone_resource
# set sv_disableresource unused_minigame
```

Trim what you do not need. Every disabled resource is wall-clock budget
you keep.

## Webhook

Set `gtarp:perf_webhook` in txAdmin's secret store to receive alerts when
`Config.WebhookHitchThreshold` hitches are seen in a report window.
