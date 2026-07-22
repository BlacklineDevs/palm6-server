# PALM6 Threads — Player-Created Custom Clothing (Design Spec)

**Date:** 2026-07-22
**Status:** Design — approved for spec, pending plan
**Author:** Kai (for David)
**Repos touched:** `gtarp` (FiveM server + generation pipeline) · `palm6-web` (editor, entitlement, admin) · GitHub Actions (generation worker)

---

## 1. Summary

Let PALM6 players design their own clothing (custom textures on a curated catalog of base
garments) through the **web dashboard**, have it moderated + staff-approved, automatically
packed into real GTA5 addon-clothing files, deployed through our normal git→CI→SFTP pipeline,
and delivered onto their character in-game. Monetized via a hybrid entitlement: a **Tebex
"custom clothing slot" purchase OR an existing perk/role** (founder / business owner / donor)
grants slots.

This is a **native, first-party rebuild** of the third-party product INTRACT. We build it
ourselves because INTRACT is a closed-source hosted platform that (a) auto-installs to prod via
its own txAdmin hook (a third party with write access to a monetized, Cfx-keyed live server),
(b) makes us liable for a player-upload IP-moderation queue with no control over the tooling, and
(c) takes revenue share. Building native keeps every asset flowing through our own reviewed
pipeline and keeps 100% of revenue.

### Non-goals (v1)
- **No custom 3D geometry.** Players retexture a curated catalog of pre-made base garments; they
  do not upload or generate new `.ydd` models. (INTRACT itself lists custom models as "upcoming".)
- **No in-game design surface.** Design happens on the web dashboard, not via an in-game menu.
- **No live/instant deploy.** Approved assets apply on the next scheduled server restart (batched),
  same as INTRACT and consistent with our deploy discipline.

---

## 2. How INTRACT works (reverse-engineered, for reference)

1. **Store** — Tebex-native via the headless API + FiveM ident (`ident.tebex.io/fivem`). A purchase
   binds to the buyer's Cfx/FiveM account — that account is the delivery key.
2. **Editor** (browser) — pick a base garment → three input modes: **upload artwork · AI-generate ·
   colors/decals** → place/scale → real-time preview → submit for approval.
3. **Moderation** — AI moderation (NSFW / hate symbols / copyrighted logos / real-world brands) +
   optional manual staff review.
4. **Asset generation** — described by the author as "an automated Durty Cloth": composites the
   design into a texture and packs GTA clothing files. Transfers only packed `.ymt`, `.ydd`, `.ytd`.
5. **Deploy** — ~600-line, zero-dep, framework-agnostic server script pulls the packed assets
   (secret-key authed) and auto-installs on restart via txAdmin.
6. **Delivery** — the approved garment is assigned to the buyer's ped in-game.

**Our design mirrors 1–6 but swaps the closed pieces for first-party equivalents that ride our
existing infrastructure.**

---

## 3. The critical technical finding

**FiveM addon clothing is streamed as loose `.ydd`/`.ytd`/`.ymt` files from a resource `stream/`
folder — NOT packed into an encrypted `.rpf`.** PALM6 already does exactly this for
`palm6_props`/`mystudio_props`. This removes the two scariest blockers up front: **no RPF packing
and no extracting NG/AES keys from `GTA5.exe`.** INTRACT's "packed .ymt/.ydd/.ytd" is precisely this
loose-file model.

Therefore the hard problem reduces to a mechanical chain:

```
player texture PNG
  → DDS         (texconv or AMD Compressonator; formats BC1/BC2/BC3/BC7 = DXT1/3/5/BC7)
  → .ytd        (C# microservice on CodeWalker.Core — the ONLY step lacking a turnkey CLI)
  → copy base .ydd into a reserved drawable slot   (Approach B, see §5)
  → .ymt        (gtautil `genpeddefs --fivem`)
  → loose-file FiveM resource (stream/ + meta/ + fxmanifest data_file)
  → assign onto ped   (SetPedComponentVariation via illenium-appearance persistence)
```

No `.rpf`, no game keys. The single piece without an off-the-shelf CLI is **DDS→`.ytd`**, built in
~a few hundred lines of C# against `CodeWalker.Core` (NuGet, .NET Standard 2.0, MIT). The GPL-3.0
tool **grzyClothTool** already chains this exact flow and is the reference implementation to study
(reference, not copy, given GPL).

---

## 4. Architecture — six subsystems

```
                         palm6-web (Next.js, Discord OAuth, shared game DB)
   ┌───────────────────────────────────────────────────────────────────────────┐
   │  (1) Entitlement      (2) Web Editor        (3) Moderation   (6) Admin queue │
   │   slot ledger          3 input modes         AI vision        staff approve  │
   └───────────────┬───────────────┬────────────────┬──────────────────┬─────────┘
                   │ writes         │ writes         │                  │ approve → dispatch
                   ▼                ▼                ▼                  ▼
        ┌──────────────────────────────────────────────────────────────────────┐
        │           Shared game DB  (palm6_clothing_* tables)                    │
        └───────────────┬───────────────────────────────────────────┬───────────┘
                        │ approved job                               │ approved+deployed design
                        ▼                                            ▼
        (4) Generation worker  (GitHub Actions windows-latest)   (5) palm6_threads (FiveM)
            PNG→DDS→.ytd→.ydd→.ymt → commit to                      streams addon, reads DB by
            palm6_threads/stream → CI→SFTP → restart                citizenid, equips via illenium
```

**Seam of the whole system = the shared game DB.** palm6-web writes; the game resource reads. Same
pattern already used by `palm6_business` and the other palm6_ systems. palm6-web already connects to
this DB (`GTARP_DB_*`) and already resolves `discord → citizenid`
(`users.discord → users.userId → players.userId → players.citizenid`, see
`palm6-web/src/lib/data/citizen.ts`).

---

## 5. Asset pipeline (subsystem 4 — the make-or-break)

### 5.1 Addon-clothing approach: one drawable per custom item ("Approach B")

Each approved custom item becomes a **self-contained `{ydd, ytd, ymt-entry}` triple at a stable,
reserved drawable index**, rather than an extra texture variation on a shared base drawable
("Approach A"). Rationale:
- Isolated per player: generate, stream, assign, and revoke one item without mutating anyone else's
  data.
- Safe assignment/GC: `SetPedComponentVariation(ped, component, <newDrawable>, 0, 2)`.
- Cost: duplicates the base `.ydd` geometry per item (byte-identical, small vs. textures) and burns
  drawable slots — mitigated by pre-reserving slot ranges (see §5.4).

Approach A (grow a shared drawable's texture table) is leaner on disk but harder to reason about and
to revoke per player; rejected for v1.

### 5.2 The generation chain (exact tools)

| Step | Tool | Notes |
|------|------|-------|
| Validate/resize PNG to garment UV resolution | `sharp` (Node) or ImageMagick | Enforce the garment's UV template; reject off-template uploads (avoids pink/misaligned textures). |
| PNG → DDS | **texconv** (`-f BC7_UNORM` / `BC3` for smaller) on Windows worker | Windows-native; BC7 GPU path is DirectX. AMD **Compressonator** is the cross-platform fallback if we ever move to Linux. |
| DDS → `.ytd` | **C# microservice on CodeWalker.Core** | Load DDS → `Texture` → `TextureDictionary` → `YtdFile.Save()`. The one bespoke component. |
| Base `.ydd` → reserved drawable slot | file copy | Base geometry pre-exists in the catalog; copy into the assigned stable index. |
| `.ymt`/`.meta` generation | **gtautil `genpeddefs --input <proj> --output <build> --reserve N --reserveprops N --fivem`** | Produces the freemode component metadata with the new drawable+texture entry. `--reserve` locks slots so indices never shift. |
| Assemble resource | our script | `palm6_threads/stream/` (loose `.ydd`/`.ytd`) + `meta/` (`.ymt`/`.meta`) + `fxmanifest.lua` `data_file 'SHOP_PED_APPAREL_META_FILE'`. |
| Deliver | git commit → CI → SFTP → restart | Worker commits generated assets to `palm6_threads` on a bot branch; normal deploy applies on restart. |

### 5.3 Where the worker runs

**GitHub Actions `windows-latest` runner, triggered by `repository_dispatch` on staff approval.**
- Zero incremental cost (free tier covers low approval volume; approvals are infrequent and human-gated).
- It *is* our CI — no new always-on server, no third party writing to prod.
- The runner: pulls the design PNG, runs the chain, commits the generated `stream/`+`meta/` assets
  back to `palm6_threads` (via a scoped deploy token), which triggers the existing CI→SFTP deploy.
- Fallback if free minutes are ever exhausted: run the same scripts on David's Windows box or a
  cheap Windows VPS. The pipeline is infra-agnostic; only the *trigger* changes.

### 5.4 Index stability (a hard invariant)

illenium/qb save skins by **index** (`{component, drawable, texture}`). If a regenerated pack ever
renumbers drawables/components, **every saved outfit corrupts.** Therefore:
- A persistent **slot allocator** (`palm6_clothing_slots_alloc`, see §6) assigns each item a fixed,
  never-reused drawable index per component.
- Generation always uses `gtautil --reserve`/`--reserveprops` with a fixed reservation so component
  IDs and the reserved band never shift.
- Revoked/deleted items free nothing by default (the index stays burned) — simplicity over reclaim.

### 5.5 Streaming cap & Cfx key

Addon `.ymt` shop packs cap at ~128 items per addon (grzyClothTool auto-splits this). Our generator
must **split into multiple sub-packs** past that limit — planned from the start. Also: streaming
addon clothing beyond ~9 stream slots requires a **Cfx Element Club Argentum** key. PALM6 already
streams props, so verify the current key tier during Phase 0 (ops item, not code).

---

## 6. Data model (shared game DB — new `palm6_clothing_*` tables, via `palm6_dbmigrate`)

All migrations are idempotent (the `palm6_dbmigrate` re-runs-every-boot convention) and registered
in the hardcoded migration list. `DEFAULT` values follow the "first-boot safety" pattern (no mass
back-grant on the first restart).

- **`palm6_clothing_garments`** — the curated base catalog.
  `id, label, category, gender, component_id, base_ydd_ref, uv_template_ref, uv_resolution,
   enabled, created_at`.
- **`palm6_clothing_slots`** — the entitlement ledger (one row = one grant).
  `id, citizenid, source ENUM('tebex','perk','admin'), source_ref (tebex txn id / role id),
   granted_at, consumed_by_design_id NULL, revoked BOOL DEFAULT 0`.
- **`palm6_clothing_designs`** — one player design through its lifecycle.
  `id, citizenid, garment_id, source_mode ENUM('curated','upload','ai'), texture_ref (stored PNG),
   status ENUM('draft','submitted','mod_pending','approved','rejected','generating','deployed','failed'),
   moderation_json, staff_reviewer, reject_reason, drawable_index NULL, texture_index NULL,
   created_at, updated_at`.
- **`palm6_clothing_slots_alloc`** — stable index allocator.
  `component_id, drawable_index, design_id, allocated_at` (UNIQUE(component_id, drawable_index)).
- **`palm6_clothing_jobs`** — generation job queue / audit.
  `id, design_id, status ENUM('queued','running','done','failed'), attempts, worker_run_id,
   error, artifact_ref, created_at, updated_at`.

Web owns writes to garments/slots/designs/jobs. The game resource reads `designs` (status='deployed')
by citizenid and reads `garments`; it never writes economy-owned tables.

---

## 7. Entitlement (subsystem 1)

A single **slot ledger** fed by two grantors, so "sell it" and "perk it" coexist:

1. **Tebex purchase** — a new `POST /api/tebex/webhook` in palm6-web, **HMAC-verified** against the
   Tebex webhook secret. On a "Custom Clothing Slot" package purchase, resolve the buyer to a
   `citizenid` (via their linked Discord / Cfx ident) and insert a `slots` row `source='tebex'`.
2. **Perk / role** — a founder / business-owner / donor Discord role grants N slots (on login or a
   periodic sync). Reuses palm6-web's existing role-gating (`DISCORD_ROLE_*`) and the founding-grant
   bot-URL pattern already in the env.

Starting a design **consumes** a slot (`consumed_by_design_id`); a rejected design **refunds** it.
Cap concurrent in-flight designs per player. This is the abuse boundary — slots are the scarce
resource, gated at grant time, so the editor/pipeline can't be spammed.

---

## 8. Web editor (subsystem 2)

Route: `palm6-web/src/app/dashboard/threads` (Discord-auth + slot gated). Flow: pick base garment →
choose input mode → design → live preview → submit.

**Three input modes, all producing one artifact: a flattened texture PNG at the garment's UV
resolution.** (This is the key insight — the modes differ only in how the PNG is produced; the entire
downstream pipeline is identical, so "support all three" is cheap once the pipeline exists.)

1. **Curated (color + decal + text)** — pick base/accent colors, place decals/patterns/text from a
   **pre-vetted library** we control, on the garment UV. **Zero IP risk, no moderation queue.** This
   is the Phase 1 mode and the safe default.
2. **Upload artwork** — upload an image, constrained/clamped to the garment UV template. Requires
   moderation + staff approval (Phase 3).
3. **AI-generate** — text prompt → texture via an image model. Requires prompt + output moderation +
   staff approval (Phase 4).

Preview: MVP is a 2D UV-template composite; a three.js 3D preview (garment model + live texture) is a
Phase 4 polish. Follows the palm6-web design system (dark-mode-only brand).

---

## 9. Moderation (subsystem 3)

On submit:
- **Curated** designs skip heavy moderation (assets are pre-vetted; still lint text for slurs).
- **Upload / AI** designs run a **vision moderation** pass (NSFW / hate symbols / real brands /
  copyrighted logos). Clear violations auto-reject with reason; everything else lands in the staff
  queue as `mod_pending` with the model's verdict attached.

Model: a vision-capable moderation call (Claude vision or a dedicated image-moderation model). No new
paid API where avoidable (David is on Max / zero-budget) — prefer the moderation path that reuses
existing access. **Staff approval is always the final gate before generation**, regardless of the AI
verdict — the AI narrows the queue, it never ships unreviewed.

This directly honors the standing rule: **on a monetized, Cfx-keyed public server, real-likeness /
copyrighted / ripped assets are existential (Take-Two owns Cfx.re → can pull the server key + Tebex
store).** Curated-first + AI-screen + human-gate is the defense.

---

## 10. FiveM resource `palm6_threads` (subsystem 5)

Lives in `gtarp/resources/[custom]/palm6_threads`. Follows every PALM6 convention:
- **Ships `Config.Enabled = false` (prod-inert)** until Phase 0/1 is proven, then flipped in one
  batched deploy.
- **Streams** the generated addon: `stream/` (loose `.ydd`/`.ytd`) + `meta/` + `fxmanifest.lua`
  `data_file 'SHOP_PED_APPAREL_META_FILE'`.
- **Reads** `palm6_clothing_designs` (status='deployed') by `citizenid` → the set of custom items that
  player owns.
- **Delivery**: writes `{component, drawable, texture}` into the player's `illenium-appearance` saved
  skin (via its exports / the appearance DB) so it reapplies on every spawn, and exposes an in-game
  **`/threads` wardrobe** (or a wardrobe NPC using the existing insurance/lottery bridge pattern) to
  equip/unequip owned custom items.
- **DoS-budgeted** in `palm6_eventguard`; migrations via `palm6_dbmigrate`; `CancelEvent()` before any
  yield per the FiveM rule.

Confirmed integration surface (from `palm6_fc_combat`): `exports['illenium-appearance']:getPedAppearance(ped)`
and `:setPedAppearance(ped, appearance)` exist and are used in-tree today.

---

## 11. Admin approval queue (subsystem 6)

Route: `palm6-web/src/app/admin/threads` (mod/admin role gated). Staff see each pending design with a
preview render + the moderation verdict, and **approve / reject with a reason**. Approve →
`repository_dispatch` to the generation worker + set `status='generating'`. Reject → refund slot +
notify. Full audit trail (`staff_reviewer`, timestamps). Mirrors the existing `/admin/whitelist` and
`/admin/players` admin surfaces.

---

## 12. Deployment & infrastructure

- **Generation worker**: GitHub Actions `windows-latest`, `repository_dispatch` trigger (§5.3).
- **Asset deploy**: worker commits generated `stream/`+`meta/` to `palm6_threads` → existing CI→SFTP
  → applies on scheduled restart. **Batch** approvals into restarts; never restart prod per-design.
- **Web deploy**: palm6-web ships via Coolify (existing). New env: `TEBEX_WEBHOOK_SECRET`,
  moderation model creds (if any), worker dispatch token.
- **Cfx key**: verify Element Club Argentum tier during Phase 0 (§5.5).
- **DB**: shared game DB — migrations added to `palm6_dbmigrate`'s hardcoded list; idempotent;
  first-boot-safe defaults. ⚠️ The game DB is shared across ~60 worktrees; coordinate the migration
  add so it doesn't collide (same discipline as the records-hub `db push` hold).

---

## 13. Security, IP & abuse

- **IP** — curated-first (no uploads in Phase 1); uploads/AI always behind AI-screen + human gate.
- **Entitlement is the rate limiter** — slots are scarce and granted server-side; the pipeline can't
  be spammed without a slot.
- **Webhook** — Tebex webhook HMAC-verified; reject unsigned. No client can forge a slot grant.
- **Delivery authority** — the game resource assigns only items whose `designs` row is
  `status='deployed'` AND `citizenid` matches; nothing client-asserted.
- **Worker isolation** — the worker only ever transfers `.ydd`/`.ytd`/`.ymt`/`.meta` and only writes
  the `palm6_threads` resource path (mirrors INTRACT's "only packed clothing files" guarantee).
- **File validation** — every uploaded PNG is re-encoded (strip EXIF/polyglot), size/dimension-capped,
  and clamped to the garment UV template before it ever reaches the packer.

---

## 14. Build phases

Even though the full platform is specified now, the build is **phased so the make-or-break is proven
first** and each phase ships behind `Config.Enabled=false` until verified.

- **Phase 0 — Pipeline spike (make-or-break).** Prove the whole chain on ONE hand-fed PNG: DDS→`.ytd`
  via CodeWalker.Core → base `.ydd` copy → `.ymt` via gtautil → `palm6_threads` streams it → it wears
  correctly on a character in-game on PALM6 via illenium. **No web UI.** If this fails, stop and
  rethink before building anything else. Also: confirm the Cfx key tier and the GH Actions Windows
  runner can run texconv + CodeWalker.Core + gtautil.
- **Phase 1 — Core loop, curated-only, perk-gated.** Catalog seed + curated color/decal editor + slot
  ledger (perk/role grant only) + admin approve + worker (GH Actions) + `palm6_threads` delivery +
  `/threads` wardrobe. No Tebex, no uploads, no AI. Flip `Config.Enabled` when proven end-to-end.
- **Phase 2 — Tebex monetization.** `POST /api/tebex/webhook` (HMAC) → slot grant; "Custom Clothing
  Slot" SKU on the store; store page wiring.
- **Phase 3 — Uploads + moderation.** Upload mode + vision moderation + expanded staff queue.
- **Phase 4 — AI-generate + 3D preview + Discord showcase.** Prompt→texture mode; three.js live 3D
  preview; optional Discord showcase tag on go-live.

---

## 15. Risks & open questions

1. **DDS→`.ytd` via CodeWalker.Core (highest risk).** No turnkey CLI; ~few-hundred-line C# service.
   **Must be proven in Phase 0 before anything else.** Reference: grzyClothTool (GPL — study, don't
   copy).
2. **Index stability.** A renumbered pack corrupts saved outfits. Enforced by the slot allocator +
   `gtautil --reserve`. Needs careful testing on regeneration.
3. **gtautil on GitHub Actions Windows runner.** gtautil is Windows-oriented C# but its Actions
   compatibility is unproven — validate in Phase 0; fallback is a local Windows box.
4. **Cfx Element Club Argentum** requirement for addon streaming (ops/cost). Verify current tier.
5. **128-item addon cap** → generator must split sub-packs. Designed for, but adds generator
   complexity.
6. **UV correctness** — a retexture only looks right if the PNG respects the garment UV; the editor
   must constrain to the template.
7. **Shared DB migration coordination** across ~60 worktrees.
8. **Tebex→citizenid resolution** — confirm how a Tebex purchase maps to a Discord/Cfx identity we can
   resolve to citizenid (FiveM ident vs. requiring the buyer to be logged into the dashboard).

---

## 16. Testing strategy

- **Phase 0**: manual in-game verification is the gate (no automated test can prove a `.ytd` renders).
  Success = the hand-fed garment wears correctly and persists across respawn.
- **Web**: unit tests for entitlement (slot grant/consume/refund), webhook HMAC verification, and the
  design lifecycle state machine; follow palm6-web's existing test conventions
  (`src/lib/auth/session.test.ts`).
- **FiveM**: `luaparse`-clean on every `.lua`; boot-verify via deploy (no local FXServer); smoke the
  `/threads` wardrobe + delivery via an ace-gated debug command before enabling.
- **Pipeline**: a golden-input test — a fixed PNG must always produce a byte-stable, in-game-valid
  asset at the same reserved index.

---

## 17. Sources (toolchain research, 2026-07-22)

- Loose-file streaming (no RPF): Cfx.re "stream clothes/props as addons"; TimyStream clothing addon
  template.
- `.ytd` construction: CodeWalker.Core (NuGet, .NET Standard 2.0, MIT); grzyClothTool (GPL-3.0,
  reference); gtautil (`genpeddefs --fivem`, Windows/.NET); ytdtool (cross-platform CLI, immature).
- PNG→DDS: Microsoft texconv/DirectXTex (MIT); AMD Compressonator (cross-platform, BC1–BC7).
- `.ymt` structure: "Basic Ped YMT Editing — Components, Clothes, Textures".
- Assignment/persistence: illenium-appearance `customization.lua` / `util.lua`
  (`SetPedComponentVariation`, per-character persistence).
- Local integration points verified in-tree: `palm6-web/src/lib/data/citizen.ts` (discord→citizenid),
  `gtarp/resources/[custom]/palm6_fc_combat/bridge/cl_game.lua` (illenium exports).

---

*Next: `writing-plans` → Phase 0 implementation plan.*
