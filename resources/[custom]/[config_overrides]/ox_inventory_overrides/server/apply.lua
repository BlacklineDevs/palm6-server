-- ============================================================================
-- ox_inventory_overrides/server/apply.lua
--
-- Validates the shop/item catalog and registers our additions with
-- ox_inventory via its exports. We do NOT vendor ox_inventory; we publish
-- our extras over the canonical export surface.
-- ============================================================================

local function validateItems()
    assert(type(ExtraItems) == 'table', 'ExtraItems missing')
    for name, def in pairs(ExtraItems) do
        assert(type(name) == 'string' and #name > 0, 'item name required')
        assert(def.label, ('item %s: label required'):format(name))
        assert(def.weight and def.weight >= 0, ('item %s: weight required'):format(name))
    end
end

local function validateShops()
    assert(type(ExtraShops) == 'table', 'ExtraShops missing')
    for key, shop in pairs(ExtraShops) do
        assert(shop.name, ('shop %s: name required'):format(key))
        assert(shop.inventory and #shop.inventory > 0,
            ('shop %s: inventory must not be empty'):format(key))
        local isSociety = shop.groups ~= nil
        for i, item in ipairs(shop.inventory) do
            assert(item.name, ('shop %s entry %d: item name required'):format(key, i))
            assert(item.price ~= nil, ('shop %s entry %d: price required'):format(key, i))
            assert(item.price >= 0, ('shop %s entry %d: price must be >= 0'):format(key, i))
            if not isSociety then
                assert(item.price > 0,
                    ('shop %s entry %d: public shop must not have zero price'):format(key, i))
            end
        end
        assert(shop.locations and #shop.locations >= 1,
            ('shop %s: at least one location required'):format(key))
    end
end

local function applyItems()
    -- ox_inventory's runtime items registry. The canonical export is
    -- ox_inventory:Items() returning the table; we mutate it directly,
    -- which is the documented extension pattern.
    local ok, items = pcall(function() return exports.ox_inventory:Items() end)
    if not ok or type(items) ~= 'table' then
        print('[ox_inventory_overrides] ox_inventory:Items() unavailable; skipping merge')
        return 0
    end
    local added = 0
    for name, def in pairs(ExtraItems) do
        if not items[name] then
            items[name] = def
            added = added + 1
        end
    end
    return added
end

local function applyShops()
    -- Same pattern for shops.
    local ok, shops = pcall(function() return exports.ox_inventory:Shops() end)
    if not ok or type(shops) ~= 'table' then
        print('[ox_inventory_overrides] ox_inventory:Shops() unavailable; skipping merge')
        return 0
    end
    local added = 0
    for key, shop in pairs(ExtraShops) do
        shops[key] = shop
        added = added + 1
    end
    return added
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    validateItems()
    validateShops()
    local i = applyItems()
    local s = applyShops()
    print(('[ox_inventory_overrides] merged %d items, %d shops'):format(i, s))
end)
