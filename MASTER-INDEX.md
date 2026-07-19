# gtarp - Palm6 Creative System Index (repo-local)

**Version:** v0.9.0-rc.1 (Candidate)
**Scope:** This index reflects what actually exists in THIS repository right now.
It is not the aspirational full-system index - it is the honest, current map so a
new session is never sent to a file that does not exist.

**Restructuring phase:** Phase 1 (Foundation) complete; **Phase 2 (Organization)
substantially complete** (brand art placement open, CD-001). See
`00-FOUNDATION/DECISION-LOG/` for the authoritative history.

---

## Present now (Phase 1)

### Root
- `README.md` - the repository's real technical docs (Qbox custom resource layer) +
  a Creative System reference section.
- `00-START-HERE.md` - Creative System onboarding entry point.
- `HANDOFF-TO-CLAUDE.md` - instructions for AI sessions.
- `MASTER-INDEX.md` - this file.

### `00-FOUNDATION/` - the Creative System foundation (11 docs)
Design Manifesto, Project Principles, North Star, Dual Visual System, Brand Pyramid,
Quality Standards, Design Review Checklist, Decision Log, Color System, Master
Structure Guide, Design Bible. Status: Candidate (v0.9.0-rc.1) except
`DESIGN-BIBLE-v1.0.md`, which is Approved.

### `00-FOUNDATION/DECISION-LOG/` - logged decisions
- `DECISION-LOG-ENTRY-001.md` (DEC-001) - Phase 1 kickoff.
- `DECISION-LOG-ENTRY-002.md` (DEC-002) - Phase 1 post-audit reconciliation +
  open blockers requiring an owner ruling.
- `DECISION-LOG-ENTRY-003.md` (DEC-003) - Phase 2 execution (structure, RFC-001,
  Asset Registry, deprecations, DEC-numbering reconciliation).
- `DECISION-LOG-ENTRY-004.md` (DEC-004) - Phase 0 promotion (rc.1 → v1.0.0),
  **Proposed**, awaiting David's signature.
- `09-DECISION-LOG.md` now carries an at-a-glance **Decision Registry** table.

### `19-RFC/` - the RFC process home
- `README.md` (how to propose changes) + `RFC-TEMPLATE.md`.
- `RFC-001-resource-and-asset-metadata-standard.md` (Approved) - the metadata standard.

### `15-VAULT/` - the Approved-only vault
- `README.md` only. Empty by design: nothing enters until it earns **Approved**
  status via the Decision Log.

---

## Present now (Phase 2 - Organization)

### `01-BRAND/` - brand assets
- `README.md`, `BRAND-GUIDELINES.md`, `BUSINESS-BRAND-BRIEF.md`; `logos/departments/`
  (24 dept crests + README), `logos/state/` (2 Verano seals + README), all registered
  Candidate. Outstanding: the System A core mark (CD-001).

### `14-OPERATIONS/` - day-to-day governance
- `README.md` (repo-local status + DEC-numbering note), `ASSET-LIFECYCLE.md`,
  `RFC-PROCESS.md`, `VERSION-CONTROL.md`, `CREATIVE-DEBT-TRACKING.md` (CD-001…CD-006).

### `17-ASSET-REGISTRY/` - the asset inventory
- `README.md`, `ASSET-REGISTRY-TEMPLATE.md`, and the populated `ASSET-REGISTRY.md`.

### `20-TEMPLATES/` - reusable governance templates
- Decision-Log entry, RFC, and Phase-Completion-Report templates.

### `deploy/` - deploy documentation hub
- `README.md` (the deploy pipeline doc; CI stays in `.github/workflows/`).

### `docs/RESTRUCTURING/` - phase working docs
- `PHASE-2-INVENTORY-MAP.md`, `PHASE-2-DEPRECATIONS.md`, `PHASE-0-FOUNDATION-REVIEW.md`.

### `CONTRIBUTING.md` (root) - Creative System alignment quickstart
- One-page "how to add anything correctly" guide (Phase 3 groundwork).

---

## Planned (Phase 3 - do NOT treat as errors if absent)

The remaining taxonomy (`02-WORLD/`…`13-MARKETING/`, `16-REFERENCE/`, `18-ROADMAP/`,
`21-ARCHIVE/`, plus `EXECUTIVE-SUMMARY.md` and `PHILOSOPHY-WHY-THIS-MATTERS.md`) is
**not yet materialized in this repo** - it is only added if/when gtarp genuinely needs
it, via the RFC process, during Phase 3 (Alignment). Read references to those as
*intended* structure, not current state.

---

*Living index - update it when documents or statuses change.*
