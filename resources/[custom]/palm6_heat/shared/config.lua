-- ============================================================================
-- palm6_heat/shared/config.lua — engine-agnostic tunables (Tier 1, carries to
-- VI). There are NO Los Santos coords here: heat is a pure number that lives
-- in a table, so every value below is framework-free and portable.
--
-- WHAT THIS RESOURCE IS
-- The crime loop mints money and reputation but, until now, no LASTING police
-- attention — heat was transient (a live chase, then gone). palm6_heat is the
-- durable per-citizen "heat" score: crime raises it (via the AddHeat export),
-- wall-clock time bleeds it off, and police / dispatch / the season Most-Wanted
-- ladder read it. It writes ONLY its own table and never edits a crime file, so
-- a fault here can never break the crime layer (the palm6_wanted/ems pattern).
-- ============================================================================
Config = {}

Config.Debug = false

-- ---------------------------------------------------------------------------
-- Heat scale + decay (all server-authoritative, all wall-clock).
--
-- Heat is stored as an integer plus the row's updated_at. Effective heat is
-- computed on READ as: stored - floor(minutes_since_update * DecayPerMin),
-- floored at 0 — so the DB is only written when heat is ADDED (or swept), never
-- once per tick per citizen. Getting arrested/dying does NOT clear heat; only
-- time does. That is the whole point: crime should follow you home.
-- ---------------------------------------------------------------------------
Config.HeatCap = 150         -- hard ceiling on a citizen's heat
Config.DecayPerMin = 0.75    -- points shed per minute of no new crime
                             -- (150 cap -> ~3h20m to fully cool from maxed out)
Config.MaxAddPerCall = 60    -- clamp on any single AddHeat() call — a buggy or
                             -- hostile caller can never spike someone past this
                             -- in one hit (defence in depth; callers self-cap too)

-- ---------------------------------------------------------------------------
-- Tiers. Effective heat maps to a tier, highest threshold that fits wins.
-- Keep sorted DESCENDING by `min`. `tier` is the frozen string other resources
-- branch on (dispatch priority, launder scrutiny); `label`/`color` are display.
-- ---------------------------------------------------------------------------
Config.Tiers = {
    { min = 110, tier = 'WANTED', label = 'WANTED',   color = { 235, 90, 90 } },
    { min = 65,  tier = 'HOT',    label = 'Hot',       color = { 235, 140, 90 } },
    { min = 30,  tier = 'WARM',   label = 'Warm',      color = { 230, 195, 90 } },
    { min = 1,   tier = 'COOL',   label = 'Cooling',   color = { 150, 190, 150 } },
    { min = 0,   tier = 'CLEAN',  label = 'Clean',     color = { 150, 160, 175 } },
}

-- Consumers (palm6_dispatch, palm6_laundering) treat a citizen at/above this
-- tier as "priority": louder dispatch, extra launder heat, etc. Exposed via the
-- GetTier export; this is just the documented threshold, not enforced here.
Config.DispatchPriorityTier = 'HOT'

-- ---------------------------------------------------------------------------
-- Police board (/heat) + self-check (/myheat).
-- ---------------------------------------------------------------------------
Config.Board = {
    Top     = 15,   -- rows shown on the /heat priority board
    ScanCap = 80,   -- rows pulled before decay+re-sort (over-fetch: a stale
                    -- high row can decay below a fresh lower one, so we decay
                    -- ScanCap candidates in Lua, then take the true Top)
}

Config.PoliceJob = 'police'   -- who may run /heat (also gated by on-duty in bridge)

Config.Command = {
    Police = 'heat',    -- on-duty police: live priority board of the hottest citizens
    Self   = 'myheat',  -- any citizen: your own heat, tier, and cool-down ETA
}

Config.RateLimits = {   -- seconds between repeats of a command, per source
    heat   = 3,
    myheat = 5,
}

Config.TextClamp = 48   -- max length of a stored/displayed reason string

-- ---------------------------------------------------------------------------
-- Housekeeping. Rows that have fully decayed to 0 are pruned so the table stays
-- small; correctness never depends on this (reads always re-derive from
-- updated_at), it is pure cleanup.
-- ---------------------------------------------------------------------------
Config.SweepIntervalMs = 300000  -- 5 min

-- ---------------------------------------------------------------------------
-- SUGGESTED heat weights (REFERENCE ONLY — not enforced here).
-- palm6_heat is shipped UNWIRED: it exposes AddHeat and nothing calls it yet.
-- When wiring a crime resource, have it call
--     exports.palm6_heat:AddHeat(citizenid, amount, reason, name)
-- at the moment it pays out / commits the crime. These are sane starting
-- amounts (a petty ATM job barely registers; a bank heist maxes you out fast).
-- Kept here so every wirer pulls from one table instead of inventing numbers.
-- ---------------------------------------------------------------------------
Config.Suggested = {
    drug_sale        = 3,
    drug_lab         = 6,
    gun_deal         = 10,
    smuggle_run      = 12,
    counterfeit      = 8,
    launder          = 5,
    shakedown        = 6,
    atm_robbery      = 8,
    store_robbery    = 15,
    house_robbery    = 20,
    chopshop         = 12,
    jewelry_heist    = 35,
    armored_truck    = 40,
    bank_heist       = 55,
    kidnap_ransom    = 45,
    assault          = 18,
    murder           = 60,
}
