# Asset Registry Template (Per Repository)

Version: v0.9.0-rc.1 (Release Candidate)
Status: Candidate template in this repo. The Palm6 Creative System has NOT been promoted to v1.0.0 in gtarp (Phase 0 / the Creative System Approval Gate has not been run here), so nothing in gtarp is auto-Approved. An asset reaches Approved only via a gtarp Decision Log entry. See `14-OPERATIONS/README.md` for the repo-local status + Decision-Log-numbering note.
Owner: Creative Lead

> Note: this template's `RESTRUCTURING-PLANS/*` references (e.g. POST-MIGRATION-OWNERSHIP-MATRIX) live in the **parent Palm6 restructuring handoff package**, not in this gtarp repo. The populated repo registry is `ASSET-REGISTRY.md` (this folder).

---

## Purpose

This template defines the single per-repository Asset Registry. Every repository in the restructuring (gtarp, Website, Discord Bot, Commercial Scripts) maintains one copy of this registry, populated with the assets that live in or ship from that repository.

The registry is the authoritative inventory of creative and functional assets. It records what an asset is, who owns it, where it sits on the status ladder, whether it may be sold, and which Decision Log entry authorized any material change to its status. If an asset is not in the registry, it is not tracked, and an untracked asset must not ship and must not be sold.

The status ladder used here is the one defined in `14-OPERATIONS/ASSET-LIFECYCLE.md` (and echoed in `00-FOUNDATION/07-QUALITY-STANDARDS.md`):

Experimental -> Candidate -> Approved -> Vault (with Archived as the retirement state).

Only Approved items enter `15-VAULT/`. Archived is the terminal state for anything retired from active use.

---

## How to use this template

1. Copy this file into the target repository as its Asset Registry. Keep the filename recognizable (for example `ASSET-REGISTRY.md`) inside the repository's documentation folder.
2. Fill the table below. Add one row per asset. Do not delete example rows until you have at least one real row; then remove the examples.
3. Keep the registry current. Update a row in the same change that alters the asset. A status change from Candidate to Approved, or any move to Archived, requires a corresponding entry in `00-FOUNDATION/09-DECISION-LOG.md`, and that entry's ID goes in the Decision Log Ref column.
4. Never advance an asset to Approved by editing this table alone. Approval is a governed decision. The table records the outcome; it does not grant it.
5. Review the registry during each phase completion (see `20-TEMPLATES/PHASE-COMPLETION-REPORT-TEMPLATE.md`) and during the project-level Cross-Repo Consistency Pass.

---

## Column definitions

- **Asset Name**: A stable, human-readable name. Keep it unique within the repository. Do not rename an Approved or Vaulted asset without a Decision Log entry.
- **Type**: One of vehicle, clothing, prop, script, graphic, audio.
- **Status**: One of Experimental, Candidate, Approved, Archived. This mirrors the lifecycle in `14-OPERATIONS/ASSET-LIFECYCLE.md`. The Vault stage of the ladder is represented in this registry as an Approved status plus a recorded vault location, not as a separate Status value: when an Approved asset is moved into `15-VAULT/`, keep its Status as Approved and note the vault location in Notes.
- **Owner**: The person or role accountable for the asset. This should match the ownership recorded in `RESTRUCTURING-PLANS/POST-MIGRATION-OWNERSHIP-MATRIX.md`.
- **License / Ownership**: The legal basis for using the asset. State one of: original work (created in-house, PALM6 owns), licensed (name the license and source), or third-party with permission (name the grantor and the scope). Vague or blank entries are not acceptable for anything past Experimental.
- **Commercial? (Y/N)**: Whether the asset is intended for sale or resale, or is bundled into anything sold. See the commercial rule below.
- **Decision Log Ref**: The Decision Log ID (DEC-XXX) that authorized the asset's current governed status. Required for any asset at Approved or Archived. Format matches `00-FOUNDATION/09-DECISION-LOG.md`.
- **Notes**: Anything a reviewer needs: vault path, dependencies, source files, known limitations, or the reason for archival.

---

## The commercial rule (mandatory)

A commercial asset must not be offered for sale until both of the following are recorded in this registry:

1. A concrete License / Ownership entry that proves PALM6 has the right to sell it. Original work owned by PALM6, or a license whose terms permit resale or commercial distribution. If the license forbids resale, the asset cannot be commercial, regardless of quality.
2. Status set to Approved, with a valid Decision Log Ref pointing to the DEC-XXX entry that approved it.

Commercial? = Y with Status other than Approved, or with a blank or unresolved License / Ownership field, is a blocking defect. It must be corrected before the asset ships or is listed for sale. This applies most directly to the Commercial Scripts repository, but any repository that produces a sellable asset is bound by the same rule.

---

## Asset Registry

| Asset Name | Type | Status | Owner | License / Ownership | Commercial? (Y/N) | Decision Log Ref | Notes |
|---|---|---|---|---|---|---|---|
| PALM6 Primary Wordmark | graphic | Approved | Creative Lead | Original work, PALM6 owns | N | DEC-### (example) | Identity asset per System A. Vaulted at `15-VAULT/`. Single-color safe, small-size safe. |
| Coastal Sedan (livery pack) | vehicle | Candidate | Creative Lead | Original work, PALM6 owns | Y | (pending) | Under review for Approved. Commercial listing blocked until Approved status and a Decision Log entry exist. |
| _example: replace these rows with real assets before completion_ | | | | | | | |

---

## Cross-references

- `00-FOUNDATION/05-DUAL-VISUAL-SYSTEM.md`, System A (Identity) and System B (Marketing).
- `00-FOUNDATION/09-DECISION-LOG.md`, the authoritative log; every Approved or Archived status change cites a DEC-XXX entry here.
- `14-OPERATIONS/ASSET-LIFECYCLE.md`, the governing lifecycle process for status transitions.
- `15-VAULT/README.md`, where Approved assets are held; only Approved items enter the vault.
- `17-ASSET-REGISTRY/README.md`, overview of the asset registry and how per-repo copies relate.
- `20-TEMPLATES/DECISION-LOG-ENTRY-TEMPLATE.md`, the format for the Decision Log entry that authorizes an Approved or Archived transition.
- `RESTRUCTURING-PLANS/POST-MIGRATION-OWNERSHIP-MATRIX.md`, the source of truth for the Owner column.
