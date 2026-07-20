-- ============================================================================
-- palm6_business/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file that calls ox_lib UI. client/main.lua
-- drives the flow and calls Game.* only, so the whole UI ports to GTA VI by
-- rewriting THIS FILE (the bridge pattern, same as palm6_gangs).
--
-- MVP is abstract (no world coords/blips/peds) — pure management UI over
-- server-authoritative state, plus one skill-check "serve" moment. Everything
-- the player does is re-validated on the server.
-- ============================================================================

Game = {}

function Game.Notify(opts)
    lib.notify(opts)
end

-- Context menu. `options` = ox_lib option list. `parentId` (optional) wires a
-- Back arrow to a previously-registered menu.
function Game.OpenMenu(id, title, options, parentId)
    lib.registerContext({ id = id, title = title, menu = parentId, options = options })
    lib.showContext(id)
end

-- Free-form input dialog. Returns the raw results array, or nil if cancelled.
function Game.InputDialog(title, fields)
    return lib.inputDialog(title, fields)
end

-- Yes/no confirmation. Returns true only if the player confirmed.
function Game.Confirm(header, content)
    return lib.alertDialog({
        header = header, content = content, centered = true, cancel = true,
    }) == 'confirm'
end

-- Read-only report dialog (roster / ledger view).
function Game.ShowReport(title, content)
    lib.alertDialog({ header = title, content = content, centered = true, cancel = false })
end

-- The "serve a walk-in customer" active-work moment. A quick skill-check gates
-- the NPC-income serve so it is active play, never AFK minting. `spec` (optional,
-- Phase per-type) = { difficulty = {...}, keys = {...} } for a themed check per
-- business type; falls back to the Phase-0 default. Returns true on success. The
-- server re-validates clock-in/supply/cooldown/daily-cap regardless.
function Game.ServeAction(spec)
    local difficulty = (spec and spec.difficulty) or { 'easy', 'easy', 'medium' }
    local keys = (spec and spec.keys) or { 'w', 'a', 's', 'd' }
    local ok = lib.skillCheck(difficulty, keys)
    return ok == true
end

-- ---------------------------------------------------------------------------
-- Phase 1 — storefront presentation (map blips + walk-up interaction). All the
-- GTA natives / ox_target live HERE so client/main.lua stays framework-free: it
-- just hands us the server's storefront list and an onSelect(id) callback.
-- ---------------------------------------------------------------------------
local hasTarget = GetResourceState('ox_target') == 'started'
local sf = { blips = {}, zones = {}, list = {}, onSelect = nil, loop = false }

function Game.HasTarget() return hasTarget end

local function tearDownStorefronts()
    for _, b in pairs(sf.blips) do if b then RemoveBlip(b) end end
    if hasTarget then
        for _, z in pairs(sf.zones) do pcall(function() exports.ox_target:removeZone(z) end) end
    end
    sf.blips, sf.zones, sf.list = {}, {}, {}
end

-- (Re)build blips + interaction points for the FULL storefront list. Called on
-- every server broadcast; a full rebuild (storefront changes are rare) sidesteps
-- any diff bugs. `cfg` = Config.Storefront (blip scale). onSelect(id) fires on walk-up.
function Game.RenderStorefronts(list, cfg, onSelect)
    tearDownStorefronts()
    sf.onSelect = onSelect
    local scale = (cfg and cfg.Scale) or 0.85
    for _, s in ipairs(list or {}) do
        if s.id and s.x and s.y and s.z then
            sf.list[s.id] = s
            local b = AddBlipForCoord(s.x + 0.0, s.y + 0.0, s.z + 0.0)
            SetBlipSprite(b, s.sprite or 52)
            SetBlipColour(b, s.color or 5)
            SetBlipScale(b, scale)
            SetBlipAsShortRange(b, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(s.name or 'Business')
            EndTextCommandSetBlipName(b)
            sf.blips[s.id] = b
            if hasTarget then
                local id = s.id
                sf.zones[id] = exports.ox_target:addSphereZone({
                    coords = vec3(s.x + 0.0, s.y + 0.0, s.z + 0.0),
                    radius = 2.0,
                    debug = false,
                    options = { {
                        name = ('palm6_biz_%s'):format(id),
                        icon = 'fa-solid fa-store',
                        label = s.name or 'Business',
                        distance = 2.5,
                        onSelect = function() if sf.onSelect then sf.onSelect(id) end end,
                    } },
                })
            end
        end
    end
    -- Marker + [E] fallback when ox_target is absent: ONE loop over all storefronts
    -- (not one thread each). Started once; reads the live sf.list each rebuild.
    if not hasTarget and not sf.loop then
        sf.loop = true
        CreateThread(function()
            while sf.loop do
                local sleep = 1000
                local ped = PlayerPedId()
                local pc = (ped ~= 0) and GetEntityCoords(ped) or nil
                local nearId, nearS
                if pc then
                    for id, s in pairs(sf.list) do
                        local dx, dy, dz = pc.x - s.x, pc.y - s.y, pc.z - s.z
                        if (dx * dx + dy * dy + dz * dz) < 6.25 then nearId, nearS = id, s; break end  -- 2.5m
                    end
                end
                if nearId then
                    sleep = 0
                    DrawMarker(1, nearS.x, nearS.y, nearS.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        0.6, 0.6, 0.4, 90, 160, 255, 120, false, false, 2, false, nil, nil, false)
                    lib.showTextUI(('[E] %s'):format(nearS.name or 'Business'))
                    if IsControlJustReleased(0, 38) and sf.onSelect then sf.onSelect(nearId) end
                else
                    lib.hideTextUI()
                end
                Wait(sleep)
            end
            lib.hideTextUI()
        end)
    end
end

-- Full teardown (resource stop). Stops the fallback loop too.
function Game.ClearStorefronts()
    tearDownStorefronts()
    sf.loop = false
    if not hasTarget then lib.hideTextUI() end
end
