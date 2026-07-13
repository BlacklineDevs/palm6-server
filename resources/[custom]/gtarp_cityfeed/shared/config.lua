-- ============================================================================
-- gtarp_cityfeed/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI).
--
-- This is the CIVIC feed: the game POSTs a small, public-facts-only event to
-- palm6-bot's /webhooks/game-event and the BOT narrates it into an in-world
-- bulletin channel (pbpd-bulletin, palm-medical-ems, doj-notices, ...) in the
-- Palm6 voice. The bot owns the embed, the routing, and a hard PII sanitizer,
-- so this resource only ships a tiny structured payload — never a raw id.
--
-- This is the SYNC-ARCHITECTURE section 5 "third leg" (game -> Discord). It is
-- distinct from gtarp_discord, which posts formatted embeds straight to Discord
-- webhook URLs for the custom-feature feeds (drops/market/live/police/heat).
--
-- Auth: the FiveM Lua runtime has no native crypto, so we authenticate with a
-- shared bearer token (Authorization: Bearer <secret>) rather than an HMAC.
-- The bot validates the schema and runs the sanitizer regardless, so the token
-- is the access gate, not the integrity check.
--
-- Both convars are UNSET in the repo. Set them in the DEPLOYED server.cfg (or
-- txAdmin convars), never here — the secret must not live in git. Unset URL or
-- secret = the feed is off, and the boot banner says so in one line.
-- ============================================================================
Config = {}

Config.Debug = false

-- Full URL to the bot's game-event intake, e.g.
--   set palm6:cityfeed_url "https://horizon-bot-production-4dfc.up.railway.app/webhooks/game-event"
Config.UrlConvar = 'palm6:cityfeed_url'
-- Shared bearer token; must equal the bot's GAME_EVENT_SIGNING_SECRET, e.g.
--   set palm6:cityfeed_secret "<64-hex>"
Config.SecretConvar = 'palm6:cityfeed_secret'

-- Delivery pacing. One POST per drain tick keeps a burst well under any rate
-- limit; the bot ALSO dedups per key and burst-caps per channel, so this is a
-- courtesy backstop, not the only guard.
Config.SendEveryMs  = 2000  -- one POST per drain tick
Config.MaxQueue     = 40    -- beyond this, oldest events drop (with a console warn)
Config.Retry429Once = true  -- respect Retry-After once, then drop
Config.PerMinute    = 20    -- global flood clamp; excess dropped with a warn

-- ---------------------------------------------------------------------------
-- Producers. Each can be toggled off without touching code.
-- ---------------------------------------------------------------------------

-- server_state -> #announcements. Emits "open" when this resource starts (the
-- city came up) and a best-effort "closed" on a clean shutdown. The bot is
-- edge-triggered, so repeated boots collapse to a single "the city is open".
Config.EmitServerState = true
Config.PlayerCap       = 48   -- advertised capacity, shown in the open embed

-- arrest -> #pbpd-bulletin. A public "Booking recorded" narration, emitted by
-- gtarp_mdt on a successful /book via exports.gtarp_cityfeed:Emit. This is the
-- in-world bulletin, complementary to (not a replacement for) gtarp_discord's
-- detailed "LSPD Case Desk" webhook post. Turn off here if the two read as
-- redundant for your community.
Config.EmitArrests = true
