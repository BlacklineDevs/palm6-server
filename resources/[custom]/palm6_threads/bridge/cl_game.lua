-- ============================================================================
-- palm6_threads/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file here that calls GTA natives / illenium-
-- appearance. client/main.lua calls Game.* only (the palm6_fc_combat pattern), so
-- the illenium coupling + native calls are isolated for a future engine port.
-- Presentation + local ped only; the server owns authority over WHICH designs.
-- ============================================================================

Game = {}

-- illenium appearance snapshot for the local ped, or nil (pcall-guarded — a missing
-- illenium never errors the equip path, it just degrades to a live-only apply).
function Game.GetAppearance(ped)
    local ok, ap = pcall(function()
        return exports['illenium-appearance']:getPedAppearance(ped)
    end)
    return ok and ap or nil
end

-- Persist an appearance table onto the ped via illenium so it survives respawns.
function Game.SetAppearance(ped, appearance)
    if not appearance then return end
    pcall(function()
        exports['illenium-appearance']:setPedAppearance(ped, appearance)
    end)
end

-- Apply a component live on the ped (immediate visual). variation palette 2 = the
-- Rockstar default variation index the Stage A spike also used.
function Game.ApplyComponent(ped, component, drawable, texture)
    if not ped or ped == 0 then return end
    SetPedComponentVariation(ped, component, drawable, texture, 2)
end

-- Read the drawable/texture currently on a component (to snapshot the base so an
-- unequip can restore it).
function Game.GetComponent(ped, component)
    if not ped or ped == 0 then return 0, 0 end
    return GetPedDrawableVariation(ped, component), GetPedTextureVariation(ped, component)
end

function Game.MyPed()
    return PlayerPedId()
end

-- ox_lib context menu. options = { { title, description, onSelect=fn }, ... }.
function Game.OpenMenu(id, title, options)
    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

function Game.Notify(opts)
    lib.notify(opts)
end
