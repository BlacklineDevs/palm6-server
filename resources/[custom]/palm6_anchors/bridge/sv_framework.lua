-- ============================================================================
-- palm6_anchors/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY server file in this resource that calls
-- qbx_core, an ACE native, or a server-side entity native. server/main.lua
-- calls Bridge.* and nothing else, so the whole tool ports by rewriting THIS
-- file. Same shape as palm6_uniform and palm6_pd_life.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Who captured an anchor, for the audit column. Returns a citizenid or nil.
-- Nil is a supported answer: a capture made from a source qbx_core does not
-- know about is still a real capture, and refusing to record it would be worse
-- than recording it unattributed.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    local pd = p and p.PlayerData
    return pd and pd.citizenid or nil
end

-- A display name for the capture log. Falls back to the source number rather
-- than to an empty string, so a console line always names somebody.
function Bridge.GetDisplayName(src)
    if src == 0 then return 'console' end
    local p = getPlayer(src)
    local ci = p and p.PlayerData and p.PlayerData.charinfo
    if ci and (ci.firstname or ci.lastname) then
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    local ok, name = pcall(function() return GetPlayerName(src) end)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return ('source %d'):format(src)
end

-- Does this source hold the admin ACE? Console (src 0) always does, matching
-- palm6_uniform and palm6_mapeditor. The console still cannot CAPTURE, because
-- it has no ped to read a position off; that refusal lives in server/main.lua.
function Bridge.IsAdmin(src)
    return src == 0 or IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Does a PRINCIPAL (a group, not a connected player) hold an ACE? Used once at
-- boot to answer the question the headless audit structurally cannot: every
-- command here is registered unrestricted, so a missing
-- `add_ace group.admin command.anchors allow` passes every static gate and then
-- locks every admin out in game with no clue why.
--
-- IsPrincipalAceAllowed READS the ACE table. It cannot grant anything, and
-- nothing in this resource should: custom.cfg is the only authority for grants.
function Bridge.PrincipalHasAce(principal, ace)
    local ok, allowed = pcall(function()
        return IsPrincipalAceAllowed(principal, ace)
    end)
    return ok and allowed == true
end

-- ---------------------------------------------------------------------------
-- THE CAPTURE READ. The single most important function in this resource.
--
-- The admin's position, read SERVER-SIDE off their ped. OneSync makes that
-- authoritative, so it is never a client-supplied coordinate. The client cannot
-- send a position to this resource at all; there is no net event here that
-- accepts one, and there never should be, because a captured anchor is written
-- into a table that a human then pastes into a config file. A client-supplied
-- number would be an invented coordinate laundered through a database.
--
-- Returns { x, y, z, h } or nil. The heading comes along because one registry
-- entry (clout_pawnshop) is written as a vector4 in its own config, and a
-- vector4 replacement line needs a fourth number that was measured rather than
-- made up.
-- ---------------------------------------------------------------------------
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    if not c then return nil end
    local h = 0.0
    local okH, heading = pcall(function() return GetEntityHeading(ped) end)
    if okH and tonumber(heading) then h = tonumber(heading) end
    return { x = c.x, y = c.y, z = c.z, h = h }
end

-- ox_lib server callback registration. ox_lib is a declared dependency and is
-- loaded via @ox_lib/init.lua in the manifest, so `lib` is present; the guard is
-- here so a broken load surfaces as a named console line instead of a resource
-- that starts and then silently answers no menu requests. Same call shape as
-- palm6_uniform/bridge/sv_framework.lua.
function Bridge.RegisterCallback(name, fn)
    if not (lib and lib.callback and lib.callback.register) then
        print(('^1[palm6_anchors] ox_lib callbacks are unavailable, so the anchor menu ("%s") cannot be served. /anchorlist still prints the list to chat.^0'):format(name))
        return false
    end
    lib.callback.register(name, fn)
    return true
end

-- Same rule as palm6_uniform: if ox_lib is not running this falls back to a
-- chat line instead of going quiet. Every message this resource sends is either
-- a confirmation that something worked or an explanation of why it did not.
function Bridge.Notify(src, msg, t)
    if not src or src <= 0 then return end
    if GetResourceState('ox_lib') == 'started' then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Anchors', description = msg, type = t or 'inform',
        })
        return
    end
    Bridge.Reply(src, { msg })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    for _, line in ipairs(lines) do
        if src == 0 then
            print('[palm6_anchors] ' .. line)
        else
            TriggerClientEvent('chat:addMessage', src,
                { color = { 255, 180, 60 }, args = { 'Anchors', line } })
        end
    end
end

-- Unrestricted chat command. Every gate (ACE, rate limit) runs server-side
-- inside the handler; see Config.AdminAce for why restricted = false is the
-- right call here and not laziness.
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end
