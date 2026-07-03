# SECURITY — gtarp threat model and hardening

## Scope

This document covers the threats `gtarp_eventguard` and the convars in
`custom.cfg` mitigate. It is a small-server threat model — not a
production replacement for txAdmin's own anticheat layer.

## Threats considered

| # | Threat                                            | Mitigation                                     |
|---|---------------------------------------------------|------------------------------------------------|
| 1 | Client-script injection (request-control flood)   | `sv_filterRequestControl 2` in custom.cfg      |
| 2 | Native scripthook hooks (mod menus)               | `sv_scriptHookAllowed 0`                       |
| 3 | Client-dictated money mutation                    | Structural: qbx_core money is server-authoritative (`AddMoney`/`RemoveMoney` only — no client-triggerable money net event exists; eventguard's legacy `QBCore:Server:UpdateMoney` guard was inert and removed 2026-07-03) |
| 4 | Spam of inventory open / shop transactions        | ox_inventory's own per-event validation (`Utils.LogExploit`) + ratelimit (`gtarp_eventguard`) |
| 5 | Spam of custom courier events                     | Ratelimit (`gtarp_eventguard`)                 |
| 6 | Long-lived suspicious sessions                    | 3-strike kick (`Config.KickThreshold`)         |
| 7 | Coord spoofing / off-map vehicles                 | `onesync_distanceCullVehicles true`            |
| 8 | Trust-mismatch joins                              | `sv_authMaxVariance 1` / `sv_authMinTrust 5`   |

## Out of scope

- Webhooks / external scraping. Treat the staff webhook URL as a secret
  and rotate when compromised.
- DDoS / network-layer abuse. Handled upstream (cloud provider, OVH game
  routing, etc.).
- Replay of in-character harassment. Handled by staff matrix
  (`docs/STAFF.md`).

## Auditing

Every breach lands in `event_violations` (sql/0008_security_events.sql)
and is also written to `audit_log` via the `gtarp_staff:Log` export.

```sql
SELECT created_at, event_name, COUNT(*) AS hits, identifier
FROM event_violations
WHERE created_at > NOW() - INTERVAL 1 DAY
GROUP BY identifier, event_name
ORDER BY hits DESC;
```

## Tuning

- If a legitimate gameplay loop trips a guard, raise `calls` (not
  `window_seconds`) in `gtarp_eventguard/config.lua` first.
- Never set a guard to ridiculous limits (calls > 100/sec); if you must,
  log it as a temporary override in this file's changelog.
