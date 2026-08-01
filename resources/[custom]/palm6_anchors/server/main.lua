-- ============================================================================
-- palm6_anchors/server/main.lua
--
-- Pure logic plus this resource's own SQL. Every framework, ACE and native read
-- goes through Bridge.* (bridge/sv_framework.lua).
--
-- ----------------------------------------------------------------------------
-- WHAT THIS RESOURCE IS, STATED ONCE SO IT IS NOT RE-DERIVED FROM THE CODE
-- ----------------------------------------------------------------------------
-- It READS the anchor registry and it RECORDS what an admin captures. That is
-- all. It does not rewrite any other resource's config, and no other resource
-- reads its overrides today. A capture produces two things: a row in
-- palm6_anchor_overrides, and a printed config line for a human to paste into
-- the owning config file. The paste is what makes a correction real.
--
-- That restraint is the design, not an unfinished corner. A half-wired override
-- system, where this table silently disagreed with fifteen audited config
-- files, would be strictly worse than the placeholders it replaced: the feature
-- would move, the config would still say otherwise, and the next person to read
-- the config would be misled by a file that used to be true.
--
-- ----------------------------------------------------------------------------
-- THE AUTHORITY MODEL
-- ----------------------------------------------------------------------------
-- The client can say exactly three things: "show me the list from where I am
-- standing", "take me to anchor <key>", and "anchor <key> belongs where I am
-- standing". It cannot say WHERE it is standing. Every position this file
-- writes is read off the player's ped on the server (Bridge.GetCoords), and
-- every destination it sends comes out of the registry. There is no net event
-- here that accepts a coordinate, and there must never be one: a client-sent
-- number pasted into a config file is an invented coordinate with extra steps.
-- ============================================================================

local lastAction = {}    -- [src] = { [key] = unix ts }
local overrides  = {}    -- [anchor_key] = { x, y, z, heading, by, byName, at }
local byKey      = {}    -- [anchor_key] = registry row
local schemaOk   = false

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_anchors] ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- REGISTRY INDEX. Built once at load, and it VALIDATES as it goes.
--
-- A duplicate key would mean one anchor silently shadowing another in the
-- capture table, and a malformed row would mean a marker at 0,0,0. Both are
-- reported loudly at boot rather than discovered in game, because "the marker
-- is in the ocean" is exactly the class of mystery this resource exists to end.
-- ---------------------------------------------------------------------------
local registryProblems = {}

local function indexRegistry()
    byKey = {}
    registryProblems = {}
    for i = 1, #Anchors do
        local a = Anchors[i]
        local where = ('Anchors[%d]'):format(i)
        if type(a) ~= 'table' or type(a.key) ~= 'string' or a.key == '' then
            registryProblems[#registryProblems + 1] = where .. ' has no key'
        elseif byKey[a.key] then
            registryProblems[#registryProblems + 1] = ('%s duplicates key "%s"'):format(where, a.key)
        elseif type(a.ref) ~= 'table'
            or tonumber(a.ref.x) == nil or tonumber(a.ref.y) == nil or tonumber(a.ref.z) == nil then
            registryProblems[#registryProblems + 1] = ('%s ("%s") has no numeric ref x/y/z'):format(where, a.key)
        else
            byKey[a.key] = a
        end
    end
end

indexRegistry()

-- ---------------------------------------------------------------------------
-- RATE LIMITING. Per source, per key.
--
-- Returns allowed, secondsLeft. Callers use rlGate rather than this directly,
-- because a rate limit that refuses in silence is worse than no rate limit at
-- all: the command looks broken and gets reported as a bug.
-- ---------------------------------------------------------------------------
local function rl(src, key)
    if src == 0 then return true, 0 end
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    local ready = (lastAction[src][key] or 0) + window
    if ready > t then return false, ready - t end
    lastAction[src][key] = t
    return true, 0
end

local function rlGate(src, key, what)
    local ok, left = rl(src, key)
    if ok then return true end
    Bridge.Reply(src, {
        ('Too fast: %s is rate limited to one call every %d second(s). Try again in %d.')
            :format(what, Config.RateLimits[key] or 1, math.max(1, math.ceil(left or 1))),
    })
    return false
end

AddEventHandler('playerDropped', function()
    local src = source
    lastAction[src] = nil
end)

-- ---------------------------------------------------------------------------
-- SCHEMA
--
-- Self-creating at boot, with the identical DDL in sql/0077_anchors.sql. The
-- number came from the "next free migration number" line printed by
-- `node tools/audit/run.js`, not from `ls sql/`: palm6_dbmigrate owns 0067 and
-- 0068-0073 with no sql/ file at all, so the directory listing lies about what
-- is free.
--
-- ONE ROW PER ANCHOR KEY. A re-capture of the same anchor REPLACES the previous
-- row rather than appending: this table is "where should this anchor be", not a
-- history of where somebody once stood. The console line and the chat line
-- printed on every capture are the history.
-- ---------------------------------------------------------------------------
local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS `palm6_anchor_overrides` (
    anchor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL DEFAULT 0,
    captured_by VARCHAR(64) DEFAULT NULL,
    captured_name VARCHAR(64) DEFAULT NULL,
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
]]

local function ensureSchema()
    local ok, err = pcall(function() MySQL.query.await(SCHEMA_SQL) end)
    if not ok then
        schemaOk = false
        print(('^1[palm6_anchors] schema init FAILED -> %s^0'):format(tostring(err)))
        return
    end
    schemaOk = true
end

local function loadOverrides()
    if not schemaOk then return end
    local rows
    local ok, err = pcall(function()
        rows = MySQL.query.await('SELECT * FROM palm6_anchor_overrides')
    end)
    if not ok then
        print(('^1[palm6_anchors] override load FAILED -> %s^0'):format(tostring(err)))
        return
    end
    local out = {}
    local orphans = {}
    for _, r in ipairs(rows or {}) do
        local key = r.anchor_key
        if type(key) == 'string' then
            out[key] = {
                x = tonumber(r.x) or 0.0,
                y = tonumber(r.y) or 0.0,
                z = tonumber(r.z) or 0.0,
                heading = tonumber(r.heading) or 0.0,
                by = r.captured_by,
                byName = r.captured_name,
                at = r.captured_at,
            }
            if not byKey[key] then orphans[#orphans + 1] = key end
        end
    end
    overrides = out
    -- ORPHANS ARE REPORTED, NOT DELETED. A row whose key is no longer in the
    -- registry usually means somebody renamed a key, and the captured position
    -- is the expensive half of that pair: it took a person walking to the right
    -- spot. Deleting it to tidy up would throw away the only thing here that
    -- cannot be regenerated.
    if #orphans > 0 then
        print(('^3[palm6_anchors] %d captured override(s) have no matching registry key and are being kept, not shown: %s^0')
            :format(#orphans, table.concat(orphans, ', ')))
    end
end

-- ---------------------------------------------------------------------------
-- THE CONFIG LINE. The output that makes a capture permanent.
--
-- Printed in the SAME FORM the owning config uses, so it is paste-ready:
--   vector3  ->  Config.LockerCoords = vector3(434.00, -983.00, 30.70)
--   vector4  ->  Config.PawnshopCoords = vector4(x, y, z, heading)
--   table    ->  Config.Board.coords = { x = 434.60, y = -981.30, z = 30.71 }
--
-- A vector3 line pasted where the file uses a plain table would break that
-- config on the next restart, which is a worse outcome than the misplaced
-- anchor it was meant to fix.
-- ---------------------------------------------------------------------------
local function fmt(n)
    return ('%.' .. tostring(Config.CoordDecimals) .. 'f'):format(tonumber(n) or 0.0)
end

local function valueLiteral(anchor, c)
    if anchor.form == 'vector4' then
        return ('vector4(%s, %s, %s, %s)'):format(fmt(c.x), fmt(c.y), fmt(c.z), fmt(c.heading or c.h or 0.0))
    elseif anchor.form == 'table' then
        return ('{ x = %s, y = %s, z = %s }'):format(fmt(c.x), fmt(c.y), fmt(c.z))
    end
    return ('vector3(%s, %s, %s)'):format(fmt(c.x), fmt(c.y), fmt(c.z))
end

local function configLine(anchor, c)
    return ('%s/%s  %s = %s'):format(anchor.resource, anchor.file, anchor.path, valueLiteral(anchor, c))
end

-- The point an anchor is CURRENTLY shown at: the captured override if there is
-- one, otherwise the reference reading transcribed from the config.
--
-- Returns coords, sourceWord where sourceWord is 'capture' or 'config'.
local function anchorPoint(anchor)
    local o = overrides[anchor.key]
    if o then
        return { x = o.x, y = o.y, z = o.z, heading = o.heading }, 'capture'
    end
    return { x = anchor.ref.x, y = anchor.ref.y, z = anchor.ref.z, heading = anchor.ref.h or 0.0 }, 'config'
end

-- ---------------------------------------------------------------------------
-- THE PAYLOAD THE CLIENT DRAWS MARKERS FROM.
--
-- Built server-side and pushed, so the client never has to decide which point
-- to draw. Sent on request and again after any capture, so a corrected anchor
-- moves on screen without the admin having to reopen anything.
-- ---------------------------------------------------------------------------
local function markerPayload()
    local out = {}
    for i = 1, #Anchors do
        local a = Anchors[i]
        if byKey[a.key] then
            local pt, from = anchorPoint(a)
            out[#out + 1] = {
                key = a.key,
                x = pt.x, y = pt.y, z = pt.z,
                captured = (from == 'capture'),
            }
        end
    end
    return out
end

local function pushMarkers(target)
    TriggerClientEvent('palm6_anchors:points', target or -1, markerPayload())
end

-- ---------------------------------------------------------------------------
-- BOOT
-- ---------------------------------------------------------------------------
CreateThread(function()
    ensureSchema()
    loadOverrides()

    for i = 1, #registryProblems do
        print(('^1[palm6_anchors] registry problem: %s^0'):format(registryProblems[i]))
    end

    local n = 0
    for _ in pairs(byKey) do n = n + 1 end
    print(('[palm6_anchors] %d anchor(s) registered, %d with a captured correction, schema=%s')
        :format(n, (function() local c = 0 for _ in pairs(overrides) do c = c + 1 end return c end)(),
                schemaOk and 'ok' or 'MISSING'))

    -- THE ACE CHECK THE HEADLESS AUDIT CANNOT DO.
    --
    -- Every command in this resource is registered unrestricted and checks the
    -- ACE inside the handler, which is the shape custom.cfg already uses for
    -- /placeped, /bizshell and the /uniform* family. The audit's command-aces
    -- check only reconciles RESTRICTED commands against grants, so a missing
    -- add_ace line passes every static gate and then locks every admin out in
    -- game with no clue why. This prints the exact missing line.
    for _, principal in ipairs(Config.ExpectedAcePrincipals or {}) do
        if not Bridge.PrincipalHasAce(principal, Config.AdminAce) then
            print(('^1[palm6_anchors] %s does not hold "%s". custom.cfg needs: add_ace %s %s allow^0')
                :format(principal, Config.AdminAce, principal, Config.AdminAce))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- THE MENU MODEL. Every row the client will draw is decided here.
--
-- Row shape: { action, arg, title, description, icon, disabled }
--   action  what to send back on select. 'note' rows are never selectable.
--
-- THE RULE THIS SECTION IS WRITTEN TO, borrowed from palm6_uniform because it
-- was learned the same expensive way: the menu is never blank and a click is
-- never silent. An empty list and a broken tool look identical from where the
-- admin is standing.
-- ---------------------------------------------------------------------------
local function buildMenu(src, px, py, pz)
    local rows = {}
    local function row(t) rows[#rows + 1] = t end
    local menu = { title = 'World anchors', rows = rows }

    if not Config.Enabled then
        row{
            action = 'note', disabled = true, icon = 'fas fa-power-off',
            title = 'The anchor inspector is switched off.',
            description = 'shared/config.lua has Config.Enabled = false. This is a tool that has been told to do nothing, not a broken one.',
        }
        return menu
    end

    if not Bridge.IsAdmin(src) then
        row{
            action = 'note', disabled = true, icon = 'fas fa-ban',
            title = 'You do not have permission to inspect anchors.',
            description = ('This tool needs the "%s" ACE. If nobody has it, custom.cfg is missing: add_ace group.admin %s allow')
                :format(Config.AdminAce, Config.AdminAce),
        }
        return menu
    end

    -- The read limit, refused as a ROW rather than by refusing to open. A menu
    -- that does not appear is the failure this whole resource exists to remove.
    if not rl(src, 'menu') then
        row{
            action = 'note', disabled = true, icon = 'fas fa-hourglass-half',
            title = 'Opening too fast.',
            description = ('This list answers once every %d second(s). Close it and open it again in a moment; nothing is broken.')
                :format(Config.RateLimits.menu or 1),
        }
        return menu
    end

    -- The player's position arrives from the client and is used ONLY to sort
    -- and label distances. It is never stored and never written into a config
    -- line. Every capture reads the position server-side instead.
    local hasPos = tonumber(px) ~= nil and tonumber(py) ~= nil and tonumber(pz) ~= nil
    px, py, pz = tonumber(px) or 0.0, tonumber(py) or 0.0, tonumber(pz) or 0.0

    local list = {}
    for i = 1, #Anchors do
        local a = Anchors[i]
        if byKey[a.key] then
            local pt, from = anchorPoint(a)
            local dx, dy, dz = pt.x - px, pt.y - py, pt.z - pz
            list[#list + 1] = {
                a = a, pt = pt, from = from,
                dist = hasPos and math.sqrt(dx * dx + dy * dy + dz * dz) or nil,
            }
        end
    end

    -- Sorted by distance. Ties and the no-position case fall back to the key so
    -- the order is stable between opens rather than whatever pairs() felt like.
    table.sort(list, function(l, r)
        if l.dist and r.dist and l.dist ~= r.dist then return l.dist < r.dist end
        return l.a.key < r.a.key
    end)

    local capturedCount = 0
    for _ in pairs(overrides) do capturedCount = capturedCount + 1 end

    row{
        action = 'note', disabled = true, icon = 'fas fa-circle-info',
        title = ('%d anchors registered, %d corrected, sorted by distance from you.'):format(#list, capturedCount),
        description = hasPos
            and 'This tool RECORDS corrections and prints the config line to paste. It does NOT rewrite any other resource\'s config, and no resource reads these corrections yet. The paste is what makes a fix real.'
            or  'Your position did not arrive, so this list is in key order rather than distance order. Distances are not shown.',
    }

    if #list == 0 then
        row{
            action = 'note', disabled = true, icon = 'fas fa-triangle-exclamation',
            title = 'The registry is empty.',
            description = 'That is a fault in palm6_anchors/shared/registry.lua, not an empty world. Check the server console for "registry problem" lines.',
        }
        return menu
    end

    local shown = math.min(#list, Config.MenuRows)
    for i = 1, shown do
        local e = list[i]
        local a = e.a
        local bits = { a.resource }
        if e.dist then bits[#bits + 1] = ('%.1fm away'):format(e.dist) end
        bits[#bits + 1] = (e.from == 'capture') and 'CORRECTED (capture on file)' or 'config value'
        if a.kind == 'zone' then bits[#bits + 1] = 'zone centre, not a walk-up point' end
        row{
            action = 'anchor', arg = a.key,
            icon = (e.from == 'capture') and 'fas fa-location-dot' or 'fas fa-location-crosshairs',
            title = a.label,
            description = table.concat(bits, '  |  '),
        }
    end

    if #list > shown then
        row{
            action = 'note', disabled = true, icon = 'fas fa-ellipsis',
            title = ('%d further anchors are not shown.'):format(#list - shown),
            description = ('This menu shows the nearest %d (Config.MenuRows). The rest are further away; walk towards them, or use /anchorlist for the whole list in chat.')
                :format(Config.MenuRows),
        }
    end

    return menu
end

-- One anchor's own submenu: what you can do with it.
local function buildAnchorMenu(src, key)
    local a = byKey[key]
    local rows = {}
    local function row(t) rows[#rows + 1] = t end
    local menu = { title = 'Anchor', rows = rows, key = key }

    if not a then
        row{
            action = 'note', disabled = true, icon = 'fas fa-triangle-exclamation',
            title = ('No anchor is registered under the key "%s".'):format(tostring(key)),
            description = 'Reopen the list; it may have been renamed in shared/registry.lua since this menu was drawn.',
        }
        return menu
    end

    menu.title = a.label

    local pt, from = anchorPoint(a)
    local o = overrides[key]

    row{
        action = 'note', disabled = true, icon = 'fas fa-circle-info',
        title = ('%s  (%s)'):format(a.key, a.kind),
        description = ('Owned by %s. The number lives at %s/%s  %s. Currently reading %s, %s, %s (%s).')
            :format(a.resource, a.resource, a.file, a.path, fmt(pt.x), fmt(pt.y), fmt(pt.z),
                    from == 'capture' and 'a capture on file' or 'the config value'),
    }

    if o then
        row{
            action = 'note', disabled = true, icon = 'fas fa-clipboard',
            title = 'Paste this into the config to make it permanent:',
            description = configLine(a, o),
        }
        row{
            action = 'note', disabled = true, icon = 'fas fa-user-clock',
            title = 'Captured by ' .. tostring(o.byName or o.by or 'unknown'),
            description = ('at %s. Until somebody pastes the line above into %s/%s, the owning resource is still using its own config value.')
                :format(tostring(o.at), a.resource, a.file),
        }
    else
        row{
            action = 'note', disabled = true, icon = 'fas fa-file-lines',
            title = 'No capture on file. This is the config value, transcribed.',
            description = ('shared/registry.lua copied it verbatim from %s/%s. If the marker is in the wrong room, that config line is the thing that is wrong.')
                :format(a.resource, a.file),
        }
    end

    if Config.TeleportEnabled then
        row{
            action = 'teleport', arg = a.key, icon = 'fas fa-person-walking-arrow-right',
            title = 'Teleport to it',
            description = 'Puts you exactly where this anchor is. If you land in a wall, on a roof or in the sea, you have found the fault.',
        }
    end

    row{
        action = 'capture', arg = a.key, icon = 'fas fa-location-crosshairs',
        title = 'This anchor belongs where I am standing',
        description = a.kind == 'zone'
            and 'Records your position as the centre of this zone. A zone has a radius around it, so moving the centre moves the whole area; the radius is not touched and stays in the config.'
            or  'Records your position against this anchor and prints the exact config line to paste. Your position is read on the SERVER off your ped, never sent by your game.',
    }

    if o then
        row{
            action = 'clear', arg = a.key, icon = 'fas fa-rotate-left',
            title = 'Forget the capture and go back to the config value',
            description = 'Deletes the recorded correction. The owning config is not touched by this, because it was never touched in the first place.',
        }
    end

    return menu
end

Bridge.RegisterCallback('palm6_anchors:menu', function(src, px, py, pz)
    if not src or src <= 0 then return nil end
    return buildMenu(src, px, py, pz)
end)

Bridge.RegisterCallback('palm6_anchors:anchorMenu', function(src, key)
    if not src or src <= 0 then return nil end
    if not Bridge.IsAdmin(src) then return nil end
    if type(key) ~= 'string' then return nil end
    return buildAnchorMenu(src, key)
end)

-- ---------------------------------------------------------------------------
-- CAPTURE. The one write path in this resource.
--
-- The position is read here, server-side, off the ped. Nothing about it comes
-- from the client, which is why this function takes no coordinates.
-- ---------------------------------------------------------------------------
local function captureAnchor(src, key)
    if not rlGate(src, 'capture', 'capturing an anchor position') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, ('Capturing an anchor needs the "%s" permission and you do not have it.'):format(Config.AdminAce), 'error')
        return
    end
    if src == 0 then
        Bridge.Reply(src, { 'This records where you are standing, so it cannot be run from the console.' })
        return
    end
    local a = byKey[key]
    if not a then
        Bridge.Notify(src, ('No anchor is registered under the key "%s", so nothing was recorded.'):format(tostring(key)), 'error')
        return
    end
    if not schemaOk then
        Bridge.Notify(src, 'The palm6_anchor_overrides table is not available, so nothing can be recorded. There is a red schema error in the server console.', 'error')
        return
    end

    local c = Bridge.GetCoords(src)
    if not c then
        Bridge.Notify(src, 'The server could not read where you are standing, so nothing was recorded.', 'error')
        return
    end

    local cid  = Bridge.GetCitizenId(src)
    local name = Bridge.GetDisplayName(src)

    local okWrite, errWrite = pcall(function()
        MySQL.query.await([[
INSERT INTO palm6_anchor_overrides
    (anchor_key, x, y, z, heading, captured_by, captured_name, captured_at)
VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
ON DUPLICATE KEY UPDATE
    x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading),
    captured_by = VALUES(captured_by), captured_name = VALUES(captured_name),
    captured_at = NOW()
        ]], { a.key, c.x, c.y, c.z, c.h, cid, name })
    end)
    if not okWrite then
        print(('^1[palm6_anchors] capture write FAILED -> %s^0'):format(tostring(errWrite)))
        Bridge.Notify(src, 'The capture could not be saved. Check the server console.', 'error')
        return
    end

    overrides[a.key] = {
        x = c.x, y = c.y, z = c.z, heading = c.h,
        by = cid, byName = name, at = os.date('%Y-%m-%d %H:%M:%S'),
    }

    local line = configLine(a, overrides[a.key])

    -- Push to EVERYONE, not just the capturer. Markers are admin-only anyway
    -- (a client with them off ignores this), and two admins walking the same
    -- station both need to see the corrected position immediately.
    pushMarkers(-1)

    -- Said three times on purpose, in three channels, because each one is the
    -- only one somebody is looking at: the notify corner for the person who
    -- clicked, chat for the line they need to copy, and the server console for
    -- the record that survives the session.
    Bridge.Notify(src, ('Recorded "%s" where you are standing. The config line to paste is in your chat.'):format(a.label), 'success')
    Bridge.Reply(src, {
        ('Captured %s at %s, %s, %s.'):format(a.key, fmt(c.x), fmt(c.y), fmt(c.z)),
        'PASTE THIS INTO THE CONFIG TO MAKE IT PERMANENT:',
        '  ' .. line,
        'Nothing else changed. palm6_anchors does not edit other resources and no resource reads this capture yet.',
    })
    print(('[palm6_anchors] capture %s by %s -> %s'):format(a.key, name, line))
end

local function clearAnchor(src, key)
    if not rlGate(src, 'capture', 'clearing an anchor capture') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, ('Clearing a capture needs the "%s" permission.'):format(Config.AdminAce), 'error')
        return
    end
    local a = byKey[key]
    if not a then
        Bridge.Notify(src, ('No anchor is registered under the key "%s".'):format(tostring(key)), 'error')
        return
    end
    if not overrides[key] then
        Bridge.Notify(src, ('"%s" has no capture on file, so there was nothing to clear.'):format(a.label), 'inform')
        return
    end
    if not schemaOk then
        Bridge.Notify(src, 'The palm6_anchor_overrides table is not available.', 'error')
        return
    end
    local ok, err = pcall(function()
        MySQL.update.await('DELETE FROM palm6_anchor_overrides WHERE anchor_key = ?', { key })
    end)
    if not ok then
        print(('^1[palm6_anchors] clear FAILED -> %s^0'):format(tostring(err)))
        Bridge.Notify(src, 'The capture could not be cleared. Check the server console.', 'error')
        return
    end
    overrides[key] = nil
    pushMarkers(-1)
    Bridge.Notify(src, ('Cleared the capture for "%s". Its marker is back on the config value.'):format(a.label), 'success')
    print(('[palm6_anchors] capture cleared for %s by %s'):format(key, Bridge.GetDisplayName(src)))
end

local function teleportTo(src, key)
    if not Config.TeleportEnabled then
        Bridge.Notify(src, 'Teleporting is switched off (Config.TeleportEnabled = false).', 'error')
        return
    end
    if not rlGate(src, 'teleport', 'teleporting to an anchor') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, ('Teleporting needs the "%s" permission.'):format(Config.AdminAce), 'error')
        return
    end
    if src == 0 then
        Bridge.Reply(src, { 'The console has no ped to move.' })
        return
    end
    local a = byKey[key]
    if not a then
        Bridge.Notify(src, ('No anchor is registered under the key "%s".'):format(tostring(key)), 'error')
        return
    end
    local pt = anchorPoint(a)
    -- The DESTINATION comes from the registry, on the server. The client asked
    -- for a key, not for a position.
    TriggerClientEvent('palm6_anchors:teleport', src, pt.x, pt.y, pt.z, a.label)
end

-- ---------------------------------------------------------------------------
-- NET EVENTS. Three, all rate limited, all re-deriving the ACE.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_anchors:menuAction', function(action, arg1)
    local src = source
    if not src or src <= 0 then return end
    if type(action) ~= 'string' then return end
    if type(arg1) ~= 'string' and arg1 ~= nil then return end

    -- ACE FIRST, and SILENTLY, before any branch that can emit a notify.
    --
    -- Each action branch below re-derives the ACE, which is right, but two
    -- early-outs used to answer before ever reaching them: the Config.Enabled
    -- refusal and the unknown-action else. Both called Bridge.Notify with no ACE
    -- check and no rate limit, so any player could spam this event with a junk
    -- string and make the server emit one outbound ox_lib:notify per inbound
    -- event, unbounded. Nobody without the ACE has a menu to click, so there is
    -- no legitimate caller to explain a refusal to: silence is correct here, and
    -- an admin who somehow lands here still gets the real answer below.
    if not Bridge.IsAdmin(src) then return end

    -- Then the rate limit, so even an admin cannot loop a modified client into
    -- an unbounded notify stream. This is the gate the README already claimed
    -- covered every net event.
    if not rlGate(src, 'menuAction', 'the anchor menu') then return end

    if not Config.Enabled then
        Bridge.Notify(src, 'palm6_anchors is switched off (Config.Enabled = false), so that did nothing.', 'error')
        return
    end

    if action == 'capture' then
        captureAnchor(src, arg1)
    elseif action == 'clear' then
        clearAnchor(src, arg1)
    elseif action == 'teleport' then
        teleportTo(src, arg1)
    else
        Bridge.Notify(src, ('The anchor menu sent an action this server does not know ("%s"). Nothing was changed.'):format(action), 'error')
    end
end)

-- The client asking for the marker list. Raised on spawn, on resource start and
-- whenever an admin turns markers on. Rate limited but SILENT on refusal:
-- nobody typed it, so nobody is waiting on an answer, and replying would let a
-- modified client spam its own screen. The client re-asks on the next spawn.
RegisterNetEvent('palm6_anchors:requestPoints', function()
    local src = source
    if not Config.Enabled then return end
    if not src or src <= 0 then return end
    if not rl(src, 'command') then return end
    -- Only admins get the list. A non-admin has nothing to draw and no reason
    -- to hold a copy of every anchor in the server.
    if not Bridge.IsAdmin(src) then return end
    pushMarkers(src)
end)

-- The client asking to toggle its own markers. The ACE is checked HERE, not on
-- the client, and the answer is what turns the loop on.
RegisterNetEvent('palm6_anchors:toggleMarkers', function(wantOn)
    local src = source
    if not Config.Enabled then return end
    if not src or src <= 0 then return end
    if not rlGate(src, 'toggle', 'toggling anchor markers') then return end
    if not Bridge.IsAdmin(src) then
        Bridge.Notify(src, ('Anchor markers need the "%s" permission. custom.cfg needs: add_ace group.admin %s allow')
            :format(Config.AdminAce, Config.AdminAce), 'error')
        return
    end
    local on = wantOn == true
    if on then pushMarkers(src) end
    TriggerClientEvent('palm6_anchors:markerState', src, on)
end)

-- ---------------------------------------------------------------------------
-- COMMANDS. The fallback for when ox_lib is not there, and the console route.
--
-- These are SERVER commands with names distinct from the two CLIENT commands
-- (/anchors and /anchormarkers, registered in client/main.lua). Registering the
-- same name in both realms would run both handlers off one keypress.
-- ---------------------------------------------------------------------------
local function adminGate(src, key, what)
    if not Config.Enabled then
        Bridge.Reply(src, { 'palm6_anchors is disabled (Config.Enabled = false).' })
        return false
    end
    if not rlGate(src, key or 'command', what or 'this command') then return false end
    if not Bridge.IsAdmin(src) then
        Bridge.Reply(src, {
            ('You do not have permission to do that. This command needs the "%s" ACE.'):format(Config.AdminAce),
            ('If nobody has it, custom.cfg is missing: add_ace group.admin %s allow'):format(Config.AdminAce),
        })
        return false
    end
    return true
end

-- /anchorlist [filter] - every registered anchor, in key order, with its
-- current reading and where that reading came from.
Bridge.RegisterCommand('anchorlist', function(src, args)
    if not adminGate(src, 'menu', '/anchorlist') then return end
    local filter = (args[1] or ''):lower()
    local keys = {}
    for k in pairs(byKey) do keys[#keys + 1] = k end
    table.sort(keys)

    local lines = {}
    for i = 1, #keys do
        local a = byKey[keys[i]]
        if filter == ''
           or a.key:lower():find(filter, 1, true)
           or a.resource:lower():find(filter, 1, true)
           or a.label:lower():find(filter, 1, true) then
            local pt, from = anchorPoint(a)
            lines[#lines + 1] = ('  %-32s %-24s %s, %s, %s  (%s)')
                :format(a.key, a.resource, fmt(pt.x), fmt(pt.y), fmt(pt.z), from)
        end
    end
    if #lines == 0 then
        Bridge.Reply(src, { ('No registered anchor matches "%s". /anchorlist with no argument lists all of them.'):format(filter) })
        return
    end
    table.insert(lines, 1, ('%d anchor(s)%s. "(config)" means the value transcribed from the owning config; "(capture)" means somebody stood somewhere and recorded it.')
        :format(#lines, filter ~= '' and (' matching "' .. filter .. '"') or ''))
    Bridge.Reply(src, lines)
end)

-- /anchorline <key> - print the paste-ready config line for one anchor.
Bridge.RegisterCommand('anchorline', function(src, args)
    if not adminGate(src, 'command', '/anchorline') then return end
    local key = args[1]
    local a = key and byKey[key]
    if not a then
        Bridge.Reply(src, { 'Usage: /anchorline <key>   (keys come from /anchorlist)' })
        return
    end
    local pt, from = anchorPoint(a)
    Bridge.Reply(src, {
        ('%s (%s)'):format(a.label, from == 'capture' and 'captured' or 'still the config value'),
        '  ' .. configLine(a, pt),
    })
end)

-- /anchorstatus - the meter.
Bridge.RegisterCommand('anchorstatus', function(src)
    if not adminGate(src, 'command', '/anchorstatus') then return end
    local registered, captured = 0, 0
    for _ in pairs(byKey) do registered = registered + 1 end
    for _ in pairs(overrides) do captured = captured + 1 end
    Bridge.Reply(src, {
        ('enabled=%s  schema=%s  registered=%d  captured=%d  registry problems=%d')
            :format(tostring(Config.Enabled), schemaOk and 'ok' or 'MISSING', registered, captured, #registryProblems),
        ('admin ACE "%s": you=%s, group.admin=%s')
            :format(Config.AdminAce, tostring(Bridge.IsAdmin(src)), tostring(Bridge.PrincipalHasAce('group.admin', Config.AdminAce))),
        'This resource RECORDS corrections and prints config lines. It does not edit other resources and nothing reads its overrides yet.',
    })
end)

-- ---------------------------------------------------------------------------
-- THE EXPORT. Shipped unused, on purpose.
--
-- GetAnchor(key) returns { x, y, z, heading } for a captured correction, or nil
-- when there is no capture on file. nil is the honest answer for "not
-- corrected": a caller must fall back to its OWN config, which is the value it
-- is already using today.
--
-- NOTHING CALLS THIS. That is the point. It is the migration path for a later
-- phase, when one resource at a time can opt in with a line like
--
--     local pt = GetResourceState('palm6_anchors') == 'started'
--         and (select(2, pcall(function() return exports.palm6_anchors:GetAnchor('evidence_locker') end)))
--         or nil
--     local coords = pt and vector3(pt.x, pt.y, pt.z) or Config.LockerCoords
--
-- and be tested on its own. Wiring fifteen audited configs to it in one go is
-- how a placement bug becomes a placement outage.
--
-- Returns a COPY. Handing out the live table would let any caller mutate this
-- resource's state through a getter.
-- ---------------------------------------------------------------------------
exports('GetAnchor', function(key)
    if type(key) ~= 'string' then return nil end
    local o = overrides[key]
    if not o then return nil end
    return { x = o.x, y = o.y, z = o.z, heading = o.heading }
end)

-- Read-only view of the registry, for a future tool or test that wants to know
-- what is registered without re-parsing the data file. Also returns copies.
exports('ListAnchors', function()
    local out = {}
    for i = 1, #Anchors do
        local a = Anchors[i]
        if byKey[a.key] then
            local pt, from = anchorPoint(a)
            out[#out + 1] = {
                key = a.key, label = a.label, resource = a.resource,
                file = a.file, path = a.path, form = a.form, kind = a.kind,
                x = pt.x, y = pt.y, z = pt.z, heading = pt.heading,
                source = from,
            }
        end
    end
    return out
end)
