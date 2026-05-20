-- ============================================================================
-- gtarp_allowlist/server/main.lua
--
-- Enforces allowlist at playerConnecting. Approves if the joining
-- identifier appears in the DB allowlist OR if their Discord member
-- carries one of Config.AllowedRoles.
-- ============================================================================

local roleCache = {}  -- [discordId] = { roles = {set}, at = ts }

local function discordIdOf(src)
    local ids = GetPlayerIdentifiers(src) or {}
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'discord:' then return ids[i]:sub(9) end
    end
    return nil
end

local function licenseOf(src)
    local ids = GetPlayerIdentifiers(src) or {}
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'license:' then return ids[i] end
    end
    return nil
end

local function dbAllowed(license, discordId)
    if not license and not discordId then return false end
    local row = MySQL.single.await(
        "SELECT 1 FROM allowlist WHERE (identifier = ? OR identifier = ?) AND enabled = 1 LIMIT 1",
        { license or '', discordId and ('discord:' .. discordId) or '' }
    )
    return row ~= nil
end

local function rolesFromDiscord(discordId, cb)
    local cached = roleCache[discordId]
    if cached and (os.time() - cached.at) < (Config.RoleCacheTtlSeconds or 60) then
        cb(cached.roles)
        return
    end
    local token  = GetConvar(Config.BotTokenConvar, '')
    local guild  = GetConvar(Config.GuildIdConvar, '')
    if token == '' or guild == '' then cb(nil); return end

    local url = ('https://discord.com/api/v10/guilds/%s/members/%s'):format(guild, discordId)
    local done = false
    PerformHttpRequest(url, function(status, body)
        if done then return end
        done = true
        if status ~= 200 or not body then cb(nil); return end
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' or type(data.roles) ~= 'table' then
            cb(nil); return
        end
        local set = {}
        for _, r in ipairs(data.roles) do set[r] = true end
        roleCache[discordId] = { roles = set, at = os.time() }
        cb(set)
    end, 'GET', '', { ['Authorization'] = 'Bot ' .. token })

    SetTimeout(Config.DiscordTimeoutMs or 4000, function()
        if not done then done = true; cb(nil) end
    end)
end

local function hasAllowedRole(roleSet)
    if not roleSet then return false end
    for roleId in pairs(Config.AllowedRoles) do
        if roleSet[roleId] then return true end
    end
    return false
end

local function logDeny(license, discord, reason)
    pcall(function()
        exports.gtarp_staff:Log('allowlist_deny', 0, nil,
            ('license=%s discord=%s reason=%s'):format(
                tostring(license), tostring(discord), reason))
    end)
end

AddEventHandler('playerConnecting', function(_name, _setKickReason, deferrals)
    local src = source
    deferrals.defer()
    -- Wait(0) yield: required after deferrals.defer before deferrals.update.
    Wait(0)
    deferrals.update('Checking allowlist…')

    local license   = licenseOf(src)
    local discordId = discordIdOf(src)

    -- 1) DB allowlist (synchronous)
    if dbAllowed(license, discordId) then
        deferrals.done()
        return
    end

    -- 2) Discord role check
    if not discordId then
        logDeny(license, nil, 'no discord linked')
        deferrals.done(Config.DenyNoLink)
        return
    end

    rolesFromDiscord(discordId, function(roles)
        if roles == nil then
            -- Timeout / error.
            local allow = Config.FailOpen and true or false
            logDeny(license, discordId, allow and 'timeout fail-open' or 'timeout fail-closed')
            if allow then deferrals.done() else deferrals.done(Config.DenyTimeout) end
            return
        end
        if hasAllowedRole(roles) then
            deferrals.done()
        else
            logDeny(license, discordId, 'no allowed role')
            deferrals.done(Config.DenyNoRole)
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Shared check used by Phase 3 whitelist (one allowlist source of truth).
-- ---------------------------------------------------------------------------

exports('HasAllowedRole', function(src)
    local discordId = discordIdOf(src)
    if not discordId then return false end
    local cached = roleCache[discordId]
    if cached then return hasAllowedRole(cached.roles) end
    return false
end)

exports('IsAllowlisted', function(src)
    local license = licenseOf(src)
    local discord = discordIdOf(src)
    if dbAllowed(license, discord) then return true end
    local cached = discord and roleCache[discord] or nil
    return cached ~= nil and hasAllowedRole(cached.roles)
end)
