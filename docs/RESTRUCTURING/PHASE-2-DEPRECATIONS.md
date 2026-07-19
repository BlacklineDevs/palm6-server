# gtarp Phase 2 - Deprecations

Version: v0.9.0-rc.1 (Release Candidate)
Status: Phase 2 (Organization) task 2.5 deliverable. Records legacy/ad-hoc patterns
identified during the reorganization. **Deprecate, do not delete** while code is live.

Phase 2 rule: no working functionality is lost. Items here are marked deprecated with a
migration note; removal happens only when it is safe and (where relevant) panel access
allows it.

---

## D-001 - `resources/[custom]/prop_spawn` (dev-only test helper)
- **Status:** Deprecated, neutralized in production. **Do not delete yet.**
- **Why:** Dev-only helper with ungated networked `CreateObject` (`/prop /crate
  /clearprops`) - a grief vector if live. It is stopped in prod via `stop prop_spawn`
  in `custom.cfg` (which execs after the panel's root `server.cfg` ensures it; that
  root cfg is outside this repo and cannot be edited here).
- **Migration path:** When panel access is available, remove the `ensure prop_spawn`
  from the root `server.cfg`, then delete/relocate the resource and drop the `stop`
  line from `custom.cfg`. Tracked as **CD-002** in `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md`.
- **Registry:** listed as **Archived (deprecated)** in `17-ASSET-REGISTRY/ASSET-REGISTRY.md`.

## Reviewed, NOT deprecated (kept intentionally)
- `server_base`, `server_identity`, `[config_overrides]` - base server/config resources,
  live and required. Non-`palm6_` prefix is expected (base layer), exempt per RFC-001.
- `mystudio_props` - a live prop resource. **Not** deprecated, but its **license/ownership
  must be confirmed** before any Approved/commercial status (registry flags this).
- `palm6_devtest` - dev/test resource kept for in-repo verification. Not shipped-facing;
  leave as-is (no grief surface like prop_spawn had). Revisit at Phase 3.

## Naming / structure hygiene
- No duplicate top-level folders found. `sql/` migrations are sequential and append-only.
- Custom resources consistently use the `palm6_<domain>` convention (RFC-001); no ad-hoc
  renames needed this phase.
