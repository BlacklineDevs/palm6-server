# Decision Log Entry 003

**Date:** 2026-07-17
**Decision ID:** DEC-003
**Decision:** Execute gtarp Phase 2 (Organization) under the Master Restructuring Plan -
establish the standardized structure + light governance, adopt RFC-001 (metadata
standard), stand up the Asset Registry, record deprecations and creative debt, and
reconcile the local Decision-Log numbering.
**Status:** Approved - Phase 2 substantially complete; one gate item (brand art
placement) remains **Open** and is tracked as creative debt, not a blocker to logging.
**Owner:** David Olverson (Palm6 Creative + Dev Lead)
**Basis:** Palm6 Restructuring Handoff Package v39; Master Restructuring Plan §6 (Phase 2).

## Context
DEC-001 executed Phase 1 (Foundation); DEC-002 recorded the Phase 1 audit + two open
blockers. David directed starting Phase 2 now. Per the Master Plan, gtarp Phase 2's
entry condition is only "Phase 1 complete and logged" - it does **not** require Phase 0
- so Phase 2 proceeds under the **Candidate** Creative System (see the reconciliation
below and `14-OPERATIONS/README.md`).

## What was done (Phase 2, tasks 2.1–2.8)
- **2.1 Inventory → destination map:** `docs/RESTRUCTURING/PHASE-2-INVENTORY-MAP.md`.
  Finding: gtarp already conforms for functional content (FiveM dictates
  `resources/ · sql/ · custom.cfg`), so Phase 2 is additive governance, not code moves.
- **2.2 Structure:** created `01-BRAND/`, `deploy/`, `17-ASSET-REGISTRY/`,
  `14-OPERATIONS/`, `20-TEMPLATES/`. Moved `DEPLOY.md` → `deploy/README.md` (history-
  preserving `git mv`; internal + `docs/TESTING.md` references updated). CI workflows
  intentionally stay in `.github/` (GitHub requirement); `deploy/` documents them.
- **2.3 Metadata RFC:** `19-RFC/RFC-001-resource-and-asset-metadata-standard.md`
  (Approved) - manifest fields, naming, registry granularity, status + license rules.
- **2.4 Asset Registry:** `17-ASSET-REGISTRY/ASSET-REGISTRY.md` populated. All rows
  **Candidate** (nothing auto-Approved), all **non-commercial** (gtarp ships no sellable
  asset). `mystudio_props` flagged: license/ownership must be confirmed before promotion.
- **2.5 Deprecations:** `docs/RESTRUCTURING/PHASE-2-DEPRECATIONS.md` - `prop_spawn`
  deprecated + neutralized (registry: Archived); nothing deleted (code is live).
- **2.6 Brand:** `01-BRAND/` scaffold + guidelines placed. David supplied Palm6
  **department emblems (System B)** during Phase 2 - an initial 6, then the full set of
  **24 department crests + 2 Verano state seals** (follow-up brand commit) - now sorted
  into `01-BRAND/logos/departments/` + `01-BRAND/logos/state/`, cataloged, and registered
  (Candidate). The rejected private-business logo tier is NOT committed (CD-006). **Still
  open:** the System A core identity mark (a different asset class) is not yet supplied.
  Tracked as CD-001 (downgraded High → Medium).
- **2.7 Creative debt:** `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` - CD-001…CD-006.
- **2.8 Log + commit:** this entry; branch pushed with scoped commits.

## Decision Log numbering reconciliation (resolves the DEC-002 collision)
The system package reserves **DEC-002** for the Creative System rc.1 → v1.0.0 promotion
(a Phase 0 output). gtarp's local **DEC-002** is already used for the Phase 1 audit.
**Ruling:** gtarp's local Decision Log is authoritative for this repo and will **not**
renumber already-logged entries. Copied system docs that say "DEC-002 (promotion)" refer
to the *system's own* log. If/when gtarp runs Phase 0, the local promotion is logged
under the next free gtarp DEC id (not DEC-002). Recorded in `14-OPERATIONS/README.md`.

## Phase 2 Quality Gate status
- ✅ Structure matches the Master Plan §2.2 target (all target folders present except
  `resources/[core]/`, which is intentionally absent - Palm6 overrides no framework files,
  so FiveM never creates that group; documented in PHASE-2-INVENTORY-MAP.md).
- ✅ At least one metadata RFC logged (RFC-001, Approved).
- ✅ Assets registered with correct ladder status.
- ✅ Builds/runs cleanly - additive/docs-only + one doc move; no `resources/`, `sql/`,
  or `custom.cfg` change, so FiveM load behavior is unaffected.
- ⚠️ **Open:** brand art not yet placed (CD-001). The brand half of task 2.6 completes
  when David's assets are sorted into `01-BRAND/logos/` and registered.

## Still open (owner rulings, not Phase 2 blockers)
- **DEC-002a** (canonical Website + Commercial Scripts repos) - gates the *downstream*
  repos, not gtarp. Tracked CD-004.
- **DEC-002b** (undefined "Phase 4 / Phase 6" gates) - **resolved by the v39 spec**
  itself (Master Plan rule #9: no Phase 4/5/6; Cross-Repo Consistency Pass replaces the
  old "Phase 6"). No local action beyond noting it here.
- **Phase 0** (promote the Creative System to v1.0.0) - required before gtarp Phase 3;
  tracked CD-005.

## Related documents
`RESTRUCTURING-PLANS/MASTER-RESTRUCTURING-PLAN.md` §6; `19-RFC/RFC-001`;
`17-ASSET-REGISTRY/ASSET-REGISTRY.md`; `14-OPERATIONS/README.md` +
`CREATIVE-DEBT-TRACKING.md`; `docs/RESTRUCTURING/PHASE-2-INVENTORY-MAP.md` +
`PHASE-2-DEPRECATIONS.md`.
