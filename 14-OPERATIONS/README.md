# 14-OPERATIONS (gtarp)

Version: v0.9.0-rc.1 (Release Candidate)
Status: Active operational reference for the gtarp repository during the Palm6
Creative System restructuring. Introduced in Phase 2 (Organization).

---

## What lives here

Day-to-day operating rules for creative + functional assets in this repository.

| File | Purpose |
|---|---|
| `ASSET-LIFECYCLE.md` | The status ladder (Experimental → Candidate → Approved → Vault; Archived = retirement) every asset in this repo moves along. Canonical system reference, copied in. |
| `RFC-PROCESS.md` | How a significant change is proposed, reviewed, and recorded before it happens. See `19-RFC/`. |
| `VERSION-CONTROL.md` | Versioning scheme for the Creative System and individual assets. |
| `CREATIVE-DEBT-TRACKING.md` | The live register of shortcuts/placeholders taken in this repo, each with an owner and a resolution path. |

The populated per-repo Asset Registry lives in `../17-ASSET-REGISTRY/ASSET-REGISTRY.md`.

---

## ⚠️ Repo-local status note (read before trusting any "Approved v1.0.0" wording)

The copied system docs describe the Creative System's own governance, where the
system is promoted from **v0.9.0-rc.1 (Candidate)** to **v1.0.0 (Approved)** during
**Phase 0 (the Creative System Approval Gate)**, recorded in the *system's* Decision
Log as its promotion entry.

**In gtarp, Phase 0 has NOT been run.** Per `DEC-001`, gtarp adopted the Creative
System as **Candidate (v0.9.0-rc.1)** for additive, reversible work only. Therefore:

- Nothing in this repository is auto-Approved. The Creative System here is Candidate.
- An asset reaches **Approved** in gtarp **only** via an explicit gtarp Decision Log
  entry (`00-FOUNDATION/09-DECISION-LOG.md`), never by a status line in a copied doc.

### Decision-Log numbering reconciliation (DEC-001 & DEC-002 collisions)

The system package's own Decision Log uses **DEC-001** for the *Dual Visual System*
decision and reserves **DEC-002** for the *Creative System rc.1 → v1.0.0 promotion*
(a Phase 0 output). **gtarp's local log already uses both IDs for other things:**
`DEC-001` = the Phase 1 (Foundation) kickoff, `DEC-002` = the Phase 1 post-execution
audit + open-blocker registration. Same IDs, different meanings, across two logs.

**Resolution (logged in `DEC-003`):** gtarp's local Decision Log is authoritative for
this repository. gtarp will **not** renumber its already-logged `DEC-001`/`DEC-002`.
Reading guide for copied system docs:
- Where a copied doc says **"DEC-001 (Dual Visual System, Approved)"**, read it as the
  Dual Visual System entry in the *system's own* log. gtarp's local DEC-001 is the Phase 1
  kickoff; the Dual Visual System is adopted here by reference via `DESIGN-BIBLE-v1.0.md`
  and `05-DUAL-VISUAL-SYSTEM.md`, not as a standalone local DEC.
- Where a copied doc says **"DEC-002 (promotion)"**, read it as the promotion entry in the
  system's own log. If/when gtarp runs Phase 0, the local promotion is logged under the
  **next free gtarp DEC id** — which is **DEC-004** (Proposed) — not `DEC-002`.

Until Phase 0 is signed, the system in gtarp is Candidate (v0.9.0-rc.1).
