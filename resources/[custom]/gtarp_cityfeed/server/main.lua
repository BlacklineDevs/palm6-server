-- ============================================================================
-- gtarp_cityfeed/server/main.lua
--
-- Pure logic. Calls Bridge.* for all runtime access (§6 gate). One FIFO queue,
-- one drain thread. Emit() never blocks a producer and never errors outward:
-- feed off, unknown type, queue full — the event is dropped with a console note
-- and gameplay continues.
--
-- SERVER-SIDE ONLY: there is deliberately no net event into this resource. A
-- modified client must never be able to post to the community Discord. Producers
-- call exports.gtarp_cityfeed:Emit(...) from server code only.
--
-- The payload is a small, public-facts-only table matching palm6-bot's
-- GameEventSchema. The bot re-validates it, strips any forbidden field, and
-- owns the embed/routing — so a producer bug here can at worst drop a post, not
-- leak an id or mis-format a channel.
-- ============================================================================

-- Event types the bot accepts (events/types.ts discriminated union). Emit()
-- rejects anything not on this list before it ever hits the queue.
local KNOWN_TYPES = {
    arrest = true, ems = true, business_milestone = true, court_date = true,
    ban = true, server_state = true, heist = true,
}

local queue = {}        -- FIFO of { body, retried }
local sentTimes = {}    -- rolling send timestamps in the last 60s
local droppedTotal = 0
local warnedNoConfig = false

local function dbg(msg)
    if Config.Debug then print('[gtarp_cityfeed] ' .. msg) end
end

-- Both convars must be present for the feed to be live.
local function endpoint()
    local url = Bridge.GetConvar(Config.UrlConvar)
    local secret = Bridge.GetConvar(Config.SecretConvar)
    if not url or not secret then return nil end
    return url, secret
end

-- Rolling one-minute flood clamp across all producers.
local function floodOk()
    local t = os.time()
    local fresh = {}
    for _, ts in ipairs(sentTimes) do
        if t - ts < 60 then fresh[#fresh + 1] = ts end
    end
    sentTimes = fresh
    return #fresh < Config.PerMinute
end

---Queue a civic event for delivery to the bot. Safe to call unconditionally:
---returns false (and does nothing) if the feed is off, the event is malformed
---or off-catalog, the feed is flooding, or the queue is full.
---@param event table { type = <known type>, ... public fields ... }
---@return boolean queued
local function emit(event)
    if type(event) ~= 'table' or type(event.type) ~= 'string' then return false end
    if not KNOWN_TYPES[event.type] then
        print(('[gtarp_cityfeed] emit rejected — unknown event type "%s"'):format(tostring(event.type)))
        return false
    end
    local url = endpoint()
    if not url then
        if not warnedNoConfig then
            dbg('emit skipped — feed off (url/secret convar unset)')
            warnedNoConfig = true
        end
        return false
    end
    if not floodOk() then
        droppedTotal = droppedTotal + 1
        print(('[gtarp_cityfeed] over %d events/min — dropping "%s"'):format(Config.PerMinute, event.type))
        return false
    end
    if #queue >= Config.MaxQueue then
        table.remove(queue, 1)
        droppedTotal = droppedTotal + 1
        print('[gtarp_cityfeed] queue full — dropped oldest event')
    end
    local ok, body = pcall(json.encode, event)
    if not ok then
        print(('[gtarp_cityfeed] emit(%s) rejected — unencodable payload'):format(event.type))
        return false
    end
    queue[#queue + 1] = { body = body, retried = false }
    sentTimes[#sentTimes + 1] = os.time()
    return true
end

exports('Emit', emit)

---Delivery/queue stats for /diag-style consumers and devtest.
exports('GetStats', function()
    return { queued = #queue, dropped = droppedTotal, live = endpoint() ~= nil }
end)

-- Single drain thread. 429 -> requeue once at the front and wait out
-- Retry-After; 401 -> warn loudly (token misconfigured) and drop; any other
-- non-2xx -> drop with a console note.
CreateThread(function()
    while true do
        Wait(Config.SendEveryMs)
        local msg = table.remove(queue, 1)
        if msg then
            local url, secret = endpoint()
            if url then
                local headers = {
                    ['Content-Type'] = 'application/json',
                    ['Authorization'] = 'Bearer ' .. secret,
                }
                Bridge.HttpPostJson(url, msg.body, headers, function(status, _, respHeaders)
                    if status == 429 and Config.Retry429Once and not msg.retried then
                        msg.retried = true
                        local after = tonumber(respHeaders['Retry-After'] or respHeaders['retry-after'] or 5)
                        dbg(('429 — retrying in %ds'):format(after))
                        SetTimeout(math.min(after, 30) * 1000, function()
                            table.insert(queue, 1, msg)
                        end)
                    elseif status == 401 then
                        droppedTotal = droppedTotal + 1
                        print('[gtarp_cityfeed] delivery rejected 401 — bearer token does not match the bot GAME_EVENT_SIGNING_SECRET')
                    elseif status < 200 or status > 299 then
                        droppedTotal = droppedTotal + 1
                        print(('[gtarp_cityfeed] delivery failed (HTTP %s) — event dropped'):format(tostring(status)))
                    end
                end)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Producer: server_state. "open" when we start (the city came up); a
-- best-effort "closed" on a clean shutdown. The bot is edge-triggered, so a
-- restart that re-emits "open" collapses to nothing.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    local url = endpoint()
    print(('[gtarp_cityfeed] civic feed %s — server_state:%s arrests:%s'):format(
        url and 'online' or 'OFF (url/secret convar unset)',
        Config.EmitServerState and 'on' or 'off',
        Config.EmitArrests and 'on' or 'off'))

    if Config.EmitServerState then
        -- A short delay so the HTTP stack and other resources are settled
        -- before the first POST on a cold boot.
        SetTimeout(5000, function()
            emit({ type = 'server_state', state = 'open', player_cap = Config.PlayerCap })
        end)
    end
end)

-- txAdmin fires this before a scheduled restart/shutdown. Best effort: the
-- POST is async and the process may exit before it flushes, but on a graceful
-- restart it usually lands. Harmless if it does not (the bot just keeps its
-- last known state, which resets on the bot's own restart anyway).
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    if Config.EmitServerState then
        emit({ type = 'server_state', state = 'closed' })
    end
end)
