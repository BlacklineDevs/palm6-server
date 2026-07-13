# gtarp_cityfeed

The **game → Discord civic feed** — the third leg of the Palm6 sync
(`docs/SYNC-ARCHITECTURE.md` §5). The game emits a small, public-facts-only
event; **palm6-bot** narrates it into an in-world bulletin channel
(`#pbpd-bulletin`, `#palm-medical-ems`, `#doj-notices`, `#the-bay-times`,
`#corporation-wire`, `#announcements`) in the Palm6 voice.

Direction is one-way: the game emits, the bot posts. The bot owns the embed,
the channel routing, and a hard PII sanitizer — this resource only ships a
tiny structured payload and never a raw identifier.

Distinct from **gtarp_discord**, which posts formatted embeds straight to
Discord webhook URLs for the custom-feature feeds (drops/market/live/police/
heat). cityfeed goes *through the bot*; gtarp_discord goes *straight to a
webhook*.

## Setup (deployed server only — never commit the secret)

Set both convars in the deployed `server.cfg` (or txAdmin → convars):

```cfg
set palm6:cityfeed_url    "https://horizon-bot-production-4dfc.up.railway.app/webhooks/game-event"
set palm6:cityfeed_secret "<same value as the bot's GAME_EVENT_SIGNING_SECRET>"
```

Unset URL or secret → the feed is off, and the boot banner says so:

```
[gtarp_cityfeed] civic feed online — server_state:on arrests:on
[gtarp_cityfeed] civic feed OFF (url/secret convar unset) — server_state:on arrests:on
```

Auth is a shared **bearer token** (`Authorization: Bearer <secret>`) because the
FiveM Lua runtime has no native crypto for an HMAC. The bot accepts either the
bearer token or the `X-Palm6-Signature` HMAC; it validates the schema and runs
the sanitizer either way, so the token is the access gate, not the integrity
check.

## Producers

| Producer | Config flag | Event | Bot channel |
|---|---|---|---|
| Server open/close | `Config.EmitServerState` | `server_state` | `#announcements` |
| Booking recorded | `Config.EmitArrests` | `arrest` | `#pbpd-bulletin` |

`server_state` is self-contained (fires on this resource's start/stop).
`arrest` is emitted by **gtarp_mdt** on a successful `/book` through the soft
export below.

## Adding a producer

Any server-side code can post a civic event without a hard dependency:

```lua
if GetResourceState('gtarp_cityfeed') == 'started' then
    pcall(function()
        exports.gtarp_cityfeed:Emit({
            type = 'court_date',           -- must be a type the bot knows
            case_ref = tostring(bookingId),
            hearing_date = 'today',
        })
    end)
end
```

**Only public facts.** Never pass a `citizenid`, `license`, Discord id, or any
balance/take figure — the bot rejects the whole event if it finds one. The bot
knows these types: `arrest`, `ems`, `business_milestone`, `court_date`, `ban`,
`server_state`, `heist` (see `palm6-bot/src/events/types.ts` for each shape).

## Design notes

- Server-only, no client script, no net event in — a modified client can never
  reach the community Discord through this resource.
- One FIFO queue drained at `Config.SendEveryMs`; 429 retried once, 401 warned
  loudly (token mismatch), other non-2xx dropped. A per-minute flood clamp and
  a queue cap keep a buggy producer from stampeding the bot.
- `exports.gtarp_cityfeed:GetStats()` → `{ queued, dropped, live }`.
