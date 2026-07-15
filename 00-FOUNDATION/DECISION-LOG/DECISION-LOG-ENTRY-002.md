# Decision Log Entry 002

**Date:** 2026-07-15
**Decision ID:** DEC-002
**Decision:** gtarp Phase 1 — post-execution adversarial audit, reconciliation of
findings, and registration of open blockers requiring an owner ruling.
**Status:** Partially Approved — remediation applied (below); two items **OPEN**, awaiting
David's ruling.
**Owner:** David Olverson (Palm6 Creative + Dev Lead)

## Context
After DEC-001 (Phase 1 executed + pushed to `BlacklineDevs/gtarp`), a multi-agent
adversarial audit ran across four lenses (spec-completeness, non-destructiveness,
governance-consistency, forward-path). 16 findings; 14 confirmed, 2 refuted as false
positives. Full record retained in the session. This entry captures what was fixed and
what remains an owner decision.

## Verified good (no action)
- **Spec-complete:** the 11 foundation docs are byte-identical to the approved source;
  branch tree matches the intended Phase-1 example; remote SHA matches local HEAD.
- **Non-destructive:** commit was additive-only (14 adds + README append); the original
  Qbox README is intact; the 5 in-flight `resources/[custom]/` files were left unstaged
  and untouched.
- **False positives (correctly dropped):** (a) "origin → EvThatGuy = Ev IP entanglement"
  — the repo was **transferred to the BlacklineDevs org**; Ev no longer owns it (residual:
  stale URL string, fixed below). (b) "DEC-001 breaks the log template" — it faithfully
  matches the intended example.

## Remediation applied in this commit
1. **Dead-link onboarding (was HIGH).** `00-START-HERE.md` / `HANDOFF-TO-CLAUDE.md`
   routed the next session to files/folders that did not exist. Fixed by: adding an
   accurate repo-local `MASTER-INDEX.md`; materializing the two governance homes the docs
   route to — `19-RFC/` (README + template) and `15-VAULT/` (README, empty by design); and
   adding a "Repository State (Phase 1)" note to both onboarding docs marking still-absent
   items (`EXECUTIVE-SUMMARY.md`, `PHILOSOPHY-WHY-THIS-MATTERS.md`, `01-BRAND/`) as
   forthcoming, not errors. The aspirational source `MASTER-INDEX.md` was deliberately
   **not** copied — it references a large taxonomy that exists nowhere and would import
   more dead links.
2. **"Approved" wording drift (was medium).** DEC-001 described Candidate/Draft docs as
   "approved" and marked itself Approved. Reworded: DEC-001's Approved status is now scoped
   strictly to the *process decision* to begin additive work; the docs are labeled
   **Candidate (v0.9.0-rc.1)**, with only `DESIGN-BIBLE-v1.0.md` noted as Approved.
3. **Stale remote (low hygiene).** `origin` updated from the redirecting
   `EvThatGuy/gtarp` URL to the canonical `BlacklineDevs/gtarp.git`.

## OPEN — requires David's ruling before the affected phases can start
- **DEC-002a — Repo identities for Website & Commercial Scripts (blocks Phase 2 repo /
  Website phase).** The spec names them only generically. Confirmed clean mappings:
  Main Server = `BlacklineDevs/gtarp`; Discord Bot = `BlacklineDevs/palm6-bot`. Unresolved:
  the **Website** repo (candidate `davidolverson/palm6-web` deploy vs a separate Blackline
  canonical — which is the restructuring target?) and **Commercial Scripts** (candidates
  `fivem-scripts` [no remote, local-only] and `davidolverson/gta-rp-bot-kit` [ambiguous] —
  or a new BlacklineDevs repo). *Action needed: David declares the two canonical remotes.*
- **DEC-002b — Undefined phase gates.** Six spec files gate later work on "Website Phase 4"
  and "Phase 6 (Cross-Repo Polish)", but the model defines only Phases 1–3. The start
  condition for the Discord Bot and (highest-IP-risk) Commercial Scripts phases is therefore
  undefined. *Action needed: reconcile "Phase 4" → "Phase 3 + post-phase review", and define
  or renumber "Phase 6 / Cross-Repo Polish".* This is a spec-integrity fix, not code.

## Housekeeping note (not blocking)
The 5 pre-existing `resources/[custom]/` modifications remain uncommitted in the working
tree (as intended). Their owning terminal should commit/branch them before Phase 2 so no
broad `add`/`clean` can lose them.

## Next Steps
Hold Phase 2 until DEC-002a and DEC-002b are ruled. gtarp Phase 1 is otherwise complete,
verified, and gap-closed.
