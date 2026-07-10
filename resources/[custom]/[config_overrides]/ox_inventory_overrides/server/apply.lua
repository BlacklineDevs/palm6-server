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
    -- ox_inventory's runtime items registry, via the ox_inventory:Items()
    -- export. CAUTION: cross-resource Lua export return values are msgpack
    -- COPIES, so mutating the returned table only reaches ox_inventory if
    -- the export exposes a live table (it usually does NOT). We attempt the
    -- merge, then VERIFY each item with a fresh per-name lookup and fail
    -- loudly for anything that did not land, instead of silently shipping
    -- items that AddItem will reject as invalid.
    local ok, items = Bridge.GetItems()
    if not ok or type(items) ~= 'table' then
        print('[ox_inventory_overrides] ox_inventory:Items() unavailable; skipping merge')
        return 0
    end
    for name, def in pairs(ExtraItems) do
        if not items[name] then
            items[name] = def
        end
    end
    local added, missing = 0, {}
    for name in pairs(ExtraItems) do
        local okV, item = Bridge.GetItem(name)
        if okV and item ~= nil then
            added = added + 1
        else
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        table.sort(missing)
        print(('^1[ox_inventory_overrides] FATAL: %d item(s) did NOT register with '
            .. 'ox_inventory: %s. The runtime merge cannot reach ox_inventory (export '
            .. 'tables are copies) — run tools/patch-ox-items.sh against the deployed resources dir and restart.^0')
            :format(#missing, table.concat(missing, ', ')))
    end
    return added
end

local function applyShops()
    -- ox_inventory v2.47.5 exposes no `Shops()` getter; the canonical way to
    -- add shops at runtime is the server-side export `RegisterShop(type, details)`
    -- defined in modules/shops/server.lua. We call it once per ExtraShops entry.
    -- Note: this registers server-side only; the client-side blip / ox_target
    -- interaction surface is created by this resource's own client/render.lua.
    local added = 0
    for key, shop in pairs(ExtraShops) do
        local ok, err = Bridge.RegisterShop(key, shop)
        if ok then
            added = added + 1
        else
            print(('[ox_inventory_overrides] RegisterShop(%s) failed: %s')
                :format(tostring(key), tostring(err)))
        end
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
