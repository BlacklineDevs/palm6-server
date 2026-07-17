-- ============================================================================
-- palm6_onboarding/shared/config.lua — engine-agnostic tunables (Tier 1, carries to VI).
-- ============================================================================
Config = {}

Config.Debug = false

-- Rate limit on the accept-rules net event (server-authoritative; a real
-- accept only ever fires once per citizen, this just bounds retry/replay
-- spam from a modified client).
Config.AcceptCooldownSec = 5

Config.Rules = {
    header = 'City Rules',
    -- Plain-text content shown in the mandatory first-load dialog and via
    -- /rules any time after. Edit for your server's real rules. Kept short
    -- on purpose — a wall of legalese gets skimmed, not read.
    content = table.concat({
        '1. **Roleplay first.** Stay in character. Metagaming and powergaming break the story for everyone else.',
        '2. **Fear for your life.** Take fights, arrests, and injuries seriously — no combat logging, no instant-forgetting a robbery at gunpoint.',
        '3. **New Life Rule.** A character who dies loses memory of the events leading to it.',
        '4. **No exploiting.** Bugs, dupes, and out-of-bounds areas get reported to staff, not abused.',
        '5. **Staff calls are final in the moment.** Disagree after the fact via a ticket, not in the moment.',
        '',
        'Breaking these gets you warned, then kicked, then banned. Full rules and the ban-appeal process are pinned in Discord.',
    }, '\n'),
}

-- Short post-accept tour — kept accurate to what this server actually has.
-- Update this list if a referenced command/system is renamed or removed.
Config.Tour = {
    header = 'Getting Started',
    content = table.concat({
        'Bank & cash — check your phone/inventory for your balance; ATMs are marked on the map.',
        'Jobs — visit a job center or the relevant NPC to get started; `/rules` re-shows this text anytime.',
        'Lost? Type `/help` for the full list of city commands — jobs, crews, EMS billing, bounties, the lottery, and more.',
        'Need help? Ping staff in Discord — an admin can `/tp` to you if something is stuck.',
        'Planning on going into law enforcement? The MDT (`/mdt`) is your case log, warrants, and BOLOs once on duty.',
    }, '\n'),
}

Config.StarterCash = {
    enabled = true,
    amount = 1500,
    account = 'bank',
    reason = 'onboarding-starter-cash',
}

-- One-time starter vehicle, granted on first-ever onboarding right after the
-- starter cash. Uses qbx_vehicles' CreatePlayerVehicle export (owned vehicle,
-- stored in a garage) — NOT a raw player_vehicles INSERT, so it stays correct
-- across qbx schema changes. If qbx_vehicles is absent, the grant silently
-- no-ops and cash still lands (see bridge/sv_framework.lua).
--
-- `model`  — a cheap, base-game, legal economy car. Keep it modest: this is a
--            get-you-moving car, not a reward. `blista` is a reliable compact.
-- `garage` — the public garage the car is parked in. MUST match a real garage
--            name in the deployed qbx_garages config; confirm in-game before
--            enabling in prod. `motelgarage` is the common Qbox central public
--            garage; override if Palm6 renamed it.
Config.StarterVehicle = {
    enabled = true,
    model = 'blista',
    garage = 'motelgarage',
    -- Player-facing name for the garage in the tour message (the internal
    -- `garage` key is not friendly). Purely cosmetic.
    garageLabel = 'motel',
    reason = 'onboarding-starter-vehicle',
}

-- One-time starter outfit. OFF by default: illenium-appearance's saved-outfit
-- format is version-specific, so forcing/saving a default outfit is deferred
-- until validated in-game. New characters already run illenium's first-spawn
-- appearance creator, so they pick clothes regardless of this flag.
Config.StarterOutfit = {
    enabled = false,
}
