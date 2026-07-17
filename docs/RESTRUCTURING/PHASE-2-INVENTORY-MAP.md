# gtarp Phase 2 — Inventory → Destination Map

Version: v0.9.0-rc.1 (Release Candidate)
Status: Phase 2 (Organization) task 2.1 deliverable. Maps every top-level item in the
gtarp repository to its destination in the standardized structure (Master Plan §2.2).

Key finding: **gtarp already conforms to the target layout for its functional content.**
FiveM dictates `resources/ · sql/ · custom.cfg` locations, so Phase 2 is mostly
*additive governance folders*, not file moves. No functional code is relocated.

---

## Target structure (Master Plan §2.2, gtarp)
`00-FOUNDATION/` · `01-BRAND/` · `docs/` · `resources/` (`[custom]`, `[core]`) · `sql/` ·
`assets/` · `tools/` · `deploy/` — plus the universal governance folders introduced in
Phase 1/2 (`15-VAULT/`, `19-RFC/`, `17-ASSET-REGISTRY/`, `14-OPERATIONS/`, `20-TEMPLATES/`).

## Map

| Current item | Type | Destination | Action | Notes |
|---|---|---|---|---|
| `resources/` (`[custom]`) | code | `resources/` | **keep** | FiveM load path — must not move. Conforms. `[core]/` (framework overrides) is a §2.2 target folder but is **intentionally absent** — Palm6 overrides no framework files, so FiveM never creates that resource group; add it only if/when an override is needed. |
| `sql/` | migrations | `sql/` | **keep (append-only)** | Never reorder/rewrite; migrations are append-only during restructuring. |
| `assets/ox_icons/` | media | `assets/` | **keep** | Conforms. Now registered in `17-ASSET-REGISTRY/`. |
| `tools/` | scripts | `tools/` | **keep** | Conforms. |
| `docs/` | docs | `docs/` | **keep** | Conforms. Phase 2 adds `docs/RESTRUCTURING/`. |
| `custom.cfg`, `server.cfg.example` | server cfg | root | **keep** | FiveM/panel exec order depends on `custom.cfg` at root. Do not move. |
| `.github/` (workflows) | CI | `.github/` | **keep** | GitHub REQUIRES workflows in `.github/workflows/`. Cannot move to `deploy/`. `deploy/` documents + points to them. |
| `DEPLOY.md` | deploy doc | `deploy/README.md` | **move (`git mv`)** | Doc-only move; consolidates deploy docs under `deploy/`. Root refs updated. |
| `CHANGELOG.md`, `README.md` | root docs | root | **keep** | Standard root docs. |
| `00-FOUNDATION/`, `15-VAULT/`, `19-RFC/`, `MASTER-INDEX.md`, `00-START-HERE.md`, `HANDOFF-TO-CLAUDE.md` | governance | as-is | **keep** | Added in Phase 1. |
| `01-BRAND/` | brand | `01-BRAND/` | **create** | New in Phase 2. Scaffold + guidelines; art pending (CD-001). |
| `deploy/` | deploy | `deploy/` | **create** | New in Phase 2. Deploy documentation hub (CI stays in `.github/`). |
| `17-ASSET-REGISTRY/`, `14-OPERATIONS/`, `20-TEMPLATES/` | governance | as-is | **create** | New in Phase 2. Universal governance folders. |
| `.claude/`, `.git/`, `.gitignore`, `.gitattributes` | infra | root | **keep** | Repo infra. |

## Deprecation candidates (see `PHASE-2-DEPRECATIONS.md`)
`resources/[custom]/prop_spawn` (dev-only, already `stop`-neutralized in prod).

## Unmapped items
None. Every top-level file and folder is accounted for above.
