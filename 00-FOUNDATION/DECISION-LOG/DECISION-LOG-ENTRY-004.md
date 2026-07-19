# Decision Log Entry 004

**Date:** 2026-07-18
**Decision ID:** DEC-004
**Decision:** Phase 0, promote the Palm6 Creative System from v0.9.0-rc.1 (Candidate) to
v1.0.0 (Approved) via **Option B**, on the strength of the audited Foundation Review.
**Status:** **APPROVED (Option B).** The Creative System is Approved at v1.0.0 on its
documentation. The System A core identity mark does not yet exist and is carried as tracked
debt (CD-001); it stays Candidate and is NOT promoted by this entry.
**Owner:** David Olverson (Palm6 Creative + Project Lead).
**Authorization:** Explicit session directive from David, 2026-07-18 (finalize DEC-004 as
Approved via Option B, unlock Phase 3).
**Basis:** Master Restructuring Plan §4 (Phase 0), tasks 0.1 to 0.6; the Foundation Review
at `docs/RESTRUCTURING/PHASE-0-FOUNDATION-REVIEW.md`.

## Why this is DEC-004, not "DEC-002"
The system package reserves "DEC-002" for this Creative System promotion (a Phase 0 output).
gtarp's local DEC-002 is already the Phase 1 post-execution audit, so per the numbering
reconciliation ruled in DEC-003 the local promotion is logged under the next free gtarp id:
**DEC-004**. Cross-reference: the plan's "DEC-002 (promotion)" and this entry (gtarp DEC-004)
are the same decision, logged once in each authoritative log. gtarp does not renumber
already-logged entries (see DEC-003 and `14-OPERATIONS/README.md`).

## What the review found (recap)
- **0.1 (docs vs Quality Standards):** all 11 Foundation documents pass, no unresolved fail.
  Promotion-ready as documentation.
- **0.3 (DEC-001 present + formatted):** pass. gtarp's DEC-001 is the Phase 1 (Foundation)
  kickoff (Approved process decision); the Dual Visual System is adopted by reference via
  `DESIGN-BIBLE-v1.0` + `05-DUAL-VISUAL-SYSTEM.md`.
- **0.2 (design review + Dual Visual System):** ONE open item, the **System A core identity
  mark does not exist yet** (CD-001), so the "System A reads in one color at 32px" gate
  cannot be verified against a mark that does not exist. System B assets (24 department
  crests, 2 Verano state seals) are acceptable as Candidate marketing art.

## The ruling: Option B (Approved)
David selected **Option B, promote now on the audited documentation.** The Foundation docs
are complete and were audited clean (handoff-package audit, 2026-07-15). The Creative System
is Approved at v1.0.0 on that basis. The missing System A identity mark stays visibly tracked
as debt (CD-001) rather than being papered over. Holding (Option A) was the stricter reading
and was declined in favor of unblocking Phase 3 now.

## Rationale
- Promotion rests on the **documentation set**, which is complete and audited, not on any
  System-A-dependent asset.
- The System A core identity mark is carried as **tracked creative debt CD-001**. It remains
  Candidate.
- The strict System A gate (**reads in one color, legible at 32px, no effects, ownable,
  timeless**) is undisturbed by this promotion. It still governs any future System A asset,
  which must pass that gate and clear CD-001 before that asset is itself marked Approved.

## What this entry authorizes (executes on this signature)
1. **Version bump:** the Creative System package moves from **v0.9.0-rc.1 (Candidate) to
   v1.0.0 (Approved)**. Concretely, the promoted Foundation governance documents have their
   per-file header `**Version:** v0.1.0` bumped to `**Version:** v1.0.0` (v0.1.0 was the
   per-file draft version, not an `-rc.1` suffix, so nothing is "stripped"; the version is
   raised to the promoted system version).
2. **Doc status flips Draft to Approved** across the promoted Foundation governance set:
   `00-MASTER-STRUCTURE-GUIDE`, `01-DESIGN-MANIFESTO`, `03-PROJECT-PRINCIPLES`, `04-NORTH-STAR`,
   `05-DUAL-VISUAL-SYSTEM`, `06-BRAND-PYRAMID`, `07-QUALITY-STANDARDS`, `08-DESIGN-REVIEW-CHECKLIST`,
   and `09-DECISION-LOG` (9 docs) move from `Draft - Under Review` to `Approved v1.0.0`.
   `DESIGN-BIBLE-v1.0` was already Approved.
   **Exceptions that stay Candidate (visual-dependent, not documentation):** (a) the System A
   core identity mark, which does not exist yet, tracked as CD-001; and (b) `COLOR-SYSTEM.md`,
   which self-declares "awaiting final visual refinement and locking" and is tracked as CD-008.
   Promoting either would be a fake-approval, so both are deliberately held. Every logo /
   System-A-dependent asset likewise stays Candidate until its own Decision Log entry.
3. **Vault the snapshot (task 0.5):** the approved Foundation set is frozen into `15-VAULT/`
   and indexed in `15-VAULT/README.md` as the v1.0.0 Foundation snapshot.
4. **Mark Phase 0 executed (task 0.6):** the project-level Creative System Approval Gate is
   recorded as run once. This is retroactive, since gtarp already ran Phase 1 and Phase 2 on
   the Candidate system (allowed: their entry conditions do not require Phase 0).
5. **Unlock:** gtarp **Phase 3 (Alignment & Governance)** is cleared to begin. This also
   closes the "Phase 0 required before Phase 3" debt (CD-005).

## Phase model note
Canonical phases: Phase 0 (Creative System Approval Gate, project-level, run once), Phase 1
(Foundation), Phase 2 (Organization), Phase 3 (Alignment & Governance). A single Cross-Repo
Consistency Pass runs once after all repos finish Phase 3. There is no Phase 4, 5, or 6.

## What this does NOT do
- It does **not** approve any System A asset. The System A core identity mark stays Candidate
  under CD-001; the 32px / one-color gate is unwaived and unmet for System A.
- It does **not** touch `resources/**`, `sql/**`, or `custom.cfg`. There is no code change and
  no deploy; FiveM load behavior is unaffected.
- It is **additive and reversible**: documentation status, a version string, and a vaulted
  snapshot only. Reverting is a doc-status change, not a code rollback.

## Related documents
`docs/RESTRUCTURING/PHASE-0-FOUNDATION-REVIEW.md`; `00-FOUNDATION/07-QUALITY-STANDARDS.md`;
`00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`; `00-FOUNDATION/05-DUAL-VISUAL-SYSTEM.md`;
`00-FOUNDATION/COLOR-SYSTEM.md` (held, CD-008); `00-FOUNDATION/DESIGN-BIBLE-v1.0.md`;
`01-BRAND/SYSTEM-A-CORE-MARK-BRIEF.md` (CD-001 execution path); `15-VAULT/README.md`;
DEC-001; DEC-003; DEC-005; `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` (CD-001, CD-005 closed
here, CD-008 new); `14-OPERATIONS/README.md`.
