-- ============================================================================
-- gtarp_staff/config.lua
--
-- Staff tooling owns:
--   - an audit log table (sql/0007_staff_log.sql)
--   - a Discord webhook fan-out for every logged staff action
--   - the exports.gtarp_staff:Log(...) sink other resources write to
--     (allowlist denials, eventguard violations, ...)
--
-- The staff CHAT COMMANDS this resource used to register (/tp /tpm /bring
-- /goto /revive /heal) were removed 2026-07-03: every one collided with a
-- command the Qbox recipe already registers (qbx_core /tp /tpm, qbx_medical
-- /revive /heal) or duplicated qbx_adminmenu's goto/bring menu actions. Use
-- the recipe's own commands/menu; this resource is now purely the audit-log
-- + webhook sink.
--
-- The webhook URL is read from a convar so it stays out of version control.
-- Set `gtarp:staff_webhook` in txAdmin's convar / secret store.
-- ============================================================================

Config = {}

-- Convar name we read the webhook URL from. Operator sets:
--   set gtarp:staff_webhook "https://discord.com/api/webhooks/XXX/YYY"
Config.WebhookConvar = 'gtarp:staff_webhook'
