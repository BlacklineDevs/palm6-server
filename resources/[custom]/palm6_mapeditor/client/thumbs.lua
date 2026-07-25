-- ============================================================================
-- palm6_mapeditor/client/thumbs.lua  —  NUI thumbnail relay
--
-- The NUI can't load cdn.rage.mp images (CEF CSP + CDN hotlink guard). The fetch
-- + base64 happens on the SERVER (server/thumbs.lua) — server-side HTTP is far
-- more reliable than the client variant, and the image is fetched once
-- server-wide. This file is just the relay: NUI request -> server, server result
-- -> NUI as a data: URI.
-- ============================================================================

RegisterNUICallback('thumb', function(data, cb)
    cb('ok')
    local model = (type(data) == 'table') and data.model or nil
    if type(model) == 'string' and model:match('^[%w_]+$') then
        TriggerServerEvent('palm6_mapeditor:thumb:req', model)
    end
end)

RegisterNetEvent('palm6_mapeditor:thumb:res', function(model, dataUri)
    SendNUIMessage({ action = 'thumb', model = model, data = dataUri })
end)
