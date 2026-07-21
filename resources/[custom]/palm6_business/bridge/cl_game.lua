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
function Game.RenderStorefronts(list, cfg, onSelect, onEnter)
    tearDownStorefronts()
    sf.onSelect = onSelect
    sf.onEnter = onEnter
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
                local opts = { {
                    name = ('palm6_biz_%s'):format(id),
                    icon = 'fa-solid fa-store',
                    label = s.name or 'Business',
                    distance = 2.5,
                    onSelect = function() if sf.onSelect then sf.onSelect(id) end end,
                } }
                -- Enterable storefronts get a second option; the server flags
                -- s.hasInterior only when interiors are on AND this type has a
                -- captured shell, so a non-enterable shop is unchanged.
                if s.hasInterior then
                    opts[#opts + 1] = {
                        name = ('palm6_biz_enter_%s'):format(id),
                        icon = 'fa-solid fa-door-open',
                        label = 'Enter',
                        distance = 2.5,
                        onSelect = function() if sf.onEnter then sf.onEnter(id) end end,
                    }
                end
                sf.zones[id] = exports.ox_target:addSphereZone({
                    coords = vec3(s.x + 0.0, s.y + 0.0, s.z + 0.0),
                    radius = 2.0,
                    debug = false,
                    options = opts,
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
                    local prompt = ('[E] %s'):format(nearS.name or 'Business')
                    if nearS.hasInterior then prompt = prompt .. '  |  [G] Enter' end
                    lib.showTextUI(prompt)
                    if IsControlJustReleased(0, 38) and sf.onSelect then sf.onSelect(nearId) end       -- E
                    if nearS.hasInterior and IsControlJustReleased(0, 47) and sf.onEnter then           -- G
                        sf.onEnter(nearId)
                    end
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

-- Nearest rendered storefront within `radius` (metres) of the player, or nil. Used
-- by /robstore; the server re-validates the business id + proximity + all gates.
function Game.NearestStorefront(radius)
    local ped = PlayerPedId()
    if ped == 0 then return nil end
    local pc = GetEntityCoords(ped)
    local r2 = (radius or 3.5) * (radius or 3.5)
    local bestId, bestD, bestName
    for id, s in pairs(sf.list) do
        local dx, dy, dz = pc.x - s.x, pc.y - s.y, pc.z - s.z
        local d = dx * dx + dy * dy + dz * dz
        if d <= r2 and (not bestD or d < bestD) then bestId, bestD, bestName = id, d, s.name end
    end
    if bestId then return { id = bestId, name = bestName } end
    return nil
end

-- The "crack the register" active-work moment for a robbery. Harder skill-check than
-- a serve; server re-validates every money gate regardless of the client result.
function Game.RobAction(spec)
    local difficulty = (spec and spec.difficulty) or { 'medium', 'medium', 'hard' }
    local keys = (spec and spec.keys) or { 'w', 'a', 's', 'd' }
    return lib.skillCheck(difficulty, keys) == true
end

-- ---------------------------------------------------------------------------
-- Phase 1b — interior teleport + per-business prop dressing. All GTA natives
-- live here so client/main.lua stays framework-free.
--
-- The player is ALREADY moved into the business's routing bucket server-side
-- before enterInterior arrives, so the shell + these props render only to
-- people inside this business. Props spawn NON-NETWORKED (CreateObject with
-- isNetwork=false): each client renders its own local copy at identical offsets,
-- so the room looks furnished to everyone in the bucket at zero server cost and
-- with no ymap. We track and delete them on exit.
-- ---------------------------------------------------------------------------
local spawnedProps = {}

local function clearInteriorProps()
    for _, obj in ipairs(spawnedProps) do
        if obj and DoesEntityExist(obj) then DeleteObject(obj) end
    end
    spawnedProps = {}
end

-- Rotate a local (ox,oy) offset by the shell heading so a layout authored around
-- +Y lands correctly whatever direction the shell faces.
local function rotateOffset(ox, oy, headingDeg)
    local rad = math.rad(headingDeg or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    return ox * c - oy * s, ox * s + oy * c
end

local function loadModel(model, timeoutMs)
    local hash = (type(model) == 'number') and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < (timeoutMs or 3000) do
        Wait(50); waited = waited + 50
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- Spawn a layout's props relative to the shell anchor. `layout` = the resolved
-- Config.Interior.Layouts entry; `anchor` = { x,y,z,h }. A prop that fails to
-- load is skipped, never fatal — a missing prop must not block or empty the room.
local function spawnLayout(layout, anchor)
    clearInteriorProps()
    if not layout or not layout.props then return end
    local cap = (Config.Interior and Config.Interior.MaxPropsPerLayout) or 24
    local timeout = (Config.Interior and Config.Interior.PropLoadTimeoutMs) or 3000
    for i, p in ipairs(layout.props) do
        if i > cap then break end
        local hash = loadModel(p.model, timeout)
        if hash then
            local rx, ry = rotateOffset(p.ox or 0.0, p.oy or 0.0, anchor.h)
            local obj = CreateObject(hash, anchor.x + rx, anchor.y + ry, anchor.z + (p.oz or 0.0), false, false, false)
            if obj and obj ~= 0 then
                SetEntityHeading(obj, (anchor.h or 0.0) + (p.oh or 0.0))
                FreezeEntityPosition(obj, true)
                SetEntityAsMissionEntity(obj, true, true)  -- so DeleteObject reliably reaps it
                spawnedProps[#spawnedProps + 1] = obj
            end
            SetModelAsNoLongerNeeded(hash)
        end
    end
end

-- Resolve a layout key against Config, falling back to DefaultLayout then bare.
local function resolveLayout(key)
    local layouts = (Config.Interior and Config.Interior.Layouts) or {}
    for _, l in ipairs(layouts) do if l.key == key then return l end end
    local def = Config.Interior and Config.Interior.DefaultLayout
    for _, l in ipairs(layouts) do if l.key == def then return l end end
    return nil
end

-- The exit interaction (ox_target zone, or a fallback key loop) living at the
-- shell door anchor while the player is inside. onExit(died) fires the server
-- exit event; died=true (death path) tells the server to reset the bucket WITHOUT
-- teleporting to the door, so the respawn positions the player. Torn down on
-- every exit so it never leaks between visits.
local exitState = { zone = nil, loop = false, watch = false, anchor = nil, onExit = nil }

local function tearDownExit()
    if exitState.zone and hasTarget then
        pcall(function() exports.ox_target:removeZone(exitState.zone) end)
    end
    exitState.zone = nil
    exitState.loop = false
    exitState.watch = false
    exitState.anchor = nil
    if not hasTarget then lib.hideTextUI() end
end

local function setUpExit(anchor, onExit)
    tearDownExit()
    exitState.anchor = anchor
    exitState.onExit = onExit
    local exitR = (Config.Interior and Config.Interior.ExitRadius) or 2.5
    if hasTarget then
        exitState.zone = exports.ox_target:addSphereZone({
            coords = vec3(anchor.x + 0.0, anchor.y + 0.0, anchor.z + 0.0),
            radius = exitR,
            debug = false,
            options = { {
                name = 'palm6_biz_leave',
                icon = 'fa-solid fa-door-closed',
                label = 'Leave',
                distance = exitR + 0.5,
                onSelect = function() if exitState.onExit then exitState.onExit(false) end end,
            } },
        })
    else
        exitState.loop = true
        CreateThread(function()
            local r2 = exitR * exitR
            while exitState.loop do
                local sleep = 500
                local a = exitState.anchor
                local ped = PlayerPedId()
                if a and ped ~= 0 then
                    local pc = GetEntityCoords(ped)
                    local dx, dy, dz = pc.x - a.x, pc.y - a.y, pc.z - a.z
                    if (dx * dx + dy * dy + dz * dz) <= r2 then
                        sleep = 0
                        lib.showTextUI('[E] Leave')
                        if IsControlJustReleased(0, 38) and exitState.onExit then exitState.onExit(false) end
                    else
                        lib.hideTextUI()
                    end
                end
                Wait(sleep)
            end
            lib.hideTextUI()
        end)
    end

    -- DEATH WATCH — the critical anti-stranding guard. If the player dies inside,
    -- the exit zone (at the door) can never be reached: they respawn at a hospital
    -- still in the routing bucket, seeing an empty world with no way out. This
    -- thread detects the death and fires a SILENT exit (bucket reset, no door
    -- teleport) so the respawn lands them back in the normal world. Fires once.
    exitState.watch = true
    CreateThread(function()
        local fired = false
        while exitState.watch do
            local ped = PlayerPedId()
            if not fired and ped ~= 0 and (IsEntityDead(ped) or IsPedFatallyInjured(ped)) then
                fired = true
                if exitState.onExit then exitState.onExit(true) end
                break
            end
            Wait(300)
        end
    end)
end

-- Move into the shell: fade out, teleport, dress the room, arm the exit, fade in.
-- onExit fires the server exit event when the player leaves.
function Game.EnterInterior(d, onExit)
    if type(d) ~= 'table' or not d.x then return end
    local fade = (Config.Interior and Config.Interior.FadeMs) or 500
    DoScreenFadeOut(fade); Wait(fade)
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, d.x + 0.0, d.y + 0.0, d.z + 0.0, false, false, false)
    SetEntityHeading(ped, d.h or 0.0)
    -- Give the shell interior a moment to stream in around the new position.
    local iid = GetInteriorAtCoords(d.x + 0.0, d.y + 0.0, d.z + 0.0)
    if iid ~= 0 then
        RefreshInterior(iid)
        local waited = 0
        while not IsInteriorReady(iid) and waited < 2000 do Wait(50); waited = waited + 50 end
    end
    spawnLayout(resolveLayout(d.layout), { x = d.x, y = d.y, z = d.z, h = d.h or 0.0 })
    setUpExit({ x = d.x, y = d.y, z = d.z }, onExit)
    Wait(150)
    DoScreenFadeIn(fade)
end

-- Move back out: fade, tear down the exit, clear props, teleport to the captured
-- return coords, fade in.
function Game.ExitInterior(d)
    local fade = (Config.Interior and Config.Interior.FadeMs) or 500
    DoScreenFadeOut(fade); Wait(fade)
    tearDownExit()
    clearInteriorProps()
    if type(d) == 'table' and d.x then
        local ped = PlayerPedId()
        SetEntityCoordsNoOffset(ped, d.x + 0.0, d.y + 0.0, d.z + 0.0, false, false, false)
    end
    Wait(100)
    DoScreenFadeIn(fade)
end

-- Hard reset used when the resource stops with the player still inside (server
-- sends a nil-payload exit): tear down the exit + props and make sure the screen
-- is not stuck black. Teleport is skipped — the server already reset the bucket,
-- so the player simply reappears in the world at their current coords.
function Game.ForceExitInterior()
    tearDownExit()
    clearInteriorProps()
    DoScreenFadeIn(0)
end
