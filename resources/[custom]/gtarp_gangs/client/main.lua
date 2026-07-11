-- ============================================================================
-- gtarp_gangs/client/main.lua
--
-- Pure UI-flow logic. Calls Game.* (bridge/cl_game.lua) for ALL ox_lib UI, so
-- a port to GTA VI is a rewrite of the bridge only. The server owns every
-- decision: this file renders the server's menu snapshot and fires net events;
-- it NEVER decides membership, rank, or amounts (all re-validated server-side).
-- ============================================================================

-- Forward-declared so the menu builders can reference each other in any order.
local promptCreate, promptDeposit, promptWithdraw, promptRename
local openMemberActions, openMembersMenu, openGangMenu

function promptCreate()
    local input = Game.InputDialog('Found a gang', {
        { type = 'input', label = 'Gang name',
          description = ('%d-%d letters/numbers'):format(Config.NameMinLen, Config.NameMaxLen),
          required = true, min = 1, max = Config.NameMaxLen },
        { type = 'input', label = 'Tag',
          description = ('%d-%d letters/numbers'):format(Config.TagMinLen, Config.TagMaxLen),
          required = true, min = 1, max = Config.TagMaxLen },
    })
    if not input then return end
    TriggerServerEvent('gtarp_gangs:create', { name = input[1], tag = input[2] })
end

function promptDeposit()
    local v = Game.InputDialog('Deposit to gang vault', {
        { type = 'number', label = 'Amount ($)', required = true,
          min = Config.VaultMinAmount, max = Config.VaultMaxPerAction },
    })
    if not v or not v[1] then return end
    TriggerServerEvent('gtarp_gangs:deposit', math.floor(tonumber(v[1]) or 0))
end

function promptWithdraw()
    local v = Game.InputDialog('Withdraw from gang vault', {
        { type = 'number', label = 'Amount ($)', required = true,
          min = Config.VaultMinAmount, max = Config.VaultMaxPerAction },
    })
    if not v or not v[1] then return end
    TriggerServerEvent('gtarp_gangs:withdraw', math.floor(tonumber(v[1]) or 0))
end

function promptRename(g)
    local input = Game.InputDialog('Rename gang', {
        { type = 'input', label = 'Gang name',
          description = ('%d-%d letters/numbers'):format(Config.NameMinLen, Config.NameMaxLen),
          required = true, min = 1, max = Config.NameMaxLen, default = g.name },
        { type = 'input', label = 'Tag',
          description = ('%d-%d letters/numbers'):format(Config.TagMinLen, Config.TagMaxLen),
          required = true, min = 1, max = Config.TagMaxLen, default = g.tag },
    })
    if not input then return end
    TriggerServerEvent('gtarp_gangs:rename', { name = input[1], tag = input[2] })
end

function openMemberActions(data, m)
    local rank = data.myRank or 1
    local mr = data.minRank or {}
    local opts = {}
    if rank >= (mr.promote or 3) and m.rank < 2 then
        opts[#opts + 1] = { title = 'Promote to Officer', icon = 'arrow-up',
            onSelect = function() TriggerServerEvent('gtarp_gangs:promote', m.cid) end }
    end
    if rank >= (mr.demote or 3) and m.rank == 2 then
        opts[#opts + 1] = { title = 'Demote to Member', icon = 'arrow-down',
            onSelect = function() TriggerServerEvent('gtarp_gangs:demote', m.cid) end }
    end
    if rank >= (mr.kick or 2) and m.rank < rank then
        opts[#opts + 1] = { title = 'Kick from gang', icon = 'user-minus',
            onSelect = function()
                if Game.Confirm('Kick member', ('Kick %s from the gang?'):format(m.name or m.cid)) then
                    TriggerServerEvent('gtarp_gangs:kick', m.cid)
                end
            end }
    end
    if #opts == 0 then opts[1] = { title = 'No actions available', disabled = true } end
    Game.OpenMenu('gtarp_gangs_member_actions', m.name or m.cid, opts, 'gtarp_gangs_members')
end

function openMembersMenu(data)
    local rank = data.myRank or 1
    local mr = data.minRank or {}
    local opts = {}
    for _, m in ipairs(data.members or {}) do
        local canManage = (rank >= (mr.promote or 3)) or (rank >= (mr.kick or 2) and m.rank < rank)
        opts[#opts + 1] = {
            title = m.name or m.cid,
            description = m.rankName or ('rank ' .. tostring(m.rank)),
            icon = 'user',
            disabled = not canManage,
            onSelect = canManage and function() openMemberActions(data, m) end or nil,
        }
    end
    if #opts == 0 then opts[1] = { title = 'No members', disabled = true } end
    Game.OpenMenu('gtarp_gangs_members', 'Members', opts, 'gtarp_gangs_main')
end

function openGangMenu(data)
    if not data then return end
    if not data.inGang then
        Game.OpenMenu('gtarp_gangs_main', 'Gangs', {
            { title = 'Create a gang', description = 'Found your own crew', icon = 'users',
              onSelect = function() promptCreate() end },
        })
        return
    end

    local g = data.gang or {}
    local rank = data.myRank or 1
    local mr = data.minRank or {}
    local opts = {}

    opts[#opts + 1] = {
        title = ('[%s] %s'):format(g.tag or '?', g.name or '?'),
        description = ('Rank: %s   ·   Rep: %d   ·   Vault: $%d'):format(
            data.myRankName or '?', g.rep or 0, g.vault or 0),
        icon = 'shield-halved',
        disabled = true,
    }
    opts[#opts + 1] = { title = 'Deposit to vault', icon = 'money-bill-wave',
        onSelect = function() promptDeposit() end }
    if rank >= (mr.withdraw or 2) then
        opts[#opts + 1] = { title = 'Withdraw from vault', icon = 'money-bill-transfer',
            onSelect = function() promptWithdraw() end }
    end
    if rank >= (mr.invite or 2) then
        opts[#opts + 1] = { title = 'Invite nearby player', icon = 'user-plus',
            description = 'Invites the closest eligible player',
            onSelect = function() TriggerServerEvent('gtarp_gangs:invite') end }
    end
    opts[#opts + 1] = { title = ('Members (%d)'):format(#(data.members or {})), icon = 'list',
        onSelect = function() openMembersMenu(data) end }

    if rank >= Config.Rank.Leader then
        opts[#opts + 1] = { title = 'Rename gang', icon = 'pen',
            onSelect = function() promptRename(g) end }
    end

    if rank >= (mr.disband or 3) then
        opts[#opts + 1] = { title = 'Disband gang', icon = 'trash',
            onSelect = function()
                if Game.Confirm('Disband gang',
                    'This deletes the gang for everyone. The vault balance returns to you. Continue?') then
                    TriggerServerEvent('gtarp_gangs:disband')
                end
            end }
    else
        opts[#opts + 1] = { title = 'Leave gang', icon = 'door-open',
            onSelect = function()
                if Game.Confirm('Leave gang', 'Leave your gang?') then
                    TriggerServerEvent('gtarp_gangs:leave')
                end
            end }
    end

    Game.OpenMenu('gtarp_gangs_main', 'Gang', opts)
end

RegisterNetEvent('gtarp_gangs:openMenu', function(data)
    openGangMenu(data)
end)

RegisterNetEvent('gtarp_gangs:invitePrompt', function(inv)
    if not inv then return end
    local accept = Game.Confirm('Gang invite',
        ('%s invited you to join [%s] %s.\n\nAccept?'):format(
            inv.inviterName or 'Someone', inv.gangTag or '?', inv.gangName or '?'))
    if accept then
        TriggerServerEvent('gtarp_gangs:acceptInvite', inv.gangId)
    else
        TriggerServerEvent('gtarp_gangs:declineInvite')
    end
end)
