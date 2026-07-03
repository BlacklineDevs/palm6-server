# STAFF — gtarp staff matrix

This document describes the staff hierarchy, the ACE groups each role
belongs to, and the commands each can run. Source of truth: ACE grants in
`custom.cfg` + the principal mappings each operator applies in their
recipe-generated `server.cfg`.

## Groups

| Group           | Purpose                                                              |
|-----------------|----------------------------------------------------------------------|
| `group.owner`   | Full server access. Maps to txAdmin owner principal as well.         |
| `group.admin`   | Day-to-day admins. All staff commands + setjob.                      |
| `group.mod`     | Moderators. Player-management commands only — no setjob, no economy. |
| `group.trial`   | Trial moderators. Read-only logging + `/coords` lookups.             |
| `group.eup`     | Whitelisted-services roster — non-staff. Allowed to /setjob          |
|                 | their assigned emergency-services job.                               |

## Command matrix

All player-management commands are the RECIPE's own (qbx_core `/tp` `/tpm`,
qbx_medical `/revive` `/heal`, qbx_adminmenu's `/admin` menu for
goto/bring/spectate/etc.) — gtarp_staff's duplicate registrations were
removed 2026-07-03 because they collided with and overrode the recipe
handlers. The recipe restricts these to `group.admin`; the `custom.cfg` ACE
matrix is what extends `/tp` `/tpm` `/revive` `/heal` to `group.mod`.

| Command                     | owner | admin | mod | trial |
|-----------------------------|:-----:|:-----:|:---:|:-----:|
| `/coords`                   |   y   |   y   |  y  |   y   |
| `/serverinfo`               |   y   |   y   |  y  |   y   |
| `/tp` (qbx_core)            |   y   |   y   |  y  |       |
| `/tpm` (qbx_core)           |   y   |   y   |  y  |       |
| `/revive` (qbx_medical)     |   y   |   y   |  y  |       |
| `/heal` (qbx_medical)       |   y   |   y   |  y  |       |
| `/admin` menu (qbx_adminmenu — goto/bring/spectate/…) | y | y | per its config | |
| `/setjob`                   |   y   |   y   |     |       |
| `/giveitem`                 |   y   |   y   |     |       |

## ACE wiring

ACEs are granted by `custom.cfg`. To enrol a player, add to your
recipe-generated `server.cfg`:

```
add_principal identifier.license:CHANGEME group.admin
add_principal identifier.discord:000000000000000000 group.mod
```

Inheritance is left flat — no `add_principal group.admin group.mod`-style
nesting — so removing a principal from `group.admin` does not
accidentally strip lower-tier access.

## Audit log

Staff/security actions logged through `exports.gtarp_staff:Log(...)`
(allowlist denials, eventguard violations, pumpcoin rug reveals, …) are
written to the `audit_log` table
(`sql/0007_staff_log.sql`) and posted to the Discord webhook configured
via the `gtarp:staff_webhook` convar. The webhook URL is a secret-grade
value and must be set in txAdmin's secret store, never committed.

Querying recent staff activity:

```sql
SELECT created_at, action, actor_name, target_name, detail
FROM audit_log
ORDER BY created_at DESC
LIMIT 50;
```
