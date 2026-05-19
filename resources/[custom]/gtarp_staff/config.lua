-- ============================================================================
-- gtarp_staff/config.lua
--
-- Staff tooling owns:
--   - lightweight chat commands that staff can run (bring, goto, freeze, etc.)
--   - an audit log table (sql/0007_staff_log.sql)
--   - a Discord webhook fan-out for every staff action
--
-- The webhook URL is read from a convar so it stays out of version control.
-- Set `gtarp:staff_webhook` in txAdmin's convar / secret store.
-- ============================================================================

Config = {}

-- Convar name we read the webhook URL from. Operator sets:
--   set gtarp:staff_webhook "https://discord.com/api/webhooks/XXX/YYY"
Config.WebhookConvar = 'gtarp:staff_webhook'

-- Default ACE permission node required to invoke any /staff:* command.
-- Per-command nodes (command.tp, command.bring, etc.) are also enforced.
Config.AceBaseNode = 'command.staff'

-- Each entry: { command = 'name', ace = 'command.<name>', help = '...' }
-- The handler function is wired in server/main.lua and dispatched on this
-- table — keeping the registration in one place.
Config.Commands = {
    { command = 'tp',      ace = 'command.tp',      help = '/tp <id>  teleport to player' },
    { command = 'tpm',     ace = 'command.tpm',     help = '/tpm      teleport to map waypoint' },
    { command = 'bring',   ace = 'command.bring',   help = '/bring <id>  bring player to you' },
    { command = 'goto',    ace = 'command.goto',    help = '/goto <id>   teleport to player (alias of /tp)' },
    { command = 'revive',  ace = 'command.revive',  help = '/revive <id> revive player' },
    { command = 'heal',    ace = 'command.heal',    help = '/heal <id>   heal player' },
}
