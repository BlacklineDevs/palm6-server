-- ============================================================================
-- palm6_threads/client/main.lua
--
-- Phase 1 equip path + /threads wardrobe. Requests the caller's DEPLOYED designs
-- from the server (identity resolved server-side), lets the player equip/unequip
-- them, applies the component live, and writes {component, drawable, texture} into
-- the illenium saved skin so it re-applies on every spawn (spec §10 persistence).
--
-- The equip path applies whatever indices a deployed design declares — it does NOT
-- know or care whether the .ytd arrived via Stage A replacement or a Stage B addon
-- (the delivery abstraction). Everything is INERT while Config.Enabled = false.
-- ============================================================================

local function enabled()
    return Config and Config.Enabled == true
end

local myDesigns = {}                 -- server cache: deployed designs for my citizenid
local equipped = {}                  -- component -> { designId, drawable, texture }
local baseSnapshot = {}              -- component -> { drawable, texture } (for restore)

RegisterNetEvent('palm6_threads:designs', function(designs)
    myDesigns = (type(designs) == 'table') and designs or {}
end)

local function requestDesigns()
    TriggerServerEvent('palm6_threads:requestDesigns')
end

-- Sanity-check an index sits inside the reserved band for its component before we
-- apply it (defense-in-depth against a bad/mismatched row corrupting the ped).
local function indexInBand(component, drawable)
    local band = Config.Bands and Config.Bands[component]
    if not band then return true end -- no band configured -> don't block
    return drawable >= band.start and drawable < (band.start + band.size)
end

-- Write one component into the illenium saved appearance so it survives respawn.
local function persistComponent(ped, component, drawable, texture)
    local ap = Game.GetAppearance(ped)
    if not ap or type(ap.components) ~= 'table' then return end
    for _, c in ipairs(ap.components) do
        if c.component_id == component then
            c.drawable = drawable
            c.texture = texture
            Game.SetAppearance(ped, ap)
            return
        end
    end
    ap.components[#ap.components + 1] =
        { component_id = component, drawable = drawable, texture = texture, palette = 0 }
    Game.SetAppearance(ped, ap)
end

local function equipDesign(d)
    if not enabled() then return end
    local component = tonumber(d.componentId)
    local drawable = tonumber(d.drawableIndex)
    local texture = tonumber(d.textureIndex) or 0
    if not component or not drawable then return end
    if not indexInBand(component, drawable) then
        Game.Notify({ title = 'Threads', description = 'That design is not deliverable yet.', type = 'error' })
        return
    end
    local ped = Game.MyPed()
    if not baseSnapshot[component] then
        local bd, bt = Game.GetComponent(ped, component)
        baseSnapshot[component] = { drawable = bd, texture = bt }
    end
    Game.ApplyComponent(ped, component, drawable, texture)
    persistComponent(ped, component, drawable, texture)
    equipped[component] = { designId = d.designId, drawable = drawable, texture = texture }
    Game.Notify({ title = 'Threads', description = ('Equipped %s'):format(d.label or 'design'), type = 'success' })
end

local function unequip(component)
    local ped = Game.MyPed()
    local base = baseSnapshot[component]
    if base then
        Game.ApplyComponent(ped, component, base.drawable, base.texture)
        persistComponent(ped, component, base.drawable, base.texture)
    end
    equipped[component] = nil
    Game.Notify({ title = 'Threads', description = 'Unequipped.', type = 'inform' })
end

-- Build + open the wardrobe menu from the current design cache.
local function openWardrobe()
    local options = {}
    for _, d in ipairs(myDesigns) do
        local comp = tonumber(d.componentId)
        local isOn = comp and equipped[comp] and equipped[comp].designId == d.designId
        options[#options + 1] = {
            title = (d.label or ('Design #' .. tostring(d.designId))) .. (isOn and '  (equipped)' or ''),
            description = ('component %s, drawable %s'):format(tostring(d.componentId), tostring(d.drawableIndex)),
            onSelect = function()
                if isOn then unequip(comp) else equipDesign(d) end
            end,
        }
    end
    if #options == 0 then
        options[1] = { title = 'No deliverable designs', description = 'Design one at the Threads dashboard.', disabled = true }
    end
    Game.OpenMenu('palm6_threads_wardrobe', 'Threads Wardrobe', options)
end

RegisterCommand('threads', function()
    if not enabled() then
        print('[palm6_threads] disabled (Config.Enabled=false)')
        return
    end
    requestDesigns()
    -- Give the server round-trip a beat to populate the cache before rendering.
    CreateThread(function()
        Wait(400)
        openWardrobe()
    end)
end, false)

-- Re-apply equipped items live on (re)spawn. illenium's saved-skin persistence is
-- the primary mechanism; this is a belt-and-suspenders live re-apply. Inert when dark.
AddEventHandler('playerSpawned', function()
    if not enabled() then return end
    requestDesigns()
    local ped = Game.MyPed()
    for component, e in pairs(equipped) do
        Game.ApplyComponent(ped, component, e.drawable, e.texture)
    end
end)

-- Warm the cache once on resource start so /threads is responsive. Inert when dark.
CreateThread(function()
    Wait(2000)
    if enabled() then requestDesigns() end
end)
