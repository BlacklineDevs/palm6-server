-- ============================================================================
-- palm6_mdt/client/nui.lua — tablet NUI (Cylex-parity W4+)
-- Opens with F5 / mdt_tablet. Lookups + warrant/bolo clear.
-- ============================================================================

local nuiOpen = false

local function hasTablet()
    local ok, count = pcall(function()
        return exports.ox_inventory:Search('count', Config.TabletItem) or 0
    end)
    if not ok then return true end
    return (count or 0) > 0
end

local function setOpen(open)
    nuiOpen = open
    SetNuiFocus(open, open)
    SendNUIMessage({ action = open and 'open' or 'close' })
end

RegisterCommand('mdt_tablet', function()
    if nuiOpen then
        setOpen(false)
        return
    end
    if not hasTablet() then
        BeginTextCommandThefeedDisplay('STRING')
        AddTextComponentSubstringPlayerName('MDT tablet required.')
        EndTextCommandThefeedDisplayTicker(false, true)
        return
    end
    setOpen(true)
end, false)

RegisterKeyMapping('mdt_tablet', 'Open Palm6 MDT tablet', 'keyboard', 'F5')

RegisterNUICallback('close', function(_, cb)
    setOpen(false)
    cb({ ok = true })
end)

RegisterNUICallback('ready', function(_, cb)
    cb({
        ok = true,
        resource = GetCurrentResourceName(),
        note = 'Tablet online — plate/warrant/bolo lookup + clear. Chat /warrant /bolo still work.',
    })
end)

RegisterNUICallback('lookupPlate', function(data, cb)
    local plate = tostring(data and data.plate or ''):upper():gsub('%s+', '')
    if plate == '' then
        cb({ ok = false, error = 'Enter a plate' })
        return
    end
    TriggerServerEvent('palm6_mdt:nuiLookupPlate', plate)
    cb({ ok = true, pending = true })
end)

RegisterNUICallback('lookupWarrants', function(_, cb)
    TriggerServerEvent('palm6_mdt:nuiListWarrants')
    cb({ ok = true, pending = true })
end)

RegisterNUICallback('lookupBolos', function(_, cb)
    TriggerServerEvent('palm6_mdt:nuiListBolos')
    cb({ ok = true, pending = true })
end)

RegisterNUICallback('clearWarrant', function(data, cb)
    local id = tonumber(data and data.id)
    if not id then
        cb({ ok = false, error = 'Warrant # required' })
        return
    end
    TriggerServerEvent('palm6_mdt:nuiClearWarrant', id)
    cb({ ok = true, pending = true })
end)

RegisterNUICallback('clearBolo', function(data, cb)
    local id = tonumber(data and data.id)
    if not id then
        cb({ ok = false, error = 'BOLO # required' })
        return
    end
    TriggerServerEvent('palm6_mdt:nuiClearBolo', id)
    cb({ ok = true, pending = true })
end)

RegisterNetEvent('palm6_mdt:nuiResult', function(payload)
    SendNUIMessage({ action = 'result', payload = payload })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if nuiOpen then setOpen(false) end
end)
