# RFC-001: Resource & Asset Metadata Standard (gtarp)

**Author:** Dev Lead / Creative Lead (Palm6)
**Date:** 2026-07-17
**Status:** Approved
**Affects:** gtarp - `resources/[custom]/*`, `assets/*`, `17-ASSET-REGISTRY/ASSET-REGISTRY.md`

## Summary

Defines the minimum, consistent metadata every gtarp custom resource and shippable
asset must carry, and the granularity at which assets are recorded in the Asset
Registry. This is the metadata RFC required by Phase 2 (Master Plan task 2.3).

## Motivation

gtarp has ~56 custom resources plus item icons and (soon) brand art. Before Phase 3
alignment, we need one predictable way to answer "what is this, who owns it, what
status is it, and is it tracked?" without inventing per-resource conventions. A single
standard also makes the Asset Registry populate-able and auditable, and sets the
pattern the Website / Bot / Commercial Scripts repos inherit.

## Proposal

### 1. Custom resource manifest metadata (`fxmanifest.lua`)
Every `resources/[custom]/palm6_*` resource's `fxmanifest.lua` SHOULD carry:
- `author` - `'Palm6'` (or the specific author for third-party-derived resources).
- `version` - SemVer (`'x.y.z'`); bump on meaningful change.
- `description` - one line: what the resource does.
- A top-of-file banner comment already used across the layer (purpose + money/authority
  notes) remains the human reference; this RFC does not change code, only standardizes
  the manifest fields.

Naming: custom resources are `palm6_<domain>` (lower_snake). Non-`palm6_` resources in
`[custom]` (`server_base`, `server_identity`, `[config_overrides]`, `mystudio_props`,
`prop_spawn`) are pre-existing/base and are exempt from the `palm6_` prefix but MUST
still appear in the Asset Registry.

### 2. Asset (media) metadata
Media assets in `assets/` (icons, and future props/vehicles/clothing/EUP/audio) are
tracked by **registry row**, not by embedded metadata (image files carry none reliably).
Each shippable media asset or coherent set gets a registry row with: name, type, status,
owner, **license/ownership**, commercial flag, Decision Log ref, notes.

### 3. Registry granularity (what is "one asset")
- The **live custom script layer** is registered as **one tracked collection** row
  (`palm6_*`), because the resources ship and evolve together as the server. A single
  resource is split into its own row only when it is (a) proposed for reuse/sale, (b)
  under individual review for Approved status, or (c) deprecated/archived (so its
  retirement is auditable - e.g. `prop_spawn`).
- **Media** (icons, brand marks, props, vehicles, clothing, EUP, audio) is registered
  **per file or per coherent set** (e.g. "item icons" is one set row; each brand mark
  is its own row once placed, because brand marks are individually governed).

### 4. Status + license discipline
- New/untried = **Experimental**; shipping-but-not-formally-reviewed = **Candidate**;
  review-passed + logged = **Approved**; retired = **Archived**.
- No row is **Approved** without a Decision Log entry (ID in the registry).
- Any asset past Experimental MUST have a concrete license/ownership entry. A blank
  license blocks promotion (see `mystudio_props`, whose license must be confirmed).

## Alternatives Considered

- **Per-resource registry rows for all 56 resources.** Rejected for now: high churn,
  low signal - the layer ships as a unit. RFC allows splitting a resource out when it
  genuinely needs individual governance.
- **Embed metadata in a sidecar `.meta.json` per asset.** Rejected: duplicates the
  registry, drifts from it. The registry is the single source of truth.

## Impact & Risks

- **Additive only.** No code behavior changes; manifest fields are documentation.
- **Low risk.** Existing manifests already mostly carry author/version/description;
  this codifies it. Enforcement is at review time, not by a runtime gate.

## Decision

**Approved.** Adopted as the gtarp metadata standard for Phase 2 onward. Recorded in
`00-FOUNDATION/09-DECISION-LOG.md` as part of **DEC-003** (gtarp Phase 2). Applied to
the initial Asset Registry population in the same phase. Future changes to this standard
go through a new RFC.
