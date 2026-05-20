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

| Command         | owner | admin | mod | trial |
|-----------------|:-----:|:-----:|:---:|:-----:|
| `/coords`       |   y   |   y   |  y  |   y   |
| `/serverinfo`   |   y   |   y   |  y  |   y   |
| `/tp`, `/goto`  |   y   |   y   |  y  |       |
| `/tpm`          |   y   |   y   |  y  |       |
| `/bring`        |   y   |   y   |  y  |       |
| `/revive`       |   y   |   y   |  y  |       |
| `/heal`         |   y   |   y   |  y  |       |
| `/setjob`       |   y   |   y   |     |       |
| `/giveitem`     |   y   |   y   |     |       |
| `/staff_log`    |   y   |   y   |     |       |

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

Every staff command is written to the `audit_log` table
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
