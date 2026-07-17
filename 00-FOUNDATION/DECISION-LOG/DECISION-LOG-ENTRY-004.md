# Decision Log Entry 004

**Date:** 2026-07-17
**Decision ID:** DEC-004
**Decision:** Phase 0 — promote the Palm6 Creative System from v0.9.0-rc.1 (Candidate) to
v1.0.0 (Approved), on the strength of the Foundation Review.
**Status:** **PROPOSED — awaiting David's signature (Creative Lead + Project Lead).**
NOT yet Approved. The system remains Candidate (v0.9.0-rc.1) until this entry is signed.
**Owner:** David Olverson (Creative Lead + Project Lead co-signer).
**Basis:** Master Restructuring Plan §4 (Phase 0), tasks 0.1–0.6; the Foundation Review at
`docs/RESTRUCTURING/PHASE-0-FOUNDATION-REVIEW.md`.

## Why this is DEC-004, not "DEC-002"
The system package reserves "DEC-002" for this promotion. gtarp's local DEC-002 is already
the Phase 1 audit, so per the numbering reconciliation in DEC-003 the local promotion is
logged under the next free gtarp id: **DEC-004**.

## What the review found
- **0.1 (docs vs Quality Standards):** all 11 Foundation documents pass, no unresolved
  fail. Promotion-ready as documentation.
- **0.3 (DEC-001 present + formatted):** pass. gtarp's DEC-001 is the Phase 1 (Foundation)
  kickoff (Approved process decision); the Dual Visual System is adopted by reference via
  DESIGN-BIBLE-v1.0 + 05-DUAL-VISUAL-SYSTEM.md, not a standalone local DEC.
- **0.2 (design review + Dual Visual System):** ONE open item — the **System A core
  identity mark does not exist yet** (CD-001), so the "System A reads in one color at 32px"
  gate cannot be verified. System B assets (department crests, state seals) are acceptable
  as Candidate marketing art.

## The decision to be made (pick one, then sign)
- **[ ] Option A — Hold.** Do not promote until the System A mark exists and passes 0.2.
- **[ ] Option B — Promote now on the docs (recommended).** Approve the Creative System at
  v1.0.0 on the documentation, and keep "produce + verify the System A identity mark" as an
  open Candidate item (CD-001) that must close before any System A asset is itself Approved.

## On signing (Option B), the following executes
1. This entry's Status flips to **Approved**, both-lead-signed.
2. Version strings that carry the promotion move to **v1.0.0** (the `-rc` suffix is
   removed only where the promotion applies).
3. The approved Foundation set is copied into `15-VAULT/` and `15-VAULT/README.md` indexed
   (task 0.5).
4. A short unlock note is logged (task 0.6) — retroactive, since gtarp already ran Phase
   1/2 on the Candidate system.
5. gtarp **Phase 3 (Alignment)** is cleared to begin.

## Reasoning
The Foundation is complete and was audited clean (2026-07-15). Promoting on the docs
(Option B) unblocks Phase 3 without overstating the state of the art: the missing System A
mark stays visibly tracked as debt rather than being papered over. Holding (Option A) is
the stricter reading and is also valid if you'd rather the logo exist first.

## Related documents
`docs/RESTRUCTURING/PHASE-0-FOUNDATION-REVIEW.md`; `00-FOUNDATION/07-QUALITY-STANDARDS.md`;
`08-DESIGN-REVIEW-CHECKLIST.md`; `05-DUAL-VISUAL-SYSTEM.md`; DEC-001; DEC-003;
`14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` (CD-001).
