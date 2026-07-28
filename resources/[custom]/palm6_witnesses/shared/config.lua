-- ============================================================================
-- palm6_witnesses/shared/config.lua — engine-agnostic tunables (Tier 1,
-- carries to VI). Every crime leaves living NPC witnesses; police canvass
-- them for partial suspect facts, criminals press or pay them off.
--
-- Design intent: the witness layer is TESTIMONIAL ONLY. Physical forensics
-- (casings / blood / fingerprints) belong to qbx_police's evidence system
-- (client/evidence.lua) and are deliberately NOT captured here. Plate facts
-- are PARTIAL (3 chars max) so qbx_police ANPR stays the full-plate source.
-- Everything a witness "knows" is snapshotted and stored SERVER-SIDE at
-- crime time — the peds on screen are just markers; a modified client can
-- never invent, read, or destroy testimony.
-- ============================================================================
Config = {}

Config.Debug = false

-- ---------------------------------------------------------------------------
-- The event bus: which crimes create witnesses.
--
-- weaponDamage rides the built-in server game event (weaponDamageEvent) —
-- gunfire and armed assaults. The named entries shadow-listen on net events
-- fired by other resources (we validate nothing for them; the owning
-- resource does — we only snapshot bystanders).
--
-- `qbxAlerts = true` marks crimes the recipe ALREADY rolls its own
-- NPC-reported police alerts for (qbx_storerobbery's alertPolice(),
-- qbx_drugs cornerselling's policeCallChance — both fire
-- police:server:policeAlert themselves). palm6_witnesses must never fire a
-- SECOND alert for those, so alert eligibility is per-hook and the global
-- switch below defaults OFF. Witness creation itself is always silent:
-- the value is the canvass, not a 911 ping.
-- ---------------------------------------------------------------------------
Config.Hooks = {
    -- Fired by qbx resources (storerobbery registers/safes, drugs corner
    -- selling, jewelery, houserobbery, bankrobbery) — they all funnel
    -- through police:server:policeAlert. Hooking the alert event itself
    -- covers every robbery-style trigger in the recipe with zero coupling.
    policeAlert = {
        enabled = true,
        crime = 'reported_crime',
        label = 'a reported crime',
        qbxAlerts = true,          -- the alert we hooked IS the qbx alert
    },
    -- Server game event: a player damaged something with a weapon while
    -- armed. Fist fights are ignored.
    weaponDamage = {
        enabled = true,
        crime = 'shots_fired',
        label = 'shots fired',
        qbxAlerts = false,         -- qbx_police logs casings client-side but
                                   -- rolls no NPC 911 call for gunfire
    },
    -- Our own custom layer: ATM robberies. palm6_robbery already sends its
    -- own dispatch to police, so this hook is alert-ineligible too.
    -- SERVER-ONLY event: palm6_robbery TriggerEvent()s it after every start
    -- gate passes (never the raw, forgeable 'palm6_robbery:start' net event).
    palm6Robbery = {
        enabled = true,
        event = 'palm6_robbery:started',
        crime = 'atm_robbery',
        label = 'an ATM robbery',
        qbxAlerts = true,          -- palm6_robbery fires its own dispatch
    },
}

-- 911 layer for crimes nothing else alerts on. When true, hooks with
-- qbxAlerts = false fire ONE police:server:policeAlert when witnesses
-- actually saw the crime. Hooks with qbxAlerts = true never re-alert
-- regardless of this switch.
--
-- Double-alert verification (the condition the duplication review set for
-- enabling this): no resource in the deployed recipe tree handles
-- weaponDamageEvent / CEventGunShot / gunfire at all, so shots_fired has no
-- competing recipe alert. qbx_vehiclekeys' theft alert can coincide with a
-- shots_fired alert during an armed carjacking, but those are distinct
-- crimes, and the per-suspect IncidentCooldownSec below caps the rate.
Config.FirePoliceAlerts = true

-- ---------------------------------------------------------------------------
-- Persistent police attention (palm6_heat) for a witnessed crime.
--
-- WHY THIS HOOK EXISTS. The heaviest crimes on this server (murder, the bank
-- job, the jewellery store, house robberies) live in qbx_* resources that are
-- NOT part of this repo, so there is no file to add a one-line AddHeat to. They
-- all funnel through police:server:policeAlert, and this resource already
-- shadow-listens on it. finalizeIncident is therefore the single portable point
-- where a crime the base recipe owns becomes a durable, server-side FACT with a
-- suspect citizenid attached, which makes it the right place to score heat.
--
-- WHAT THE BUS ACTUALLY CARRIES. `reported_crime` is NOT "the qbx robbery
-- fan-in": police:server:policeAlert is a shared bus, and seven IN-REPO
-- resources raise it too (palm6_business, palm6_counterfeit, palm6_drugs,
-- palm6_laundering, palm6_protection, palm6_smuggling and this one, each from
-- its own bridge/sv_framework.lua). Five of those call AddHeat on the very same
-- code path, so scoring every alert here would have charged a flagged wash, a
-- flagged street sale, a shakedown, a cook start and a smuggling run TWICE, and
-- would have put a store-robbery-sized 15 on counterfeit and business printing
-- runs that are deliberately priced elsewhere or not at all.
--
-- THE SUPPRESSION LATCH. Instead of listing those emitters (a list that rots the
-- moment a new palm6 resource calls Bridge.PoliceAlert), server/main.lua's
-- policeAlert hook passes its existing `isServerCall` discriminator through to
-- reportCrime as `emitterOwnsHeat`. Every in-repo emitter uses a SERVER-side
-- TriggerEvent with an explicit playerSource; the qbx robbery clients this hook
-- exists for fire the alert from the CLIENT, so the suspect is the caller. A
-- server-side alert therefore still creates witnesses and testimony, it just
-- does not get charged heat here, because its owning resource already did that
-- or deliberately does not price it. This is the cross-resource form of the
-- `selfAlerting` latch that keeps our OWN opt-in alert from echoing back.
-- Failure direction is safe: a future out-of-repo resource that alerted
-- server-side would be under-charged, never double-charged.
--
-- Weights are keyed by the hook's `crime` string. A crime with NO entry here
-- scores nothing, which is deliberate:
--   * `sim`         : the /witnesses sim QA path must never move a real score.
--   * `atm_robbery` : this crime does NOT arrive on the alert bus (palm6_robbery
--                     dispatches through its own palm6_robbery:dispatch event);
--                     it reaches us on the dedicated palm6Robbery hook above,
--                     fired by palm6_robbery/server/main.lua:58, which also
--                     calls AddHeat at :93. Listing it here would double-charge.
-- Sibling resources feeding the bus via the ReportCrime export are unlisted for
-- the same reason: they own their own AddHeat wire if they want one.
--
-- ANTI-FARM, inherited for free: Config.IncidentCooldownSec caps reported_crime
-- and shots_fired at one scoring incident per suspect per window, so a robbery
-- that also involves gunfire cannot score both inside the same window. It is a
-- witnesses-side per-suspect cap only, and it knows nothing about another
-- resource's wire, which is why the suppression latch above is needed and not
-- optional.
--   EXCEPTION, do not assume otherwise: the cooldown is SKIPPED whenever
-- witnessCoordsOverride is set (server/main.lua's reportCrime), and the
-- intimidation path is exactly that case. intimidation heat is therefore
-- bounded by available active witnesses and the palm6_witnesses:press:finish
-- eventguard budget, NOT by the 120s incident window. That is tolerable only
-- because intimidation is SELF-heat: raising your own police attention is a
-- penalty, and the policeAlert trust boundary means a modded client can never
-- aim it at someone else. Revisit this the day intimidation scores a third
-- party.
--   Two further brakes apply to every weight here: MinWitnesses means an unseen
-- crime scores nothing, and the policeAlert trust boundary in server/main.lua
-- means a modded client can only ever mint heat against ITSELF, never another
-- player.
-- ---------------------------------------------------------------------------
Config.Heat = {
    Enabled = true,

    -- Police doing police work are not criminals. weaponDamageEvent fires for
    -- an officer returning fire in a shootout exactly as it does for the robber,
    -- so on-duty police are exempt from the heat wire (they still generate
    -- witnesses and testimony, which is the point of this resource).
    ExemptOnDutyPolice = true,

    -- crime string -> heat points. Sized against palm6_heat's Config.Suggested.
    Weights = {
        reported_crime = 15,  -- Suggested.store_robbery. Only client-fired
                              -- alerts reach this weight (see the suppression
                              -- latch above), i.e. the qbx store/house/bank/
                              -- jewellery jobs it was sized for.
        shots_fired    = 18,  -- Suggested.assault, an armed assault someone saw
        intimidation   = 10,  -- leaning on a witness in front of another witness
    },
}

-- ---------------------------------------------------------------------------
-- Witness snapshot
-- ---------------------------------------------------------------------------
Config.WitnessRadius       = 40.0 -- NPC peds within this range of the crime
Config.MinWitnesses        = 1    -- fewer eligible NPCs = the crime went unseen
Config.MaxWitnesses        = 4    -- hard cap per incident
Config.WitnessTtlMin       = 30   -- minutes a witness marker persists
Config.IncidentCooldownSec = 120  -- one incident per suspect per this window
                                  -- (a magazine dump is one crime, not thirty)

-- Facts a witness can hold. Each witness is dealt FactsPerWitnessMin..Max
-- distinct facts from whatever the suspect actually exposed (on foot = no
-- vehicle facts). Partial plates are clamped to PlateChars characters.
Config.FactsPerWitnessMin = 1
Config.FactsPerWitnessMax = 2
Config.PlateChars         = 3

-- Coarse clothing-colour vocabulary. The reported colour derives
-- DETERMINISTICALLY from the suspect ped's real torso drawable/texture
-- variation (same outfit = same statement every time), bucketed into this
-- street-level vocabulary — witnesses say "a dark top", not RGB values.
Config.TopColors = {
    'dark', 'light', 'red', 'blue', 'green', 'grey', 'brown', 'white',
}

-- Vehicle classes as a witness would describe them, keyed by the
-- server-side vehicle type string.
Config.VehicleClassLabels = {
    automobile = 'a car',
    bike       = 'a motorcycle',
    heli       = 'a helicopter',
    plane      = 'a plane',
    boat       = 'a boat',
    quadbike   = 'a quad bike',
    bicycle    = 'a bicycle',
    trailer    = 'a trailer',
    train      = 'a train',
    submarine  = 'a submarine',
}

-- ---------------------------------------------------------------------------
-- Police canvass
-- ---------------------------------------------------------------------------
Config.Canvass = {
    Radius      = 2.5,   -- client prompt range at a witness marker
    DurationSec = 5,     -- the doorstep interview takes this long
    GraceSec    = 15,    -- server tolerance past DurationSec (latency)
    CooldownSec = 6,     -- per-character canvass cooldown
}

-- Case-file integration (palm6_evidence v2 exports). Cases are created
-- LAZILY: the first canvass of an incident calls EnsureCase with the
-- incident's stable key, so uncanvassed incidents never leave empty cases.
Config.Evidence = {
    Source   = 'palm6_witnesses',        -- AppendEntry source tag
    TitleFmt = 'Witness canvass — %s',   -- %s = crime label
}

-- ---------------------------------------------------------------------------
-- Criminal counterplay. Only the incident's OWN suspect can press or pay
-- off its witnesses (server-enforced) — you cannot scrub someone else's
-- crime scene.
-- ---------------------------------------------------------------------------
Config.Press = {
    Radius       = 8.0,  -- how close the suspect must be to the marker
    AimSec       = 5,    -- weapon must stay aimed this long
    GraceSec     = 15,   -- server tolerance past AimSec
    AnchorRadius = 4.0,  -- max drift between press start and finish
    CooldownSec  = 30,   -- per-character press cooldown
    -- A pressed witness either clams up entirely or feeds police corrupted
    -- facts (wrong colour, flipped mask, scrambled plate). Chance the
    -- canvass still yields (corrupted) facts rather than nothing:
    CorruptedFactChance = 0.5,
}

Config.Payoff = {
    Radius      = 2.5,
    Price       = 750,   -- cash, charged server-side
    CooldownSec = 15,    -- per-character payoff cooldown
}

-- Pressing a witness in view of ANOTHER witness creates a fresh
-- intimidation incident against the presser. "In view" is approximated
-- server-side as another active witness within this range of the pressed
-- one (there is no server-side raycast; radius is the honest proxy).
Config.Intimidation = {
    WitnessRadius = 25.0,
    CrimeLabel    = 'witness intimidation',
}

-- ---------------------------------------------------------------------------
-- Presentation (Tier 3 — blip sprites are GTA V values)
-- ---------------------------------------------------------------------------
Config.PoliceBlip  = { sprite = 480, colour = 47, scale = 0.75, label = 'Witness' }
Config.SuspectBlip = { sprite = 480, colour = 1,  scale = 0.75, label = 'They saw you' }
Config.MarkerDrawDistance = 30.0   -- draw the ground marker inside this range

-- How often clients re-request their entitled witness list (seconds).
-- Event pushes cover the common case; this timer covers duty toggles and
-- late joins without any per-frame cost.
Config.ClientSyncSec = 60

-- ---------------------------------------------------------------------------
-- Anti-spam. palm6_eventguard exposes no registration export for new
-- events (its guard list is its own static config, and we stay out of
-- other resources' files), so — per the palm6_pumpcoin pattern — every
-- client-triggerable event here carries its own per-source rate limit AND
-- per-citizen cooldown, all server-side.
-- ---------------------------------------------------------------------------
Config.RateLimits = {   -- seconds, per source
    sync    = 10,
    canvass = 2,
    press   = 2,
    payoff  = 2,
    policeAlert = 10,   -- the police:server:policeAlert fan-in hook (it is
                        -- client-triggerable, so it needs its own limiter)
}

-- weaponDamageEvent fires per damage tick. When a crime goes unseen the
-- incident cooldown is refunded (by design), so this separate per-citizen
-- throttle caps how often the expensive GetAllPeds NPC scan can run.
Config.WeaponScanThrottleSec = 10
