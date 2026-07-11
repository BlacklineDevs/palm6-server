-- ============================================================================
-- gtarp_discord/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all runtime
-- access. No direct native calls here (§6 gate).
--
-- One FIFO queue, one drain thread. Announce() never blocks a producer and
-- never errors outward: bad feed name, feed off, queue full — the message
-- is dropped with a console note and gameplay continues. SERVER-SIDE ONLY:
-- there is deliberately no net event into this resource — a modified
-- client must never be able to post to the community Discord.
-- ============================================================================

local queue = {}          -- FIFO of { url, body, feed, retried }
local sentPerFeed = {}    -- [feed] = { timestamps of sends in the last 60s }
local droppedTotal = 0

local function dbg(msg)
    if Config.Debug then print('[gtarp_discord] ' .. msg) end
end

local function feedUrl(feed)
    local def = Config.Feeds[feed]
    if not def then return nil end
    return Bridge.GetConvar(def.convar)
end

-- Rolling per-feed minute window.
local function floodOk(feed)
    local t = os.time()
    local w = sentPerFeed[feed] or {}
    local fresh = {}
    for _, ts in ipairs(w) do
        if t - ts < 60 then fresh[#fresh + 1] = ts end
    end
    sentPerFeed[feed] = fresh
    return #fresh < Config.PerFeedPerMinute
end

local function markSent(feed)
    local w = sentPerFeed[feed] or {}
    w[#w + 1] = os.time()
    sentPerFeed[feed] = w
end

-- payload: { title, description, fields = { {name,value,inline?}, ... } }
-- All strings are truncated to Discord's embed limits so a producer can
-- never 400 the whole queue with an oversized field.
local function buildBody(feed, payload)
    local def = Config.Feeds[feed]
    local fields = {}
    for i, f in ipairs(payload.fields or {}) do
        if i > 10 then break end
        fields[#fields + 1] = {
            name   = tostring(f.name or ''):sub(1, 256),
            value  = tostring(f.value or ''):sub(1, 1024),
            inline = f.inline == true,
        }
    end
    return json.encode({
        username = def.username,
        embeds = { {
            title       = tostring(payload.title or ''):sub(1, 256),
            description = tostring(payload.description or ''):sub(1, 2048),
            color       = payload.color or def.color,
            fields      = fields,
            footer      = { text = 'Palm6 Roleplay' },
        } },
    })
end

---Queue an embed for a feed. Safe to call unconditionally: returns false
---(and does nothing) if the feed is unknown, its webhook convar is unset,
---the feed is flooding, or the queue is full.
---@param feed string key into Config.Feeds
---@param payload table { title, description, fields?, color? }
---@return boolean queued
local function announce(feed, payload)
    if type(feed) ~= 'string' or type(payload) ~= 'table' then return false end
    local url = feedUrl(feed)
    if not url then
        dbg(('announce(%s) skipped — feed off'):format(feed))
        return false
    end
    if not floodOk(feed) then
        droppedTotal = droppedTotal + 1
        print(('[gtarp_discord] feed "%s" over %d msgs/min — dropping message'):format(
            feed, Config.PerFeedPerMinute))
        return false
    end
    if #queue >= Config.MaxQueue then
        table.remove(queue, 1)
        droppedTotal = droppedTotal + 1
        print('[gtarp_discord] queue full — dropped oldest message')
    end
    local ok, body = pcall(buildBody, feed, payload)
    if not ok then
        print(('[gtarp_discord] announce(%s) rejected — unencodable payload'):format(feed))
        return false
    end
    queue[#queue + 1] = { url = url, body = body, feed = feed, retried = false }
    markSent(feed)
    return true
end

exports('Announce', announce)

---Delivery/queue stats for /diag-style consumers and devtest.
exports('GetStats', function()
    local live = {}
    for feed in pairs(Config.Feeds) do
        if feedUrl(feed) then live[#live + 1] = feed end
    end
    table.sort(live)
    return { queued = #queue, dropped = droppedTotal, liveFeeds = live }
end)

-- Single drain thread. 429 → requeue once at the front and wait out
-- Retry-After; anything else non-2xx → drop with a console note.
CreateThread(function()
    while true do
        Wait(Config.SendEveryMs)
        local msg = table.remove(queue, 1)
        if msg then
            Bridge.HttpPostJson(msg.url, msg.body, function(status, _, headers)
                if status == 429 and Config.Retry429Once and not msg.retried then
                    msg.retried = true
                    local after = tonumber(headers['Retry-After'] or headers['retry-after'] or 5)
                    dbg(('429 on feed "%s" — retrying in %ds'):format(msg.feed, after))
                    SetTimeout(math.min(after, 30) * 1000, function()
                        table.insert(queue, 1, msg)
                    end)
                elseif status < 200 or status > 299 then
                    droppedTotal = droppedTotal + 1
                    print(('[gtarp_discord] feed "%s" delivery failed (HTTP %s) — message dropped'):format(
                        msg.feed, tostring(status)))
                end
            end)
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local live, off = {}, {}
    for feed in pairs(Config.Feeds) do
        if feedUrl(feed) then live[#live + 1] = feed else off[#off + 1] = feed end
    end
    table.sort(live); table.sort(off)
    print(('[gtarp_discord] announcer online — live: %s | off: %s'):format(
        #live > 0 and table.concat(live, ', ') or '(none)',
        #off > 0 and table.concat(off, ', ') or '(none)'))
end)
