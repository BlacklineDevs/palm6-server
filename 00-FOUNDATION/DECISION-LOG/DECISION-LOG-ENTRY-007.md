# Decision Log Entry 007

**Date:** 2026-07-20
**Decision ID:** DEC-007
**Decision:** Approve the Palm6 System A core identity mark (the "P6" mark) and close CD-001.
**Status:** Approved. The flat one-color master passes the acceptance gate. The mark is promoted
to Approved and vaulted; CD-001 is closed.
**Owner:** David Olverson (Creative Lead).
**Authorization:** David generated the mark in ChatGPT and delivered the full package
(`palm6-p6-logo-package.zip`) on 2026-07-20 for approval, per the CD-001 execution path.

## What was delivered
`01-BRAND/logos/core/`: primary (`palm6-p6-primary.png`), one-color black master
(`palm6-p6-black-master.svg`), reversed white (`palm6-p6-reversed-white.svg`), a color 32px
(`palm6-p6-32px-color.png`), and a clear-space note. Clean mono renders generated from the master
for the gate and favicon use (`palm6-p6-mono-512.png`, `palm6-p6-mono-32.png`).

## Acceptance gate (against `07-QUALITY-STANDARDS.md` + `08-DESIGN-REVIEW-CHECKLIST.md`)
- **One flat color:** PASS. The `black-master.svg` and `reversed-white.svg` are clean
  single-color vector paths (one `#000000` / `#FFFFFF` path, no gradients, filters, or effects).
- **32px legible:** PASS. Rendered from the master, "P6" reads at 32px. The palm silhouette
  inside the 6 is a larger-size detail that drops at favicon scale; the mark still reads.
- **Flat vector / no effects (master):** PASS.
- **Reproducible by hand, any size:** PASS. Bold varsity letterform, simple silhouette.
- **Ownable / distinct:** PASS. "P6" with a palm inside the 6 is distinctive and on-theme for a
  Miami-style RP city; distinct from the department crests and Verano seals.

## System A vs System B classification (important)
The delivered **`primary.png` is a System B treatment**: gradient (pink to orange P, cyan 6),
3D bevel, and neon styling, which the System A brief deliberately steered away from
(no neon, no synthwave, no palm-sunset). That is fine as a **marketing lockup** and is registered
as **System B**. The **System A core identity mark is the flat one-color master** (black + reversed
white), which is what passes the gate and what governs favicon, official documents, and small-size
use. Both are approved for their respective roles. The bold Miami direction is recorded as an
intentional Creative-Lead choice, not a defect.

## What this authorizes
1. Advance the "Palm6 System A core identity mark" registry row Experimental to **Approved**
   (flat master); add a **System B "P6" lockup** row (Approved) for the color primary.
2. Vault the master into `15-VAULT/`.
3. **Close CD-001** in `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md`.
4. Fill the System A specifics in `01-BRAND/BRAND-GUIDELINES.md` and flip it to Approved.
5. Propagate (follow-up): Website favicon from the mono master (`src/app/icon.svg`), bot avatar,
   scripts branding; each repo references this DEC id.

## What this does NOT do
- It does not by itself change the Website favicon or any app code (that is a scoped follow-up in
  each repo).
- It does not touch `resources/**`, `sql/`, or `custom.cfg`.

## Related
`01-BRAND/logos/core/README.md`; `01-BRAND/SYSTEM-A-CORE-MARK-BRIEF.md`;
`17-ASSET-REGISTRY/ASSET-REGISTRY.md`; `14-OPERATIONS/CREATIVE-DEBT-TRACKING.md` (CD-001 closed);
`01-BRAND/BRAND-GUIDELINES.md`; DEC-004 (Option B, carried CD-001).
