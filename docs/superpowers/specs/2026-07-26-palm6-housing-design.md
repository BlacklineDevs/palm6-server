# palm6_housing — Design Spec

**Date:** 2026-07-26
**Status:** Draft for review
**Author:** Kai (for David / PALM6)
**Phase:** 1 of the Quasar-gap roadmap (Housing → Casino → Restaurant)

---

## 1. Goal

Add the one core RP pillar PALM6 is missing: player-owned housing. A **hybrid** model —
tiered **apartments** as the starter rung for everyone, plus purchasable **real-map houses**
as prestige — with **full furniture placement from day one**, storage, wardrobe, roommate
keys, and a home respawn point. Housing is the strongest retention mechanic in RP (players
anchor to a home and a place to store/show off their stuff), so this is Phase 1.

### Success criteria
- A player can buy an apartment at a lobby, enter their private instance, store items, save
  outfits, set it as spawn, and have all of it persist across relog and server restart.
- A player can buy a real-map house via an in-world "For Sale" point, get door ownership, and
  grant keys to roommates.
- A player can buy furniture, place/move/rotate/remove it inside their home, and it persists.
- Purchases and a recurring property tax move money through `palm6_economy` as a net sink.
- Zero cross-instance leakage: player A never sees player B's apartment or furniture.

### Non-goals (explicitly out of scope for v1)
- Buying/selling houses between players (player-to-player market) — sell-back is to the city only.
- Housing raids/robberies (a later tie-in to the crime systems).
- Shared/warehouse gang bases (separate future system).
- Exterior customization of real-map houses.

---

## 2. Framework & conventions

- Standard `palm6_*` resource: `server/`, `client/`, `shared/`, `bridge/` (matching e.g.
  `palm6_business`, `palm6_yard`).
- QBox (`qbx_core`) + `ox_inventory` + `ox_lib` + `ox_target` + `oxmysql`.
- Money via `palm6_economy` (clean-money debit/credit; tax as a sink, matching the
  lottery-rake / numbers-edge sink pattern).
- Storage via `ox_inventory` registered stashes. Outfits via the ox appearance/outfit path
  already used on the server.
- SQL via a new numbered migration through `palm6_dbmigrate` (next free number, e.g.
  `0073_housing.sql` — confirm the actual next index at implementation time).
- FiveM discipline per house rules: `CancelEvent()` before any yield in event handlers; no
  `;` comments in cfg; server-authoritative money and ownership (never trust the client).

---

## 3. Architecture — Approach A: routing buckets + MLO interiors

**Chosen approach (of three considered):**

- **A. Routing buckets + MLO interiors** ✅ — each owned home instance = a routing bucket for
  privacy; interiors are MLOs (many already loaded by `bob74_ipl`); furniture spawns as
  networked objects inside the owner's bucket. Most QBox-native, reuses loaded IPLs, cleanest
  furniture isolation, no new dependency.
- B. Sky-shell system — infinite instances but adds a shell dependency and blander interiors. Rejected.
- C. Split MLO-houses / shell-apartments — most flexible, two interior systems to maintain. Rejected for v1.

### Instancing model
- **Apartments:** a fixed set of MLO interiors (studio → penthouse tiers). Each *owner* gets a
  private instance realized as a **routing bucket**. On enter, the player is moved into their
  bucket and teleported to the interior spawn; on exit, back to bucket 0 at the lobby door.
- **Houses:** real-map buildings with an MLO/enterable interior. Ownership is per-property
  (one owner per house). Entry uses the same bucket-per-property instancing so furniture and
  roommates are isolated, but the entrance is a fixed door on the map rather than a lobby menu.

### Bucket allocation
- A server-side allocator maps `property_owner_id → routing bucket id` on demand (first entry),
  releasing the bucket when the last occupant leaves. Deterministic, no collisions, logged.

---

## 4. Data model (new migration)

- **`palm6_properties`** — catalog of ownable units.
  `id, ptype ('apartment'|'house'), label, tier, entrance_x/y/z/h, interior_key (MLO/coords),
  price, storage_slots, storage_weight, spawn_x/y/z/h (interior), config JSON, enabled`.
- **`palm6_property_owners`** — ownership + per-instance state.
  `id, property_id, citizenid, purchased_at, last_paid_tax_at, is_spawn (bool), label_override`.
  (Apartments: many owners per `property_id`, each row = one instance. Houses: one owner row.)
- **`palm6_property_keys`** — access grants.
  `id, owner_id (FK palm6_property_owners), citizenid, granted_by, granted_at`.
- **`palm6_property_furniture`** — placed furniture.
  `id, owner_id (FK), model (hash/name), rel_x/y/z, rot_x/y/z, placed_by, placed_at`.
  Coords stored **relative to the interior origin** so the same layout is bucket-portable.
- Storage inventory lives in `ox_inventory` under stash id `home:{owner_id}`; outfits under the
  existing ox appearance/outfit tables keyed by citizenid + a home slot.

---

## 5. Components

1. **Property registry (`shared/config.lua` + `palm6_properties`)** — declares apartment tiers
   and house locations: entrance, interior, price, storage, spawn. Editable without code changes.
2. **Purchase flow** — apartment lobby (ox_target/menu) or in-world house "For Sale" point.
   Validates funds via `palm6_economy`, writes `palm6_property_owners`, registers the ox stash.
3. **Enter/exit + instancing** — bucket allocator; teleport in/out; door lock state;
   `ox_target` on interior exit door.
4. **Storage** — register `home:{owner_id}` stash with tier capacity; access for owner + keyholders.
5. **Wardrobe** — save current outfit to the home slot; change/into saved outfits from inside.
6. **Keys / roommates** — owner grants/revokes entry + storage access to another citizenid.
7. **Respawn point** — mark one owned home as spawn; integrate with the spawn/logout flow.
8. **Furniture (day 1, reuses existing tech)** — a placement mode built on **`object_gizmo`**
   (move/rotate handles) and the **`palm6_mapeditor` persistence pattern** (spawn/save/despawn
   networked objects). Buy furniture (ox_inventory items or a config catalog) → enter placement
   mode → place/move/rotate/remove → persist to `palm6_property_furniture` → respawn on enter,
   only inside the owner's bucket.
9. **Economy** — purchase debits clean money; **recurring property tax** (per in-game period)
   as a sink, with a grace window; **sell-back to the city** at a configurable % of price.

---

## 6. Build slices (all in v1 scope, shipped/tested in order)

1. **Slice 1 — Apartments core:** registry, buy, bucket-instanced enter/exit, ox stash,
   wardrobe, set-as-spawn, relog+restart persistence. *(Foundational, riskiest instancing.)*
2. **Slice 2 — Houses + keys:** real-map door ownership, house purchase point, keys/roommates,
   shared storage access.
3. **Slice 3 — Furniture:** catalog + buy, `object_gizmo` placement mode, per-property persist,
   respawn-on-enter, remove/refund.
4. **Slice 4 — Economy + polish:** property tax sink, sell-back, blips/UX, edge-case hardening.

---

## 7. Testing

Manual in-server pass per slice (aligned with the FiveM/Rojo "verify live before done" rule):
- **Persistence:** buy → store items → place furniture → set spawn → relog → **server restart** →
  everything intact.
- **Isolation:** two players, two apartments of the same tier → neither sees the other's interior,
  stash, or furniture (routing-bucket correctness — the top risk).
- **Access:** keyholder can enter + use storage; revoked keyholder cannot.
- **Economy:** purchase debits correctly; insufficient funds blocked; tax deducts on schedule and
  is a net sink; sell-back credits the right %.
- **Money safety:** all money + ownership mutations are server-authoritative; client cannot forge
  a purchase, a key, or a furniture refund.

---

## 8. Key risks

- **Routing-bucket isolation** — the correctness linchpin; leaks = players in each other's homes.
  Mitigate with the deterministic allocator + the two-player isolation test as a hard gate.
- **Furniture persistence at scale** — many objects × many homes. Store relative coords, spawn
  lazily on enter, despawn on exit, cap objects per property.
- **MLO interior availability** — confirm which apartment/house MLOs are actually loaded
  (`bob74_ipl` + recipe) before finalizing the registry; fall back to a known-loaded set.
- **Next migration index** — confirm the real next `palm6_dbmigrate` number at implementation.
