-- ============================================================================
-- ox_inventory_overrides/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls GTA V
-- natives (blips, markers, help prompts, controls), ox_target zones, the
-- ox_inventory shop UI, or ox_lib points.
--
-- Core logic (client/render.lua) calls Game.* and nothing else. To port
-- this resource to GTA VI, rewrite THIS FILE against the new natives and
-- interaction framework. The shop-catalog walk, the target-vs-marker
-- fallback decision, and the created-handle bookkeeping are untouched.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Game = {}

-- True when ox_target is available for zone/model interactions (else the
-- renderer falls back to a lib.points marker with an E prompt).
function Game.HasTarget()
    return GetResourceState('ox_target') == 'started'
end

-- Open the ox_inventory shop UI for a shop type / optional location id.
function Game.OpenShop(shopType, locationId)
    exports.ox_inventory:openInventory('shop', {
        type = shopType,
        id   = locationId,
    })
end

-- Add a map blip at {x,y,z}. Returns the blip handle, or nil when blipDef is
-- absent (a shop without a `blip` field renders no blip).
function Game.AddBlip(coords, blipDef, shopName)
    if type(blipDef) ~= 'table' then return nil end
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, blipDef.id or 52)
    SetBlipColour(b, blipDef.colour or 0)
    SetBlipScale(b, blipDef.scale or 0.8)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(shopName or 'Shop')
    EndTextCommandSetBlipName(b)
    return b
end

-- Remove a blip handle if it exists.
function Game.RemoveBlip(handle)
    if handle and DoesBlipExist(handle) then RemoveBlip(handle) end
end

-- Add an ox_target sphere zone bound to `onSelect`. Returns the zone id.
function Game.AddSphereTarget(name, coords, label, groups, onSelect)
    return exports.ox_target:addSphereZone({
        coords = coords,
        radius = 1.5,
        debug  = false,
        options = {
            {
                name     = name,
                icon     = 'fas fa-shopping-basket',
                label    = label,
                groups   = groups,
                onSelect = onSelect,
                distance = 2.0,
            },
        },
    })
end

-- Add an ox_target box zone bound to `onSelect`. `geo` carries the resolved
-- geometry {coords, length, width, height, heading, distance}. Returns the
-- zone id.
function Game.AddBoxTarget(name, geo, label, groups, onSelect)
    return exports.ox_target:addBoxZone({
        coords   = geo.coords,
        size     = vec3(geo.length or 1.0, geo.width or 1.0, geo.height),
        rotation = geo.heading or 0.0,
        debug    = false,
        options  = {
            {
                name     = name,
                icon     = 'fas fa-shopping-basket',
                label    = label,
                groups   = groups,
                onSelect = onSelect,
                distance = geo.distance or 2.0,
            },
        },
    })
end

-- Add an ox_target model-bound option. Records nothing itself — the caller
-- tracks the {models, name} pair for cleanup.
function Game.AddModelTarget(name, models, label, groups, onSelect)
    exports.ox_target:addModel(models, {
        {
            name     = name,
            icon     = 'fas fa-shopping-basket',
            label    = label,
            groups   = groups,
            onSelect = onSelect,
            distance = 2.0,
        },
    })
end

-- Remove an ox_target zone by id.
function Game.RemoveZone(zoneId)
    if zoneId then exports.ox_target:removeZone(zoneId) end
end

-- Remove an ox_target model option by its models + option name.
function Game.RemoveModel(models, name)
    exports.ox_target:removeModel(models, name)
end

-- Create a lib.points marker at {x,y,z} that draws a marker and opens the
-- shop via `onSelect` when the player is close and presses E. Returns the
-- point handle (has :remove()).
function Game.AddMarkerPoint(shopType, locationId, coords, onSelect)
    local point = lib.points.new({
        coords   = coords,
        distance = 16.0,
        invId    = locationId,
        invType  = shopType,
    })

    function point:nearby()
        DrawMarker(
            2,
            self.coords.x, self.coords.y, self.coords.z + 0.5,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            0.3, 0.3, 0.3,
            255, 255, 255, 200,
            false, true, 2, false, nil, nil, false
        )
        if self.currentDistance < 1.5 then
            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to open shop')
            EndTextCommandDisplayHelp(0, false, true, -1)
            if IsControlJustReleased(0, 38) then -- E
                onSelect()
            end
        end
    end

    return point
end

-- Remove a lib.points marker handle.
function Game.RemovePoint(point)
    if point and point.remove then point:remove() end
end
