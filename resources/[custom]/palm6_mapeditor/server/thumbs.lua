-- ============================================================================
-- palm6_mapeditor/server/thumbs.lua  —  thumbnail proxy (server side)
--
-- FiveM's NUI (CEF) blocks external images from cdn.rage.mp (CSP + the CDN's
-- referer hotlink guard), so the browser can never load odb thumbnails directly.
-- We fetch them HERE instead: server-side PerformHttpRequest is not a browser
-- and is bound by neither, and is far more reliable than the client variant.
-- Each image is fetched ONCE server-wide, base64-encoded, cached, and handed to
-- whichever client asked as a data: URI (which CSP always allows). The client
-- (client/thumbs.lua) relays NUI requests here and the result back to the NUI.
-- ============================================================================

local THUMB_BASE = 'https://cdn.rage.mp/public/odb/imgs-small/'
local MAX_ACTIVE = 16

local cache = {}       -- [model] = dataURI (string) | false (no image)
local waiters = {}     -- [model] = { src, ... } clients awaiting this fetch
local queue = {}
local active = 0
local logged = false   -- one-time diagnostic of the first fetch

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

local function thumbUrl(model)
    local hash = GetHashKey(model) & 0xFFFFFFFF   -- unsigned uint32 = odb filename hash
    return THUMB_BASE .. model:lower() .. '-' .. hash .. '.jpg'
end

local function resolve(model, result)
    cache[model] = result
    local list = waiters[model]; waiters[model] = nil
    if list then
        for _, s in ipairs(list) do
            TriggerClientEvent('palm6_mapeditor:thumb:res', s, model, result)
        end
    end
end

local function pump()
    while active < MAX_ACTIVE and #queue > 0 do
        local model = table.remove(queue, 1)
        active = active + 1
        local ok = pcall(function()
            PerformHttpRequest(thumbUrl(model), function(code, body)
                active = active - 1
                local result = false
                local isJpeg = type(body) == 'string' and #body > 3
                    and body:byte(1) == 0xFF and body:byte(2) == 0xD8 and body:byte(3) == 0xFF
                if code == 200 and isJpeg then
                    result = 'data:image/jpeg;base64,' .. base64(body)
                end
                -- One-time diagnostic: tells us in the server console whether the
                -- fetched body arrived as raw JPEG bytes (b1=255 -> binary intact)
                -- or was UTF-8-mangled (b1=239 -> the U+FFFD replacement, ef bf bd).
                if not logged then
                    logged = true
                    print(('[palm6_mapeditor] thumb probe: code=%s len=%s b1=%s b2=%s b3=%s jpeg=%s')
                        :format(tostring(code), body and #body or 'nil',
                            body and body:byte(1) or 'nil', body and body:byte(2) or 'nil',
                            body and body:byte(3) or 'nil', tostring(isJpeg)))
                end
                resolve(model, result)
                pump()
            end, 'GET', '', {
                -- Browser-ish headers + a matching Referer so the CDN's hotlink
                -- guard can't 403 the fetch (a foreign referer is what it blocks).
                ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
                ['Referer'] = 'https://rage.mp/',
                ['Accept'] = 'image/jpeg,image/*,*/*',
            })
        end)
        if not ok then active = active - 1; resolve(model, false) end
    end
end

RegisterNetEvent('palm6_mapeditor:thumb:req', function(model)
    local src = source
    if type(model) ~= 'string' or #model == 0 or #model > 64 or not model:match('^[%w_]+$') then return end
    if cache[model] ~= nil then
        TriggerClientEvent('palm6_mapeditor:thumb:res', src, model, cache[model])
        return
    end
    if waiters[model] then                       -- fetch already in flight: just wait on it
        waiters[model][#waiters[model] + 1] = src
        return
    end
    waiters[model] = { src }
    queue[#queue + 1] = model
    pump()
end)
