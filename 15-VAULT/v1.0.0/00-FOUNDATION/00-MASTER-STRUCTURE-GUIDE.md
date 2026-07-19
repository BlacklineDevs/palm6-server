# Palm6 Master Repository Structure Guide

**Version:** v1.0.0  
**Status:** Approved v1.0.0 (Phase 0, DEC-004, 2026-07-18)  
**Purpose:** This document defines the standardized folder structure for all Palm6 repositories.

---

## Core Philosophy

Every repo must feel like it belongs to the same professional studio. Structure supports consistency, discoverability, and long-term maintainability.

## Universal Folders (Present in Most Repos)

- `00-FOUNDATION/` - Creative System documents (Design Bible, North Star, etc.)
- `01-BRAND/` - Brand assets (logos, UI kit, color system, typography)
- `docs/` - Technical and project documentation
- `src/` or `resources/` - Main code / assets
- `assets/` - Organized media, props, textures, etc.
- `tools/` - Utility scripts and automation
- `deploy/` or `INFRA/` - Deployment and infrastructure
- `tests/` - Test files
- `.github/` - GitHub workflows

---

## Repo-Specific Structure

### 1. Main Server Repo (`gtarp`)

- `00-FOUNDATION/`
- `01-BRAND/`
- `docs/`
- `resources/` - FiveM resources
  - `[custom]/` - Palm6 custom scripts
  - `[core]/` - Framework overrides
- `sql/`
- `assets/` - Props, vehicles, clothing
- `tools/`
- `deploy/`

### 2. Website Repo (`horizon-rp-web` or `palm6-website`)

- `00-FOUNDATION/`
- `01-BRAND/`
- `docs/`
- `src/` - Next.js / frontend code
- `public/assets/` - Images, fonts, etc.
- `components/`
- `pages/` or `app/`
- `deploy/`

### 3. Discord Bot Repo

- `00-FOUNDATION/`
- `01-BRAND/`
- `docs/`
- `src/` - Bot code
- `commands/`
- `events/`
- `utils/`
- `deploy/`

### 4. Commercial Scripts / Assets Repo

- `00-FOUNDATION/`
- `01-BRAND/`
- `docs/`
- `assets/` - Sellable items (vehicles, clothing, props)
- `packages/` - Individual script packages
- `examples/`
- `tools/`

---

**Implementation Rules**

- All new repos start with this structure.
- Existing repos will be migrated gradually.
- Use semantic versioning and the Decision Log for major changes.

This guide will evolve as we add more repos.

**Approved by:** (to be filled when reviewed)