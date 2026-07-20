# palm6_founder

In-game rendering of the **Founding Tester** mark. This resource is the
authoritative reader of the `palm6_founding_grants` ledger — the same table the
**website** writes when a verified `/beta` reservation links its Discord identity,
and the same DB the game already uses (oxmysql). It closes the third leg of the
founding pipeline:

```
web  → writes palm6_founding_grants (discord_id, tag_label, tag_icon, revoked_at)
bot  → assigns the Founding Tester Discord role
game → THIS resource: shows the founder tag / name icon in game   ← you are here
```

## What it does

- On join (and a backfill sweep on resource restart) it looks up the player's
  Discord id in `palm6_founding_grants` (active = `revoked_at IS NULL`) and caches
  their tag (`tag_label` / `tag_icon`, seeded by the web as `FOUNDER` / `founder`).
- It exposes the result to the rest of the server:

  ```lua
  local label, icon = exports.palm6_founder:GetTag(src)  -- nil if not a founder
  local isFounder   = exports.palm6_founder:IsFounder(src)
  exports.palm6_founder:Refresh(src)                     -- force an immediate re-read
  ```

  These are **non-blocking** (cache-backed) and **fail-open** (a DB hiccup just
  means no tag — never a blocked connect or a dropped chat line). The cache has a
  freshness TTL (`Config.CacheTtlSeconds`, default 60s): a grant earned or revoked
  **while the player is connected** is picked up within that window (one deduped
  background re-query on the next read), so a relog is no longer required. Use
  `Refresh(src)` to apply a change instantly (e.g. from an admin command).

## Rendering the tag

Pick ONE of these depending on your chat stack:

### A. Stock `chat` resource (simple servers)

Set the convar and start the resource:

```cfg
setr palm6:founder_chat_badge true
ensure palm6_founder
```

The built-in handler cancels the default broadcast for a founder and re-emits
their line prefixed with `[FOUNDER]`. This relies on the stock `chat` resource
checking `WasEventCanceled()` before broadcasting (it does).

### B. Proximity / custom chat (most RP servers — DEFAULT: leave the badge OFF)

Do **not** set `palm6:founder_chat_badge` — the built-in badge broadcasts to
everyone and would break proximity. Instead, in your chat/nameplate/scoreboard
resource, ask this resource for the tag and render it your own way:

```lua
local label = exports.palm6_founder:GetTag(src)
if label then
    -- prepend `[label]` to the author, add a badge icon, colour the name, etc.
    -- using YOUR chat system's own (proximity-correct) send path.
end
```

## Install

```cfg
ensure palm6_founder            # after oxmysql + qbx_core
# optional, stock chat only:
setr palm6:founder_chat_badge true
```

No new SQL: `palm6_founding_grants` is created by the website's migrations
(`0006_beta_waitlist_and_grants.sql`) in the shared DB.

## Verify

1. `ensure palm6_founder` → console prints `[palm6_founder] ready …`.
2. As a player who holds an active grant, `exports.palm6_founder:IsFounder(src)`
   returns `true` (or the `[FOUNDER]` badge shows in stock-chat mode).
3. Revoke in DB (`UPDATE palm6_founding_grants SET revoked_at = NOW() WHERE …`),
   the tag clears within `Config.CacheTtlSeconds` (or instantly via `Refresh(src)`)
   — no relog needed. Fail-open: stop the DB and chat/gameplay still work.

## Safety notes

- Reads only; never writes the ledger.
- The built-in chat badge is **off by default** and gated behind a convar, so
  adding this resource to your cfg cannot alter live chat until you opt in.
- Keyed by `discord_id` today (matches how the web links identity); a future
  `citizen_id` column can be added to the same lookup without touching consumers.
