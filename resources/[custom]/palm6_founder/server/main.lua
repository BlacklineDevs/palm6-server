-- ============================================================================
-- palm6_founder/server/main.lua
--
-- Reads the palm6_founding_grants ledger (written by the website when a verified
-- /beta reservation links its Discord identity) and renders the Founding Tester
-- tag in game. Two consumers:
--
--   1. exports.palm6_founder:GetTag(src)  -> label, icon   (nil if not a founder)
--      exports.palm6_founder:IsFounder(src) -> boolean
--      exports.palm6_founder:Refresh(src)   -> force an immediate re-read
--      The authoritative, non-blocking way for ANY resource (chat, scoreboard,
--      nameplate) to ask "is this player a founder, and how should I mark them?"
--
--   2. An optional built-in chat badge (Config.ChatBadgeEnabled) for servers on
--      the STOCK `chat` resource. OFF by default — see shared/config.lua + README.
--
-- Fail-open by design: a DB hiccup or a missing ledger just means no tag. Nothing
-- here can block a connect, a chat line, or gameplay.
-- ============================================================================

-- [src] = { value = {label,icon} (founder) | false (known non-founder), ts = ms }
-- A missing key (nil) means "unknown, never loaded". `ts` (GetGameTimer ms at
-- write) drives the freshness TTL so a mid-session grant/revoke is picked up.
local cache = {}
-- [src] = true while a background (re)load is in flight, so repeated reads during
-- a query do not spawn N concurrent DB hits for the same player.
local loading = {}

local TTL_MS = (Config.CacheTtlSeconds or 60) * 1000

-- Resolve a discord id to its active grant, cb({label, icon} | nil). Fail-open.
local function queryGrant(discordId, cb)
    if not discordId then cb(nil); return end
    local ok = pcall(function()
        MySQL.single(
            'SELECT tag_label, tag_icon FROM palm6_founding_grants WHERE discord_id = ? AND revoked_at IS NULL LIMIT 1',
            { discordId },
            function(row)
                if row then
                    cb({
                        label = row.tag_label or Config.DefaultLabel,
                        icon = row.tag_icon or Config.DefaultIcon,
                    })
                else
                    cb(nil)
                end
            end
        )
    end)
    if not ok then cb(nil) end
end

-- Populate/refresh the cache for a connected player. `false` records a confirmed
-- non-founder so we do not re-query on every chat line. Deduped by `loading` so
-- only one query per src is in flight at a time.
local function loadForSrc(src, cb)
    if loading[src] then if cb then cb(nil) end; return end
    loading[src] = true
    -- Capture the identity we are querying FOR, so a callback that lands after the
    -- player left (and their temp server id was recycled to a NEW player) cannot
    -- stamp this founder's tag onto the newcomer. FiveM reuses server ids.
    local discordId = Bridge.GetDiscordId(src)
    queryGrant(discordId, function(tag)
        loading[src] = nil
        -- Drop the result if this src is no longer the same connected player.
        if GetPlayerName(src) == nil or Bridge.GetDiscordId(src) ~= discordId then
            if cb then cb(nil) end
            return
        end
        cache[src] = { value = tag or false, ts = GetGameTimer() }
        if cb then cb(tag) end
    end)
end

AddEventHandler('playerJoining', function()
    loadForSrc(source)
end)

AddEventHandler('playerDropped', function()
    cache[source] = nil
    loading[source] = nil
end)

-- Backfill already-connected players on a hot (re)start so founder tags are not
-- blank until each founder reconnects.
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, pid in ipairs(GetPlayers()) do
        loadForSrc(tonumber(pid))
    end
end)

--- The authoritative founder tag for a player. Non-blocking: returns the cached
--- grant (populated on join); on a cache miss it kicks an async load and returns
--- nil for THIS call. A cached entry older than the TTL triggers ONE background
--- re-query (deduped) so a mid-session grant/revoke is honoured within the window,
--- while this call still serves the current (soon-refreshed) value.
--- @return string|nil label, string|nil icon
local function getTag(src)
    src = tonumber(src)
    if not src then return nil end
    local hit = cache[src]
    if hit == nil then
        loadForSrc(src) -- warm for next time
        return nil
    end
    if (GetGameTimer() - hit.ts) > TTL_MS then
        loadForSrc(src) -- stale: refresh in the background (deduped), serve current
    end
    if hit.value == false then return nil end
    return hit.value.label, hit.value.icon
end

exports('GetTag', getTag)
exports('IsFounder', function(src)
    local label = getTag(src)
    return label ~= nil
end)

--- Force an immediate re-read of a player's founder status (e.g. an admin command
--- or the website->bot path after a grant/revoke, so it lands without a relog).
exports('Refresh', function(src)
    src = tonumber(src)
    if not src then return end
    cache[src] = nil
    loadForSrc(src)
end)

-- Optional built-in badge for servers on the STOCK `chat` resource. Cancels the
-- default broadcast and re-emits the founder's line with a [FOUNDER] prefix. OFF
-- unless palm6:founder_chat_badge=true. DO NOT enable on a proximity/custom chat
-- (it broadcasts to everyone) — have that chat call the exports instead.
if Config.ChatBadgeEnabled then
    AddEventHandler('chatMessage', function(src, name, message)
        -- Use getTag (not a raw cache read) so the TTL refresh applies: a founder
        -- revoked mid-session stops being badged within the freshness window.
        local label = getTag(src)
        if not label then return end
        CancelEvent()
        TriggerClientEvent('chat:addMessage', -1, {
            color = Config.BadgeColor,
            multiline = true,
            args = { ('[%s] %s'):format(label, name), message },
        })
    end)
    print('[palm6_founder] built-in chat badge ENABLED (stock-chat mode)')
else
    print('[palm6_founder] ready — exports live; built-in chat badge off (palm6:founder_chat_badge=false)')
end
