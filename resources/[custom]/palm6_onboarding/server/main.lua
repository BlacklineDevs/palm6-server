-- ============================================================================
-- palm6_onboarding/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- First-ever character load: prompt the mandatory rules dialog, record
-- server-side acceptance, grant a one-time starter cash amount, log to
-- palm6_staff, then show a short tour. Every later load is a no-op (the
-- `palm6_onboarding` row already exists) except /rules, which just
-- re-displays the text — it never re-triggers the accept flow.
--
-- Client-trust note: `palm6_onboarding:acceptRules` is a client-addressable
-- net event. It is NOT trusted as proof the dialog was actually shown or
-- accepted — the guard that matters is server-side: UNIQUE(citizenid) on
-- palm6_onboarding means the starter-cash grant can only ever land once
-- per citizen no matter how many times (or how fast) the event fires,
-- replayed or otherwise. Same idiom as every other guarded-write feature
-- this session (palm6_ransom's payout guard, palm6_pumpcoin's mint-ticker
-- fix, palm6_courier's escrow guard).
-- ============================================================================

local lastAccept = {} -- [src] = ts — accept-event rate limit
local lastCheck = {}  -- [src] = ts — checkStatus rate limit (it runs a DB query)

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a new box boots with no
-- palm6_onboarding table. UNIQUE(citizenid) on that table is the ENTIRE
-- double-grant guard for starter cash (see the file header), and every query
-- here is pcall-wrapped: with the table absent, alreadyOnboarded() answers
-- "no" for everyone, the rules prompt fires on every single load, and the
-- accept INSERT fails silently so nobody is ever onboarded. On the live box
-- these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0030_onboarding.sql, plus the additive ALTER
-- from sql/0045_onboarding_starter_grants.sql (trailing semicolons dropped,
-- same as the other resources that carry their own DDL).
-- ---------------------------------------------------------------------------
local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_onboarding` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    accepted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    starter_cash_granted TINYINT(1) NOT NULL DEFAULT 0,
    UNIQUE KEY uniq_palm6_onboarding_citizenid (citizenid)
)
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists. Folding it into SchemaReady would make a perfectly
    -- healthy MySQL box print `schema MISSING` on every boot, which is the
    -- permanent-false-alarm failure that trains an operator to ignore the
    -- banner. palm6_onboarding is the table this resource owns and is what
    -- SchemaReady answers for; these two columns are additive audit markers
    -- (sql/0045 says so itself) and their absence is reported on its own line.
    -- Same pattern as palm6_mdt/server/main.lua's schemaOk.
    local alters = {
        [[
ALTER TABLE `palm6_onboarding`
    ADD COLUMN IF NOT EXISTS starter_vehicle_granted TINYINT(1) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS starter_outfit_granted  TINYINT(1) NOT NULL DEFAULT 0
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_onboarding] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_onboarding] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the columns already exist)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

local function now() return os.time() end

local function alreadyOnboarded(citizenid)
    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT id FROM palm6_onboarding WHERE citizenid = ?', { citizenid })
    end)
    return row ~= nil
end

-- ---------------------------------------------------------------------------
-- Starter vehicle.
--
-- THE DEFECT THIS REPLACES. The old inline version asked
-- Bridge.GiveStarterVehicle for a boolean and treated it as "the player has a
-- car". It does not mean that. It means qbx_vehicles' CreatePlayerVehicle
-- returned a row id — and that export writes the `garage` string into the
-- owned-vehicle row WITHOUT checking it against qbx_garages. So a garage name
-- that does not exist on the box still produced: a created row, granted=true,
-- starter_vehicle_granted=1, and the player told "Your starter vehicle is
-- parked at the motel garage." The car is real, owned, and in a garage no
-- door opens. And because the once-per-citizen INSERT in acceptRules is the
-- double-grant guard, that player can NEVER be granted another one.
--
-- `motelgarage` was never verified against the deployed qbx_garages — the
-- config comment next to it says so in as many words ("confirm in-game before
-- enabling in prod") while the flag above it is already `enabled = true`.
--
-- The fix is ordering plus doubt:
--   1. Resolve the garage first. Only 'present' grants. 'absent' and
--      'unknown' DEFER (see Config.StarterVehicle.requireVerifiedGarage) —
--      a deferral is reversible, an unreachable car is not.
--   2. CLAIM THE FLAG BEFORE CREATING THE CAR, with a conditional UPDATE the
--      database settles (`AND starter_vehicle_granted = 0`). Only the caller
--      whose UPDATE reports one affected row proceeds. This is what makes the
--      retry path below safe to run on every load: two concurrent loads, a
--      replayed accept and a reconnect mid-grant all lose the claim instead of
--      producing a second car. Same synchronous-latch-before-yield shape as
--      palm6_flashdrop's finishCheckout.
--   3. Release the claim if creation then fails, so it is retried later
--      rather than burned.
--
-- Consequence worth stating plainly: if the additive ALTER never ran (MySQL 8
-- — see ensureSchema), the claim UPDATE throws, nothing is claimed and NO car
-- is granted. That is the safe direction. It is reported in the boot banner
-- rather than left to be discovered as "starter vehicles stopped working".
-- ---------------------------------------------------------------------------
local GarageState = 'unknown'   -- resolved at boot and re-resolved per grant
local VehicleColumnReady = nil  -- nil = unprobed; set by probeVehicleColumn()

local function starterGarageName()
    local cv = Config.StarterVehicle.garageConvar
    if cv and cv ~= '' then
        local override = GetConvar(cv, '')
        if override ~= '' then return override, true end
    end
    return Config.StarterVehicle.garage, false
end

local function grantStarterVehicle(src, cid)
    if not cid then return false end
    local garage, overridden = starterGarageName()

    GarageState = Bridge.ResolveGarage(garage)
    if GarageState ~= 'present' and Config.StarterVehicle.requireVerifiedGarage then
        print(('^3[palm6_onboarding] starter vehicle DEFERRED for %s — garage "%s" is %s%s. ' ..
               'No car was created and nothing was marked granted; it will be retried on a ' ..
               'later load. Fix with: set %s "<real garage name>" in server.cfg.^0'):format(
            cid, garage, GarageState,
            overridden and ' (from the convar override)' or ' (from shared/config.lua)',
            Config.StarterVehicle.garageConvar or 'palm6:onboarding_garage'))
        return false
    end

    -- Claim first. The DB, not this process, decides who wins.
    local claimed = false
    local claimErr
    local ok = pcall(function()
        local affected = MySQL.update.await(
            'UPDATE palm6_onboarding SET starter_vehicle_granted = 1 ' ..
            'WHERE citizenid = ? AND starter_vehicle_granted = 0', { cid })
        claimed = (tonumber(affected) or 0) == 1
    end)
    if not ok then claimErr = true end
    if claimErr then
        VehicleColumnReady = false
        print('^1[palm6_onboarding] starter vehicle claim FAILED — the ' ..
              'starter_vehicle_granted column is missing (the additive ALTER never ran on ' ..
              'this box). No car granted. Apply sql/0045_onboarding_starter_grants.sql.^0')
        return false
    end
    if not claimed then return false end -- already granted, or a concurrent caller won

    local created = Bridge.GiveStarterVehicle(cid, Config.StarterVehicle.model, garage)
    if not created then
        -- Release, so this is a deferral and not a burned grant.
        pcall(function()
            MySQL.update.await(
                'UPDATE palm6_onboarding SET starter_vehicle_granted = 0 WHERE citizenid = ?',
                { cid })
        end)
        print(('^3[palm6_onboarding] starter vehicle creation failed for %s (qbx_vehicles ' ..
               'down or refused). Claim released; will retry on a later load.^0'):format(cid))
        return false
    end

    if src then
        Bridge.Notify(src, 'Welcome to Palm6',
            ('Your starter vehicle is parked at the %s garage.'):format(
                Config.StarterVehicle.garageLabel or garage),
            'success')
    end
    return true
end

-- ---------------------------------------------------------------------------
-- First load (or reconnect) — server decides whether the mandatory prompt
-- is owed. Nothing here is client-trusted: the DB row is the source of truth.
-- ---------------------------------------------------------------------------
-- Already-onboarded citizen who is still owed a starter vehicle (the grant was
-- deferred because the garage could not be verified, or creation failed). One
-- indexed read on a column that is 1 for everybody healthy, so this is a cheap
-- no-op in the normal case.
local function owesStarterVehicle(citizenid)
    local row
    local ok = pcall(function()
        row = MySQL.single.await(
            'SELECT id FROM palm6_onboarding ' ..
            'WHERE citizenid = ? AND starter_vehicle_granted = 0', { citizenid })
    end)
    return ok and row ~= nil
end

-- Retry a deferred grant. Safe to call on every load: grantStarterVehicle
-- claims the flag conditionally, so a citizen who already has a car loses the
-- claim and nothing happens.
local function retryStarterVehicle(src, cid)
    if not Config.StarterVehicle.enabled then return end
    if not owesStarterVehicle(cid) then return end
    grantStarterVehicle(src, cid)
end

Bridge.OnPlayerLoaded(function(src)
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if alreadyOnboarded(cid) then
        retryStarterVehicle(src, cid)
        return
    end
    TriggerClientEvent('palm6_onboarding:promptRules', src)
end)

-- Client also explicitly asks on load (belt-and-suspenders — if the client
-- resource restarted after the player was already in the world, the
-- Bridge.OnPlayerLoaded event won't refire, but this will).
RegisterNetEvent('palm6_onboarding:checkStatus', function()
    local src = source
    local ct = os.time()
    if ct - (lastCheck[src] or 0) < 3 then return end  -- rate-limit: runs a DB query
    lastCheck[src] = ct
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if alreadyOnboarded(cid) then
        -- This path matters more than it looks: the bridge records that
        -- QBCore:Server:OnPlayerLoaded may deliver a sentinel `source` on this
        -- box, in which case the handler above never resolves a citizenid and
        -- the retry never fires there. This event carries a real net `source`.
        retryStarterVehicle(src, cid)
        return
    end
    TriggerClientEvent('palm6_onboarding:promptRules', src)
end)

-- ---------------------------------------------------------------------------
-- Accept — guarded INSERT is the entire safety story here (see header).
-- ---------------------------------------------------------------------------
RegisterNetEvent('palm6_onboarding:acceptRules', function()
    local src = source
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local t = now()
    if (lastAccept[src] or 0) + Config.AcceptCooldownSec > t then return end
    lastAccept[src] = t

    local inserted = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_onboarding (citizenid) VALUES (?)', { cid })
    end)
    if not inserted then
        -- UNIQUE(citizenid) rejected it — already onboarded (a race, or a
        -- replayed event from a modified client). Nothing left to grant.
        return
    end

    if Config.StarterCash.enabled then
        Bridge.CreditBank(src, Config.StarterCash.amount, Config.StarterCash.reason)
        pcall(function()
            MySQL.update.await(
                'UPDATE palm6_onboarding SET starter_cash_granted = 1 WHERE citizenid = ?',
                { cid })
        end)
    end

    -- Starter vehicle — see grantStarterVehicle(). Deliberately NOT inline
    -- any more: the same grant has to be reachable from a later load, because
    -- a deferred grant that can never be retried is just a lost grant.
    if Config.StarterVehicle.enabled then
        grantStarterVehicle(src, cid)
    end

    -- Starter outfit — deferred (Config.StarterOutfit.enabled is false by
    -- default); the Bridge hook is a no-op until the illenium path is validated.
    if Config.StarterOutfit.enabled then
        if Bridge.SetStarterOutfit(src, cid) then
            pcall(function()
                MySQL.update.await(
                    'UPDATE palm6_onboarding SET starter_outfit_granted = 1 WHERE citizenid = ?',
                    { cid })
            end)
        end
    end

    if Bridge.ResourceStarted('palm6_staff') then
        pcall(function()
            exports.palm6_staff:Log('onboarding_rules_accepted', src, nil, cid)
        end)
    end

    TriggerClientEvent('palm6_onboarding:showTour', src)
end)

-- ---------------------------------------------------------------------------
-- /rules — read-only, any time, does not touch the DB or re-trigger accept.
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('rules', function(source)
    if source == 0 then return end
    TriggerClientEvent('palm6_onboarding:showRulesReadOnly', source)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The count has to run after ensureSchema, and ensureSchema has to Wait for
    -- oxmysql's connection first, so the banner moves onto its own thread.
    -- Nothing in this resource is cached in memory, so there is no boot window
    -- to gate: the accept path was already a pure guarded write.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        local total = 0
        pcall(function()
            local r = MySQL.single.await('SELECT COUNT(*) AS n FROM palm6_onboarding')
            total = r and tonumber(r.n) or 0
        end)
        print(('[palm6_onboarding] online — %d citizen(s) onboarded all-time'):format(total))
        if not SchemaReady then
            print('^1[palm6_onboarding] schema MISSING - nobody can be onboarded and the rules ' ..
                  'prompt will refire on every load.^0')
        end

        -- Starter-garage state. Reported at boot because the failure it
        -- guards is silent by nature: before this check, a wrong garage name
        -- produced a cheerful success notification and an unreachable car.
        if Config.StarterVehicle.enabled then
            local garage, overridden = starterGarageName()
            GarageState = Bridge.ResolveGarage(garage)
            local src = overridden and 'convar override' or 'shared/config.lua'
            if GarageState == 'present' then
                print(('[palm6_onboarding] starter garage "%s" resolved in qbx_garages (%s).')
                    :format(garage, src))
            elseif GarageState == 'absent' then
                print(('^1[palm6_onboarding] starter garage "%s" (%s) does NOT exist in ' ..
                       'qbx_garages. Starter vehicles are DEFERRED — no car is created and ' ..
                       'no grant is burned. Fix with: set %s "<real garage name>".^0'):format(
                    garage, src, Config.StarterVehicle.garageConvar))
            else
                print(('^3[palm6_onboarding] starter garage "%s" (%s) could NOT be verified ' ..
                       '(qbx_garages not started, or it exposes no readable garage list). ' ..
                       'Starter vehicles are DEFERRED while requireVerifiedGarage is true. ' ..
                       'Confirm the name in-game, then set %s "%s" to release them.^0'):format(
                    garage, src, Config.StarterVehicle.garageConvar, garage))
            end
        end

        -- Owed-grant backlog: citizens onboarded but still without a car.
        local owed = 0
        local probed = pcall(function()
            local r = MySQL.single.await(
                'SELECT COUNT(*) AS n FROM palm6_onboarding WHERE starter_vehicle_granted = 0')
            owed = r and tonumber(r.n) or 0
        end)
        VehicleColumnReady = probed
        if not probed then
            print('^1[palm6_onboarding] starter_vehicle_granted column MISSING — starter ' ..
                  'vehicles cannot be granted at all on this box. Apply ' ..
                  'sql/0045_onboarding_starter_grants.sql.^0')
        elseif owed > 0 then
            print(('^3[palm6_onboarding] %d onboarded citizen(s) are still owed a starter ' ..
                   'vehicle; each is retried on their next load.^0'):format(owed))
        end
    end)
end)

---Onboarded-citizen counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { totalAccepted = 0, starterVehicles = 0, starterOutfits = 0 }
    pcall(function()
        local r = MySQL.single.await([[
            SELECT COUNT(*) AS n,
                   COALESCE(SUM(starter_vehicle_granted), 0) AS veh,
                   COALESCE(SUM(starter_outfit_granted), 0)  AS fit
            FROM palm6_onboarding]])
        if r then
            out.totalAccepted   = tonumber(r.n) or 0
            out.starterVehicles = tonumber(r.veh) or 0
            out.starterOutfits  = tonumber(r.fit) or 0
        end
    end)
    return out
end)
