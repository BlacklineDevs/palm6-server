-- ============================================================================
-- palm6_business/shared/config.lua — engine-agnostic tunables.
--
-- DESIGN INTENT — the player-owned BUSINESS layer neither Qbox nor qbx_management
-- ships. qbx_management provides society bank accounts + boss menus for the
-- whitelisted JOBS (police/EMS/mechanic). It has NO concept of a civilian
-- business a player REGISTERS and RUNS: a registry, an account, employees,
-- payroll, walk-in revenue, and a ledger. That is this resource's scope, built
-- on our own tables (palm6_businesses / palm6_business_members /
-- palm6_business_ledger) — the same player-run-org shape as palm6_gangs.
--
-- MONEY SAFETY: a business is a POOLED REAL-MONEY account (like a gang vault),
-- never a printer. Money enters only via owner deposit, customer charge, and the
-- ONE capped NPC-income faucet (§ below). See docs/superpowers/specs/
-- 2026-07-20-palm6-business-design.md §2 for the full invariant list.
-- ============================================================================
Config = {}

Config.Debug = false

-- MASTER GATE. false = prod-inert: commands refuse, net events early-return,
-- nothing player-facing registers. Flip true (+ redeploy) to go live, batched
-- with a feel-test. Mirrors the palm6_racing / palm6_fc_core dark-ship idiom.
Config.Enabled = false

-- PHASE 1 GATE — physical storefronts (map location + blip + walk-up target;
-- proximity-gated management; storefront-anchored serving). Independent of
-- Config.Enabled so enabling Phase 0 does NOT auto-enable storefronts: BOTH must
-- be true for any storefront code path to run. Flip true (+ redeploy) only after
-- the Phase 1 feel-test. false = Phase 0 behaves exactly as it does today (a
-- business with no storefront row is indistinguishable from a Phase-0 business).
Config.Phase1Enabled = false

-- PER-TYPE MECHANICS GATE — gives each business type its own economic identity
-- (payout / supply cost / cooldown / daily cap / supply cap) and a themed serve
-- interaction (verb, nouns, skill-check), instead of all five sharing the Phase-0
-- numbers. INDEPENDENT of the storefront gate. While false, opServe/opBuyStock use
-- the GLOBAL Config values below EXACTLY as today — the LIVE Phase-0 economy is
-- byte-for-byte unchanged. Flip true (+ redeploy) only after a per-type feel-test.
-- Every serve stays bounded the same four ways (cost basis + clocked-in worker +
-- per-worker cooldown + atomic per-business daily cap); this only changes the
-- NUMBERS per type, never the invariants — no new faucet, no new exploit surface.
Config.PerTypeMechanics = false

-- Command that opens the business menu (+ a short alias).
Config.Command = 'business'
Config.CommandAlias = 'biz'

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
-- One-time fee to register a business, charged from the founder's BANK (server
-- re-validates affordability before creating). A clean-money SINK. Set 0 = free.
Config.RegistrationCost = 75000

-- Name: 3-48 chars after sanitising to letters/digits/spaces/&'- (collapsed).
Config.NameMinLen = 3
Config.NameMaxLen = 48

-- Case-insensitive substring blocklist for the business name (first-line
-- profanity/impersonation filter — staff can still close via DB). Mirrors the
-- palm6_gangs blocklist.
Config.Blocklist = {
    'nigger', 'faggot', 'retard', 'rape', 'nazi', 'hitler', 'kkk',
    'cunt', 'admin', 'staff', 'police', 'server',
}

-- Business catalog. `label` shows in the register picker + roster. `flavor` is
-- cosmetic copy. All types share the same mechanics in Phase 0 (the difference
-- is roleplay identity + future storefront/venue hooks in Phase 1). Extensible.
-- `blip` = the DEFAULT map-blip sprite for a new storefront of this type (Phase 1;
-- the owner can re-pick from Config.Storefront.Sprites). All sprite ids are
-- validated against the allowlist on write, so an unknown value here is inert.
--
-- `service` = the per-type ECONOMIC PROFILE + themed serve interaction, applied
-- only when Config.PerTypeMechanics is true (else the global Config.* values below
-- are used for every type — the live Phase-0 numbers). Each profile keeps the same
-- faucet shape, just different values: fast/cheap/high-volume (restaurant, retail)
-- vs slow/expensive/big-ticket (garage, dealership). `skill` is the ox_lib
-- skillCheck spec for that type's serve (difficulty list + input keys). Labels
-- theme the UI + notifications + ledger memo. dailyCap here overrides the per-type
-- NPC income ceiling; maxSupply the per-type storage cap.
Config.Types = {
    { key = 'restaurant', label = 'Restaurant',   flavor = 'Serve the city. Keep the lights on.',            blip = 93,
      service = { payout = 280,  stockCost = 110, cooldown = 30,  dailyCap = 16000, maxSupply = 600,
                  verb = 'Serve a plate',  serveNoun = 'diner',    supplyNoun = 'ingredients',
                  skill = { difficulty = { 'easy', 'easy' },            keys = { 'w', 'a', 's', 'd' } } } },
    { key = 'bar',        label = 'Bar / Venue',  flavor = 'Own the room. Turn a night into an institution.', blip = 93,
      service = { payout = 320,  stockCost = 120, cooldown = 35,  dailyCap = 16000, maxSupply = 500,
                  verb = 'Pour a round',   serveNoun = 'patron',   supplyNoun = 'bar stock',
                  skill = { difficulty = { 'easy', 'medium' },          keys = { 'w', 'a', 's', 'd' } } } },
    { key = 'garage',     label = 'Garage / Shop',flavor = 'A service people come back to.',                  blip = 402,
      service = { payout = 650,  stockCost = 260, cooldown = 70,  dailyCap = 15000, maxSupply = 200,
                  verb = 'Complete a job', serveNoun = 'customer',  supplyNoun = 'parts',
                  skill = { difficulty = { 'medium', 'medium', 'hard' }, keys = { 'w', 'a', 's', 'd' } } } },
    { key = 'retail',     label = 'Retail Front', flavor = 'A legit storefront on the map.',                  blip = 52,
      service = { payout = 240,  stockCost = 95,  cooldown = 28,  dailyCap = 15000, maxSupply = 700,
                  verb = 'Ring up a sale', serveNoun = 'shopper',   supplyNoun = 'inventory',
                  skill = { difficulty = { 'easy', 'easy' },            keys = { 'w', 'a', 's', 'd' } } } },
    { key = 'dealership',  label = 'Dealership',   flavor = 'Move product. Build a name.',                     blip = 326,
      service = { payout = 1200, stockCost = 520, cooldown = 120, dailyCap = 18000, maxSupply = 80,
                  verb = 'Close a sale',   serveNoun = 'buyer',     supplyNoun = 'units',
                  skill = { difficulty = { 'medium', 'hard' },          keys = { 'w', 'a', 's', 'd' } } } },
}

-- Default serve labels used when Config.PerTypeMechanics is off (matches the
-- Phase-0 wording so the gate-off UI is unchanged).
Config.DefaultServeLabels = { verb = 'Serve a walk-in', serveNoun = 'customer', supplyNoun = 'supply' }

-- ---------------------------------------------------------------------------
-- Roster / roles. Higher number = more authority. OWN ranks (palm6_business_
-- members.role stores these). Room left at 2 for a future Manager delegate.
-- ---------------------------------------------------------------------------
Config.Role = { Employee = 1, Manager = 2, Owner = 3 }
Config.RoleName = { [1] = 'Employee', [2] = 'Manager', [3] = 'Owner' }

Config.MaxEmployees = 10  -- excludes the owner (roster cap = MaxEmployees + 1)

-- Hire: the owner's nearest UNAFFILIATED online player within this radius gets
-- the prompt. The server picks the target from real ped positions; the client
-- never names who to hire (mirrors the palm6_gangs invite model). Expires.
Config.HireRadius = 6.0
Config.HireExpirySec = 60
Config.HireCooldownSec = 10  -- per owner, anti-spam (a hire pops a confirm dialog)

-- ---------------------------------------------------------------------------
-- Account (BANK money — clean, auditable). Deposits pull the owner's bank;
-- withdrawals + payroll + wages credit a bank. Every move is atomic + logged.
-- ---------------------------------------------------------------------------
Config.MinAmount = 1
Config.MaxPerAction = 1000000  -- sanity clamp on a single deposit/withdraw

-- Wage: the per-payroll-run amount an owner sets per employee. Clamp only.
Config.MaxWage = 100000

-- ---------------------------------------------------------------------------
-- Customer charge (player -> business). The owner/employee rings up the nearest
-- player, who CONFIRMS before their bank is charged. Pure redistribution.
-- ---------------------------------------------------------------------------
Config.ChargeRadius = 6.0
Config.ChargeExpirySec = 45
Config.ChargeMax = 100000
Config.ChargeCooldownSec = 5  -- per cashier, anti-spam

-- ---------------------------------------------------------------------------
-- NPC walk-in income — the ONE faucet. Bounded four ways (cost basis + active
-- work + per-employee cooldown + per-business daily cap). See spec §6.
-- ---------------------------------------------------------------------------
-- Owner buys SUPPLY with clean bank money (a SINK) before any NPC income is
-- possible. Each serve consumes 1 unit. This cost basis is the primary limiter:
-- net margin per unit = ServePayout - StockUnitCost, bounded and small.
Config.StockUnitCost = 120       -- clean bank $ per supply unit
Config.MaxSupplyUnits = 500      -- storage cap (prevents infinite pre-stocking)
Config.StockMaxPerBuy = 100      -- units per buy action (clamp)

-- Each serve: a clocked-in worker performs the serve action (client skill-check),
-- consumes 1 supply unit, credits the account by ServePayout.
Config.ServePayout = 300         -- clean bank $ an NPC pays per serve
Config.ServeCooldownSec = 45     -- per worker, between serves (persisted, os.time)

-- Per-business daily cap on NPC income (day_npc_income, resets when the UTC
-- day_key rolls). A full day of serving cannot exceed this.
Config.DailyNpcIncome = 15000

-- Require a supply cost basis for NPC income (keep true — this is the faucet's
-- primary limiter). If ever false, NPC income becomes free-mint: DON'T.
Config.NpcRequiresSupply = true

-- ---------------------------------------------------------------------------
-- PHASE 1 — Storefronts. A business becomes a PLACE: the owner marks a location
-- (server captures their real ped coords/heading — never client-supplied), a
-- public map blip + a walk-up interaction point spawn there, day-to-day
-- management is proximity-gated to the storefront, and NPC serving happens AT the
-- shop. All of this is inert unless Config.Phase1Enabled (+ Config.Enabled).
--
-- LOCKOUT SAFETY: registering a business and setting/moving/removing a storefront
-- are ALWAYS reachable from /business regardless of where the owner stands — only
-- the recurring management actions require being at the storefront. An owner can
-- never strand themselves by placing a storefront somewhere awkward.
-- ---------------------------------------------------------------------------
Config.Storefront = {
    -- How close (metres, 3D) a staff member must be to their storefront to manage
    -- it and to serve walk-ins. Generous so the whole shop interior counts.
    Radius = 30.0,

    -- Blip appearance defaults + scale. Per-type default sprite lives on
    -- Config.Types[].blip; DefaultColor applies until the owner customises.
    DefaultColor = 5,   -- yellow
    Scale = 0.85,

    -- Owner-selectable blip cosmetics. The server validates every write against
    -- these two allowlists (a client can't set an arbitrary sprite/colour). Keep
    -- to well-known-valid ids; an id that renders generically is harmless.
    Sprites = {
        { sprite = 52,  label = 'Storefront' },
        { sprite = 93,  label = 'Restaurant' },
        { sprite = 431, label = 'Bar' },
        { sprite = 402, label = 'Garage' },
        { sprite = 326, label = 'Dealership' },
        { sprite = 496, label = 'Boutique' },
        { sprite = 568, label = 'Cafe' },
        { sprite = 500, label = 'Star' },
    },
    Colors = {
        { color = 5,  label = 'Yellow' },
        { color = 2,  label = 'Green' },
        { color = 3,  label = 'Blue' },
        { color = 1,  label = 'Red' },
        { color = 27, label = 'Cyan' },
        { color = 83, label = 'Purple' },
        { color = 48, label = 'Grey' },
        { color = 47, label = 'Orange' },
    },
}
