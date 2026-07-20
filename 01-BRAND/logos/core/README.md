# System A Core Identity Mark: Landing Zone (reserved)

**Status:** DELIVERED + Approved (System A core mark, DEC-007, 2026-07-20). Files below. This folder is where David's
ChatGPT-generated System A files land, and this README is the runbook for placing, approving,
and propagating them. Brief + prompts: `../../SYSTEM-A-CORE-MARK-BRIEF.md`.

David generates the artwork in ChatGPT (standing hard rule). Everything below is what happens
the moment the files arrive; no image generation is done here.

## 1. Files David delivers (drop them in this folder)

| File | What | Naming |
|------|------|--------|
| Primary mark | main lockup (monogram, or monogram + wordmark), transparent | `palm6-core.png` (and `.svg` if vector) |
| One-color master | pure black `#000000` on transparent | `palm6-core-black.png` |
| Reversed | pure white on transparent, for dark backgrounds | `palm6-core-white.png` |
| 32px test | the mark rendered at 32px | `palm6-core-32px.png` |
| Clear-space note | one line (min clear space + min size) | recorded in this README on delivery |

## 2. Acceptance gate (run BEFORE any Approval)

All must be yes; source of truth is `00-FOUNDATION/07-QUALITY-STANDARDS.md` +
`00-FOUNDATION/08-DESIGN-REVIEW-CHECKLIST.md`.

- [ ] Legible and recognizable at 32px (verify against the 32px render, do not assume).
- [ ] Works as solid black on white AND reversed white on black; no gradient, chrome, glow,
      bevel, or shadow.
- [ ] Flat vector construction; no photographic or 3D effects.
- [ ] Timeless (5+ year horizon); not trend-chasing.
- [ ] Reproducible by hand and at any size (embroidery / engraving safe).
- [ ] Ownable and original; distinct from the 14 business logos and the Verano state seals.
- [ ] Strong, balanced negative space.

If any answer is no, it stays Candidate and goes back to David for a refined generation.

## 3. Placement + promotion (on a passing gate)

1. Files placed here in `01-BRAND/logos/core/`.
2. Advance the "Palm6 System A core identity mark" row in `17-ASSET-REGISTRY/ASSET-REGISTRY.md`
   from Experimental to **Candidate**, then to **Approved** once the gate passes.
3. Log a new gtarp Decision Log entry (next free `DEC-###`) that: records the acceptance-gate
   pass, promotes the mark to Approved, **closes CD-001** (and any System-A-dependent debt), and
   copies the master into `15-VAULT/`.
4. Fill the System A specifics in `01-BRAND/BRAND-GUIDELINES.md` (primary mark, clear space,
   min size, one-color and reversed usage).

## 4. Cross-repo propagation (after Approval)

- **Website (`palm6-web`):** regenerate the favicon from the monogram at
  `src/app/icon.svg`, update `src/app/apple-icon.tsx` and `src/app/manifest.ts`, and place the
  mark under `01-BRAND/logos/core/` there. This is where System A is most visible.
- **Discord Bot (`palm6-bot`):** use the mark for the bot avatar / embed branding; place under
  its `01-BRAND/logos/core/`.
- **Commercial Scripts (`palm6-scripts`):** place under its `01-BRAND/logos/core/` for any
  packaged / store branding.
- Each repo registers its copy and references gtarp's Approving DEC id (no re-approval needed).

## Clear-space note (fill on delivery)

Clear space: keep at least 1× the width of the P’s vertical stem on every side of the P6 mark.
