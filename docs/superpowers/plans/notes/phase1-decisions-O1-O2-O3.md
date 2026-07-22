# Phase 1 — Locked decisions (O1 / O2 / O3)

Resolves the three open questions in
`2026-07-22-palm6-threads-phase1-curated-core-loop.md` §Self-review. Locked with
defaults on David's "do all above" (2026-07-22). O2 is the only permanent choice and
is flagged for David's confirmation before Task 9 writes the first allocation.

## O1 — curated approval: **light staff gate** (LOCKED)

`submitDesign` transitions `draft → submitted`; the design appears in `/admin/threads`
and a staff member approves it (one click). Curated designs do NOT auto-approve.

**Why:** curation bounds *what assets* a design may reference (library colors/decals/
fonts only) but residual abuse survives — a text field can spell a slur from legal
glyphs, or combine a legal decal + legal text into brand-adjacent/hateful output. A
one-click staff gate is the cheap IP safety net the Take-Two risk (§Global Constraints
"IP is existential") demands, and it gives the Task 7 admin queue a real Phase-1 purpose.
Task 5 `submitDesign` therefore does NOT collapse `submitted→approved→deployed`.

## O2 — reserved drawable-index band: **component 11 → start 4000, size 1000** (LOCKED, ⚠️ PERMANENT)

`Config.Garments[].drawableBase = 4000` for component 11 (jbib/torso); the allocator
assigns the lowest free index in `[4000, 5000)`; `palm6_clothing_slots_alloc` PK
`(component_id, drawable_index)` enforces never-reused. Future components get their own
non-overlapping bands (e.g. component 8 tshirt → 5000, component 4 pants → 6000).

**Why:** base-game `mp_m_freemode_01` component-11 drawable counts are in the low
hundreds even summed across all official DLC; a band starting at 4000 is unmistakably
above any base-game or common community-addon index, so collision is effectively
impossible. `drawable_index` is an INT (Task 2 schema) so the magnitude is free. Band
size 1000 is ample Phase-1 headroom; the 128-item addon sub-pack cap is the Stage B
*generator's* concern (it splits packs), NOT the allocator's numbering.

**⚠️ PERMANENT:** an allocated index is never renumbered or reclaimed (illenium saves
outfits by `{component, drawable, texture}`; renumbering corrupts every saved outfit).
No allocation is written until Task 9 (David's gate) approves the first design, so this
band is still freely changeable until then. **David: confirm 4000/1000 against the
actual server's base-game + installed-addon clothing inventory before the Task 9 gate.**

## O3 — `approved → deployed` in Phase 1: **accept staff-driven seam** (LOCKED)

On approval, staff click approve → `approveDesign` (allocate index) → `markDeliverable`
(`approved → deployed`) in one action (Task 7). The physical `.ytd` is seeded manually
(Task 9 Step 3) as the stand-in for the future Stage B worker.

**Why:** the Stage B binary generator is out of scope (gated on the un-passed in-game
render test). Holding designs at `approved` until that worker exists would leave nothing
in `status='deployed'`, so the Task 8 equip path (reads `deployed` by citizenid) would be
untestable — defeating Phase 1's whole point of proving the loop end-to-end. The
`palm6_clothing_jobs` table + the `approved→deliverable` seam stay in place for Stage B
to split (approve → dispatch → generate → deliverable) later.
