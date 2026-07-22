# Phase 1 Task 9 — in-game gate runbook (David)

Everything buildable is done + tested. This is the exact checklist to run the two
in-game gates and flip Threads live. Two gates are independent:

- **Stage A gate** (Phase 0 leftover): proves OUR generated `.ytd` renders in-game.
- **Phase 1 gate**: proves the whole loop — web design → slot → approve → stable index →
  game reads by citizenid → illenium equip + persist.

The KEY realization: Phase 1's equip path applies whatever `drawable_index` a deployed
design declares. A real *custom per-design* asset at index 4000+ needs the Stage B
generator (out of scope). But you can prove the ENTIRE Phase 1 plumbing + render RIGHT
NOW by pointing the test garment at the **Stage A drawable (component 11, drawable 0)** —
the one slot where a custom `.ytd` already renders. So the Phase 1 gate reuses the
Stage-A-proven asset and needs zero new binary work.

---

## 0. Prerequisites
- Deploy the `feat/palm6-threads` branch (both repos). `palm6_threads` + `palm6_dbmigrate`
  LOADED in `info.json` (FiveM drops erroring resources → LOADED = clean boot).
- `illenium-appearance` started (palm6_fc_combat already depends on it → it's present).
- `oxmysql` started (palm6_threads depends on it).

## 1. Stage A gate (unchanged, ~1 min)
1. In `palm6_threads/shared/config.lua` set `Config.Enabled = true`; deploy.
2. In-game: `/threads_spike`.
3. **Expect:** a hot-magenta shirt with teal diagonal stripe + white circle + black "P6"
   on the male torso (component 11, drawable 0). Renders = the make-or-break `.ytd`
   pipeline is proven in-game.
4. Revert `Config.Enabled = false` unless proceeding straight to the Phase 1 gate.

## 2. Phase 1 gate

### 2a. Confirm the 0074 tables (post-deploy)
```sql
SHOW TABLES LIKE 'palm6_clothing_%';   -- expect garments, slots, designs, slots_alloc, jobs
```

### 2b. Seed the base garments (idempotent; web owns this data)
Run once against the game DB (or hit the designer page which lists them — but the JOIN in
the game resource needs a row, so seed first):
```sql
INSERT INTO palm6_clothing_garments (label, category, gender, component_id, base_ydd_ref, uv_template_ref, uv_resolution, enabled)
VALUES ('Male Torso Tee','torso','male',11,'mp_m_freemode_01^jbib_000_u','uv/torso_m.png',512,1)
ON DUPLICATE KEY UPDATE component_id=VALUES(component_id);
-- (repeat for Female Torso Tee / Male Torso Hoodie if wanted; see seed.ts)
```
Note the garment `id` (`SELECT id,label FROM palm6_clothing_garments;`).

### 2c. Point the test garment at the Stage A drawable (temporary, for the gate)
So the equip renders the already-proven Stage A texture:
- **palm6-web** `src/lib/threads/designs.ts` → `RESERVED_BANDS[11] = { start: 0, size: 1 }`
- **palm6_threads** `shared/config.lua` → `Config.Bands = { [11] = { start = 0, size = 1 } }`
Redeploy web + resource. (Approve will now allocate drawable 0; equip applies drawable 0 =
the Stage A `.ytd`.) ⚠️ This writes a PERMANENT `slots_alloc` row at (11,0). Prefer a
non-prod DB for the test, or accept/clear that test allocation. **Revert both bands to the
O2 production values `{ start: 4000, size: 1000 }` after the gate** (see
`phase1-decisions-O1-O2-O3.md`).

### 2d. Enable the web surface (staff-only)
Set env `THREADS_WEB_ENABLED=true` (Coolify, is_literal=false). The editor/queue/API go live.
(Optional: `DISCORD_ROLE_THREADS_DONOR` / `DISCORD_ROLE_BUSINESS_OWNER` role ids to grant
those perks; founder auto-grants from the founding grant on opening the designer.)

### 2e. Grant the test citizen a slot
Either open `/dashboard/threads` as a founder (auto-syncs a founder slot), OR SQL:
```sql
INSERT IGNORE INTO palm6_clothing_slots (citizenid, source, source_ref, granted_at)
VALUES ('<TEST_CID>','admin','task9', UNIX_TIMESTAMP());
```

### 2f. Web loop
1. `/dashboard/threads`: pick the garment, choose base color + a decal + text, **Submit for
   review** (consumes the slot; design → `submitted`).
2. `/admin/threads` (as MOD+): **Approve**. Verify:
```sql
SELECT id,status,drawable_index,texture_index FROM palm6_clothing_designs WHERE citizenid='<TEST_CID>';  -- status=deployed, drawable_index=0 (test band)
SELECT * FROM palm6_clothing_slots_alloc;  -- one row (11,0,<designId>)
```

### 2g. In-game equip
1. `palm6_threads/shared/config.lua` → `Config.Enabled = true`; deploy.
2. In-game as the test citizen: `/threads` → equip the design.
3. **Verify (Task 9 criteria):**
   - [ ] Shows the Stage A texture (magenta shirt), NOT pink/missing.
   - [ ] Persists across respawn (illenium re-applies the saved skin).
   - [ ] No script error / console spam.
   - [ ] `palm6_threads` LOADED in `info.json`.
   - **PASS** → the entire Phase 1 loop is proven end-to-end. **FAIL** → diagnose (equip path
     vs. asset vs. index) before any flip; do NOT leave enabled on a failure.

## 3. After the gate
- Revert the test band to O2 `{ start: 4000, size: 1000 }` in BOTH repos.
- Set `Config.Enabled` to your chosen state (default `false` until you greenlight
  player-facing). Delete `client/debug.lua` now that Stage A has passed (plan Task 8 Step 6),
  and drop the `client_script 'client/debug.lua'` line from `fxmanifest.lua`.
- Push both `feat/palm6-threads` branches.
- Record PASS/FAIL + the outcome in `tools/threads-pipeline/README.md`.

## 4. Production custom-asset delivery (deferred, NOT this gate)
Real per-design custom textures at index 4000+ need the **Stage B generator** (PNG→DDS→
.ytd/.ydd + a SHOP_PED_APPAREL_META_FILE declaring the reserved index, committed to
`stream/`), gated on this render test passing. The `approved → deployed` seam +
`palm6_clothing_jobs` table are already in place for it. Until then, `deployed` designs are
seeded manually per Task 9 Step 3.
