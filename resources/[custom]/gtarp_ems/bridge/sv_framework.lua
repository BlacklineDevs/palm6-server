-- ============================================================================
-- gtarp_ems/bridge/sv_framework.lua
--
-- Framework adapter (server). The ONLY file in this resource that calls
-- qbx_core / framework exports or server-side natives. server/main.lua
-- calls Bridge.* only, so its logic ports to GTA VI by rewriting THIS FILE.
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
--
-- Copied almost verbatim from gtarp_citations/bridge/sv_framework.lua; the
-- substantive change is the on-duty gate (ambulance instead of police,
-- proven by gtarp_mechanic's IsOnDutyMechanic) plus one helper,
-- GetCitizenIdOf, for billing a present online patient by server id.
-- ============================================================================

Bridge = {}

local function getPlayer(src)
    local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    return ok and p or nil
end

-- Stable per-character id, or nil.
function Bridge.GetCitizenId(src)
    local p = getPlayer(src)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- citizenid of an online server id, or nil. Used by /emsbill, which bills a
-- present, online patient by player id rather than an offline citizenid.
function Bridge.GetCitizenIdOf(playerId)
    local p = getPlayer(playerId)
    return p and p.PlayerData and p.PlayerData.citizenid or nil
end

-- Display name for bill attribution.
function Bridge.GetPlayerName(src)
    local p = getPlayer(src)
    if p and p.PlayerData and p.PlayerData.charinfo then
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return GetPlayerName(src) or ('player %d'):format(src)
end

-- Is this source an on-duty medic right now?
-- Mirrors gtarp_citations Bridge.IsOnDutyPolice / gtarp_mechanic
-- Bridge.IsOnDutyMechanic exactly, swapping the job name.
function Bridge.IsOnDutyMedic(src)
    local p = getPlayer(src)
    local job = p and p.PlayerData and p.PlayerData.job
    return job ~= nil and job.name == Config.JobName and job.onduty == true
end

-- Is the source carrying at least one of `item`?
function Bridge.HasItem(src, item)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and (tonumber(n) or 0) > 0
end

-- Notify a player.
function Bridge.Notify(src, title, msg, t)
    TriggerClientEvent('ox_lib:notify', src, {
        title = title, description = msg, type = t or 'inform',
    })
end

-- Reply to a command invoker: console gets prints, players get chat lines.
function Bridge.Reply(src, lines)
    if src == 0 then
        for _, line in ipairs(lines) do print('[gtarp_ems] ' .. line) end
        return
    end
    -- One gtarp_ui panel instead of dumping lines into the chat feed.
    TriggerClientEvent('gtarp_ui:show', src, { tag = 'EMS', color = { 255, 195, 100 }, lines = lines })
end

-- Caller position as {x,y,z}, or nil.
function Bridge.GetCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z }
end

function Bridge.Distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Charge `amount` from bank. Returns true if the player could pay.
function Bridge.ChargeBank(src, amount, reason)
    local p = getPlayer(src)
    if not p or not p.Functions then return false end
    if (p.PlayerData.money.bank or 0) < amount then return false end
    return p.Functions.RemoveMoney('bank', amount, reason) and true or false
end

-- Route a settled bill to the EMS society account. Soft, absence never
-- blocks settlement.
function Bridge.CreditEmsAccount(account, amount)
    pcall(function()
        exports['Renewed-Banking']:addAccountMoney(account, amount)
    end)
end

-- Resolve a citizenid to a display name, online or offline, or nil when
-- no such citizen exists (framework schema knowledge lives here).
function Bridge.GetCitizenName(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return Bridge.GetPlayerName(src)
        end
    end
    local name
    pcall(function()
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if row and row.charinfo then
            local ci = json.decode(row.charinfo)
            if type(ci) == 'table' then
                name = ('%s %s'):format(ci.firstname or '', ci.lastname or '')
                    :gsub('^%s+', ''):gsub('%s+$', '')
            end
        end
    end)
    return name
end

-- Server source for an online character, or nil.
function Bridge.GetSourceByCitizenId(citizenid)
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local p = getPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid == citizenid then
            return src
        end
    end
    return nil
end

function Bridge.ResourceStarted(name)
    return GetResourceState(name) == 'started'
end

-- Unrestricted chat command (all gating happens server-side in the
-- handler).
function Bridge.RegisterCommand(name, handler)
    RegisterCommand(name, handler, false)
end
