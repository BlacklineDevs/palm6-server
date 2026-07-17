# Decision Log Entry Template

**Version:** v0.9.0-rc.1 (Release Candidate)
**Status:** Release Candidate, Ready for Execution
**Owner:** Palm6 Creative System

---

## Purpose

This is the canonical copy-paste template for a single Decision Log entry. Its fields and ordering match `00-FOUNDATION/09-DECISION-LOG.md` exactly. Use it any time a decision needs to be recorded so that the log stays consistent and machine-readable over time.

The governing rule of the Creative System is preserved here: nothing is "Approved" without a corresponding Decision Log entry. If a decision is not written down, it did not happen.

---

## Usage Note

1. Copy the block under "Template" below.
2. Paste it as a new entry into `00-FOUNDATION/09-DECISION-LOG.md`, in chronological order, beneath the most recent entry.
3. Fill every field. Do not leave a field blank. If a field does not apply, write "None" so the omission is intentional and visible.
4. Assign the next sequential Decision ID. DEC-001 (Dual Visual System) is already recorded as Approved. DEC-002 (promotion of the Creative System from v0.9.0-rc.1 to v1.0.0) is created during Phase 0, the Creative System Approval Gate. Continue from the highest existing ID.
5. Use the date format YYYY-MM-DD.
6. Set Status to exactly one of: Approved, Rejected, or Deferred.
7. In Related Documents, reference files by their exact manifest names (for example `05-DUAL-VISUAL-SYSTEM.md`, `07-QUALITY-STANDARDS.md`, `08-DESIGN-REVIEW-CHECKLIST.md`).
8. Do not edit or delete a recorded entry. If a decision is superseded, add a new entry that references the earlier Decision ID and change the earlier entry's Status only if it is now Rejected or Deferred.

---

## Field Reference

| Field | Requirement |
|---|---|
| Date | Date the decision was finalized, in YYYY-MM-DD format. |
| Decision ID | Next sequential identifier, formatted DEC-XXX with zero-padding (DEC-003, DEC-014). |
| Topic | Short, specific subject line (for example, Primary Logo Direction, Color Palette Lock). |
| Decision Made | The decision itself, stated plainly and unambiguously. |
| Reasoning | Why this decision was made, including the alternatives considered and rejected. |
| Impact Areas | The parts of the system, repos, or workflow this decision affects. |
| Status | Approved, Rejected, or Deferred. |
| Related Documents | Exact filenames of documents that support or are changed by this decision. |

---

## Template

Copy from here.

```
**Date:** YYYY-MM-DD  
**Decision ID:** DEC-XXX  
**Topic:**  
**Decision Made:**  
**Reasoning:**  
**Impact Areas:**  
**Status:** Approved / Rejected / Deferred  
**Related Documents:**  
```

Copy to here.

---

## Worked Example

The entry below shows a completed record. It matches the example already present in `09-DECISION-LOG.md`.

```
**Date:** 2026-07-12  
**Decision ID:** DEC-001  
**Topic:** Dual Visual System  
**Decision Made:** Palm6 will use two distinct systems. System A (Identity) for logos and official branding, and System B (Marketing) for cinematic and emotional assets.  
**Reasoning:** Prevents the logo from having to carry all emotional weight. Allows a clean, timeless identity while still delivering cinematic marketing.  
**Impact Areas:** Logo design, marketing assets, UI, world-building consistency  
**Status:** Approved  
**Related Documents:** 05-DUAL-VISUAL-SYSTEM.md
```

---

## Related Documents

- `09-DECISION-LOG.md` (canonical log this template feeds)
- `05-DUAL-VISUAL-SYSTEM.md` (subject of DEC-001)
- `07-QUALITY-STANDARDS.md` (Phase 0 Foundation Review criteria)
- `08-DESIGN-REVIEW-CHECKLIST.md` (Phase 0 Foundation Review checklist)
