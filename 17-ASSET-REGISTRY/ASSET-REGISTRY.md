# gtarp Asset Registry

Version: v0.9.0-rc.1 (Release Candidate)
Status: Active, populated. This is the authoritative inventory of assets that live in
or ship from the gtarp repository. Established in Phase 2 (Organization).
Owner: Creative Lead (David Olverson)

Status ladder (see `14-OPERATIONS/ASSET-LIFECYCLE.md`): Experimental → Candidate →
Approved → Vault; Archived is the retirement state. **Nothing is Approved without a
gtarp Decision Log entry.** Row granularity follows `19-RFC/RFC-001`.

> **Repo state:** the Palm6 Creative System is **Candidate** in gtarp (Phase 0 not run
> here — see `14-OPERATIONS/README.md`). Accordingly, no asset below is marked Approved
> yet; the live custom layer is tracked as **Candidate** (shipping, not yet formally
> review-approved). "Commercial? = N" throughout — gtarp ships no sellable asset; the
> Commercial Scripts repo is where the commercial rule bites.

---

## Registry

| Asset Name | Type | Status | Owner | License / Ownership | Commercial? | Decision Log Ref | Notes |
|---|---|---|---|---|---|---|---|
| Palm6 custom resource layer (`resources/[custom]/palm6_*`) | script | Candidate | Dev Lead | Original work — PALM6 owns | N | — | ~56 live resources on prod (economy, crime, justice, governance). Registered as one tracked collection; per-resource rows added only if/when a resource is split out for review or reuse. Granularity per RFC-001. |
| Item icons (`assets/ox_icons/*.png`) | graphic | Candidate | Creative Lead | Original work — PALM6 owns | N | — | 7 custom ox_inventory item icons (cured_leather, cured_meat, fillet, refined_metal, yard_commissary_snack, yard_pruno, yard_soap). Deployed via `.github/workflows/palm6-upload-icons.yml`. Confirm none are derived from third-party art before any Approved promotion. |
| Server config layer (`resources/[custom]/server_base`, `server_identity`, `[config_overrides]`) | script | Candidate | Dev Lead | Original work — PALM6 owns | N | — | Base server + identity + config-override resources. Live; not creative/sellable. |
| `mystudio_props` | prop | Candidate | Dev Lead | **License to confirm** | N | — | Prop resource in `resources/[custom]`. License/ownership basis MUST be confirmed before any Approved or commercial status — do not promote past Candidate with a blank license. |
| `prop_spawn` (dev helper) | script | Archived (deprecated) | Dev Lead | Original work — PALM6 owns | N | — | Dev-only test helper, neutralized in prod via `stop prop_spawn` in `custom.cfg`. Retirement pending panel access. See `docs/RESTRUCTURING/PHASE-2-DEPRECATIONS.md` + CD-002. |
| Palm6 department emblems (System B set, 24) | graphic | Candidate | Creative Lead | Original work — PALM6 owns (generated in ChatGPT by David) | N | — | Received via Palm6 Discord DMs 2026-07-14…17. 24 city department crests (police/fire/EMS/national-guard/corrections/emergency-management/DMV×2/transportation/public-works/water-sewer/sanitation/building-zoning/housing/port/aviation/parks/library/tourism/animal-control/environmental/elections/revenue/business-licensing). `01-BRAND/logos/departments/` (see README). Candidate until a Decision Log promotion. |
| Verano state seals (System A-leaning, 2) | graphic | Candidate | Creative Lead | Original work — PALM6 owns (generated in ChatGPT by David) | N | — | State of Verano great seal + Verano Department of Justice seal. `01-BRAND/logos/state/`. Formal circular seals; state-level (Verano = state, Palm6 = city). |
| Palm6 private-business logos (System B) | graphic | Experimental | Creative Lead | Original work — PALM6 owns | N | — | **REJECTED first batch → being redone** (David: "ugly"). NOT in the repo. Redo direction: `01-BRAND/BUSINESS-BRAND-BRIEF.md`. Businesses: Apex Motors, Bayside Realty, Verano Air, Coastline Insurance, Harbor Freight, Palm Medical, Harbor Energy, PalmLink, Palm6 Garage, +more. Register the set here once the redo is approved. |
| Palm6 System A core identity mark | graphic | Experimental | Creative Lead | Original work — PALM6 owns | N | — | **Still pending** (CD-001). The primary ownable Palm6 logo (System A) has not been supplied — the department/state art above is System B / seals, a different asset class. Placeholder row until the core mark is delivered + placed in `01-BRAND/logos/`. |

---

## Change rule

Update a row in the **same change** that alters the asset. Advancing any row to
**Approved** requires a new `00-FOUNDATION/09-DECISION-LOG.md` entry, whose ID goes in
the *Decision Log Ref* column. A `Commercial? = Y` row with Status ≠ Approved or a
blank License field is a blocking defect (not applicable to gtarp today — all rows are
non-commercial — but the rule stands for any future sellable asset).
