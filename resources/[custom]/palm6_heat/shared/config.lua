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

-- Consumers treat a citizen at/above this tier as "priority": louder dispatch,
-- extra launder scrutiny, etc. Exposed via the GetTier export; this is just the
-- documented threshold, not enforced here.
--
-- LIVE consumers today, both reading GetTier through the soft-dep guard:
--   palm6_laundering  Config.HeatScrutiny: the front skims extra off a HOT or
--                     WANTED launderer.
--   palm6_mdt         Config.CallPriority: the DISPATCH consumer this value was
--                     named for. A 911 call on the MDT's /calls board from a
--                     citizen at one of these tiers is marked and floated to the
--                     top. It ships OFF, and there is no palm6_dispatch resource
--                     to build: /calls already IS the dispatch surface.
-- Each consumer keeps its OWN copy of which tier strings count as priority
-- (a separate resource is a separate Lua state and cannot read this file);
-- this line stays the single documented source of what the threshold MEANS.
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
-- Housekeeping. Rows that have fully decayed are SETTLED to heat = 0, not
-- deleted: `heat` re-derives from updated_at on every read, but `lifetime` is a
-- cumulative career total that GetSummary sums and the README documents as part
-- of the frozen export contract, and deleting the row destroyed it. A separate
-- long-TTL prune keeps the table from growing without bound.
-- ---------------------------------------------------------------------------
Config.SweepIntervalMs = 300000  -- 5 min
Config.SweepRetainDays = 30      -- delete a settled (heat = 0) row only after it
                                 -- has sat untouched this long, i.e. a citizen
                                 -- who has committed no crime in a month

-- ---------------------------------------------------------------------------
-- SUGGESTED heat weights (REFERENCE ONLY — not enforced here).
--
-- This block used to say palm6_heat "ships UNWIRED" and that nothing calls
-- AddHeat. That has not been true for a long time. As of this writing the
-- export is wired in TEN resources:
--     palm6_robbery      atm_robbery     palm6_chopshop     chopshop
--     palm6_smuggling    smuggle_run     palm6_gunrunning   gun_deal
--     palm6_laundering   launder         palm6_protection   shakedown
--     palm6_drugs        drug_sale + drug_lab
--     palm6_counterfeit  counterfeit     palm6_ransom       kidnap_ransom
--     palm6_witnesses    reported_crime / shots_fired / intimidation
-- and GetTier is read by palm6_laundering (the front skims harder off a HOT or
-- WANTED launderer). palm6_witnesses is the important one: the heaviest crimes
-- (murder, bank, jewellery, house robbery) live in qbx_* resources that are not
-- in this repo, and its policeAlert shadow-listener is the only portable hook
-- that reaches them.
--
-- When wiring a NEW crime resource, have it call
--     exports.palm6_heat:AddHeat(citizenid, amount, reason, name)
-- at the moment it pays out / commits the crime, keyed to the ACTOR's own
-- citizenid, inside the soft-dep shape every existing wire uses:
--     if GetResourceState('palm6_heat') == 'started' then
--         pcall(function() exports.palm6_heat:AddHeat(cid, weight, 'reason') end)
--     end
-- These are sane starting amounts (a petty ATM job barely registers; a bank
-- heist maxes you out fast). Kept here so every wirer pulls from one table
-- instead of inventing numbers.
-- ---------------------------------------------------------------------------
Config.Suggested = {
    drug_sale        = 3,
    drug_lab         = 6,
    gun_deal         = 10,
    smuggle_run      = 12,
    counterfeit      = 8,
    launder          = 5,   -- REFERENCE ONLY, and no longer what palm6_laundering
                            -- charges: that wire is amount-proportional (see its
                            -- Config.PlayerHeat), because a launder run takes a
                            -- variable $500..$25,000 and a flat per-run charge
                            -- made one huge wash as quiet as a tiny one. Under
                            -- that wire a quiet wash spans 1 ($500) to 13
                            -- ($25,000) and hits exactly 5 at ~$8,000; 5 stays
                            -- here as the anchor a new FLAT-charge wirer would
                            -- size against, not as a value anything reads.
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
