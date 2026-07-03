-- ============================================================================
-- gtarp_staff/server/main.lua
--
-- Audit-log sink: writes staff/security actions to the audit_log table and
-- fans out to a Discord webhook (URL via convar). Other resources append
-- through exports.gtarp_staff:Log(action, actorSrc, targetSrc, detail).
--
-- This resource no longer registers chat commands — the Qbox recipe already
-- ships /tp /tpm (qbx_core), /revive /heal (qbx_medical) and goto/bring via
-- qbx_adminmenu; registering them here overrode the recipe handlers.
-- ============================================================================

local function actorName(src)
    if src == 0 then return 'console' end
    local name = Bridge.GetPlayerName(src) or ('player:%d'):format(src)
    return name
end

local function actorIdentifier(src)
    if src == 0 then return 'console' end
    return Bridge.GetLicense(src) or ('src:%d'):format(src)
end

local function log(action, actorSrc, targetSrc, detail)
    local actor_name = actorName(actorSrc)
    local actor_id   = actorIdentifier(actorSrc)
    local target_name = targetSrc and actorName(targetSrc) or nil
    local target_id   = targetSrc and actorIdentifier(targetSrc) or nil

    MySQL.insert.await(
        "INSERT INTO audit_log (action, actor_name, actor_identifier, target_name, target_identifier, detail, created_at) VALUES (?,?,?,?,?,?, NOW())",
        { action, actor_name, actor_id, target_name, target_id, detail or '' }
    )

    local url = GetConvar(Config.WebhookConvar, '')
    if url == '' then return end
    local payload = json.encode({
        embeds = { {
            title = ('staff: %s'):format(action),
            description = ('actor=%s target=%s detail=%s'):format(
                actor_name, tostring(target_name or '-'), detail or '-'),
            color = 5814783, -- dark blue
        } },
        username = 'gtarp-staff',
    })
    PerformHttpRequest(url, function(status)
        if status >= 400 then
            print(('[gtarp_staff] webhook %s -> HTTP %d'):format(action, status))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print(('[gtarp_staff] audit-log sink online; webhook=%s'):format(
        GetConvar(Config.WebhookConvar, '') ~= '' and 'set' or 'unset'
    ))
end)

-- Public export so other resources (allowlist denials, eventguard kicks,
-- pumpcoin rug reveals, ...) write to the same audit log.
exports('Log', log)
