-- ============================================================================
-- gtarp_robbery/shared/config.lua
--
-- ATM robberies with a police dispatch alert. Rob an ATM while armed, hold
-- through a timer, and collect cash. A dispatch pings on-duty police; a
-- minimum-cops gate is configurable.
--
-- Store/register robbery is intentionally NOT here — the recipe's own
-- `qbx_storerobbery` already does that at these exact store locations
-- (registers, safes, cameras, lockpick requirement, cop-count gate). Confirmed
-- by reading `resources/[qbx]/qbx_storerobbery` directly, not just its
-- config — see the "verify against the real deployed tree" lesson in
-- docs/DEVELOPMENT.md. An earlier draft of this resource duplicated it; that
-- half was removed before merge.
--
-- DESIGN (reward, timer, cooldown, dispatch rules) is Tier 1 and carries.
-- The ATM coords are Tier 3 (Los Santos points) — mirrored in
-- docs/GTA6-TIER3-RETUNE.md.
-- ============================================================================

Config = {}

Config.Debug = false

-- Minimum on-duty police required before a robbery can start.
-- 0 = solo-testable (a robbery works with no cops online). Raise for live
-- (2–3 is typical for a small serious-RP server).
Config.MinPolice = 0

-- Interaction radius (metres) for an ATM.
Config.InteractRadius = 1.8

-- The player must be holding a weapon (not fists/unarmed) to start a robbery.
Config.RequireWeapon = true

-- Police dispatch: blip lifetime + label.
Config.Dispatch = { blipSprite = 161, blipColour = 1, blipScale = 1.2,
                    label = 'Robbery in progress', durationSeconds = 90 }

-- ---------------------------------------------------------------------------
-- ATMs — small payout, short hold, short cooldown.
-- ---------------------------------------------------------------------------
Config.ATMs = {
    hold_seconds  = 6,
    cooldown_secs = 600,             -- 10 min per ATM
    reward_min    = 150,
    reward_max    = 400,
    locations = {
        -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
        { label = 'ATM — Legion Sq',    coords = vector3(147.43, -1035.79, 29.34) },
        -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
        { label = 'ATM — Del Perro',    coords = vector3(-1205.35, -325.24, 37.87) },
        -- retuned 2026-07-10 — VERIFY IN-GAME (on-ground/reachable)
        { label = 'ATM — Sandy Shores', coords = vector3(1822.51, 3683.11, 34.28) },
    },
}
