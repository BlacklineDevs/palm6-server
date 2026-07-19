# Creative Debt Tracking (gtarp)

Version: v0.9.0-rc.1 (Release Candidate)
Status: Active register. Every known shortcut, placeholder, or deferred item in this
repository is recorded here with an owner and a resolution path. No undocumented
creative debt may remain at the end of a phase.

Severity: Critical (blocks release/sale) · High · Medium · Low.
Status values: Open · In Progress · Resolved · Accepted (a deliberate, owned trade-off).

---

## Register

### CD-001: Brand art: department + state art placed; System A core mark still pending
- **Severity:** Medium · **Status:** In Progress · **Owner:** David Olverson
- **Detail:** Full keeper set pulled from the Palm6 Discord bot DMs and placed:
  **24 Palm6 department crests** (`01-BRAND/logos/departments/`) + **2 Verano state seals**
  (`01-BRAND/logos/state/`), all registered Candidate. **Still missing:** the **System A
  core identity mark** (the primary ownable Palm6/Verano logo) - a different asset class
  from the department crests and state seals.
- **Resolution:** (a) DONE - 24 departments + 2 state seals placed + registered.
  (b) OPEN - supply the System A core mark, place in `01-BRAND/logos/`, register it, and
  fill the System A specifics in `BRAND-GUIDELINES.md`. The brand half of the Phase 2 gate
  closes when the System A core mark lands.

### CD-006: Private-business logo tier rejected, being redone
- **Severity:** Low · **Status:** In Progress · **Owner:** David Olverson
- **Detail:** The first private-business logo batch (Apex Motors, Bayside Realty, Verano
  Air, Coastline Insurance, Harbor Freight, Palm Medical, Harbor Energy, PalmLink, Palm6
  Garage, +more - the synthwave "P6" style) was rejected as too generic/"ugly". Those
  assets are deliberately **NOT** committed to the repo.
- **Resolution:** David regenerates in ChatGPT using the improved system in
  `01-BRAND/BUSINESS-BRAND-BRIEF.md` (one palette, flat vector, one type family, one icon
  each, consistent lockup). Register the approved set in the Asset Registry once done.

### CD-002: `prop_spawn` dev resource is stopped, not removed
- **Severity:** Medium · **Status:** Accepted (for now) · **Owner:** Dev Lead
- **Detail:** `resources/[custom]/prop_spawn` is a dev-only test helper (ungated
  networked `CreateObject`). It is neutralized in production via `stop prop_spawn` in
  `custom.cfg` (execs after the panel's root server.cfg ensures it), because the panel
  server.cfg is outside this repo and cannot be edited to un-ensure it.
- **Resolution:** When panel access is available, remove the ensure from the root
  server.cfg and delete/relocate the resource. Until then the `stop` is the correct,
  documented mitigation. See `docs/RESTRUCTURING/PHASE-2-DEPRECATIONS.md`.

### CD-003: Placeholder in-world coordinates on new NPC destinations
- **Severity:** Low · **Status:** Open · **Owner:** David Olverson (in-game feel-test)
- **Detail:** Several discoverable destinations use placeholder coords pending an
  in-game pass: lottery kiosk (near Davis 24/7), gunrunning dealer (scrapyard lot),
  fightclub ring (Vanilla Unicorn back lot - config marks it placeholder pending MLO),
  black market (Config). All are flagged VERIFY IN-GAME in their configs.
- **Resolution:** David retunes coords/headings in-game; update the resource configs.

### CD-004: Downstream repo identities undefined (DEC-002a)
- **Severity:** Medium · **Status:** Resolved by DEC-005 (2026-07-18) · **Owner:** David Olverson
- **Detail:** Canonical remotes confirmed for Main Server (`BlacklineDevs/gtarp`) and
  Discord Bot (`BlacklineDevs/palm6-bot`). The **Website** and **Commercial Scripts**
  canonical repos are still undeclared (DEC-002a). Does not block gtarp Phase 2/3; does
  block starting the Website repo.
- **Resolution:** David declares the two remotes; log the ruling as a Decision Log entry.

### CD-005: Creative System Candidate until Phase 0 (now run, DEC-004)
- **Severity:** Medium · **Status:** Resolved by DEC-004 (2026-07-18) · **Owner:** David Olverson (Project Lead)
- **Detail:** gtarp adopted the Creative System as Candidate (v0.9.0-rc.1) per DEC-001.
  Phase 0 (the project-level Approval Gate that promotes the system to v1.0.0) has not
  run. Phase 2's entry condition is only "Phase 1 complete," so Phase 2 proceeds under
  the Candidate system; Phase 3 (Alignment) should run against an Approved system.
- **Resolution:** Run Phase 0 (Foundation Review + promotion) before gtarp Phase 3.
  See `14-OPERATIONS/README.md` for the DEC-numbering reconciliation.

### CD-007: Website repo lives in a personal org (davidolverson/palm6-web)
- **Severity:** Low · **Status:** Accepted · **Owner:** David Olverson
- **Detail:** DEC-005 fixed the Website canonical repo as `davidolverson/palm6-web` (the only
  live web repo). Consolidating it into the `BlacklineDevs` org would improve org hygiene and
  match Main/Bot, but is not required to proceed.
- **Resolution:** Optional future migration to `BlacklineDevs/palm6-web` at David's discretion;
  until then `davidolverson/palm6-web` is canonical. Non-blocking.

### CD-008: COLOR-SYSTEM awaits final visual refinement
- **Severity:** Low · **Status:** Accepted · **Owner:** David Olverson (Creative Lead)
- **Detail:** The Phase 0 promotion (DEC-004, Option B) approved the Foundation governance
  documentation to v1.0.0 but deliberately held `00-FOUNDATION/COLOR-SYSTEM.md` at Candidate,
  because it self-declares awaiting final visual refinement and locking. Promoting it now would
  be a fake-approval.
- **Resolution:** Lock the palette against the approved DESIGN-BIBLE and the System A core mark
  (CD-001) when it lands, then promote COLOR-SYSTEM to Approved via a Decision Log entry.

## Phase 3 scheduling pass (DEC-006, 2026-07-18)

Task 3.4 requires every open debt item to be closed or to carry an owner and a target date.

| Item | Owner | Status | Target |
|------|-------|--------|--------|
| CD-001 System A core mark | David (Creative Lead) | In Progress | Next brand session; prompts emailed 2026-07-18 |
| CD-002 prop_spawn ensure removal | David (Dev Lead) | Accepted | When txAdmin panel access is available |
| CD-003 NPC destination coords | David | Open | Next in-game feel-test pass |
| CD-006 private-business logo redo | David (Creative Lead) | In Progress | Regenerate in ChatGPT per BUSINESS-BRAND-BRIEF |
| CD-007 Website org migration | David | Accepted | Optional, non-blocking, at David's discretion |
| CD-008 COLOR-SYSTEM refinement | David (Creative Lead) | Accepted | Lock with the System A core mark (CD-001) |
| Cleanup: delete stray `BlacklineDevs/palm6-scripts-old-placeholder` | David | Open | Needs `delete_repo` scope (bot token lacks it) |

CD-004 (repo identities) closed by DEC-005; CD-005 (Phase 0) closed by DEC-004. The real
Commercial Scripts repo was renamed `GTARPScripts-` to `palm6-scripts` (DEC-006 follow-up),
so the canonical name now holds real content and GitHub redirects preserve the old URL.
