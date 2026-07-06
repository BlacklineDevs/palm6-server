-- ============================================================================
-- gtarp_evidence/server/main.lua
--
-- Police evidence log + locker. The Phase 6 roadmap candidate
-- ("evidence-locker workflow extension for police") that was never built.
-- Pure logic — all framework/native access via Bridge.* (§6 gate). Our own
-- `gtarp_evidence` SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
-- ============================================================================

local STASH_ID = 'evidence_locker'

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Restrict to the police group and to the locker coords so ox_inventory
    -- enforces access itself; the server on-duty/proximity gate below is then
    -- a second layer, not the only one.
    Bridge.RegisterStash(STASH_ID, 'Evidence Locker', Config.LockerSlots, Config.LockerMaxWeight,
        { police = 0 }, Config.LockerCoords)
    print('[gtarp_evidence] evidence locker registered')
end)

RegisterCommand('logevidence', function(src, args)
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end
    local description = table.concat(args, ' ')
    if #description == 0 then
        Bridge.Notify(src, 'Evidence', 'Usage: /logevidence <description>', 'error')
        return
    end

    local cid = Bridge.GetCitizenId(src)
    local coords = Bridge.GetCoords(src)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO gtarp_evidence (citizenid, officer_name, description, coords) VALUES (?, ?, ?, ?)',
            { cid, Bridge.GetPlayerName(src), description, coords and json.encode(coords) or nil })
    end)

    if ok then
        Bridge.Notify(src, 'Evidence', 'Logged.', 'success')
    else
        Bridge.Notify(src, 'Evidence', 'Failed to log evidence.', 'error')
    end
end, false)

RegisterCommand('evidence', function(src)
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT officer_name, description, created_at FROM gtarp_evidence ORDER BY created_at DESC LIMIT ?',
            { Config.LogEntryLimit })
    end)

    if not ok or not rows or #rows == 0 then
        Bridge.Notify(src, 'Evidence', 'No evidence logged yet.', 'inform')
        return
    end

    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ('**%s** — %s\n_%s_'):format(r.officer_name, r.description, tostring(r.created_at))
    end
    TriggerClientEvent('gtarp_evidence:showLog', src, table.concat(lines, '\n\n'))
end, false)

RegisterNetEvent('gtarp_evidence:requestOpenLocker', function()
    local src = source
    if not Bridge.IsOnDutyPolice(src) then
        Bridge.Notify(src, 'Evidence', 'You need to be on duty as police.', 'error')
        return
    end
    local coords = Bridge.GetCoords(src)
    if not coords or Bridge.Distance(coords, Config.LockerCoords) > (Config.InteractRadius + 3.0) then
        Bridge.Notify(src, 'Evidence', 'You are too far from the locker.', 'error')
        return
    end
    TriggerClientEvent('gtarp_evidence:openLocker', src, STASH_ID)
end)
