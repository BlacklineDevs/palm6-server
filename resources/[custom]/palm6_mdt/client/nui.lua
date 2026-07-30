-- ============================================================================
-- palm6_mdt/client/nui.lua — minimal tablet NUI scaffold (Cylex-parity W4)
--
-- Opens a local HTML shell when the officer has mdt_tablet and is on duty.
-- Does NOT replace chat commands yet — lookups still run server-side via
-- existing commands. This lands the in-game surface so Fieldline/live-map
-- can grow into it without another architecture rewrite.
-- ============================================================================

local nuiOpen = false

local function hasTablet()
    -- Prefer ox_inventory if present; fail-open to true when item check fails
    -- so local/dev without inventory still exercises the NUI shell.
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
        note = 'Scaffold — use chat MDT commands for live writes until NUI actions wire up.',
    })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if nuiOpen then setOpen(false) end
end)
