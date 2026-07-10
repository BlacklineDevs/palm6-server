-- ============================================================================
-- ox_inventory_overrides/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that knows
-- about ox_inventory's server export surface (the items registry and the
-- RegisterShop entrypoint).
--
-- Core logic (server/apply.lua) calls Bridge.* and nothing else. To port
-- this resource to a different inventory framework (or to GTA VI), rewrite
-- THIS FILE against the new items/shop API. The catalog validation and the
-- merge/verify flow above it are untouched.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

-- ox_inventory's full runtime items registry. Returns (ok, items) mirroring
-- pcall: ok=false means the export errored/was unavailable. CAUTION: the
-- returned table is a msgpack COPY — mutating it does NOT reach ox_inventory
-- (see server/apply.lua applyItems for why this matters).
function Bridge.GetItems()
    return pcall(function() return exports.ox_inventory:Items() end)
end

-- A single registered item definition by name. Returns (ok, item) mirroring
-- pcall; item is nil when the name is not registered.
function Bridge.GetItem(name)
    return pcall(function() return exports.ox_inventory:Items(name) end)
end

-- Register one shop with ox_inventory at runtime (server-side only, via the
-- RegisterShop export in modules/shops/server.lua). Returns (ok, err)
-- mirroring pcall.
function Bridge.RegisterShop(key, shop)
    return pcall(function() exports.ox_inventory:RegisterShop(key, shop) end)
end
