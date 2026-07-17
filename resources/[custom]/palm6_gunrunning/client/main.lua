-- ============================================================================
-- palm6_gunrunning/client/main.lua
--
-- Pure logic. Calls Game.* (bridge/cl_game.lua) for all native / ox_lib UI.
-- No direct GTA natives or ox_lib here (§6 gate).
--
-- Presentation only: the dealer NPC, the map blip, and the catalog menu. Buying
-- fires palm6_gunrunning:dealer:buy with a catalog INDEX; the server re-runs the
-- exact authority as /buyweapon (proximity, price resolved from Config server-
-- side, bank charge, serialized grant). A modified client can only pick WHICH
-- catalog index to request — it can never set the price or bypass the drop-point
-- check. The catalog shown here is the shared Config.Catalog (labels/prices are
-- display; the server is the source of truth).
-- ============================================================================

local dealerPed, dealerZone, dealerBlip

-- Thousands separators for display ($12,345).
local function comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

local function openDealer()
    local opts = {}
    opts[#opts + 1] = {
        title = 'Black-market dealer',
        description = 'Cash only, no questions. Serials are traceable.',
        icon = 'fa-solid fa-user-secret', disabled = true,
    }
    for i, e in ipairs(Config.Catalog or {}) do
        opts[#opts + 1] = {
            title = e.label,
            description = ('$%s from your bank'):format(comma(e.price)),
            icon = 'fa-solid fa-gun',
            onSelect = function() TriggerServerEvent('palm6_gunrunning:dealer:buy', i) end,
        }
    end
    Game.OpenMenu('palm6_gunrunning_dealer', 'Scrapyard Dealer', opts)
end

CreateThread(function()
    local d = Config.Dealer
    if not d then return end
    dealerBlip = Game.AddBlip(Config.DropPoint.coords, d.blip)
    dealerPed = Game.SpawnPed(d.model, Config.DropPoint.coords, d.heading)
    dealerZone = Game.AddPedInteraction(dealerPed, Config.DropPoint.coords, d.label, d.icon, openDealer)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Game.RemoveInteraction(dealerZone)
    Game.DeletePed(dealerPed)
    Game.RemoveBlip(dealerBlip)
end)
