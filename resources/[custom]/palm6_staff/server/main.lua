-- ============================================================================
-- palm6_staff/server/main.lua
--
-- Audit-log sink: writes staff/security actions to the audit_log table and
-- fans out to a Discord webhook (URL via convar). Other resources append
-- through exports.palm6_staff:Log(action, actorSrc, targetSrc, detail).
--
-- This resource no longer registers chat commands — the Qbox recipe already
-- ships /tp /tpm (qbx_core), /revive /heal (qbx_medical) and goto/bring via
-- qbx_adminmenu; registering them here overrode the recipe handlers.
-- ============================================================================

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql, per-statement pcall, CREATE TABLE IF NOT
-- EXISTS so re-runs are harmless no-ops.
--
-- Why this resource in particular: sql/ is applied BY HAND (deploy/README.md)
-- and CI never touches the DB, so a restored backup or a new box boots with no
-- audit_log. This is the sink EVERY other resource writes its security trail
-- into (allowlist denials, eventguard kicks, pumpcoin rug reveals) - losing it
-- silently means losing the record of exactly the events you would later need
-- to reconstruct. On the live box this statement is a pure no-op.
--
-- DDL copied VERBATIM from sql/0007_staff_log.sql.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local ok, err = pcall(function()
        MySQL.query.await([[
CREATE TABLE IF NOT EXISTS `audit_log` (
    `id`                INT AUTO_INCREMENT PRIMARY KEY,
    `action`            VARCHAR(50) NOT NULL,
    `actor_name`        VARCHAR(100) DEFAULT NULL,
    `actor_identifier`  VARCHAR(100) DEFAULT NULL,
    `target_name`       VARCHAR(100) DEFAULT NULL,
    `target_identifier` VARCHAR(100) DEFAULT NULL,
    `detail`            TEXT,
    `created_at`        DATETIME NOT NULL,
    KEY `idx_action_time` (`action`, `created_at`),
    KEY `idx_actor`       (`actor_identifier`),
    KEY `idx_target`      (`target_identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
    end)
    if not ok then
        print(('^1[palm6_staff] schema init FAILED -> %s^0'):format(tostring(err)))
    end
    SchemaReady = ok
    return ok
end

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
        username = 'palm6-staff',
    })
    PerformHttpRequest(url, function(status)
        if status >= 400 then
            print(('[palm6_staff] webhook %s -> HTTP %d'):format(action, status))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        -- The banner names the schema state explicitly. "online" with a missing
        -- table was the old behaviour and it read as healthy while every Log()
        -- call threw into its caller's pcall and vanished.
        print(('[palm6_staff] audit-log sink %s; webhook=%s'):format(
            SchemaReady and 'online' or 'ONLINE BUT SCHEMA MISSING (audit_log absent)',
            GetConvar(Config.WebhookConvar, '') ~= '' and 'set' or 'unset'
        ))
    end)
end)

-- Public export so other resources (allowlist denials, eventguard kicks,
-- pumpcoin rug reveals, ...) write to the same audit log.
exports('Log', log)
