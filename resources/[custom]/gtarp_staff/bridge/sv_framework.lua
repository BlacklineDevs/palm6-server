-- ============================================================================
-- gtarp_staff/bridge/sv_framework.lua
--
-- Framework + game adapter (server). The ONLY file in this resource that
-- touches player names or identifiers.
--
-- Core logic (server/main.lua) calls Bridge.* only, so the audit-log writes
-- (our own table) and the Discord webhook stay engine-agnostic. To port to
-- GTA VI, rewrite THIS FILE against the new identity API.
--
-- See docs/GTA6-READINESS.md (Section 3, the bridge pattern).
-- ============================================================================

Bridge = {}

-- Display name for a server source.
function Bridge.GetPlayerName(src)
    return GetPlayerName(src)
end

-- The player's license identifier if present, else their first identifier,
-- else nil. Used to label audit-log rows.
function Bridge.GetLicense(src)
    local ids = GetPlayerIdentifiers(src) or {}
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'license:' then return ids[i] end
    end
    return ids[1]
end
