# Phase 1 Task 1 — palm6-web path/pattern verification note

Recon done 2026-07-22 against the palm6-web checkout at
`C:\Users\Mgtda\Projects\Active\palm6-web` (shared checkout, then isolated worktree for
writes). Confirms every **[VERIFY AT EXECUTION]** path the plan flagged. Consumed by
Tasks 3–7.

## Confirmed interfaces

| Plan reference | Confirmed path | Exported signature / notes |
|----------------|----------------|----------------------------|
| discord→citizenid resolver | `src/lib/data/citizen.ts` | `getPrimaryCitizenId(discordId: string): Promise<string \| null>` and `getCharactersByDiscord(discordId): Promise<{characters: CharacterCard[]; offline: boolean}>`. Reads game DB via `@/lib/db`. `server-only`. |
| game-DB client | `src/lib/db.ts` (import `@/lib/db`) | `query<T>(sql, params?): Promise<T[]>`; `execute(sql, params?): Promise<mysql.ResultSetHeader>` (has `insertId`/`affectedRows`); **`withTransaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T>`** with `Tx.query`/`Tx.execute` — supports `SELECT ... FOR UPDATE`. `server-only`, Node runtime only (mysql2). Uses `?` placeholders (NOT named). |
| role / staff gating | `src/lib/auth/session.ts` (import `@/lib/auth/session`) | `getSession(): Promise<Session \| null>`; `Session = {sub, name, avatar, tier: Tier, cid: string\|null, exp}`; `TIER = {PLAYER:0, MODERATOR:1, ADMIN:2, OWNER:3}`; `atLeast(session, min): session is Session`; `resolveTier(roleIds)`. **Session already carries `cid` (linked citizenid) and `tier`** — player gate = `getSession()` + `session.cid`; admin gate = `atLeast(session, TIER.MODERATOR/ADMIN)`. |
| perk grantor (founder) | `src/lib/founding.ts` | `getActiveGrant(discordId): Promise<{tagLabel, tagIcon} \| null>` reads `palm6_founding_grants` (keyed by `discord_id`). Founder = active grant present. Uses `@/lib/db` `withTransaction`/`execute`/`query`. |
| test conventions | `src/lib/auth/session.test.ts` | **vitest** (`describe/it/expect/vi/beforeEach/afterEach`). Env set inline (`process.env.X = ...`). `vi.mock("next/headers", ...)` to stub server-only deps. For DB-touching modules, `vi.mock("@/lib/db", ...)`. Co-located `*.test.ts`. |
| storage helper (gang-logo) | `src/lib/gangs.ts` | ⚠️ **Only stores a URL string** — `updateGangBranding(... SET logo_url = ?)`. The actual file-upload mechanism is NOT here (client-side upload → URL → store). **Task 6 open item** (see below). |

## Corrections vs. the plan's File Structure

- **DB client name** was "TBD" → it is `@/lib/db` with `query`/`execute`/`withTransaction`.
  The allocator (Task 5) should use `withTransaction` + `SELECT ... FOR UPDATE` on
  `palm6_clothing_slots_alloc` so concurrent approvals serialize (same pattern as
  `founding.ts` `linkDiscordReservation` and the reservation allocator this codebase
  already uses).
- **Role gating name** was "TBD" → `@/lib/auth/session` (`getSession`/`atLeast`/`TIER`).
  Note: `session.ts` only resolves MOD/ADMIN/OWNER *staff* tiers. The perk *grantor*
  roles (founder/business-owner/donor) are NOT tiers — founder is `founding.ts`
  `getActiveGrant`; business-owner is `palm6_businesses` ownership; donor is a Discord
  role id. Task 4 must wire these grantor sources explicitly/configurably, not via
  `resolveTier`.
- **Storage** was "TBD" and is a genuine gap for the curated texture PNG. **Resolution
  for Task 6:** a curated design is a *pure function of its spec* (garment + library
  color/decal/text refs, all server-owned). So Phase 1 can store the **curated spec JSON**
  in a column and treat `texture_ref` as either (a) a deterministic server-composed PNG
  written to a storage path, or (b) deferred/recomposed on demand. Decide the concrete
  storage sink (local public dir vs. object store) at Task 6 Step 1 against how gang
  logos actually get their URL; do NOT invent an object-store client that doesn't exist.

## palm6-web write isolation

palm6-web shared checkout was on `feat/system-a-favicon` with uncommitted work at recon
time. Threads web code (Tasks 3–7) was written in an **isolated palm6-web worktree**:

- **Worktree:** `C:\Users\Mgtda\Projects\Active\palm6-web-threads`, branch
  `feat/palm6-threads` off `origin/main` (base `56c3b7b`). node_modules is a **junction**
  to the main checkout — ⚠️ STRIP the junction before any `git worktree remove` (the
  junction-follow data-loss landmine), and Turbopack `next build` rejects the junction
  ("symlink out of filesystem root") → use `next build --webpack` here (tsc + vitest
  follow the junction fine).

**palm6-web commit hashes (branch feat/palm6-threads):**
| Task | Commit | Contents |
|------|--------|----------|
| Task 3 | `bd76a57` | catalog.ts + library + validate + db.ts + seed.ts (12 tests) |
| Task 4 | `b2910b9` | entitlement.ts + tests (12 tests) |
| Task 5 | `2ed6697` | designs.ts lifecycle + allocator + designs/db tests (→40 tests) |
| Tasks 6+7 | `487ff61` | API routes + editor + admin queue + actions (→47 tests) |

**Verification:** `tsc --noEmit` clean (0 errors); 47 vitest tests green;
`next build --webpack` COMPILED OK, all 4 threads routes emitted dynamic.

**gtarp worktree commits (branch feat/palm6-threads):** Task 1+decisions `58ea936`,
Task 2 migration `e5d814c`, Task 8 FiveM equip `99b814c`. Neither repo's branch is
pushed yet (awaiting David).
