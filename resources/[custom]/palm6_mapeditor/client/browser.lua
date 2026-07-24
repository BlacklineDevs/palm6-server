-- ============================================================================
-- palm6_mapeditor/client/browser.lua  —  prop catalog browser + fuzzy search
--
-- 5,295 props across 44 categories (data/prop_groups.lua). Browse by category
-- or /propsearch <query> (fuzzy). Picking a prop spawns it into the editor. Uses
-- ox_lib menus (reliable, no NUI build step); the in-world ghost/carry preview
-- from client/main.lua is the "did I pick the right one" check.
-- ============================================================================

local groups = Config.PropGroups or {}

-- Flatten all models once for search.
local allModels = {}
for _, g in ipairs(groups) do
    for _, m in ipairs(g.models or {}) do allModels[#allModels + 1] = m end
end

local function pickProp(model)
    TriggerEvent('palm6_mapeditor:spawn', model)
end

-- --- category browse -------------------------------------------------------
local function showCategory(gi)
    local g = groups[gi]
    if not g then return end
    local opts = {}
    for _, m in ipairs(g.models or {}) do
        opts[#opts + 1] = { title = m, icon = 'cube', onSelect = function() pickProp(m) end }
    end
    lib.registerContext({ id = 'p6me_cat_' .. gi, title = g.category, menu = 'p6me_cats', options = opts })
    lib.showContext('p6me_cat_' .. gi)
end

local function showCategories()
    local opts = {}
    for i, g in ipairs(groups) do
        opts[#opts + 1] = {
            title = g.category, description = (#(g.models or {})) .. ' props', icon = 'folder',
            onSelect = function() showCategory(i) end,
        }
    end
    lib.registerContext({ id = 'p6me_cats', title = 'Prop Catalog (' .. #allModels .. ')', options = opts })
    lib.showContext('p6me_cats')
end

-- --- fuzzy search ----------------------------------------------------------
-- Cheap score: exact-substring first (strip prop_/_), then subsequence match.
local function score(model, q)
    local name = model:gsub('prop_', ''):gsub('_', ' ')
    local sub = name:find(q, 1, true)
    if sub then return 1000 - sub end
    -- subsequence: all query chars appear in order
    local qi, pos = 1, 0
    for i = 1, #name do
        if name:sub(i, i) == q:sub(qi, qi) then qi = qi + 1; pos = pos + i; if qi > #q then break end end
    end
    if qi > #q then return 100 - (pos / #name) end
    return nil
end

local function search(q)
    q = (q or ''):lower():gsub('%s+', '')
    if #q < 2 then return end
    local hits = {}
    for _, m in ipairs(allModels) do
        local s = score(m, q)
        if s then hits[#hits + 1] = { m = m, s = s } end
    end
    table.sort(hits, function(a, b) return a.s > b.s end)
    local opts = {}
    for i = 1, math.min(#hits, 50) do
        opts[#opts + 1] = { title = hits[i].m, icon = 'cube', onSelect = function() pickProp(hits[i].m) end }
    end
    if #opts == 0 then opts[1] = { title = 'no matches for "' .. q .. '"', disabled = true } end
    lib.registerContext({ id = 'p6me_search', title = ('Search: %s (%d)'):format(q, #hits), options = opts })
    lib.showContext('p6me_search')
end

-- --- commands --------------------------------------------------------------
RegisterCommand('props', function() showCategories() end, false)
RegisterCommand('propsearch', function(_, args)
    if args[1] then search(table.concat(args, ' '))
    else
        local input = lib.inputDialog('Prop search', { { type = 'input', label = 'query', required = true } })
        if input and input[1] then search(input[1]) end
    end
end, false)
