# gtarp_courier — player-run delivery board

This is the signature feature for gtarp at Phase 6 of the build roadmap. It
lets players post and accept paid delivery jobs from one map point to
another, with the bounty held in escrow on the poster's bank balance.

## Why this resource

A signature feature should:
- depend only on the framework primitives the recipe ships (qbx_core money,
  ox_lib notify, oxmysql);
- give players something to do that isn't on any framework rail;
- not require staff intervention to run;
- be cheap to switch off (delete the resource folder).

The courier board satisfies all four.

## How it works

- `/courierpost <bounty> [label]` — set a map waypoint to the dropoff,
  stand at the pickup point, then run the command. The server validates
  bounds (`Config.BountyBounds`), debits the bounty from your bank, and
  inserts an `open` row in `courier_postings`.
- `/courier list` — lists open postings in chat.
- `/courier accept <id>` — accept a posting. The server marks it `taken`
  and pushes a destination blip + GPS route to your client.
- On arrival within `Config.DeliveryRadiusMeters` of the dropoff, the
  client fires `gtarp_courier:complete`, the server marks the posting
  `complete`, and pays you the bounty.
- A 60-second sweep marks postings older than
  `Config.PostingLifetimeMinutes` as `expired` and refunds the bounty.

## Files

- `fxmanifest.lua` — declares deps on ox_lib, oxmysql, qbx_core, and
  qbx_economy_overrides.
- `shared/config.lua` — bounty bounds, lifetime, per-player cap, delivery
  radius, blip colour.
- `server/main.lua` — postings cache, net events
  (`post`/`accept`/`complete`/`cancel`), command handler, sweep thread.
- `client/main.lua` — blip + GPS route on accept, arrival detection,
  `/courierpost` helper.

## Schema

The `courier_postings` table is created in `sql/0006_courier.sql`. The
columns map 1:1 to the fields written in `server/main.lua`.

## Swapping it out

If you want a different signature feature later:

1. Drop a new resource into `resources/[custom]/gtarp_<feature>/`.
2. Add an `ensure` line to `custom.cfg` and remove `ensure gtarp_courier`.
3. Stop new postings: nothing else in the layer reads from
   `courier_postings`, so leaving the table behind is harmless. If you
   want it gone, ship a tear-down migration.

The signature-feature slot is intentionally a single resource so swaps
stay clean.
