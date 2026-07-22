-- ============================================================================
-- palm6_threads/server/main.lua
--
-- Read-only deliverable-design fetch. On a client request the server resolves the
-- caller's citizenid via the bridge (NEVER client-asserted) and returns that
-- citizen's DEPLOYED designs with their allocated {component, drawable, texture}.
-- The resource NEVER writes clothing tables — palm6-web owns all writes; this only
-- reads palm6_clothing_designs (JOINing garments for the authoritative component).
--
-- Inert while Config.Enabled = false: the handler returns an empty list, so no
-- design is ever served until David flips the Task 9 gate.
-- ============================================================================

local function enabled()
    return Config and Config.Enabled == true
end

local function now()
    return os.time()
end

-- Per-source request budget (local token bucket, same shape as palm6_fc_combat's
-- rl). A client may ask for its designs at most once per REQUEST_WINDOW seconds.
local REQUEST_WINDOW = 3
local lastRequest = {}

local function rateLimited(src)
    local t = now()
    if (lastRequest[src] or 0) + REQUEST_WINDOW > t then return true end
    lastRequest[src] = t
    return false
end

AddEventHandler('playerDropped', function()
    local src = source
    lastRequest[src] = nil
end)

-- Read the caller's deployed designs. Read-only; JOINs garments for component_id.
-- Only rows with an allocated drawable_index are deliverable (approval allocates it).
local function fetchDeployedDesigns(citizenid)
    if not citizenid then return {} end
    local ok, rows = pcall(function()
        return MySQL.query.await([[
            SELECT d.id AS designId, d.garment_id AS garmentId, g.component_id AS componentId,
                   d.drawable_index AS drawableIndex, d.texture_index AS textureIndex,
                   g.label AS label
              FROM palm6_clothing_designs d
              JOIN palm6_clothing_garments g ON g.id = d.garment_id
             WHERE d.citizenid = ? AND d.status = 'deployed' AND d.drawable_index IS NOT NULL
        ]], { citizenid })
    end)
    return (ok and rows) or {}
end

-- Client asks for its wardrobe. `local src = source` FIRST (before any yield) so the
-- identity is stable across the DB await (FiveM source-after-yield hazard).
RegisterNetEvent('palm6_threads:requestDesigns', function()
    local src = source
    if not enabled() then
        TriggerClientEvent('palm6_threads:designs', src, {})
        return
    end
    if rateLimited(src) then return end
    local citizenid = Bridge.GetCitizenId(src)
    if not citizenid then
        TriggerClientEvent('palm6_threads:designs', src, {})
        return
    end
    local designs = fetchDeployedDesigns(citizenid)
    TriggerClientEvent('palm6_threads:designs', src, designs)
end)
