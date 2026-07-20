-- ============================================================================
-- palm6_founder/shared/config.lua
--
-- Engine-agnostic tunables. This resource is the authoritative in-game reader of
-- the palm6_founding_grants ledger (written by the website when a verified /beta
-- reservation links its Discord). Its job is one thing: given a player, tell the
-- rest of the server whether they are a Founding Tester and what tag to show.
-- ============================================================================

Config = {}

-- Master gate for the BUILT-IN chat badge. The resource always reads the ledger
-- and exposes exports.palm6_founder:GetTag / :IsFounder regardless of this flag.
-- The built-in badge (cancel the default chat broadcast + re-emit the founder's
-- line with a [FOUNDER] prefix) ONLY runs when this is true.
--
-- Leave OFF until you have confirmed your server uses the STOCK `chat` resource
-- (which checks WasEventCanceled before broadcasting). On a proximity/custom
-- chat, do NOT enable this — instead have that chat system call the exports so
-- it renders the tag its own (proximity-correct) way. See README.md.
Config.ChatBadgeEnabled = GetConvar('palm6:founder_chat_badge', 'false') == 'true'

-- Fallbacks when a grant row omits tag_label / tag_icon (the web seeds
-- FOUNDER / founder).
Config.DefaultLabel = 'FOUNDER'
Config.DefaultIcon = 'founder'

-- Accent (RGB) for the built-in stock-chat badge only.
Config.BadgeColor = { 255, 180, 60 }

-- Cache freshness (seconds). A player's founder status is cached on join so we do
-- not hit the DB on every chat line. This TTL bounds how stale that cache can be:
-- after it lapses, the next read triggers ONE background re-query (deduped), so a
-- grant earned or revoked WHILE the player is connected takes effect within this
-- window instead of only on reconnect. Set higher to reduce DB reads, lower for
-- fresher tags. exports.palm6_founder:Refresh(src) forces an immediate re-read.
Config.CacheTtlSeconds = 60
