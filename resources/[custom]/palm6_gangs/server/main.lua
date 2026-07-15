-- ============================================================================
-- palm6_gangs/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for ALL framework /
-- native access; our OWN SQL (palm6_gangs / palm6_gang_members /
-- palm6_gang_vault_log) lives here per docs/GTA6-READINESS.md §3. Nothing
-- here trusts a client-supplied gang id, rank, amount, or membership — every
-- action re-reads authority from the DB server-side.
--
-- SCOPE: the player-run gang layer Qbox does NOT ship. qbx_core owns the
-- STATIC gang registry (predefined gangs + grades, PlayerData.gang, /setgang)
-- — we do not touch or duplicate that. We add: player-created gangs,
-- membership + ranks, a shared CASH vault, and reputation, exposed via the
-- server-only exports at the bottom (GetGang / IsSameGang / AddRep /
-- GetSummary) so turf/protection/drugs can reward gang activity later.
-- ============================================================================

local pendingInvites = {}   -- [targetCid] = { gangId, gangName, gangTag, inviterCid, inviterName, expiresAt }

local function now() return os.time() end
local function dbg(m) if Config.Debug then print('[palm6_gangs] ' .. m) end end

-- /gangweb single-use token minting (see sql/0044_gang_web_tokens.sql).
local webCooldown = {}    -- [src] = ts of last /gangweb (anti-spam)
local inviteCooldown = {} -- [src] = ts of last invite (anti-spam; stops forcing
                          -- repeated confirm-dialogs onto a nearby player)
local menuCooldown = {}   -- [src] = ts of last requestMenu (anti-spam: pushMenu
                          -- runs 1-3 DB reads; any client can spam this event)
local WEB_TOKEN_CHARS = '0123456789abcdefghijklmnopqrstuvwxyz'
local function makeWebToken()
    math.randomseed(os.time() + os.clock() * 1000)
    local out = {}
    for i = 1, 32 do
        local k = math.random(#WEB_TOKEN_CHARS)
        out[i] = WEB_TOKEN_CHARS:sub(k, k)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- DB read helpers (all pcall-guarded; nil/empty on error)
-- ---------------------------------------------------------------------------
local function memberRow(cid)
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT citizenid, gang_id, rank, name FROM palm6_gang_members WHERE citizenid = ?', { cid })
    end)
    return row
end

local function gangRow(id)
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT id, name, tag, leader_cid, vault_balance, rep FROM palm6_gangs WHERE id = ?', { id })
    end)
    return row
end

local function gangMembers(id)
    local rows
    pcall(function()
        rows = MySQL.query.await(
            'SELECT citizenid, rank, name FROM palm6_gang_members WHERE gang_id = ? ORDER BY rank DESC, joined_at ASC', { id })
    end)
    return rows or {}
end

local function memberCount(id)
    local n = 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS c FROM palm6_gang_members WHERE gang_id = ?', { id })
        n = r and tonumber(r.c) or 0
    end)
    return n
end

local function logVault(gangId, cid, action, amount, balanceAfter)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_gang_vault_log (gang_id, citizenid, action, amount, balance_after) VALUES (?,?,?,?,?)',
            { gangId, cid, action, amount, balanceAfter })
    end)
end

-- Atomically remove ALL cash from a gang's vault, returning exactly the amount
-- removed (0 if empty/gone). The exact-value WHERE + affected-rows check means
-- we only ever pay out what we actually took, even under a concurrent
-- withdraw. Bounded retry covers the (rare) race where the balance shifts
-- between the read and the zeroing update.
local function captureVault(gangId)
    for _ = 1, 4 do
        local bal
        pcall(function()
            local r = MySQL.single.await('SELECT vault_balance FROM palm6_gangs WHERE id = ?', { gangId })
            bal = r and tonumber(r.vault_balance) or 0
        end)
        if not bal or bal == 0 then return 0 end
        local affected = 0
        pcall(function()
            affected = MySQL.update.await(
                'UPDATE palm6_gangs SET vault_balance = 0 WHERE id = ? AND vault_balance = ?', { gangId, bal })
        end)
        if affected == 1 then return bal end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Name / tag sanitising + profanity filter
-- ---------------------------------------------------------------------------
local function hasBlocked(s)
    local flat = s:lower():gsub('%s+', '')
    for _, bad in ipairs(Config.Blocklist) do
        if flat:find(bad, 1, true) then return true end
    end
    return false
end

local function sanitizeName(raw)
    if type(raw) ~= 'string' then return nil, 'Invalid name.' end
    local name = raw:gsub('[^%w ]', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #name < Config.NameMinLen or #name > Config.NameMaxLen then
        return nil, ('Name must be %d-%d letters/numbers.'):format(Config.NameMinLen, Config.NameMaxLen)
    end
    if hasBlocked(name) then return nil, 'That name is not allowed.' end
    return name
end

local function sanitizeTag(raw)
    if type(raw) ~= 'string' then return nil, 'Invalid tag.' end
    local tag = raw:gsub('[^%w]', ''):upper()
    if #tag < Config.TagMinLen or #tag > Config.TagMaxLen then
        return nil, ('Tag must be %d-%d letters/numbers.'):format(Config.TagMinLen, Config.TagMaxLen)
    end
    if hasBlocked(tag) then return nil, 'That tag is not allowed.' end
    return tag
end

-- ---------------------------------------------------------------------------
-- Menu snapshot push (server builds the state; client only renders it)
-- ---------------------------------------------------------------------------
local function pushMenu(src)
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local mr = memberRow(cid)
    if not mr then
        TriggerClientEvent('palm6_gangs:openMenu', src, { inGang = false })
        return
    end
    local g = gangRow(mr.gang_id)
    if not g then
        -- membership orphaned (gang deleted out from under it) — self-heal.
        pcall(function() MySQL.update.await('DELETE FROM palm6_gang_members WHERE citizenid = ?', { cid }) end)
        TriggerClientEvent('palm6_gangs:openMenu', src, { inGang = false })
        return
    end
    local members = {}
    for _, m in ipairs(gangMembers(mr.gang_id)) do
        members[#members + 1] = {
            cid = m.citizenid, name = m.name or m.citizenid,
            rank = m.rank, rankName = Config.RankName[m.rank] or ('rank ' .. tostring(m.rank)),
        }
    end
    TriggerClientEvent('palm6_gangs:openMenu', src, {
        inGang = true,
        gang = { id = g.id, name = g.name, tag = g.tag, rep = tonumber(g.rep) or 0, vault = tonumber(g.vault_balance) or 0 },
        myRank = mr.rank,
        myRankName = Config.RankName[mr.rank],
        members = members,
        minRank = {
            invite = Config.MinRank.Invite, kick = Config.MinRank.Kick,
            withdraw = Config.MinRank.Withdraw, promote = Config.MinRank.Promote,
            demote = Config.MinRank.Demote, disband = Config.MinRank.Disband,
        },
    })
end

-- Pay a gang's vault remainder to `leaderCid`, notify online members, and
-- delete the gang + all membership rows. Shared by disband and sole-leader
-- leave so money is never voided.
local function destroyGang(g, leaderCid, actorSrc)
    local remainder = captureVault(g.id)
    local paidOut = 0
    if remainder > 0 then
        if Bridge.CreditBankByCitizenId(leaderCid, remainder, 'gang-disband-payout') then
            logVault(g.id, leaderCid, 'disband_payout', remainder, 0)
            paidOut = remainder
        else
            -- Bank credit failed (both online + offline paths). captureVault has
            -- already zeroed the vault, so do NOT silently void the money: write a
            -- reconcilable ledger row (no FK cascade — it survives the gang delete
            -- below) and warn loudly so staff can reimburse leaderCid.
            logVault(g.id, leaderCid, 'disband_payout_failed', remainder, 0)
            print(('^1[palm6_gangs] disband payout FAILED — %s is owed $%d from gang %d (reconcile manually)^0')
                :format(leaderCid, remainder, g.id))
        end
    end
    for _, m in ipairs(gangMembers(g.id)) do
        local msrc = Bridge.GetSourceByCitizenId(m.citizenid)
        if msrc and msrc ~= actorSrc then
            Bridge.Notify(msrc, 'Gangs', ('[%s] %s has been disbanded.'):format(g.tag, g.name), 'inform')
            Bridge.MirrorQbxGang(msrc, 'none', 0)
        end
    end
    pcall(function()
        MySQL.update.await('DELETE FROM palm6_gang_members WHERE gang_id = ?', { g.id })
        MySQL.update.await('DELETE FROM palm6_gangs WHERE id = ?', { g.id })
    end)
    return paidOut
end

-- ---------------------------------------------------------------------------
-- Net events — every handler re-derives citizenid + rank server-side.
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_gangs:requestMenu', function()
    local src = source
    local mt = now()
    if mt - (menuCooldown[src] or 0) < 1 then return end  -- throttle DB-read spam
    menuCooldown[src] = mt
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:create', function(payload)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if memberRow(cid) then
        Bridge.Notify(src, 'Gangs', 'You are already in a gang.', 'error'); return
    end
    payload = type(payload) == 'table' and payload or {}
    local name, nerr = sanitizeName(payload.name)
    if not name then Bridge.Notify(src, 'Gangs', nerr, 'error'); return end
    local tag, terr = sanitizeTag(payload.tag)
    if not tag then Bridge.Notify(src, 'Gangs', terr, 'error'); return end

    local clash
    pcall(function()
        clash = MySQL.single.await('SELECT id FROM palm6_gangs WHERE name = ? OR tag = ? LIMIT 1', { name, tag })
    end)
    if clash then Bridge.Notify(src, 'Gangs', 'That name or tag is already taken.', 'error'); return end

    if Config.CreationCost > 0 and not Bridge.ChargeBank(src, Config.CreationCost, 'gang-creation') then
        Bridge.Notify(src, 'Gangs',
            ('Founding a gang costs $%d from your bank.'):format(Config.CreationCost), 'error')
        return
    end

    local gangId
    local ok = pcall(function()
        gangId = MySQL.insert.await('INSERT INTO palm6_gangs (name, tag, leader_cid) VALUES (?,?,?)', { name, tag, cid })
    end)
    if not ok or not gangId then
        if Config.CreationCost > 0 then Bridge.CreditBankByCitizenId(cid, Config.CreationCost, 'gang-creation-refund') end
        Bridge.Notify(src, 'Gangs', 'That name or tag was just taken — try another.', 'error')
        return
    end

    local mok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_gang_members (citizenid, gang_id, rank, name) VALUES (?,?,?,?)',
            { cid, gangId, Config.Rank.Leader, Bridge.GetPlayerName(src) })
    end)
    if not mok then
        -- membership insert failed (raced into another gang, PK collision) —
        -- roll the gang row back + refund so no ownerless gang is stranded.
        pcall(function() MySQL.update.await('DELETE FROM palm6_gangs WHERE id = ?', { gangId }) end)
        if Config.CreationCost > 0 then Bridge.CreditBankByCitizenId(cid, Config.CreationCost, 'gang-creation-refund') end
        Bridge.Notify(src, 'Gangs', 'Could not create your gang — try again.', 'error')
        return
    end

    Bridge.MirrorQbxGang(src, name, Config.Rank.Leader)
    Bridge.Notify(src, 'Gangs', ('Founded [%s] %s. You are the leader.'):format(tag, name), 'success')
    dbg(('%s founded gang %d [%s] %s'):format(cid, gangId, tag, name))
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:rename', function(payload)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Gangs', 'You are not in a gang.', 'error'); return end
    -- Leader-only, re-derived from the DB (never trust the client). Rank gate
    -- like disband, then the ACTUAL-leader identity check for defence-in-depth
    -- against a stale/misranked row (leadership is never granted via promote).
    if mr.rank < Config.Rank.Leader then
        Bridge.Notify(src, 'Gangs', 'Only the leader can rename the gang.', 'error'); return
    end
    local g = gangRow(mr.gang_id)
    if not g then
        pcall(function() MySQL.update.await('DELETE FROM palm6_gang_members WHERE citizenid = ?', { cid }) end)
        return
    end
    if g.leader_cid ~= cid then
        Bridge.Notify(src, 'Gangs', 'Only the leader can rename the gang.', 'error'); return
    end

    payload = type(payload) == 'table' and payload or {}
    local name, nerr = sanitizeName(payload.name)
    if not name then Bridge.Notify(src, 'Gangs', nerr, 'error'); return end
    local tag, terr = sanitizeTag(payload.tag)
    if not tag then Bridge.Notify(src, 'Gangs', terr, 'error'); return end

    -- Nothing changed after sanitising — reject BEFORE charging so a leader is
    -- never billed for a no-op (and an identical UPDATE yields affected==0).
    if name == g.name and tag == g.tag then
        Bridge.Notify(src, 'Gangs', 'That is already the gang name and tag — nothing to change.', 'error'); return
    end

    -- Uniqueness, excluding OUR OWN gang so re-saving one unchanged field isn't
    -- a false collision against ourselves.
    local clash
    pcall(function()
        clash = MySQL.single.await(
            'SELECT id FROM palm6_gangs WHERE (name = ? OR tag = ?) AND id <> ? LIMIT 1', { name, tag, mr.gang_id })
    end)
    if clash then Bridge.Notify(src, 'Gangs', 'That name or tag is already taken.', 'error'); return end

    if Config.RenameCost > 0 and not Bridge.ChargeBank(src, Config.RenameCost, 'gang-rename') then
        Bridge.Notify(src, 'Gangs',
            ('Renaming your gang costs $%d from your bank.'):format(Config.RenameCost), 'error')
        return
    end

    local affected = 0
    local ok = pcall(function()
        affected = MySQL.update.await('UPDATE palm6_gangs SET name = ?, tag = ? WHERE id = ?', { name, tag, mr.gang_id })
    end)
    if not ok or affected ~= 1 then
        if Config.RenameCost > 0 then Bridge.CreditBankByCitizenId(cid, Config.RenameCost, 'gang-rename-refund') end
        Bridge.Notify(src, 'Gangs', 'That name or tag was just taken — try another.', 'error')
        return
    end

    -- Re-mirror EVERY online member so their PlayerData.gang reflects the new
    -- name (create only mirrors the founder, but a rename changes it for all).
    -- No-op unless Config.MirrorToQbxGang; pcall-guarded in the bridge.
    for _, m in ipairs(gangMembers(mr.gang_id)) do
        local msrc = Bridge.GetSourceByCitizenId(m.citizenid)
        if msrc then Bridge.MirrorQbxGang(msrc, name, m.rank) end
    end
    Bridge.Notify(src, 'Gangs', ('Renamed to [%s] %s.'):format(tag, name), 'success')
    dbg(('%s renamed gang %d to [%s] %s'):format(cid, mr.gang_id, tag, name))
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:disband', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Gangs', 'You are not in a gang.', 'error'); return end
    if mr.rank < Config.MinRank.Disband then
        Bridge.Notify(src, 'Gangs', 'Only the leader can disband the gang.', 'error'); return
    end
    local g = gangRow(mr.gang_id)
    if not g then
        pcall(function() MySQL.update.await('DELETE FROM palm6_gang_members WHERE citizenid = ?', { cid }) end)
        return
    end
    local remainder = destroyGang(g, cid, src)
    Bridge.MirrorQbxGang(src, 'none', 0)
    Bridge.Notify(src, 'Gangs',
        ('Disbanded [%s] %s.'):format(g.tag, g.name) .. (remainder > 0 and (' $%d vault returned to you.'):format(remainder) or ''),
        'success')
    dbg(('%s disbanded gang %d'):format(cid, g.id))
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:invite', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Gangs', 'You are not in a gang.', 'error'); return end
    if mr.rank < Config.MinRank.Invite then
        Bridge.Notify(src, 'Gangs', 'You do not have permission to invite.', 'error'); return
    end
    -- Throttle BEFORE the O(players) proximity scan below (which runs a memberRow()
    -- DB query per online player) — an unthrottled invite could be spammed to hammer
    -- the DB pool on every packet, and to spam confirm-dialogs at the target. Set
    -- unconditionally here so even the "no target nearby" path is rate-limited.
    local it = now()
    if it - (inviteCooldown[src] or 0) < (Config.InviteCooldownSec or 10) then
        Bridge.Notify(src, 'Gangs', 'Slow down before inviting again.', 'error'); return
    end
    inviteCooldown[src] = it
    local g = gangRow(mr.gang_id)
    if not g then return end
    if memberCount(g.id) >= Config.MaxMembers then
        Bridge.Notify(src, 'Gangs', 'Your gang is full.', 'error'); return
    end
    local myCoords = Bridge.GetCoords(src)
    if not myCoords then return end

    -- Server picks the target: nearest online gangless player within radius.
    -- The client never supplies WHO to invite.
    local bestSrc, bestCid, bestName, bestDist
    for _, osrc in ipairs(Bridge.GetOnlinePlayers()) do
        if osrc ~= src then
            local ocid = Bridge.GetCitizenId(osrc)
            if ocid and not memberRow(ocid) then
                local oc = Bridge.GetCoords(osrc)
                if oc then
                    local d = Bridge.Distance(myCoords, oc)
                    if d <= Config.InviteRadius and (not bestDist or d < bestDist) then
                        bestSrc, bestCid, bestName, bestDist = osrc, ocid, Bridge.GetPlayerName(osrc), d
                    end
                end
            end
        end
    end
    if not bestSrc then
        Bridge.Notify(src, 'Gangs', 'No eligible player nearby to invite.', 'error'); return
    end

    pendingInvites[bestCid] = {
        gangId = g.id, gangName = g.name, gangTag = g.tag,
        inviterCid = cid, inviterName = Bridge.GetPlayerName(src),
        expiresAt = now() + Config.InviteExpirySec,
    }
    Bridge.Notify(src, 'Gangs', ('Invited %s to [%s] %s.'):format(bestName, g.tag, g.name), 'success')
    TriggerClientEvent('palm6_gangs:invitePrompt', bestSrc, {
        gangId = g.id, gangName = g.name, gangTag = g.tag, inviterName = Bridge.GetPlayerName(src),
    })
end)

RegisterNetEvent('palm6_gangs:acceptInvite', function(gangId)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    gangId = tonumber(gangId)
    local inv = pendingInvites[cid]
    if not inv or not gangId or inv.gangId ~= gangId then
        Bridge.Notify(src, 'Gangs', 'That invite is no longer valid.', 'error'); return
    end
    if now() > inv.expiresAt then
        pendingInvites[cid] = nil
        Bridge.Notify(src, 'Gangs', 'That invite expired.', 'error'); return
    end
    if memberRow(cid) then
        pendingInvites[cid] = nil
        Bridge.Notify(src, 'Gangs', 'You are already in a gang.', 'error'); return
    end
    local g = gangRow(gangId)
    if not g then
        pendingInvites[cid] = nil
        Bridge.Notify(src, 'Gangs', 'That gang no longer exists.', 'error'); return
    end
    if memberCount(gangId) >= Config.MaxMembers then
        pendingInvites[cid] = nil
        Bridge.Notify(src, 'Gangs', 'That gang is now full.', 'error'); return
    end
    pendingInvites[cid] = nil
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_gang_members (citizenid, gang_id, rank, name) VALUES (?,?,?,?)',
            { cid, gangId, Config.Rank.Member, Bridge.GetPlayerName(src) })
    end)
    if not ok then Bridge.Notify(src, 'Gangs', 'Could not join — try again.', 'error'); return end
    Bridge.MirrorQbxGang(src, g.name, Config.Rank.Member)
    Bridge.Notify(src, 'Gangs', ('You joined [%s] %s.'):format(g.tag, g.name), 'success')
    local isrc = Bridge.GetSourceByCitizenId(inv.inviterCid)
    if isrc then Bridge.Notify(isrc, 'Gangs', ('%s joined the gang.'):format(Bridge.GetPlayerName(src)), 'inform') end
    dbg(('%s joined gang %d'):format(cid, gangId))
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:declineInvite', function()
    local cid = Bridge.GetCitizenId(source)
    if cid then pendingInvites[cid] = nil end
end)

RegisterNetEvent('palm6_gangs:leave', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Gangs', 'You are not in a gang.', 'error'); return end
    local g = gangRow(mr.gang_id)
    if not g then
        pcall(function() MySQL.update.await('DELETE FROM palm6_gang_members WHERE citizenid = ?', { cid }) end)
        Bridge.Notify(src, 'Gangs', 'You left.', 'inform'); return
    end
    if mr.rank >= Config.Rank.Leader then
        if memberCount(g.id) > 1 then
            Bridge.Notify(src, 'Gangs', 'As leader, promote a new officer/leader or disband before leaving.', 'error'); return
        end
        -- sole leader leaving == disband the (now empty) gang.
        local remainder = destroyGang(g, cid, src)
        Bridge.MirrorQbxGang(src, 'none', 0)
        Bridge.Notify(src, 'Gangs',
            ('You left and disbanded [%s] %s.'):format(g.tag, g.name) .. (remainder > 0 and (' $%d returned.'):format(remainder) or ''),
            'inform')
        pushMenu(src)
        return
    end
    pcall(function() MySQL.update.await('DELETE FROM palm6_gang_members WHERE citizenid = ?', { cid }) end)
    Bridge.MirrorQbxGang(src, 'none', 0)
    Bridge.Notify(src, 'Gangs', ('You left [%s] %s.'):format(g.tag, g.name), 'inform')
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:kick', function(targetCid)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid or type(targetCid) ~= 'string' then return end
    if targetCid == cid then Bridge.Notify(src, 'Gangs', 'You cannot kick yourself — leave instead.', 'error'); return end
    local mr = memberRow(cid)
    if not mr or mr.rank < Config.MinRank.Kick then
        Bridge.Notify(src, 'Gangs', 'You do not have permission to kick.', 'error'); return
    end
    local tr = memberRow(targetCid)
    if not tr or tr.gang_id ~= mr.gang_id then
        Bridge.Notify(src, 'Gangs', 'That player is not in your gang.', 'error'); return
    end
    if tr.rank >= mr.rank then
        Bridge.Notify(src, 'Gangs', 'You can only kick members ranked below you.', 'error'); return
    end
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'DELETE FROM palm6_gang_members WHERE citizenid = ? AND gang_id = ?', { targetCid, mr.gang_id })
    end)
    if affected ~= 1 then Bridge.Notify(src, 'Gangs', 'Could not kick that member.', 'error'); return end
    Bridge.Notify(src, 'Gangs', ('Kicked %s.'):format(tr.name or targetCid), 'success')
    local tsrc = Bridge.GetSourceByCitizenId(targetCid)
    if tsrc then
        Bridge.Notify(tsrc, 'Gangs', 'You were kicked from your gang.', 'error')
        Bridge.MirrorQbxGang(tsrc, 'none', 0)
    end
    dbg(('%s kicked %s from gang %d'):format(cid, targetCid, mr.gang_id))
    pushMenu(src)
end)

-- Shared promote/demote. direction +1 promotes, -1 demotes. Ranks move only
-- between Member(1) and Officer(2); leadership is never granted via promote.
local function setRank(src, targetCid, direction)
    local cid = Bridge.GetCitizenId(src)
    if not cid or type(targetCid) ~= 'string' then return end
    local mr = memberRow(cid)
    local needed = direction > 0 and Config.MinRank.Promote or Config.MinRank.Demote
    if not mr or mr.rank < needed then
        Bridge.Notify(src, 'Gangs', 'Only the leader can change ranks.', 'error'); return
    end
    if targetCid == cid then Bridge.Notify(src, 'Gangs', 'You cannot change your own rank.', 'error'); return end
    local tr = memberRow(targetCid)
    if not tr or tr.gang_id ~= mr.gang_id then
        Bridge.Notify(src, 'Gangs', 'That player is not in your gang.', 'error'); return
    end
    local newRank = tr.rank + direction
    if newRank < Config.Rank.Member or newRank > Config.Rank.Officer then
        Bridge.Notify(src, 'Gangs',
            direction > 0 and 'That member is already an officer.' or 'That member is already the lowest rank.', 'error')
        return
    end
    -- Guard the UPDATE on the CURRENT rank so two racing rank changes can't
    -- compound (affected==1 confirms we transitioned from exactly tr.rank).
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'UPDATE palm6_gang_members SET rank = ? WHERE citizenid = ? AND gang_id = ? AND rank = ?',
            { newRank, targetCid, mr.gang_id, tr.rank })
    end)
    if affected ~= 1 then Bridge.Notify(src, 'Gangs', 'Rank change failed — try again.', 'error'); return end
    Bridge.Notify(src, 'Gangs', ('%s is now %s.'):format(tr.name or targetCid, Config.RankName[newRank]), 'success')
    local tsrc = Bridge.GetSourceByCitizenId(targetCid)
    if tsrc then Bridge.Notify(tsrc, 'Gangs', ('You are now %s.'):format(Config.RankName[newRank]), 'inform') end
    pushMenu(src)
end

RegisterNetEvent('palm6_gangs:promote', function(targetCid) setRank(source, targetCid, 1) end)
RegisterNetEvent('palm6_gangs:demote', function(targetCid) setRank(source, targetCid, -1) end)

RegisterNetEvent('palm6_gangs:deposit', function(amount)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    amount = math.floor(tonumber(amount) or 0)
    if amount ~= amount or amount < Config.VaultMinAmount or amount > Config.VaultMaxPerAction then
        Bridge.Notify(src, 'Vault', 'Enter a valid amount.', 'error'); return
    end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Vault', 'You are not in a gang.', 'error'); return end

    -- Consume-before-credit: pull the cash first; credit the vault only if it
    -- actually left the wallet.
    if not Bridge.RemoveCash(src, amount, 'gang-vault-deposit') then
        Bridge.Notify(src, 'Vault', 'You do not have that much cash on hand.', 'error'); return
    end
    local newBal
    local ok = pcall(function()
        MySQL.update.await('UPDATE palm6_gangs SET vault_balance = vault_balance + ? WHERE id = ?', { amount, mr.gang_id })
        local r = MySQL.single.await('SELECT vault_balance FROM palm6_gangs WHERE id = ?', { mr.gang_id })
        newBal = r and tonumber(r.vault_balance) or nil
    end)
    if not ok or not newBal then
        -- credit failed after the cash was taken — hand it straight back.
        Bridge.AddCash(src, amount, 'gang-vault-deposit-refund')
        Bridge.Notify(src, 'Vault', 'Deposit failed — your cash was returned.', 'error'); return
    end
    logVault(mr.gang_id, cid, 'deposit', amount, newBal)
    Bridge.Notify(src, 'Vault', ('Deposited $%d. Vault balance: $%d.'):format(amount, newBal), 'success')
    pushMenu(src)
end)

RegisterNetEvent('palm6_gangs:withdraw', function(amount)
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    amount = math.floor(tonumber(amount) or 0)
    if amount ~= amount or amount < Config.VaultMinAmount or amount > Config.VaultMaxPerAction then
        Bridge.Notify(src, 'Vault', 'Enter a valid amount.', 'error'); return
    end
    local mr = memberRow(cid)
    if not mr then Bridge.Notify(src, 'Vault', 'You are not in a gang.', 'error'); return end
    if mr.rank < Config.MinRank.Withdraw then
        Bridge.Notify(src, 'Vault', 'Only officers and above can withdraw.', 'error'); return
    end

    -- Atomic guarded decrement — succeeds (affected==1) only if the balance was
    -- sufficient AT commit time. This is the double-withdraw / overdraft guard:
    -- two same-tick withdraws can never both pass.
    local affected = 0
    pcall(function()
        affected = MySQL.update.await(
            'UPDATE palm6_gangs SET vault_balance = vault_balance - ? WHERE id = ? AND vault_balance >= ?',
            { amount, mr.gang_id, amount })
    end)
    if affected ~= 1 then
        Bridge.Notify(src, 'Vault', 'The vault does not have that much.', 'error'); return
    end
    -- Vault debited; pay the player. If the payout fails, put it back so money
    -- is never destroyed.
    if not Bridge.AddCash(src, amount, 'gang-vault-withdraw') then
        pcall(function()
            MySQL.update.await('UPDATE palm6_gangs SET vault_balance = vault_balance + ? WHERE id = ?', { amount, mr.gang_id })
        end)
        Bridge.Notify(src, 'Vault', 'Withdrawal failed — nothing was taken.', 'error'); return
    end
    local newBal = 0
    pcall(function()
        local r = MySQL.single.await('SELECT vault_balance FROM palm6_gangs WHERE id = ?', { mr.gang_id })
        newBal = r and tonumber(r.vault_balance) or 0
    end)
    logVault(mr.gang_id, cid, 'withdraw', amount, newBal)
    Bridge.Notify(src, 'Vault', ('Withdrew $%d. Vault balance: $%d.'):format(amount, newBal), 'success')
    pushMenu(src)
end)

-- Expired-invite sweep.
CreateThread(function()
    while true do
        Wait(30000)
        local t = now()
        for k, inv in pairs(pendingInvites) do
            if t > inv.expiresAt then pendingInvites[k] = nil end
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Bridge.RegisterCommand(Config.Command, function(source) pushMenu(source) end)

    -- /gangweb — a LEADER mints a single-use, time-limited link to the Palm6
    -- site's gang-admin page. Leadership is re-derived from the DB (never the
    -- client); the token is claimed once by POST /api/gang/branding.
    Bridge.RegisterCommand(Config.WebCommand, function(source)
        local src = source
        local cid = Bridge.GetCitizenId(src)
        if not cid then return end

        local t = now()
        if t - (webCooldown[src] or 0) < (Config.WebCooldown or 30) then
            Bridge.Notify(src, 'Gangs', 'Give it a moment before requesting another link.', 'error'); return
        end
        webCooldown[src] = t

        local mr = memberRow(cid)
        if not mr then Bridge.Notify(src, 'Gangs', 'You are not in a gang.', 'error'); return end
        if mr.rank < Config.Rank.Leader then
            Bridge.Notify(src, 'Gangs', 'Only the leader can get a web-manage link.', 'error'); return
        end
        local g = gangRow(mr.gang_id)
        if not g then return end
        if g.leader_cid ~= cid then
            Bridge.Notify(src, 'Gangs', 'Only the leader can get a web-manage link.', 'error'); return
        end

        local token = makeWebToken()
        local expires = t + (Config.WebTokenTtl or 900)
        local ok = pcall(function()
            -- One live link per gang: drop any prior UNUSED tokens before minting.
            MySQL.update.await(
                'DELETE FROM palm6_gang_web_tokens WHERE gang_id = ? AND used_at IS NULL', { mr.gang_id })
            MySQL.insert.await(
                'INSERT INTO palm6_gang_web_tokens (token, gang_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
                { token, mr.gang_id, t, expires })
        end)
        if not ok then
            Bridge.Notify(src, 'Gangs', 'Could not mint a link right now — try again.', 'error'); return
        end

        local mins = math.max(1, math.floor((Config.WebTokenTtl or 900) / 60))
        local url = ('%s/gang/%s/manage?t=%s'):format(Config.WebBaseUrl, g.tag, token)
        Bridge.Notify(src, 'Gangs',
            ('Web-manage link posted to your chat (one use, %d min).'):format(mins), 'success')
        -- Chat so the leader can copy the full URL (Notify would truncate it).
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 180, 60 }, multiline = true,
            args = { 'Palm6', ('Manage [%s] %s (one-time, %d min): %s'):format(g.tag, g.name, mins, url) },
        })
        dbg(('%s minted a web token for gang %d'):format(cid, mr.gang_id))
    end)

    local gangs, members = 0, 0
    pcall(function()
        local r = MySQL.single.await('SELECT COUNT(*) AS c FROM palm6_gangs')
        gangs = r and tonumber(r.c) or 0
        local m = MySQL.single.await('SELECT COUNT(*) AS c FROM palm6_gang_members')
        members = m and tonumber(m.c) or 0
    end)
    print(('[palm6_gangs] online — /%s opens the gang menu; %d gang(s), %d member(s) loaded'):format(
        Config.Command, gangs, members))
end)

-- ---------------------------------------------------------------------------
-- Server-only exports (tie-in surface for other resources + devtest).
-- ---------------------------------------------------------------------------

--- The player-run gang for a citizenid, or nil.
exports('GetGang', function(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    local mr = memberRow(citizenid)
    if not mr then return nil end
    local g = gangRow(mr.gang_id)
    if not g then return nil end
    return {
        id = g.id, name = g.name, tag = g.tag,
        rank = mr.rank, rankName = Config.RankName[mr.rank],
        rep = tonumber(g.rep) or 0, vault = tonumber(g.vault_balance) or 0,
        leaderCid = g.leader_cid,
    }
end)

--- True if both citizens are members of the SAME player-run gang.
exports('IsSameGang', function(cidA, cidB)
    if type(cidA) ~= 'string' or type(cidB) ~= 'string' then return false end
    local a = memberRow(cidA)
    if not a then return false end
    if cidA == cidB then return true end
    local b = memberRow(cidB)
    if not b then return false end
    return a.gang_id == b.gang_id
end)

--- Reward (or penalise) a gang's reputation. Server-only; other resources call
--- this to credit gang activity (turf held, protection collected, etc.).
--- Returns the new rep, or nil if the gang doesn't exist. Rep floors at 0.
exports('AddRep', function(gangId, amount, reason)
    gangId = tonumber(gangId)
    amount = math.floor(tonumber(amount) or 0)
    if not gangId or amount == 0 then return nil end
    local newRep
    local ok = pcall(function()
        local affected = MySQL.update.await(
            'UPDATE palm6_gangs SET rep = GREATEST(0, rep + ?) WHERE id = ?', { amount, gangId })
        if affected == 1 then
            local r = MySQL.single.await('SELECT rep FROM palm6_gangs WHERE id = ?', { gangId })
            newRep = r and tonumber(r.rep) or nil
        end
    end)
    if not ok or not newRep then return nil end
    dbg(('rep %+d on gang %d (%s) -> %d'):format(amount, gangId, tostring(reason), newRep))
    return newRep
end)

--- Totals for the /economy scoreboard, devtest, and a future dashboard.
exports('GetSummary', function()
    local out = { gangs = 0, members = 0, totalVault = 0, topRep = 0 }
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS c, COALESCE(SUM(vault_balance),0) AS v, COALESCE(MAX(rep),0) AS tr FROM palm6_gangs')
        if r then
            out.gangs = tonumber(r.c) or 0
            out.totalVault = tonumber(r.v) or 0
            out.topRep = tonumber(r.tr) or 0
        end
        local m = MySQL.single.await('SELECT COUNT(*) AS c FROM palm6_gang_members')
        out.members = m and tonumber(m.c) or 0
    end)
    return out
end)
