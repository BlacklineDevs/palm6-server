-- ============================================================================
-- palm6_mapeditor/client/thumbs.lua  —  NUI thumbnail proxy
--
-- FiveM's NUI (CEF) refuses external images from cdn.rage.mp — its CSP only
-- allows self / data: / cfx-nui-* (and the CDN also hotlink-guards by referer),
-- so <img src="https://cdn.rage.mp/..."> fails every time. Lua's
-- PerformHttpRequest is NOT the browser and is bound by neither, so we fetch the
-- odb thumbnail HERE, base64-encode it, and hand the NUI a data: URI — which CSP
-- always permits. Results are session-cached and a small concurrency cap keeps
-- the request burst civil.
--
-- NUI contract:
--   NUI -> Lua  : fetch('https://palm6_mapeditor/thumb', {model})
--   Lua -> NUI  : SendNUIMessage({action='thumb', model=, data=<dataURI|false>})
-- ============================================================================

local THUMB_BASE = 'https://cdn.rage.mp/public/odb/imgs-small/'
local MAX_ACTIVE = 10

local cache = {}       -- [model] = dataURI (string) | false (no image)
local requested = {}   -- [model] = true once we've begun (dedupe)
local queue = {}
local active = 0

-- Standard base64 of a raw byte string, 3 bytes -> 4 chars.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(data)
    local out, n = {}, #data
    local byte, sub = string.byte, string.sub
    for i = 1, n, 3 do
        local b1 = byte(data, i) or 0
        local b2 = byte(data, i + 1) or 0
        local b3 = byte(data, i + 2) or 0
        local v = b1 * 65536 + b2 * 256 + b3
        local c1 = (v // 262144) % 64
        local c2 = (v // 4096) % 64
        local c3 = (v // 64) % 64
        local c4 = v % 64
        out[#out + 1] = sub(B64, c1 + 1, c1 + 1) .. sub(B64, c2 + 1, c2 + 1)
            .. (i + 1 <= n and sub(B64, c3 + 1, c3 + 1) or '=')
            .. (i + 2 <= n and sub(B64, c4 + 1, c4 + 1) or '=')
    end
    return table.concat(out)
end

-- odb filename is "<lowercase name>-<unsigned joaat>.jpg".
local function thumbUrl(model)
    local hash = GetHashKey(model) & 0xFFFFFFFF   -- unsigned uint32
    return THUMB_BASE .. model:lower() .. '-' .. hash .. '.jpg'
end

local function deliver(model)
    SendNUIMessage({ action = 'thumb', model = model, data = cache[model] })
end

local function pump()
    while active < MAX_ACTIVE and #queue > 0 do
        local model = table.remove(queue, 1)
        active = active + 1
        PerformHttpRequest(thumbUrl(model), function(code, body)
            active = active - 1
            local result = false
            if code == 200 and body and #body > 0 then
                result = 'data:image/jpeg;base64,' .. base64(body)
            end
            cache[model] = result
            deliver(model)
            pump()
        end, 'GET')
    end
end

RegisterNUICallback('thumb', function(data, cb)
    cb('ok')
    local model = (type(data) == 'table') and data.model or nil
    if type(model) ~= 'string' or not model:match('^[%w_]+$') then return end
    if cache[model] ~= nil then deliver(model); return end   -- cached (hit or known-miss)
    if requested[model] then return end                      -- already in flight
    requested[model] = true
    queue[#queue + 1] = model
    pump()
end)
