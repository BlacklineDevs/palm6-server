# Phase Completion Report Template

Version: v0.9.0-rc.1 (Release Candidate)
Status: Release Candidate template, ready for use by executors closing a phase.
Owner: PALM6 Creative System governance.

> Note: this is a verbatim copy of a system-package template. Its `RESTRUCTURING-PLANS/*`
> references (MASTER-RESTRUCTURING-PLAN, CLAUDE-HANDOFF-INSTRUCTIONS, RISK-REGISTER,
> TRANSITION-TO-STEADY-STATE-PROTOCOL, POST-MIGRATION-OWNERSHIP-MATRIX) live in the
> **parent Palm6 restructuring handoff package**, not in this gtarp repo.

---

## Purpose

An executor fills in one copy of this template every time a phase closes for a repository, and one copy when the project-level Cross-Repo Consistency Pass closes. This operationalizes the "report after each phase" rule defined in `RESTRUCTURING-PLANS/CLAUDE-HANDOFF-INSTRUCTIONS.md`. The completed report is the durable evidence that a phase actually finished, was verified against the quality standards, and left the repository in a recoverable state.

No phase counts as complete until a filled copy of this report exists and its Quality Gate Result reads Pass. If the gate result is Conditional Pass or Fail, the phase remains open and the Next Step field states what must happen before it can close.

### How to use it

1. Copy this file. Do not edit the template in place.
2. Name the copy so the repo and phase are obvious, for example `phase-report-gtarp-phase1.md`.
3. Fill every field. If a field does not apply, write "Not applicable" and one line of reasoning. Do not delete fields.
4. Store the completed report in the target repository's history record and reference it from the relevant Decision Log entry in `00-FOUNDATION/09-DECISION-LOG.md` when a governance decision was involved.
5. For phase and ordering rules, follow `RESTRUCTURING-PLANS/MASTER-RESTRUCTURING-PLAN.md`. For the quality bar and the review procedure, use `00-FOUNDATION/07-QUALITY-STANDARDS.md` and `00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`.

### Phase model reference

The valid values for the Phase field are:

- Phase 0: Creative System Approval Gate. Project-level, run once before any repo. Promotes the Creative System from v0.9.0-rc.1 to v1.0.0 and records DEC-002.
- Phase 1: Foundation. Per repo.
- Phase 2: Organization. Per repo.
- Phase 3: Alignment and Governance. Per repo. Ends with Transition to Steady State plus a post-phase review scheduled 4 to 8 weeks later.
- Cross-Repo Consistency Pass: Project-level, run once after all four repos finish Phase 3.

There is no Phase 4, 5, or 6. The repository order is gtarp, then Website, then Discord Bot, then Commercial Scripts, per `RESTRUCTURING-PLANS/MASTER-RESTRUCTURING-PLAN.md`.

---

## Report

### 1. Header

| Field | Value |
| --- | --- |
| Repo | (gtarp / Website / Discord Bot / Commercial Scripts / Project-level) |
| Phase | (0 / 1 / 2 / 3 / Cross-Repo Consistency Pass) |
| Date | (YYYY-MM-DD) |
| Executor | (name or agent identifier) |
| Creative System version in effect | (v0.9.0-rc.1 before Phase 0 completes, otherwise v1.0.0 or later) |
| Report status | (Draft / Complete) |

### 2. What was done

Describe the concrete work performed during this phase. Be specific. List the actions taken, the files or folders created, moved, renamed, or retired, and any assets that changed status on the Experimental to Candidate to Approved to Vault ladder. State what was intentionally left out of scope so the next executor is not misled.

- Summary:
- Actions taken:
- Files and folders changed:
- Asset status changes (if any), with old status and new status:
- Explicitly out of scope this phase:

### 3. What was verified, with evidence

Verification is not a claim. Each verified item needs evidence that another person can re-check. Evidence means a command and its output, a file path that now exists, a checklist item marked against `00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`, a screenshot reference, or a link to a review record. Do not write "verified" without stating how.

| Item verified | Method | Evidence (path, command output, checklist item, or link) | Result |
| --- | --- | --- | --- |
| | | | Pass / Fail |
| | | | Pass / Fail |
| | | | Pass / Fail |

Notes on anything that could not be verified and why:

### 4. Quality gate result

State the outcome of the review against `00-FOUNDATION/07-QUALITY-STANDARDS.md` and `00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`. For Phase 0 this is the Foundation Review that decides whether the Creative System is promoted to v1.0.0.

| Field | Value |
| --- | --- |
| Reviewer | |
| Standards applied | 07-QUALITY-STANDARDS.md, 08-DESIGN-REVIEW-CHECKLIST.md |
| Checklist items passed | (count) |
| Checklist items failed or deferred | (count) |
| Gate result | Pass / Conditional Pass / Fail |

If Conditional Pass, list each condition and its owner. If Fail, list the blocking gaps. A phase with a Conditional Pass or Fail result stays open until every condition is cleared, and the Next Step field records that.

- Conditions or blocking gaps:

### 5. Rollback status

Confirm the repository can be returned to its pre-phase state if the phase is later reverted. This protects against a bad migration becoming permanent.

| Field | Value |
| --- | --- |
| Pre-phase restore point | (tag, commit, branch, or backup location) |
| Rollback tested | Yes / No |
| Rollback method | (how a revert would be performed) |
| Known irreversible changes | (list, or "None") |
| Rollback status | Recoverable / Recoverable with caveats / Not recoverable |

If the status is anything other than Recoverable, explain the caveat and reference the relevant risk in `RESTRUCTURING-PLANS/RESTRUCTURING-RISK-REGISTER.md`.

### 6. Decision Log reference

Nothing is Approved without a Decision Log entry. If this phase produced or depended on a governance decision, record it here and confirm the matching entry exists in `00-FOUNDATION/09-DECISION-LOG.md` using the standard fields (Date, Decision ID, Topic, Decision Made, Reasoning, Impact Areas, Status, Related Documents).

| Field | Value |
| --- | --- |
| Decision Log entry required | Yes / No |
| Decision ID | (for example DEC-002, or "Not applicable") |
| Entry recorded in 09-DECISION-LOG.md | Yes / No |
| Topic | |

Phase 0 note: the Phase 0 report must reference DEC-002, which promotes the Creative System from v0.9.0-rc.1 to v1.0.0 (Approved) and moves the approved Foundation set into `15-VAULT/`. Until DEC-002 is recorded, downstream preconditions worded "Approved Creative System (v1.0.0 or later)" are not satisfied and no repo phase may begin.

### 7. Next step

State exactly what happens next, so the following executor can start without re-deriving context.

- Immediate next action:
- Next phase or pass, and its precondition per `RESTRUCTURING-PLANS/MASTER-RESTRUCTURING-PLAN.md`:
- For a completed Phase 3: confirm Transition to Steady State was performed per `RESTRUCTURING-PLANS/TRANSITION-TO-STEADY-STATE-PROTOCOL.md`, and record the scheduled date of the post-phase review (4 to 8 weeks out).
- For the completed Cross-Repo Consistency Pass: confirm all four repos passed their Phase 3 and record the system health check outcome. This pass is the final project-level step. There is no Phase 4, 5, or 6.
- Open items carried forward:

---

## Sign-off

| Field | Value |
| --- | --- |
| Executor sign-off | (name, date) |
| Reviewer sign-off | (name, date) |
| Report filed at | (path in repository history) |

---

Related documents:
- `RESTRUCTURING-PLANS/CLAUDE-HANDOFF-INSTRUCTIONS.md` (the report-after-each-phase rule this template serves)
- `RESTRUCTURING-PLANS/MASTER-RESTRUCTURING-PLAN.md` (phase model, repo order, preconditions)
- `RESTRUCTURING-PLANS/TRANSITION-TO-STEADY-STATE-PROTOCOL.md` (Phase 3 close-out)
- `RESTRUCTURING-PLANS/RESTRUCTURING-RISK-REGISTER.md` (rollback and risk references)
- `00-FOUNDATION/07-QUALITY-STANDARDS.md` and `00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md` (quality gate)
- `00-FOUNDATION/09-DECISION-LOG.md` (decision entries, including DEC-002)
- `20-TEMPLATES/DECISION-LOG-ENTRY-TEMPLATE.md` (format for any decision this phase records)
