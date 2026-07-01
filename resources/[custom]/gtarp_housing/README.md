# gtarp_housing

Player-owned properties for the gtarp custom layer: buy, sell, share keys,
and enter an instanced shell interior with a per-property stash. Built on the
existing `properties` table (`sql/0010_properties.sql`) — this resource is the
logic that table was waiting for.

Bridge-pattern (see `docs/GTA6-READINESS.md`): all logic is in `server/` and
`client/`; every qbx/native/ox_lib call lives in `bridge/`. The `properties`
SQL is our own schema and stays in the logic.

## How it works

- **Catalog seed.** On start the server ensures a DB row for each
  `Config.Properties` entry (keyed by `apartment`), so a fresh database has
  homes for sale immediately. Ownership then lives in the DB.
- **Buy.** Walk to a for-sale door → `[E]` → confirm. The bank is charged
  (`Bridge.ChargeBank`) after a server-side affordability + proximity check;
  the row flips to `owner = <citizenid>, for_sale = 0`.
- **Sell back.** Owner menu → *Sell back* refunds `Config.SellBackRate` of the
  price and returns the property to the market.
- **Keys.** Owner menu → *Give key to nearest player* adds their citizenid to
  `has_access`; *Manage keys* revokes. Keyed players can enter but not manage.
- **Enter / exit.** Entering puts the player in a per-property routing bucket
  (`Bridge.SetRoutingBucket`) so shells never overlap, then teleports to the
  shell interior. `/exithome` returns them to the door and bucket 0.
- **Stash.** Each property registers an `ox_inventory` stash; `/stash` inside
  opens it (server-gated on being inside + having access).

## Commands

| Command | Where | Effect |
| --- | --- | --- |
| `[E]` at a door | at a property | buy / enter / owner menu (by relation) |
| `/exithome` | inside a shell | leave, return to the door |
| `/stash` | inside a shell | open the property stash |

## Config (`shared/config.lua`)

- `InteractRadius`, `SellBackRate`, `ShowForSaleBlips`, `Blips` styling.
- `Shells` — interior coords per shell type (Tier 3 map coords).
- `Properties` — the starter for-sale catalog (door coords are Tier 3).

## Deploy

- `ensure gtarp_housing` is wired into `custom.cfg` (after `gtarp_courier`).
- No new migration — reuses `sql/0010_properties.sql`.

## GTA VI notes (Tier 3)

The `Shells[*].interior` and `Properties[*].door` coords are Los Santos
points; add them to `docs/GTA6-TIER3-RETUNE.md` and re-author for the VI map.
The whole lifecycle (buy/sell/keys/instancing) is Tier 1 and carries.

## Deferred to v2

- Furniture placement (the `furnitures` JSON column is unused in v1).
- Real MLO/shell resource instead of fixed GTA V interior coords.
- ox_inventory-level stash access binding (v1 gates opening server-side).
- Property listing UI / realtor flow (v1 seeds the catalog from config).
