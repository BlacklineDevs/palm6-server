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
-- LIVE in production (preserved across the feat->main merge; the new Phase-1 gates
-- below stay false so only the hardened Phase-0 core is active).
Config.Enabled = true

-- PHASE 1 GATE — physical storefronts (map location + blip + walk-up target;
-- proximity-gated management; storefront-anchored serving). Independent of
-- Config.Enabled so enabling Phase 0 does NOT auto-enable storefronts: BOTH must
-- be true for any storefront code path to run. Flip true (+ redeploy) only after
-- the Phase 1 feel-test. false = Phase 0 behaves exactly as it does today (a
-- business with no storefront row is indistinguishable from a Phase-0 business).
-- *** ENABLED 2026-07-21 for feel-test (gate 1 of 6, per GO-LIVE-RUNBOOK §C).
-- Rollback = set false + redeploy; storefront rows persist and simply go unused. ***
Config.Phase1Enabled = true

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

-- MANAGER DELEGATE GATE — lets an owner promote an employee to MANAGER (role 2),
-- who can run the day-to-day (hire, fire employees, run payroll, buy supply, serve)
-- but CANNOT extract or redefine the business: withdraw, set wages, rename,
-- storefront, and promote/demote stay OWNER-only. Keeping setWage owner-only is
-- deliberate — it closes the only account-drain path a delegate could otherwise
-- abuse (inflate a wage + run payroll). INDEPENDENT gate; while false, promote/
-- demote refuse and every management op falls back to OWNER-only — byte-for-byte
-- the current behaviour (no manager has ever been assigned). Flip true (+ redeploy)
-- after a delegate feel-test.
Config.ManagerRole = false

-- Max managers an owner can appoint (excludes the owner). Bounds delegation.
Config.MaxManagers = 3

-- OWNERSHIP LIFECYCLE GATE — lets an owner TRANSFER the business to a roster member
-- (they become owner, the old owner drops to employee) or CLOSE it (remaining
-- account balance is refunded to the owner's bank, then the business + roster are
-- deleted). Fills the documented gap where an owner was stuck forever (opResign
-- refuses an owner). INDEPENDENT gate; while false the two ops refuse and the menu
-- items are hidden — no change to the live Phase-0 system. Flip true (+ redeploy)
-- after a transfer/close feel-test. Neither op can mint or overdraw: transfer moves
-- no money; close refunds the OWNER their own account via the crash-safe pending
-- idiom (drain-to-zero captured atomically) before deleting.
Config.OwnershipLifecycle = false

-- ROBBERY GATE — a non-member can crack a business's register at its storefront for
-- a CAPPED cut of the account, paid to their bank. Pure redistribution (atomic
-- guarded debit of the business account, never minted, never overdrawn), bounded by
-- a small percentage + a hard cap + a long per-business cooldown + a per-robber
-- cooldown, and it fires a police alert. Gives a placed storefront real stakes and
-- rewards owners who withdraw profits instead of hoarding. INDEPENDENT gate; while
-- false /robstore refuses and nothing changes. Requires a placed storefront (Phase 1a).
Config.Robbery = false
Config.Rob = {
    Command = 'robstore',   -- namespaced to avoid the ATM-robbery /rob (palm6_robbery)
    Pct = 0.25,             -- fraction of the account taken (before the hard cap)
    Max = 5000,             -- hard cap per robbery ($)
    Min = 2000,             -- account must hold at least this to be worth robbing
    Radius = 3.5,           -- must be right at the storefront
    CooldownSec = 2700,     -- 45 min per business (the register is emptied/locked)
    RobberCooldownSec = 600,-- 10 min per robber (anti-farm), set before any DB yield
    AlertChance = 1.0,      -- chance a robbery trips a police alert
    Payout = 'bank',        -- where the take lands (bank = clean; seam for a dirty variant)
    Skill = { difficulty = { 'medium', 'medium', 'hard' }, keys = { 'w', 'a', 's', 'd' } },
}

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

-- PASSIVE NPC INCOME (AI-NPC living world, docs/AI-NPC-ROADMAP.md). When true,
-- exports('AccrueNpcPassive') lets the AI Director's mover walk-ins credit a
-- business EVEN WHILE THE OWNER IS AWAY — so a growing server's economy keeps
-- ticking off-peak. This is NOT a new faucet: the passive path runs the EXACT
-- same atomic, supply-consuming, ledgered credit as the owner-present serve, and
-- shares the SAME day_npc_income column + DailyNpcIncome cap. So an absent owner
-- can never earn MORE than a present one, never exceeds the daily ceiling, and
-- never mints free money (it always consumes pre-bought supply, ALWAYS — stricter
-- than NpcRequiresSupply). Off by default: this is the live-economy gate David
-- browser-walks (the AFK-printer attack path) BEFORE flipping. See RUNBOOK.
Config.NpcPassiveIncome = false

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

-- ---------------------------------------------------------------------------
-- PHASE 1b — INTERIORS. Makes a storefront an actual PLACE you walk into,
-- instead of a blip over open street ("it's virtually there, there is no actual
-- building"). Three parts, all inert behind this gate:
--
--   1. SHELL      an existing enterable interior, reused as the room.
--   2. BUCKET     a native routing bucket per business, so every business gets
--                 a PRIVATE copy of that shell (unlimited businesses, one room).
--   3. LAYOUT     per-business prop dressing spawned on entry, so two businesses
--                 in the same shell do NOT look the same.
--
-- WHY NOT A CUSTOM MLO PER BUSINESS: a bespoke interior needs an MLO archetype
-- (rooms/portals/entity sets) plus a BINARY .ymap placement. Neither Sollumz nor
-- szio can emit a binary ymap headlessly (see fivem-asset-templates/
-- ASSET-PIPELINE.md §8) — it is a manual CodeWalker step per interior. Runtime
-- prop spawning needs NO ymap at all, so the LAYOUT tier buys per-business
-- identity with the fully-headless prop pipeline we already have.
--
-- 🔴 bob74_ipl IS NOT INSTALLED on this server (verified: absent from custom.cfg,
-- absent from server.cfg.example, zero references in docs/deploy/CI; the only
-- mentions are palm6_counterfeit treating it as optional). So the shell catalog
-- is restricted to BASE-GAME enterable interiors, which need no IPL. If bob74_ipl
-- is ever added, extra shells drop into Config.Interior.Shells with no code change.
--
-- INDEPENDENT gate. While false: no entry target, no bucket is ever assigned, no
-- prop is ever spawned, /bizshell refuses. Requires a placed storefront (Phase 1a).
-- *** ENABLED 2026-07-21 for the in-game feel-test (gate of 7, per GO-LIVE-RUNBOOK
-- §C). SAFE to ship on: the feature is INERT until an admin /bizshell-captures at
-- least one shell — no Enter option appears, no routing bucket is ever assigned,
-- and migration 0073 is additive (new table + nullable column). First in-game step
-- is capture (see docs/BUSINESS-INTERIORS-CAPTURE.md). Rollback = set false +
-- redeploy; captured shells persist and simply go unused. ***
-- ---------------------------------------------------------------------------
Config.Interiors = true

Config.Interior = {
    -- ROUTING BUCKETS. bucket = BucketBase + business id. Verified 2026-07-21 that
    -- NOTHING else in this server calls SetPlayerRoutingBucket, so the whole range
    -- is ours and cannot collide. Bucket 0 is the shared world and is NEVER used
    -- as an interior — a business id of 0 would collide with it, and ids start at 1.
    -- Base is 10000 (well clear of bucket 0) leaving ample headroom below FiveM's
    -- bucket-id ceiling; the server also clamps in bucketFor as belt-and-braces.
    BucketBase = 10000,

    -- 🔴 TRADEOFF David must sign off on before this gate flips: a routing bucket
    -- is TRUE dimensional isolation, which means staff/admin SPECTATE of a player
    -- inside a business interior breaks unless the spectating admin is moved into
    -- the same bucket. qbx_properties chose NetworkConcealPlayer (visual-only) to
    -- keep staff tooling working. We choose real buckets because concealment does
    -- not actually instance (every business would share one room). If admin
    -- spectate matters more than instancing, this is the line to revisit.
    -- palm6_staff integration is a follow-up, NOT shipped in this gate.
    AdminBucketFollow = false,

    -- SHELL CATALOG — deliberately EMPTY. Interior coordinates are NEVER hardcoded
    -- from memory or from a wiki: a wrong coord drops a player inside geometry or
    -- into the void, and that is exactly the "empty/broken" feel this phase exists
    -- to kill. Instead an admin STANDS in a real interior and captures it, the same
    -- way a storefront captures the owner's real ped coords server-side. Captured
    -- shells persist to palm6_business_shells and load on boot.
    --
    -- Shape once captured:
    --   { key='shell_247', label='24/7 Store', x=, y=, z=, h=, exitDist=, }
    -- `exitDist` = how far from the entry anchor the exit prompt appears.
    Shells = {},

    -- Admin capture command. Stand inside a real interior and run
    -- `/bizshell <type|key> [label]` — a business type (restaurant/bar/garage/
    -- retail/dealership) auto-maps to that type's shell key, or pass a raw key.
    -- Client-side it warns (does not block) if it can't detect an interior at your
    -- feet — a soft guard, because valid map-mesh walk-ins (many 24/7s, LTD) report
    -- no interior id even though they work. The server re-checks the
    -- `command.bizshell` ace and reads your coords authoritatively. List captures +
    -- missing type mappings with /bizshells.
    CaptureCommand = 'bizshell',

    -- Which shell each business type prefers, by shell key. A type with no
    -- captured shell simply has no interior yet (storefront still works as today).
    TypeShell = {
        restaurant = 'shell_restaurant',
        bar        = 'shell_bar',
        garage     = 'shell_garage',
        retail     = 'shell_retail',
        dealership = 'shell_dealership',
    },

    -- Entry/exit feel.
    EntryRadius = 2.0,    -- ox_target sphere at the storefront door
    FadeMs      = 500,    -- screen fade each way; covers the teleport + prop spawn
    ExitRadius  = 2.5,    -- target radius on the inside-the-door exit point

    -- WHO MAY ENTER. Owner/manager/employee always may. `PublicEntry` lets any
    -- citizen walk in (a shop with no customers is not a shop). Server re-checks
    -- membership on every entry — the client never asserts its own role.
    -- ⚠️ BALANCE RISK to weigh before flipping the gate: because entry moves a
    -- player into a TRUE routing bucket that pursuers cannot follow into (admin
    -- spectate + police chase both), a public interior is an instant escape hatch
    -- from a pursuit. Options if this bites at feel-test: set PublicEntry=false
    -- (staff-only rooms), or add a wanted-state check to opEnterInterior. Left true
    -- by default because the customer-facing shop is the whole point; decide live.
    PublicEntry = true,

    -- LAYOUTS — per-business prop dressing. Props spawn CLIENT-side and
    -- NON-NETWORKED: inside a routing bucket each client renders its own local
    -- copy at identical coords, so the room looks furnished to everyone in it at
    -- zero server-entity cost and with no ymap.
    --
    -- Offsets are RELATIVE to the shell anchor (x,y,z,h), so one layout works in
    -- any shell. Models are base-game props (always present). A model that fails
    -- to load is skipped, never fatal — a missing prop must not block entry.
    MaxPropsPerLayout = 40,   -- hard clamp; a layout cannot grief the client
    PropLoadTimeoutMs = 3000, -- per-model streaming wait before giving up

    -- Owner-selectable dressing styles. This is the knob that makes two shops of
    -- the same type look different. Extend freely; keys are validated on write.
    --
    -- 🔶 PROP NAMES: base-game models chosen from a verified prop kit, but a GTA
    -- model name can't be confirmed offline. An unknown name is SKIPPED (never
    -- fatal) AND printed to the server console on entry
    -- (`[palm6_business] layout "X": N prop(s) failed to load: ...`). So the tuning
    -- loop is: walk in → read the console → swap any that missed. Higher-confidence
    -- props are used first so no layout is ever fully empty.
    --
    -- Offsets assume the shell anchor sits at a doorway facing +Y INTO the room;
    -- +X is to the anchor's right. Tune per shell in-game once captured. Table
    -- height ≈ 0.9m (set oz for props that sit ON a table).
    Layouts = {
        { key = 'bare',     label = 'Bare (empty)',  props = {} },

        -- RESTAURANT — ROOFTOP LOUNGE. Built to sit on a real open rooftop, so the
        -- SETTING is the immersive part (real skyline) and these props BUILD THE
        -- VENUE around it — the ingredients a real rooftop-lounge MLO uses (studied
        -- from Skyline Reverie): floor rugs over bare concrete, a gazebo pergola to
        -- define the covered lounge, glass balustrade railings around the edge,
        -- palms + potted greenery, real yacht-style lounge sofas + a stocked bar,
        -- and light-emitting lamps + warm point lights for night.
        -- All model names VERIFIED against the GTA v1.50 hash dump. Anchor faces +Y
        -- with the view/railing at the far +Y edge; tune offsets to the chosen roof.
        -- (Honest gaps: GTA has no true wood-deck or string-light prop — rugs stand
        -- in for decking, neon/lit-lamps for the glow.)
        { key = 'rooftop',  label = 'Rooftop lounge', props = {
            -- floor: warm rugs over the concrete (no wood-deck prop exists in GTA)
            { model = 'apa_mp_h_acc_rugwoolm_01', ox = -1.6, oy = 3.6, oz = 0.02, oh = 0.0 },
            { model = 'apa_mp_h_acc_rugwoolm_03', ox = 1.8,  oy = 5.0, oz = 0.02, oh = 0.0 },
            -- pergola: a modern gazebo over the lounge cluster (defines the venue)
            { model = 'ch_prop_ch_gazebo_01', ox = -1.6, oy = 3.6, oz = 0.0, oh = 0.0 },
            -- lounge cluster (yacht sofa set reads as a real lounge)
            { model = 'apa_mp_h_yacht_sofa_01', ox = -2.8, oy = 3.0, oz = 0.0, oh = 90.0 },
            { model = 'apa_mp_h_yacht_sofa_02', ox = -2.8, oy = 4.4, oz = 0.0, oh = 90.0 },
            { model = 'apa_mp_h_yacht_coffee_table_01', ox = -1.5, oy = 3.7, oz = 0.0, oh = 0.0 },
            { model = 'hei_prop_yah_lounger', ox = -0.2, oy = 2.4, oz = 0.0, oh = 30.0 },
            -- dining (center-right)
            { model = 'prop_table_03',      ox = 1.7,  oy = 5.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',     ox = 1.7,  oy = 4.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',     ox = 1.7,  oy = 6.3, oz = 0.0, oh = 180.0 },
            { model = 'prop_table_03',      ox = 3.2,  oy = 3.4, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',     ox = 3.2,  oy = 2.7, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',     ox = 3.2,  oy = 4.1, oz = 0.0, oh = 180.0 },
            -- bar (right, back) + back-shelf + stools + bottles + neon glow
            { model = 'prop_beer_bar',      ox = 3.7,  oy = 1.3, oz = 0.0, oh = 90.0 },
            { model = 'v_ret_fh_shelf_01',  ox = 4.5,  oy = 1.3, oz = 0.0, oh = 90.0 },
            { model = 'prop_bar_stool_01',  ox = 2.9,  oy = 0.8, oz = 0.0, oh = 0.0 },
            { model = 'prop_bar_stool_01',  ox = 2.9,  oy = 1.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_wine_red',      ox = 3.6,  oy = 1.1, oz = 0.95, oh = 0.0 },
            { model = 'prop_whiskey_01',    ox = 3.7,  oy = 1.6, oz = 0.95, oh = 0.0 },
            { model = 'prop_beer_neon_01',  ox = 4.5,  oy = 1.3, oz = 1.9, oh = 90.0 },
            -- glass balustrade railing (view edge + sides)
            { model = 'prop_balcony_glass_01', ox = -2.5, oy = 7.4, oz = 0.0, oh = 0.0 },
            { model = 'prop_balcony_glass_01', ox = 0.0,  oy = 7.4, oz = 0.0, oh = 0.0 },
            { model = 'prop_balcony_glass_01', ox = 2.5,  oy = 7.4, oz = 0.0, oh = 0.0 },
            { model = 'prop_balcony_glass_01', ox = -4.3, oy = 4.6, oz = 0.0, oh = 90.0 },
            { model = 'prop_balcony_glass_01', ox = 4.3,  oy = 4.6, oz = 0.0, oh = 90.0 },
            -- palms + greenery
            { model = 'prop_palm_med_01a',  ox = -4.2, oy = 6.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_palm_med_01a',  ox = 4.2,  oy = 6.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_bush_ivy_01_pot', ox = -3.9, oy = 0.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_bush_ivy_01_pot', ox = 3.9,  oy = 0.6, oz = 0.0, oh = 0.0 },
            -- light-emitting standing lamps (cast real light, unlike plain props)
            { model = 'apa_mp_h_lit_floorlamp_01', ox = -3.7, oy = 5.7, oz = 0.0, oh = 0.0 },
            { model = 'apa_mp_h_lit_floorlamp_01', ox = 1.0,  oy = 1.3, oz = 0.0, oh = 0.0 },
        }, lights = {
            { ox = -1.6, oy = 3.7, oz = 2.6, r = 255, g = 188, b = 132, range = 8.5, intensity = 3.8 }, -- warm over lounge
            { ox = 2.3,  oy = 4.6, oz = 2.6, r = 255, g = 188, b = 132, range = 8.5, intensity = 3.8 }, -- warm over dining
            { ox = 3.9,  oy = 1.4, oz = 2.2, r = 255, g = 176, b = 118, range = 6.0, intensity = 3.2 }, -- bar
            { ox = 0.0,  oy = 7.0, oz = 1.6, r = 120, g = 160, b = 255, range = 7.0, intensity = 2.5 }, -- cool accent, view edge
        } },

        -- RESTAURANT — casual diner. Three 2-seat tables, a service counter, and
        -- greenery. Built from plain tables + separate chairs (higher-confidence
        -- names) rather than combo props.
        { key = 'diner',    label = 'Diner',         props = {
            -- dining set 1 (left)
            { model = 'prop_table_03',     ox = -1.9, oy = 1.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = -1.9, oy = 0.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = -1.9, oy = 2.3, oz = 0.0, oh = 180.0 },
            -- dining set 2 (right)
            { model = 'prop_table_03',     ox = 1.9,  oy = 1.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = 1.9,  oy = 0.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = 1.9,  oy = 2.3, oz = 0.0, oh = 180.0 },
            -- dining set 3 (center back)
            { model = 'prop_table_03',     ox = 0.0,  oy = 3.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = 0.0,  oy = 2.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',    ox = 0.0,  oy = 4.3, oz = 0.0, oh = 180.0 },
            -- service / order counter along the right wall
            { model = 'prop_ff_counter_01', ox = 3.0, oy = 3.4, oz = 0.0, oh = 90.0 },
            { model = 'prop_ff_counter_02', ox = 3.0, oy = 2.2, oz = 0.0, oh = 90.0 },
            -- greenery
            { model = 'prop_pot_plant_01a', ox = -3.0, oy = 0.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_pot_plant_01a', ox = -3.0, oy = 4.2, oz = 0.0, oh = 0.0 },
        } },

        -- RESTAURANT — upscale. Round tables, a glass host stand, plants, a rug.
        { key = 'fine_dining', label = 'Fine dining', props = {
            { model = 'prop_table_05',      ox = -1.8, oy = 1.8, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_04a',     ox = -1.8, oy = 1.0, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_04a',     ox = -1.8, oy = 2.6, oz = 0.0, oh = 180.0 },
            { model = 'prop_table_05',      ox = 1.8,  oy = 1.8, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_04a',     ox = 1.8,  oy = 1.0, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_04a',     ox = 1.8,  oy = 2.6, oz = 0.0, oh = 180.0 },
            { model = 'p_counter_01_glass', ox = 0.0,  oy = 0.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_plant_int_02a', ox = -2.8, oy = 3.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_plant_int_02a', ox = 2.8,  oy = 3.6, oz = 0.0, oh = 0.0 },
        } },

        -- RESTAURANT / cafe — lighter footprint.
        { key = 'cafe',     label = 'Cafe',          props = {
            { model = 'prop_table_03',      ox = -1.6, oy = 1.5, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_02',      ox = -1.6, oy = 0.8, oz = 0.0, oh = 0.0 },
            { model = 'prop_table_03',      ox = 1.6,  oy = 1.5, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_02',      ox = 1.6,  oy = 0.8, oz = 0.0, oh = 0.0 },
            { model = 'prop_ff_counter_01', ox = 0.0,  oy = 3.4, oz = 0.0, oh = 180.0 },
            { model = 'prop_pot_plant_01a', ox = -2.6, oy = 3.0, oz = 0.0, oh = 0.0 },
        } },

        -- BAR / venue.
        { key = 'lounge',   label = 'Lounge / bar',  props = {
            { model = 'prop_ff_counter_01', ox = 2.6,  oy = 2.4, oz = 0.0, oh = 90.0 },
            { model = 'prop_ff_counter_02', ox = 2.6,  oy = 1.2, oz = 0.0, oh = 90.0 },
            { model = 'prop_table_03',      ox = -1.8, oy = 1.6, oz = 0.0, oh = 0.0 },
            { model = 'prop_chair_01a',     ox = -1.8, oy = 0.9, oz = 0.0, oh = 0.0 },
            { model = 'prop_pot_plant_01a', ox = -2.8, oy = 3.4, oz = 0.0, oh = 0.0 },
        } },

        -- RETAIL — shop floor.
        { key = 'stocked',  label = 'Stocked shop',  props = {
            { model = 'prop_boxpile_07d',   ox = 1.8,  oy = 1.2,  oz = 0.0, oh = 0.0 },
            { model = 'prop_boxpile_06b',   ox = 2.1,  oy = -0.6, oz = 0.0, oh = 45.0 },
            { model = 'prop_pallet_02a',    ox = -1.9, oy = 1.5,  oz = 0.0, oh = 90.0 },
            { model = 'prop_ff_counter_01', ox = 0.0,  oy = 2.8,  oz = 0.0, oh = 180.0 },
        } },

        -- GARAGE — workshop.
        { key = 'workshop', label = 'Workshop',      props = {
            { model = 'prop_toolchest_01',  ox = 2.0,  oy = 0.4,  oz = 0.0, oh = 180.0 },
            { model = 'prop_roadcone02a',   ox = 0.9,  oy = 2.1,  oz = 0.0, oh = 0.0 },
            { model = 'prop_pot_plant_01a', ox = -2.6, oy = 2.4,  oz = 0.0, oh = 0.0 },
        } },
    },

    -- Fallback layout when a business has never picked one, BY TYPE — so a
    -- restaurant looks like a restaurant on first entry without the owner touching
    -- anything. Falls through to DefaultLayout for an unlisted type.
    TypeDefaultLayout = {
        restaurant = 'rooftop',
        bar        = 'lounge',
        retail     = 'stocked',
        garage     = 'workshop',
        dealership = 'fine_dining',
    },

    DefaultLayout = 'bare',
}
