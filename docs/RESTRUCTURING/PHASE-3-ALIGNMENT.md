# Phase 3: Alignment and Governance (gtarp)

**Version:** v1.0.0
**Status:** Tasks 3.1 to 3.7 executed 2026-07-18. Task 3.8 (post-phase review) scheduled;
Phase 3 is NOT formally complete until that review passes.
**Owner:** Creative Lead (governance culture), Dev Lead (in-repo enforcement).
**Basis:** Master Restructuring Plan Section 7 (Phase 3, tasks 3.1 to 3.8). Unlocked by
DEC-004 (Phase 0 promotion, Option B, 2026-07-18). Logged as DEC-006.

---

## What Phase 3 is

Phase 3 makes the approved Creative System (v1.0.0, DEC-004) the normal, enforced way of
working in gtarp, then transitions the repository out of migration mode into steady-state.
It is governance and process, not code: no task in this phase touches `resources/**`, `sql/`,
or `custom.cfg`, so nothing here deploys or affects the live server.

An important honesty note up front: the Phase 3 quality gate requires the lightweight
post-phase review (task 3.8), held 4 to 8 weeks after this work, to pass before Phase 3 is
declared complete. That review is definitionally in the future. This document executes the
actionable tasks (3.1 to 3.7) and schedules 3.8. Until 3.8 passes, the gtarp -> Website
handoff stays locked.

---

## Task-by-task execution

### 3.1 Enforce the Dual Visual System, Brand Guidelines, and Quality Standards on new work
- **Done.** `CONTRIBUTING.md` is the enforcement front door: every new resource and every
  brand/creative asset is routed through the design-review checklist
  (`00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`), the Quality Standards
  (`00-FOUNDATION/07-QUALITY-STANDARDS.md`), and the Dual Visual System split
  (`00-FOUNDATION/05-DUAL-VISUAL-SYSTEM.md`). CONTRIBUTING was updated in this phase to
  drop the migration-mode "Candidate until Phase 0" banner (Phase 0 is now signed) and to
  state the enforcement gate as standing policy.
- **Gate:** no new work merges without passing the design-review checklist. For a solo
  operator this is a self-review discipline recorded against the checklist, not a second
  reviewer.

### 3.2 Make the RFC + Decision Log the standard process for changes
- **Done.** The RFC process (`14-OPERATIONS/RFC-PROCESS.md`, `19-RFC/RFC-TEMPLATE.md`) and
  the Decision Log (`00-FOUNDATION/09-DECISION-LOG.md` + `DECISION-LOG/` entries) are the
  standard path for non-trivial change, wired into CONTRIBUTING.
- **Demonstrated non-trivial change through the full flow:** RFC-001 (resource + asset
  metadata standard, Approved in Phase 2) and the DEC-003 through DEC-006 chain show the
  process in active use, not merely described. Phase 3 itself is logged as DEC-006.

### 3.3 Adopt version-control discipline for creative assets
- **Done.** `14-OPERATIONS/VERSION-CONTROL.md` is the standard and is referenced from
  CONTRIBUTING. Asset versioning is expressed through the ladder status in
  `17-ASSET-REGISTRY/ASSET-REGISTRY.md` plus the Decision Log ID that promotes an asset,
  and through the frozen snapshot in `15-VAULT/v1.0.0/` (Foundation set, DEC-004).

### 3.4 Resolve or schedule the creative debt logged in Phase 2
- **Done.** `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` updated so every open item (CD-001,
  CD-002, CD-003, CD-006, CD-007, CD-008) carries an owner and a scheduled target date.
  CD-004 and CD-005 were closed by DEC-005 and DEC-004. No high-severity debt is left
  unscheduled. CD-001 (System A core mark) is the only item that gates a later step and it
  has an owner (David) and an execution path (`01-BRAND/SYSTEM-A-CORE-MARK-BRIEF.md`,
  prompts emailed 2026-07-18).

### 3.5 Promote qualifying assets to Approved and Vault them
- **Done for what qualifies.** The Foundation governance set was promoted to Approved
  v1.0.0 and frozen into `15-VAULT/v1.0.0/00-FOUNDATION/` under DEC-004. No brand asset is
  promoted here: the 24 department crests and 2 Verano seals remain Candidate (System B
  marketing art, acceptable as Candidate), and no System A asset exists yet (CD-001). The
  ladder is respected; nothing enters the Vault without an Approved Decision Log entry.

### 3.6 Execute the Transition to Steady-State Protocol (end migration mode)
- **Done.** See `14-OPERATIONS/TRANSITION-TO-STEADY-STATE.md`. Migration mode is formally
  ended for gtarp as of 2026-07-18. All new work follows the full approved Creative System
  as the default, with no migration exceptions. The post-phase review (Step 7 of the
  protocol) is the confirmation gate and is scheduled below.

### 3.7 Update the ownership matrix
- **Done.** See `14-OPERATIONS/OWNERSHIP-MATRIX.md`, the gtarp-specific alignment of the
  project ownership matrix. David currently holds all lead roles (Creative, Dev, Project;
  Design applies to the Website repo), recorded honestly rather than inventing separate
  owners. Escalation path and review cadence are explicit.

### 3.8 Lightweight post-phase review (4 to 8 weeks later)
- **Scheduled, not yet done.** Window: **2026-08-15 to 2026-09-12**. It will use
  `20-TEMPLATES/PHASE-COMPLETION-REPORT-TEMPLATE.md` and confirm steady-state held (the
  Creative System is being followed without active enforcement pressure). Tracked as the
  open item in `docs/RESTRUCTURING/PHASE-3-COMPLETION-REPORT.md`.

---

## Phase 3 status

- Tasks 3.1 to 3.7: **executed and logged (DEC-006, 2026-07-18).**
- Task 3.8: **scheduled** for the 2026-08-15 to 2026-09-12 window.
- gtarp is now in **steady-state operations, pending post-phase confirmation.**
- The gtarp -> Website handoff **stays locked** until 3.8 passes (Master Plan Section 3).

This is the honest end state: everything that can be done now is done; the one remaining
task is a scheduled observation-window review that cannot be compressed.
