# 17-ASSET-REGISTRY (gtarp)

Version: v0.9.0-rc.1 (Release Candidate)
Status: Active. Introduced in Phase 2 (Organization).

The single per-repository Asset Registry for gtarp lives in
[`ASSET-REGISTRY.md`](./ASSET-REGISTRY.md). It is the authoritative inventory of the
creative and functional assets that live in or ship from this repository.

- `ASSET-REGISTRY-TEMPLATE.md` - the blank template (system reference).
- `ASSET-REGISTRY.md` - **the populated gtarp registry** (source of truth for this repo).

**Rules (from the template + `14-OPERATIONS/ASSET-LIFECYCLE.md`):**
- If an asset is not in the registry, it is not tracked; an untracked asset must not
  ship and must not be sold.
- Status ladder: Experimental → Candidate → Approved → (Vault). Archived = retirement.
- No asset reaches **Approved** without a gtarp Decision Log entry (`00-FOUNDATION/09-DECISION-LOG.md`).
- Granularity (what counts as one registry row) follows **`19-RFC/RFC-001`**.
- See `14-OPERATIONS/README.md` for the repo-local Candidate-status + DEC-numbering note.
