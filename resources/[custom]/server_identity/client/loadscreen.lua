-- ============================================================================
-- Push early identity into the NUI loadscreen while it is still visible.
-- Framework character names arrive after multichar — too late for load UI —
-- so we send the FiveM display name here via SendLoadingScreenMessage.
-- Also emit a small handshake so the Boot panel / systems HUD stay honest.
-- ============================================================================

local function pushNui(payload)
    if type(payload) ~= 'table' then return end
    SendLoadingScreenMessage(json.encode(payload))
end

local function pushWelcome(name)
    if not name or name == '' or name == '**Invalid**' then return end
    pushNui({
        eventName = 'welcome',
        playerName = name,
    })
end

local function pushHandshake(step)
    pushNui({
        eventName = 'onLogLine',
        message = step,
    })
end

CreateThread(function()
    pushHandshake('server_identity · link open')
    -- Retry briefly: PlayerId/name can be empty on the very first ticks.
    for i = 1, 24 do
        local name = GetPlayerName(PlayerId())
        if name and name ~= '' and name ~= '**Invalid**' then
            pushWelcome(name)
            pushHandshake(('welcome · %s'):format(name))
            break
        end
        Wait(250)
        if i == 8 then
            pushHandshake('waiting · player name')
        end
    end
end)

-- If a framework character name becomes available while the loadscreen is
-- somehow still up, prefer it. Safe no-op once ShutdownLoadingScreen runs.
Game.OnPlayerLoaded(function()
    local name = GetPlayerName(PlayerId())
    -- Qbox / QB: try local player data when present.
    local charName = nil
    pcall(function()
        if GetResourceState('qbx_core') == 'started' then
            local pdata = exports.qbx_core:GetPlayerData()
            if pdata and pdata.charinfo then
                local ci = pdata.charinfo
                charName = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
            end
        elseif GetResourceState('qb-core') == 'started' then
            local QBCore = exports['qb-core']:GetCoreObject()
            local pdata = QBCore and QBCore.Functions.GetPlayerData()
            if pdata and pdata.charinfo then
                local ci = pdata.charinfo
                charName = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
            end
        end
    end)
    local finalName = (charName and charName ~= '' and charName) or name
    pushWelcome(finalName)
    if finalName and finalName ~= '' then
        pushHandshake(('spawn · %s'):format(finalName))
    end
end)
