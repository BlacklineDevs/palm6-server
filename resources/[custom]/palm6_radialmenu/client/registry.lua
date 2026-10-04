--[[
    client/registry.lua — runtime item registration API.

    Other resources inject items at runtime (police duty menu, mechanic tools, etc.) — this
    mirrors how qbx_radialmenu's ecosystem already works today, so palm6_radialmenu offers an
    equivalent surface.

    exports('palm6_radialmenu'):RegisterRadialItem(parentId, item)
    exports('palm6_radialmenu'):RemoveRadialItem(parentId, itemId)

    CONSTRAINT (document verbatim to callers, also in README.md): a Lua closure (e.g. a
    canShow() condition function) cannot cross the export boundary safely — item tables are
    copied across the export call, so a function value would either error or silently become
    unusable. Callers that need conditional visibility must call RemoveRadialItem /
    RegisterRadialItem themselves when their condition changes (job change, zone enter/exit,
    vehicle state). palm6_radialmenu does not accept function-valued fields in registered
    items, only the static per-open `job` string/table gate documented in shared/config.lua.
]]

local Registry = {
    extra = {},   -- extra[parentId] = { item, item, ... }
    owner = {},   -- owner[parentId][itemId] = registering resource name (or nil)
}
local currentJob = nil

--- Registers an item to be spliced into the folder node with id == parentId, at every
--- BuildTree() call from this point forward (including the currently-open menu on its next
--- OpenRadial()).
---@param parentId string
---@param item table  node shape per shared/config.lua's schema (no function-valued fields)
exports('RegisterRadialItem', function(parentId, item)
    if type(parentId) ~= 'string' or type(item) ~= 'table' or type(item.id) ~= 'string' then
        return
    end

    -- The invoking resource is recorded so its entries can be dropped when it
    -- stops (see the onResourceStop handler below). GetInvokingResource() is
    -- nil when called from this resource itself, which never happens today but
    -- would simply mean "no owner to clean up after".
    local owner = GetInvokingResource()

    local list = Registry.extra[parentId] or {}
    Registry.extra[parentId] = list

    -- REPLACE BY ID, NEVER APPEND BLINDLY.
    --
    -- This was a plain table.insert with no id scan, so `restart palm6_police`
    -- while palm6_radialmenu keeps running re-registered every one of its
    -- wedges on top of the copies already there - duplicated labels and a
    -- shrinking angleStep for the whole level. Re-registering the same id is
    -- the normal way a caller updates an item anyway (the export boundary
    -- cannot carry a closure, so callers re-register on state changes - see
    -- this file's header), which makes replace the correct semantic, not just
    -- the safe one.
    -- Ownership is tracked in a PARALLEL table rather than as a field on the
    -- item: the item itself is deep-copied straight into the menu tree and
    -- shipped to the NUI, and bookkeeping has no business travelling with it.
    Registry.owner[parentId] = Registry.owner[parentId] or {}
    Registry.owner[parentId][item.id] = owner

    for i = 1, #list do
        if list[i].id == item.id then
            list[i] = item
            return
        end
    end

    list[#list + 1] = item
end)

--- Removes a previously-registered item by id from the given parent's extra list. No-op if
--- the parent has no registrations or the id isn't found.
---@param parentId string
---@param itemId string
exports('RemoveRadialItem', function(parentId, itemId)
    local list = Registry.extra[parentId]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].id == itemId then table.remove(list, i) end
    end
    if Registry.owner[parentId] then Registry.owner[parentId][itemId] = nil end
end)

--- Drops every item registered by a resource that has just stopped.
---
--- Without this, a stopped resource's wedges stayed in the menu forever,
--- pointing at events nothing listens for any more - and on its restart they
--- were re-registered alongside the stale copies. RegisterRadialItem's
--- replace-by-id covers the restart half; this covers the "stopped and did not
--- come back" half.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end

    for parentId, owners in pairs(Registry.owner) do
        local list = Registry.extra[parentId]
        if list then
            for i = #list, 1, -1 do
                local id = list[i].id
                if owners[id] == resource then
                    table.remove(list, i)
                    owners[id] = nil
                end
            end
        end
    end
end)

-- v0.1.0: this event exists so the wiring is ready the moment v0.2.0's server/main.lua
-- starts firing it (see fxmanifest.lua's commented-out server_scripts block and README.md
-- §"job-gating"). With no server-side sender yet, currentJob simply stays nil and every
-- `job`-gated node passes the filter below unfiltered.
RegisterNetEvent('palm6_radialmenu:syncJob', function(job)
    currentJob = job
end)

--- Deep-copies an arbitrary table (menu-tree nodes only contain strings/numbers/booleans/
--- nested tables — no functions, so a plain recursive copy is safe and sufficient here).
local function deepCopy(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = deepCopy(v)
    end
    return out
end

--- Returns true if `nodeJob` (a node's `job` field: nil, a string, or an array of strings)
--- allows the current synced job. nil job = always visible.
local function passesJobGate(nodeJob)
    if nodeJob == nil then return true end
    if currentJob == nil then return true end -- v0.1.0: no sync yet, treat as inert/no-op
    if type(nodeJob) == 'string' then
        return nodeJob == currentJob
    end
    if type(nodeJob) == 'table' then
        for _, j in ipairs(nodeJob) do
            if j == currentJob then return true end
        end
        return false
    end
    return true
end

--- Recursively splices Registry.extra[node.id] into node.items at every folder node, then
--- strips any node whose `job` field doesn't pass passesJobGate(). Mutates the (already
--- deep-copied) tree in place and returns it.
local function spliceAndFilter(node)
    if type(node) ~= 'table' then return node end

    if node.items then
        local extra = Registry.extra[node.id]
        if extra then
            for _, item in ipairs(extra) do
                table.insert(node.items, deepCopy(item))
            end
        end

        local filtered = {}
        for _, child in ipairs(node.items) do
            if passesJobGate(child.job) then
                table.insert(filtered, spliceAndFilter(child))
            end
        end
        node.items = filtered
    end

    return node
end

--- BuildTree(): deep-copies Config.MenuTree, splices Registry.extra[node.id] into
--- node.items at every folder node (recursive), then strips any node where node.job is
--- set and doesn't match currentJob. Called fresh on every OpenRadial() in client/main.lua
--- so registrations made after the menu was last closed are always current.
---@return table
function BuildTree()
    local tree = deepCopy(Config.MenuTree)
    return spliceAndFilter(tree)
end
