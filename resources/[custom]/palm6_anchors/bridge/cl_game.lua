-- ============================================================================
-- palm6_anchors/bridge/cl_game.lua
--
-- Game adapter (client). The ONLY file in this resource that calls a GTA native
-- or touches ox_lib. client/main.lua calls Game.* and nothing else, so this
-- ports to GTA VI by rewriting THIS file.
--
-- Nothing in here decides where an anchor is. The registry says where they were
-- and the server says which of them have been corrected; this file draws that
-- answer and moves the local ped when the server tells it to.
-- ============================================================================

Game = {}

-- ---------------------------------------------------------------------------
-- WHERE THE LOCAL PLAYER IS.
--
-- Used ONLY for distance culling and for sorting the menu. It is never sent to
-- the server as a capture: a captured anchor is read server-side off the ped
-- (Bridge.GetCoords), because a client-supplied coordinate written into a config
-- file is an invented coordinate with extra steps.
-- ---------------------------------------------------------------------------
function Game.PlayerCoords()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

function Game.Distance(a, bx, by, bz)
    if not a then return nil end
    return #(a - vector3(bx + 0.0, by + 0.0, bz + 0.0))
end

function Game.Wait(ms)
    Wait(ms)
end

function Game.Now()
    return GetGameTimer()
end

-- ---------------------------------------------------------------------------
-- THE MARKER. One chevron per registered anchor within the radius.
--
-- This is the whole point of the live view: "why does nothing happen when I
-- press E here" is answered on sight, because the chevron is thirty metres away
-- or on the other side of a wall.
--
-- DrawMarker and the 3D text both run on the calling thread's frame, so this
-- function does the drawing and client/main.lua owns the loop and the culling.
-- ---------------------------------------------------------------------------
function Game.DrawAnchorMarker(x, y, z, colour)
    local c = colour or { 255, 255, 255, 140 }
    local s = Config.Markers.Scale
    DrawMarker(
        Config.Markers.Type,
        x + 0.0, y + 0.0, z + Config.Markers.ZOffset,
        0.0, 0.0, 0.0,      -- direction
        0.0, 0.0, 0.0,      -- rotation
        s, s, s,
        c[1], c[2], c[3], c[4],
        true,   -- bobUpAndDown: makes it findable in clutter
        true,   -- faceCamera
        2, false, nil, nil, false)
end

-- The anchor KEY, floating over the marker. The key and not the label, because
-- the key is what the config-line print and the capture table use, so what is
-- on screen is what you will paste and what you will search for.
--
-- SetDrawOrigin + 2D text is the cheap way to draw world-space text; the
-- alternative (World3dToScreen2d) costs a native call per anchor per frame.
function Game.DrawAnchorText(x, y, z, text)
    SetDrawOrigin(x + 0.0, y + 0.0, z + Config.Markers.ZOffset + 0.35, 0)
    SetTextFont(4)
    SetTextScale(0.30, 0.30)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ---------------------------------------------------------------------------
-- TELEPORT. Copied in shape from server_base/bridge/cl_game.lua Game.Teleport,
-- which is the placement tool this repo already uses for verifying "VERIFY
-- IN-GAME" anchors: freeze, move, wait for collision, settle onto the ground,
-- unfreeze.
--
-- The destination ALWAYS comes from the server, which looked the key up in the
-- registry. This function never chooses a coordinate.
-- ---------------------------------------------------------------------------
function Game.Teleport(x, y, z)
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return false end
    FreezeEntityPosition(ped, true)
    SetEntityCoords(ped, x + 0.0, y + 0.0, z + 0.0, false, false, false, false)
    local tries = 0
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    while not HasCollisionLoadedAroundEntity(ped) and tries < 250 do
        RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
        Wait(10)
        tries = tries + 1
    end
    -- Settle onto the ground if a valid Z is found near the requested height.
    -- If none is found the ped stays at the requested Z: an anchor that is
    -- underground or in the air is EXACTLY the fault this tool is looking for,
    -- so it must not be quietly corrected on arrival.
    local found, groundZ = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 0.0, false)
    if found then
        SetEntityCoords(ped, x + 0.0, y + 0.0, groundZ + 0.0, false, false, false, false)
    end
    FreezeEntityPosition(ped, false)
    return true, found == true
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

-- Is an ox_lib context menu actually available on this client? Checked before
-- every open, because "the menu did not appear" has to be reportable.
function Game.MenuAvailable()
    return lib ~= nil and lib.registerContext ~= nil and lib.showContext ~= nil
end

-- ox_lib context menu. Same call pair palm6_uniform and palm6_fc_arena use;
-- `parentId` gives a submenu ox_lib's own back arrow.
function Game.OpenMenu(id, title, options, parentId)
    lib.registerContext({ id = id, title = title, menu = parentId, options = options })
    lib.showContext(id)
end

-- FALLS BACK TO CHAT rather than going quiet, for the same reason
-- palm6_uniform's Game.Notify does: the notify corner is where the person who
-- just clicked is looking, and losing that line makes a working action read as
-- nothing having happened.
function Game.Notify(msg, t)
    if lib and lib.notify then
        lib.notify({ title = 'Anchors', description = msg, type = t or 'inform' })
        return
    end
    Game.Chat(msg)
end

function Game.Chat(line)
    TriggerEvent('chat:addMessage', { color = { 255, 180, 60 }, args = { 'Anchors', line } })
end

-- ---------------------------------------------------------------------------
-- Ask the server for the anchor list, sorted and annotated.
--
-- TIMED OUT rather than awaited bare. pcall catches a throw; it cannot catch a
-- call that never returns. If the server-side callback was never registered
-- (Bridge.RegisterCallback prints a red line and gives up when ox_lib is
-- missing there), lib.callback.await blocks FOREVER and the admin gets no menu,
-- no notify and no chat line. That is the silent no-op this resource exists to
-- kill, so the await runs on its own thread and this one gives up and returns
-- nil, which the caller must render as a visible error.
-- ---------------------------------------------------------------------------
local function awaitCallback(name, ...)
    if not (lib and lib.callback) then return nil end
    local args = { ... }
    local done, res = false, nil
    CreateThread(function()
        local ok, r = pcall(function()
            return lib.callback.await(name, false, table.unpack(args))
        end)
        res  = ok and r or nil
        done = true
    end)
    local waited = 0
    while not done and waited < 5000 do
        Wait(50)
        waited = waited + 50
    end
    -- A late answer is discarded on purpose: by now the caller has already told
    -- the admin it failed, and drawing a menu on top of that is worse than not.
    if not done then return nil end
    return res
end

-- Are ox_lib callbacks usable on this client at all? Checked before a fetch so
-- "no callbacks" and "the server did not answer" are different messages: the
-- first one has a working fallback to name (/anchorlist), the second does not.
function Game.CallbacksAvailable()
    return lib ~= nil and lib.callback ~= nil
end

-- The whole list, sorted server-side by distance from the position passed in.
function Game.FetchMenu(px, py, pz)
    return awaitCallback('palm6_anchors:menu', px, py, pz)
end

-- One anchor's detail. Fetched separately so the row list does not have to
-- carry every anchor's full detail on every open.
function Game.FetchAnchorMenu(key)
    return awaitCallback('palm6_anchors:anchorMenu', key)
end

-- Fires on a join AND on every respawn after death. Used only to re-ask the
-- server for the anchor list, because a client that joined before the server
-- had anything to push would otherwise never hear about it. AddEventHandler
-- rather than RegisterNetEvent: 'playerSpawned' is raised locally by the spawn
-- manager, and making it network-addressable would widen its reach for every
-- listener on this client.
function Game.OnPlayerSpawned(cb)
    AddEventHandler('playerSpawned', cb)
end

-- Register a chat command plus its rebindable keybind. Both routes fire the
-- same handler. The keybind is a convenience; clearing it in the pause menu
-- leaves the command working, which is why the command is not optional.
function Game.RegisterCommandAndKey(name, description, key, handler)
    RegisterCommand(name, handler, false)
    if key and key ~= '' then
        RegisterKeyMapping(name, description, 'keyboard', key)
    end
end
