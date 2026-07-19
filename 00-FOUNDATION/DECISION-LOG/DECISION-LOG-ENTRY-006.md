# Decision Log Entry 006

**Date:** 2026-07-18
**Decision ID:** DEC-006
**Decision:** Execute gtarp Phase 3 (Alignment and Governance), tasks 3.1 to 3.7; end
migration mode and enter steady-state; schedule the task 3.8 post-phase review.
**Status:** Approved. Tasks 3.1 to 3.7 executed. Phase 3 is NOT formally complete: the
task 3.8 post-phase review (scheduled 2026-08-15 to 2026-09-12) is the completion gate, and
the gtarp -> Website handoff stays locked until it passes.
**Owner:** David Olverson (Palm6 Creative + Dev + Project Lead).
**Authorization:** Explicit session directive from David, 2026-07-18 ("do the full phase").
**Basis:** Master Restructuring Plan Section 7 (Phase 3). Unlocked by DEC-004 (Phase 0
promotion, Option B). Phase 3 is governance and process only; it touches no `resources/**`,
`sql/`, or `custom.cfg`, so there is no code change and no deploy.

## What this entry records

Phase 3 makes the approved Creative System (v1.0.0, DEC-004) the enforced, normal way of
working in gtarp, then transitions the repository out of migration mode. Full task-by-task
evidence is in `docs/RESTRUCTURING/PHASE-3-ALIGNMENT.md`.

- **3.1 Enforcement:** `CONTRIBUTING.md` routes all new work through the design-review
  checklist, Quality Standards, and Dual Visual System; the migration-mode banner is removed.
- **3.2 RFC + Decision Log standard:** documented and in active use (RFC-001, DEC-003..006).
- **3.3 Version-control discipline:** `14-OPERATIONS/VERSION-CONTROL.md` adopted; asset
  versioning expressed via registry status + promoting Decision Log ID + the vault snapshot.
- **3.4 Creative debt:** every open item (CD-001, CD-002, CD-003, CD-006, CD-007, CD-008)
  has an owner and a scheduled date; CD-004 and CD-005 closed by DEC-005 and DEC-004.
- **3.5 Promote + Vault:** Foundation set already Approved and vaulted (DEC-004); brand
  assets remain Candidate (no System A mark yet); ladder respected.
- **3.6 Transition to steady-state:** `14-OPERATIONS/TRANSITION-TO-STEADY-STATE.md`;
  migration mode formally ended 2026-07-18.
- **3.7 Ownership matrix:** `14-OPERATIONS/OWNERSHIP-MATRIX.md` (gtarp-specific).
- **3.8 Post-phase review:** scheduled 2026-08-15 to 2026-09-12; tracked in
  `docs/RESTRUCTURING/PHASE-3-COMPLETION-REPORT.md`.

## DEC-005 execution follow-up (repo identities)

DEC-005 fixed the canonical Commercial Scripts repo as `BlacklineDevs/palm6-scripts` and
noted it as a deferred create. In this session the real scripts repo (formerly
`BlacklineDevs/GTARPScripts-`, holding `civcore-npc-pro` and `release`) was **renamed to
`BlacklineDevs/palm6-scripts`**, so the canonical name now points at real content and GitHub
redirects preserve the old URL. The empty placeholder created earlier was renamed aside to
`BlacklineDevs/palm6-scripts-old-placeholder` and is pending deletion by David (the working
token lacks `delete_repo` scope). This is tracked as CD-007-adjacent cleanup in
`14-OPERATIONS/CREATIVE-DEBT-TRACKING.md`.

## What this does NOT do

- It does **not** formally complete Phase 3. The task 3.8 review is the completion gate.
- It does **not** unlock the Website phase yet. That handoff opens only after 3.8 passes.
- It does **not** touch `resources/**`, `sql/`, or `custom.cfg`. No deploy, no server impact.
- It does **not** promote any System A / logo-dependent asset. The System A core mark stays
  Candidate under CD-001.

## Related documents

`docs/RESTRUCTURING/PHASE-3-ALIGNMENT.md`; `14-OPERATIONS/TRANSITION-TO-STEADY-STATE.md`;
`14-OPERATIONS/OWNERSHIP-MATRIX.md`; `docs/RESTRUCTURING/PHASE-3-COMPLETION-REPORT.md`;
`CONTRIBUTING.md`; `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md`; DEC-004; DEC-005.
