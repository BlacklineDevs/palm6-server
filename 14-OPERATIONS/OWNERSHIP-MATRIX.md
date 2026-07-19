# Ownership Matrix (gtarp)

**Version:** v1.0.0
**Status:** Approved v1.0.0 (Phase 3 task 3.7, DEC-006, 2026-07-18).
**Owner:** Project Lead + Creative Lead (David).
**Basis:** Master Restructuring Plan task 3.7 and the project
`POST-MIGRATION-OWNERSHIP-MATRIX.md` (Handoff Package v39), aligned to gtarp.

---

## Purpose

Define long-term ownership and accountability for gtarp after Phase 3, so responsibility
does not fall through gaps and the Creative System stays enforced over time.

## Solo-operator note

gtarp is currently run by a single operator (David), who holds every lead role below. The
roles are kept distinct on purpose: they name the different hats one person wears, and they
make the matrix drop-in ready if a role is later delegated. Where a row says "David (Dev
Lead)", it means the Dev Lead responsibilities, currently held by David.

---

## Ownership

| Area | Primary Owner | Support | Key responsibilities | Escalation |
|------|---------------|---------|----------------------|------------|
| **Creative System in gtarp** | Creative Lead (David) | Dev Lead | Maintain, version, and communicate the copied Creative System; keep it aligned to the package | Project Lead |
| **Technical structure + governance enforcement** | Dev Lead (David) | Creative Lead | Repo structure, resource conventions (`palm6_<domain>`), RFC + Decision Log enforcement, luaparse/verify gate | Creative Lead, then Project Lead |
| **Brand + Dual Visual System application** | Creative Lead (David) | Design Lead (Website) | System A identity stays minimal/ownable; System B supports and never replaces it; design-review checklist enforced | Project Lead |
| **Asset Lifecycle + Quality Standards** | Creative Lead (David) | Dev Lead | Enforce the ladder (Experimental -> Candidate -> Approved -> Vault) and the Approved-via-Decision-Log rule | Project Lead |
| **Asset Registry accuracy** | Creative Lead (David) | Dev Lead | Every shipped/sellable asset registered with correct status, owner, license, commercial flag | Project Lead |
| **Commercial / sellable assets** | Creative Lead (David) | Dev Lead | Licensing and Approved-status enforcement before any release or sale; lives in `BlacklineDevs/palm6-scripts` | Project Lead |
| **Creative debt** | Creative Lead (David) | Dev Lead | Keep `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` current; no high-severity debt unscheduled | Project Lead |
| **Risk + rollback triggers** | Dev Lead (David) | Creative Lead | Monitor active risks; every change stays additive/reversible; roll back non-compliant merges | Project Lead |
| **Knowledge continuity + onboarding** | Creative Lead (David) | Dev Lead | Keep `CONTRIBUTING.md`, Decision Log, and onboarding docs current | Project Lead |

---

## Key principles

- **Creative Lead** has final authority on creative direction, brand, Dual Visual System, and
  governance culture.
- **Dev Lead** has final authority on technical structure, tooling, and in-repo process
  enforcement.
- **Project Lead** has final authority on cross-repository consistency and overall health;
  any major conflict between roles escalates here.
- All roles keep their area aligned with the approved Creative System over time.

## Review cadence

Reviewed at each periodic strategic review (every 12 to 18 months) or after any major
change in how gtarp is staffed or operated. The next such review follows project-level
closure per the project ownership matrix.
