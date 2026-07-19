# Contributing to gtarp (Palm6)

This repo follows the **Palm6 Creative System**. This is the one-page quickstart for
adding anything correctly. Reference docs: `00-START-HERE.md`, `MASTER-INDEX.md`,
`14-OPERATIONS/`, `19-RFC/`, `17-ASSET-REGISTRY/`.

> System status: the Creative System is **Approved v1.0.0** in this repo (Phase 0 signed,
> DEC-004, 2026-07-18; Phase 3 alignment logged as DEC-006). Nothing else is **Approved**
> without its own Decision Log entry, never by editing a status line. Visual-dependent items
> (System A core mark CD-001, COLOR-SYSTEM CD-008) remain Candidate.

---

## Golden rules
1. **Additive and reversible.** During restructuring, don't delete or heavily refactor
   live code; deprecate with a migration note (`docs/RESTRUCTURING/PHASE-2-DEPRECATIONS.md`).
2. **`sql/` is append-only.** Never edit or reorder an existing migration. New migrations
   must be idempotent and registered in `palm6_dbmigrate/server.lua` (it re-runs every
   statement every boot - there is no ledger).
3. **Server is authoritative.** Clients forge any net-event payload. Price, ownership, and
   outcomes are always recomputed server-side. Sanitize client numbers (reject `NaN`/±Inf).
4. **Stage explicit paths.** Never `git add -A`/`-u` in this shared tree - stage your exact
   files by path.
5. **`main` auto-deploys** only on changes under `resources/**` or `custom.cfg`. Docs/brand
   pushes don't deploy. `luaparse`-check every changed `.lua` before pushing.

## Adding a custom resource / editing gameplay
- Name it `palm6_<domain>` (lower_snake). Keep money/authority logic server-side; add an
  `palm6_eventguard` budget for any new money/DB net event (ensure eventguard loads first).
- Fill `fxmanifest.lua` `author`/`version`/`description` per `19-RFC/RFC-001`.
- Follow the bridge pattern (`bridge/sv_framework.lua` + `bridge/cl_game.lua`) so
  framework/native calls stay isolated (GTA6-portable).
- `verify` the change end-to-end; prefer boot-verify on a local FXServer where possible.

## Adding a creative / brand asset
1. Place it in the right home: brand → `01-BRAND/`, media → `assets/`.
2. **Register it** in `17-ASSET-REGISTRY/ASSET-REGISTRY.md` (name, type, status, owner,
   license, commercial flag). If it's not in the registry, it must not ship or be sold.
3. Status ladder: Experimental → Candidate → Approved → Vault. Start at Experimental or
   Candidate. **Approved requires a Decision Log entry** (put its ID in the registry).
4. It must pass `00-FOUNDATION/07-QUALITY-STANDARDS.md`: original/ownable, timeless, and,
   for **System A** identity marks, legible in one color at 32px with no reliance on
   glow/texture. **System B** marketing art (faction crests, cinematics) has more latitude.
5. Log creative shortcuts in `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md`.

## Making a non-trivial or structural change
- Write an RFC (`19-RFC/RFC-TEMPLATE.md`) and log its decision (`20-TEMPLATES/`) before the
  change. Record significant decisions in `00-FOUNDATION/09-DECISION-LOG.md` (registry +
  a `DECISION-LOG/` entry). Use the next free `DEC-###`.

## Commit + changelog
- Conventional commits, scoped, explicit paths. Co-author trailer for AI-assisted commits.
- Player-facing gameplay changes get a `CHANGELOG.md` entry (internal detail + a public
  blurb) - it's the build-in-public source of truth.
