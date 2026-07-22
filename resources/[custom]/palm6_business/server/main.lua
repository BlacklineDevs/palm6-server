-- ============================================================================
-- palm6_business/server/main.lua
--
-- Player-owned businesses: registry, pooled BANK account, employees, payroll,
-- customer charges, a capped NPC walk-in income faucet, and a full ledger.
-- Server-authoritative throughout; the client sends intent only.
--
-- MONEY SAFETY (spec §2): a business account is pooled REAL money, never minted.
-- Every credit is charge-before-credit; every debit is an atomic guarded UPDATE
-- (WHERE balance >= amount) so the account can't overdraw; NPC income is bounded
-- by a clean-money cost basis + per-worker cooldown + per-business daily cap;
-- every move writes a palm6_business_ledger row.
-- ============================================================================

local function enabled() return Config.Enabled == true end

-- Phase 1 (storefronts) gate. Requires BOTH master + Phase-1 flags so enabling
-- Phase 0 never auto-lights storefronts. EVERY storefront code path checks this.
local function phase1() return Config.Enabled == true and Config.Phase1Enabled == true end

-- Manager delegate gate + the effective minimum role that may run staff/ops
-- management (hire/fire/payroll/buy supply). When the delegate feature is OFF this
-- is Owner — byte-for-byte the pre-manager behaviour; when ON, a Manager (role 2)
-- qualifies too. Money-out (withdraw), setWage, rename, storefront, and promote/
-- demote are NOT routed through this — they stay Owner-only regardless.
local function managerEnabled() return Config.ManagerRole == true end
local function minManageRole() return managerEnabled() and Config.Role.Manager or Config.Role.Owner end

-- Ownership-lifecycle gate (transfer / close). Requires the master flag too.
local function lifecycleEnabled() return Config.Enabled == true and Config.OwnershipLifecycle == true end

-- Robbery gate. Requires the master flag too.
local function robberyEnabled() return Config.Enabled == true and Config.Robbery == true end

-- ---------------------------------------------------------------------------
-- Utils
-- ---------------------------------------------------------------------------

-- Finite non-negative integer, or nil. `n ~= n` rejects NaN (which floor()
-- passes through and every </> comparison treats as false — the lottery lesson);
-- math.huge rejects Inf. ALL client-supplied amounts pass through here first.
local function sanitizeInt(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if v < 0 then return nil end
    return v
end

local function clampInt(v, lo, hi)
    v = sanitizeInt(v)
    if not v then return nil end
    if v < lo then v = lo end
    if v > hi then v = hi end
    return v
end

local function nowSec() return os.time() end
local function dayKey() return os.date('!%Y-%m-%d') end  -- UTC bucket

-- Blocklist check that resists separator evasion (f.u.c.k / f-u-c-k / f a g):
-- test BOTH the lowercased string and a form with every non-alphanumeric stripped,
-- so a blocked token spelled with allowed separators is still caught. Used by both
-- the business name and the Starter Pack nameplate (public-rendered text).
local function hasBlockedWord(s)
    local low = s:lower()
    local squashed = low:gsub('[^%w]', '')
    for _, bad in ipairs(Config.Blocklist or {}) do
        if low:find(bad, 1, true) or squashed:find(bad, 1, true) then return true end
    end
    return false
end

local function sanitizeName(raw)
    if type(raw) ~= 'string' then return nil end
    local s = raw:gsub("[^%w %&'%-]", '')
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #s < Config.NameMinLen or #s > Config.NameMaxLen then return nil end
    if hasBlockedWord(s) then return nil end
    return s
end

local function typeInfo(key)
    for _, t in ipairs(Config.Types) do
        if t.key == key then return t end
    end
    return nil
end

-- Phase-1 blip cosmetics: build O(1) allowlist sets once (a client can never set
-- a sprite/colour outside these), and resolve a type's default sprite.
local ALLOWED_SPRITE, ALLOWED_COLOR = {}, {}
for _, s in ipairs((Config.Storefront and Config.Storefront.Sprites) or {}) do ALLOWED_SPRITE[s.sprite] = true end
for _, c in ipairs((Config.Storefront and Config.Storefront.Colors) or {}) do ALLOWED_COLOR[c.color] = true end

local function defaultSprite(typeKey)
    local ti = typeInfo(typeKey)
    return (ti and ti.blip) or 52
end
local function defaultColor()
    return (Config.Storefront and Config.Storefront.DefaultColor) or 5
end
local function storefrontRadius()
    return (Config.Storefront and Config.Storefront.Radius) or 30.0
end

-- Phase-1 Starter Pack (store SKU) cosmetics. The gate requires phase1() as well
-- (the cosmetics dress a PLACED storefront) plus the pack flag, so gate-off =
-- storefronts render byte-for-byte as today. Build the premium-skin allowlist
-- (by key) once, like the base blip allowlists above.
local function starterPackEnabled()
    return phase1() and Config.StarterPack ~= nil and Config.StarterPack.Enabled == true
end
local STARTER_KEY = (Config.StarterPack and Config.StarterPack.Key) or 'starter'
local SKIN_BY_KEY = {}
for _, s in ipairs((Config.StarterPack and Config.StarterPack.Skins) or {}) do SKIN_BY_KEY[s.key] = s end

-- Per-owner entitlement lookup. COLD path only (the cosmetic ops + the walk-up
-- card + the export) — NEVER the getMembership hot path. True when this citizen
-- holds the Starter Pack (bought via Tebex, or granted by the admin command).
local function hasStarterEntitlement(cid)
    if not cid then return false end
    local row = MySQL.scalar.await(
        'SELECT 1 FROM palm6_business_entitlements WHERE citizenid = ? AND pack = ?',
        { cid, STARTER_KEY })
    return row ~= nil
end

-- Sanitise a custom nameplate: same character policy as a business name
-- (alphanumerics + a little punctuation), collapsed whitespace, trimmed, clamped
-- to NameplateMaxLen, and run through the same word blocklist. Returns the clean
-- string, or nil if it is empty / all-stripped / blocklisted (callers decide
-- whether a nil means "clear" or "reject", by pre-checking the raw input).
local function sanitizeNameplate(raw)
    if type(raw) ~= 'string' then return nil end
    local s = raw:gsub("[^%w %&'%.%-]", '')
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    local maxLen = (Config.StarterPack and Config.StarterPack.NameplateMaxLen) or 24
    if #s > maxLen then s = s:sub(1, maxLen):gsub('%s+$', '') end
    if #s == 0 then return nil end
    if hasBlockedWord(s) then return nil end
    return s
end

local function notify(src, title, msg, t) Bridge.Notify(src, title, msg, t) end

-- ---------------------------------------------------------------------------
-- DB layer (our schema — portable). Account never held in memory: the DB row is
-- authoritative, mutated only through the atomic helpers below.
-- ---------------------------------------------------------------------------

local function getMembership(cid)
    if not cid then return nil end
    return MySQL.single.await([[
        SELECT m.citizenid, m.business_id, m.role, m.wage, m.clocked_in, m.last_serve_at,
               b.name AS business_name, b.biz_type, b.account_balance, b.supply_units,
               b.day_key, b.day_npc_income, b.owner_cid
          FROM palm6_business_members m
          JOIN palm6_businesses b ON b.id = m.business_id
         WHERE m.citizenid = ?
    ]], { cid })
end

local function getBusinessById(id)
    return MySQL.single.await('SELECT * FROM palm6_businesses WHERE id = ?', { id })
end

-- Phase-1 storefront row, fetched SEPARATELY from getMembership so Phase 0's hot
-- per-op membership SELECT is never touched — it can never SQL-error on a DB where
-- 0070 has not yet applied, and this read only runs behind phase1() (by which
-- point 0070 has). Returns loc/heading/blip columns, or nil.
local function storefrontOf(businessId)
    return MySQL.single.await(
        'SELECT loc_x, loc_y, loc_z, loc_h, blip_sprite, blip_color FROM palm6_businesses WHERE id = ?',
        { businessId })
end

-- A storefront is "placed" only when all three coords are non-null (clearing sets
-- them null but keeps the chosen blip look for a future re-place).
local function hasLoc(sf)
    return sf ~= nil and sf.loc_x ~= nil and sf.loc_y ~= nil and sf.loc_z ~= nil
end

-- Is `src` within their storefront radius? Server-authoritative (real ped coords).
local function nearLoc(src, sf)
    if not hasLoc(sf) then return false end
    local pc = Bridge.GetCoords(src)
    if not pc then return false end
    return Bridge.Distance(pc, { x = sf.loc_x, y = sf.loc_y, z = sf.loc_z }) <= storefrontRadius()
end

-- Every placed storefront -> the public blip/target list clients render. Behind
-- phase1() so the whole feature is inert (empty list) until Phase 1 is enabled.
local function storefrontList()
    if not phase1() then return {} end
    -- Only SELECT (and apply) the Starter Pack cosmetic columns when the pack is
    -- enabled. Gate-off never references nameplate/skin, so a lagged 0073 migration
    -- can't SQL-error the storefront layer (same defensive split as phase1 vs 0070),
    -- and the payload is byte-for-byte today's.
    local starter = starterPackEnabled()
    local cols = starter
        and 'id, name, biz_type, loc_x, loc_y, loc_z, blip_sprite, blip_color, nameplate, skin'
        or  'id, name, biz_type, loc_x, loc_y, loc_z, blip_sprite, blip_color'
    -- cols is a fixed internal string (never user input), so this format is safe.
    local rows = MySQL.query.await(([[
        SELECT %s
          FROM palm6_businesses
         WHERE loc_x IS NOT NULL AND loc_y IS NOT NULL AND loc_z IS NOT NULL
    ]]):format(cols)) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local sprite = r.blip_sprite or defaultSprite(r.biz_type)
        local color = r.blip_color or defaultColor()
        local nameplate = nil
        if starter then
            -- A premium skin overrides the base blip sprite+colour; an invalid/
            -- removed skin key is ignored (falls back to the base look).
            local sk = r.skin and SKIN_BY_KEY[r.skin] or nil
            if sk then sprite = sk.sprite; color = sk.color end
            if r.nameplate and r.nameplate ~= '' then nameplate = r.nameplate end
        end
        out[#out + 1] = {
            id = r.id, name = r.name, biz_type = r.biz_type,
            x = r.loc_x, y = r.loc_y, z = r.loc_z,
            sprite = sprite, color = color, nameplate = nameplate,
        }
    end
    return out
end

local function broadcastStorefronts()
    if not phase1() then return end
    TriggerClientEvent('palm6_business:storefronts', -1, storefrontList())
end

local function sendStorefronts(src)
    if not phase1() then return end
    TriggerClientEvent('palm6_business:storefronts', src, storefrontList())
end

-- Resolve a business type's serve economics + labels. Per-type profile ONLY when
-- Config.PerTypeMechanics is on; otherwise every field is the global Config.* value
-- (the live Phase-0 numbers) and labels are the Phase-0 defaults — so with the gate
-- off this is byte-for-byte the current economy. The faucet's four bounds are
-- unchanged; only the numbers differ per type. Always returns a full table.
local function serviceOf(bizType)
    local sp = (Config.PerTypeMechanics and typeInfo(bizType) and typeInfo(bizType).service) or nil
    local dl = Config.DefaultServeLabels or { verb = 'Serve a walk-in', serveNoun = 'customer', supplyNoun = 'supply' }
    return {
        payout     = (sp and sp.payout)     or Config.ServePayout,
        stockCost  = (sp and sp.stockCost)  or Config.StockUnitCost,
        cooldown   = (sp and sp.cooldown)   or Config.ServeCooldownSec,
        dailyCap   = (sp and sp.dailyCap)   or Config.DailyNpcIncome,
        maxSupply  = (sp and sp.maxSupply)  or Config.MaxSupplyUnits,
        verb       = (sp and sp.verb)       or dl.verb,
        serveNoun  = (sp and sp.serveNoun)  or dl.serveNoun,
        supplyNoun = (sp and sp.supplyNoun) or dl.supplyNoun,
    }
end

local function rosterOf(businessId)
    return MySQL.query.await(
        'SELECT citizenid, role, wage, clocked_in, name FROM palm6_business_members WHERE business_id = ? ORDER BY role DESC, hired_at ASC',
        { businessId }) or {}
end

local function insertLedger(businessId, actorCid, action, amount, balanceAfter, memo)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_business_ledger (business_id, actor_cid, action, amount, balance_after, memo) VALUES (?,?,?,?,?,?)',
            { businessId, actorCid, action, amount, balanceAfter, memo })
    end)
end

-- Credit the account by `amount` (amount already came from a real player). Logs.
-- Returns the new balance, or NIL if the business row no longer exists (0 rows
-- affected) — which can only happen if the business was CLOSED (deleted) between a
-- charge's ChargeBank and this credit landing. Callers that pulled a PLAYER's money
-- MUST refund on nil so a mid-close charge never destroys the payer's cash. In the
-- live Phase-0 system (no close feature) a business is never deleted, so this always
-- affects 1 and returns the balance exactly as before — no behaviour change.
-- NOTE: account_balance itself is always exact (the += is atomic); the ledger's
-- balance_after snapshot is read-back and best-effort under simultaneous writes.
local function creditAccount(businessId, amount, actorCid, action, memo)
    local aff = MySQL.update.await('UPDATE palm6_businesses SET account_balance = account_balance + ? WHERE id = ?', { amount, businessId })
    if aff ~= 1 then return nil end  -- business gone (closed mid-charge) — caller refunds
    local bal = MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { businessId }) or 0
    insertLedger(businessId, actorCid, action, amount, bal, memo)
    return bal
end

-- Atomic guarded debit for an ITEM / dirty-cash payout (NOT the account->bank
-- recoverable path). The account can NEVER go negative, and the debit is refused
-- while a recoverable payout is mid-settle (pending_amount > 0) so it can't
-- interleave with the withdraw/payroll reconcile — the same guard the register-
-- robbery debit uses. Returns the new balance on success, or nil if the account
-- couldn't cover `amount` (or a payout is pending). Caller logs the ledger row.
local function debitAccount(businessId, amount)
    local aff = MySQL.update.await(
        'UPDATE palm6_businesses SET account_balance = account_balance - ? WHERE id = ? AND account_balance >= ? AND pending_amount = 0',
        { amount, businessId, amount })
    if aff ~= 1 then return nil end
    return MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { businessId }) or 0
end

-- Crash-recoverable debit: guarded debit + a durable pending-payout marker set
-- in the SAME statement. A process kill after this commits (but before the bank
-- credit lands) leaves pending_amount>0, which reconcilePending() re-drives on
-- boot — the repo's recoverable-payout idiom (cf. dbmigrate 0054-0063), adapted
-- to the account->bank direction (withdraw/payroll). Returns new balance | nil.
-- The single marker is safe because account debits are owner-serial (only
-- withdraw + payroll touch it, both driven by one owner one action at a time).
-- The `AND pending_amount = 0` guard means a business can hold at most ONE
-- unsettled payout marker: a new debit is refused while a prior payout is still
-- mid-settle (or awaiting boot reconcile), so the single marker can never be
-- overwritten and lose an owed payment.
local function debitAccountWithPending(businessId, amount, payeeCid)
    local aff = MySQL.update.await([[
        UPDATE palm6_businesses
           SET account_balance = account_balance - ?,
               pending_cid = ?, pending_amount = ?, pending_at = ?
         WHERE id = ? AND account_balance >= ? AND pending_amount = 0
    ]], { amount, payeeCid, amount, nowSec(), businessId, amount })
    if aff ~= 1 then return nil end
    return MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { businessId }) or 0
end

-- In-flight settle marker (per business). Set for the WHOLE claim->credit->restore
-- window, so opClose can refuse to delete a business whose payout is mid-settle:
-- during that window the marker is already cleared (claim-before-credit) and the
-- account is 0, so the delete guard alone can't see the in-limbo payout. Defined
-- before settlePayout so the local is in scope.
local settleBusy = {}

-- Settle a pending payout exactly once. CLAIM-BEFORE-CREDIT: atomically clear the
-- marker first (so a crash after the claim can never re-pay -> no double-pay,
-- matching the repo's claim-before-credit idiom), THEN issue the bank credit;
-- reverse the account debit if the credit fails in-process. Callable from the
-- live path OR the boot reconcile — whichever wins the atomic claim pays once.
-- Returns 'paid' | 'lost' (claimed but credit failed, refunded) | 'taken'
-- (another caller already claimed it).
local function settlePayout(businessId, payeeCid, amount, reason)
    settleBusy[businessId] = true
    local claimed = MySQL.update.await(
        'UPDATE palm6_businesses SET pending_amount = 0, pending_cid = NULL, pending_at = 0 WHERE id = ? AND pending_amount = ? AND pending_cid = ?',
        { businessId, amount, payeeCid })
    if claimed ~= 1 then settleBusy[businessId] = nil; return 'taken' end
    if Bridge.CreditBankByCitizenId(payeeCid, amount, reason) then settleBusy[businessId] = nil; return 'paid' end
    -- Credit failed: restore to the account. If the business is GONE (creditAccount
    -- returns nil — e.g. it was closed in a race the settleBusy guard didn't cover),
    -- send the money straight to the payee's bank instead of dropping it. Belt to the
    -- settleBusy braces: the payout money is never destroyed.
    -- The nil-detection relies on `amount > 0` (a +0 credit could report 0 changed
    -- rows and spuriously orphan-refund) — all three settle callers guarantee it:
    -- withdraw clamps to MinAmount>=1, payroll filters wage>0, close settles only when
    -- amount>0. Keep that invariant if a new settle caller is ever added.
    if not creditAccount(businessId, amount, payeeCid, 'payout-refund', 'Payout reversed (credit failed)') then
        Bridge.CreditBankByCitizenId(payeeCid, amount, 'business-payout-orphan-refund')
    end
    -- NOTE (liveness, money-safe): settleBusy is cleared inline on each return rather
    -- than in a finally. A thrown DB await (DB down) would leave it set, making the
    -- business un-closeable until resource restart — fail-safe (the durable pending
    -- marker + boot reconcile govern the money regardless), not money-stranding.
    settleBusy[businessId] = nil
    return 'lost'
end

-- Boot reconcile: re-drive any payout that was debited from an account but whose
-- bank credit never confirmed before a crash/restart. The atomic claim in
-- settlePayout guarantees each is paid at most once. Runs regardless of
-- Config.Enabled so money from a previously-enabled period is always recovered.
local function reconcilePending()
    local rows = MySQL.query.await('SELECT id, pending_cid, pending_amount FROM palm6_businesses WHERE pending_amount > 0') or {}
    for _, r in ipairs(rows) do
        if r.pending_cid and r.pending_amount and r.pending_amount > 0 then
            local res = settlePayout(r.id, r.pending_cid, r.pending_amount, 'business-payout-reconcile')
            print(('[palm6_business] reconcile: business %s owed %s $%s -> %s'):format(r.id, r.pending_cid, r.pending_amount, res))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Ephemeral intent (in-memory, NOT money state): pending hire/charge prompts +
-- per-actor anti-spam cooldowns. Cleared on drop.
-- ---------------------------------------------------------------------------
local pendingHire = {}    -- [targetSrc] = { businessId, businessName, ownerCid, expiresAt }
local pendingCharge = {}  -- [targetSrc] = { businessId, businessName, cashierCid, amount, memo, expiresAt }
local hireCd = {}         -- [src] = epoch
local chargeCd = {}       -- [src] = epoch
local robberCd = {}       -- [src] = epoch (per-robber /robstore cooldown, set before any DB yield)
local payrollBusy = {}    -- [businessId] = true while a payroll run is in flight (serializes payroll per business)
local lifecycleBusy = {}  -- [businessId] = true while a transfer/close is in flight (mutually exclusive)

local function onCooldown(map, src, seconds)
    local t = map[src]
    if t and (nowSec() - t) < seconds then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Menu snapshot -> client
-- ---------------------------------------------------------------------------
local function pushMenu(src)
    if not enabled() then return end  -- dark-ship: no reads/emits while disabled
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    local data = { enabled = true, types = Config.Types }
    if m then
        local today = dayKey()
        local dayIncome = (m.day_key == today) and (m.day_npc_income or 0) or 0
        local isOwner = m.role >= Config.Role.Owner
        local svc = serviceOf(m.biz_type)
        data.business = {
            id = m.business_id,
            name = m.business_name,
            biz_type = m.biz_type,
            role = m.role,
            roleName = Config.RoleName[m.role] or '?',
            supply = m.supply_units or 0,
            clockedIn = m.clocked_in == 1,
            dayIncome = dayIncome,
            dailyCap = svc.dailyCap,
        }
        -- Owner-scoped data (coworker citizenids/wages + the account balance) is
        -- attached ONLY for the owner — the SERVER is the authority on what a
        -- non-owner may receive, not the client's render gate. A role=1 employee
        -- must never receive the roster or balance in the menuData payload.
        if isOwner then
            data.business.balance = m.account_balance or 0
        end
        -- Roster goes to owners AND (when the delegate feature is on) managers — a
        -- manager needs it to hire/fire/run payroll. The account BALANCE stays
        -- owner-only. Server-authoritative: a role-1 employee receives neither.
        if isOwner or (managerEnabled() and m.role >= Config.Role.Manager) then
            data.business.roster = rosterOf(m.business_id)
        end
        data.cfg = {
            stockUnitCost = svc.stockCost,
            servePayout = svc.payout,
            maxSupply = svc.maxSupply,
            maxWage = Config.MaxWage,
            labels = { verb = svc.verb, serveNoun = svc.serveNoun, supplyNoun = svc.supplyNoun },
        }
        -- Phase 1: storefront state drives the proximity gate + owner controls.
        -- `set`=has a placed location; `atStorefront`=owner/employee is close enough
        -- to manage/serve. When Phase 1 is off, `enabled=false` and the client
        -- renders exactly the Phase-0 menu (no gate, no storefront controls).
        if phase1() then
            local sf = storefrontOf(m.business_id)
            local set = hasLoc(sf)
            data.business.storefront = {
                enabled = true,
                set = set,
                atStorefront = (not set) or nearLoc(src, sf),
                sprite = set and (sf.blip_sprite or defaultSprite(m.biz_type)) or nil,
                color = set and (sf.blip_color or defaultColor()) or nil,
            }
            data.cfg.storefront = {
                radius = storefrontRadius(),
                sprites = Config.Storefront.Sprites,
                colors = Config.Storefront.Colors,
            }
            -- Starter Pack (store SKU) cosmetic controls — owner-only, and only
            -- when the owner holds the entitlement AND the pack layer is enabled.
            -- The scoped nameplate/skin SELECT runs only here (starterPackEnabled),
            -- so a lagged 0073 migration never touches gate-off code. The client
            -- shows "Set nameplate" / "Choose skin" only when starterPack.unlocked.
            if isOwner and starterPackEnabled() and hasStarterEntitlement(cid) then
                local cos = MySQL.single.await('SELECT nameplate, skin FROM palm6_businesses WHERE id = ?', { m.business_id })
                data.business.starterPack = {
                    unlocked = true,
                    nameplate = (cos and cos.nameplate ~= '' and cos.nameplate) or nil,
                    skin = (cos and cos.skin) or nil,
                }
                data.cfg.starterPack = {
                    nameplateMaxLen = Config.StarterPack.NameplateMaxLen,
                    skins = Config.StarterPack.Skins,
                }
            end
        end
    else
        data.cfg = { registrationCost = Config.RegistrationCost }
    end
    TriggerClientEvent('palm6_business:menuData', src, data)
end

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

local function opRegister(src, rawName, typeKey)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if getMembership(cid) then
        return notify(src, 'Business', 'You already belong to a business.', 'error')
    end
    local name = sanitizeName(rawName)
    if not name then
        return notify(src, 'Business', ('Name must be %d-%d letters/digits.'):format(Config.NameMinLen, Config.NameMaxLen), 'error')
    end
    local ti = typeInfo(typeKey)
    if not ti then return notify(src, 'Business', 'Unknown business type.', 'error') end
    if MySQL.scalar.await('SELECT id FROM palm6_businesses WHERE name = ?', { name }) then
        return notify(src, 'Business', 'That business name is taken.', 'error')
    end
    -- Charge-before-create: the registration fee is a clean-money SINK.
    if not Bridge.ChargeBank(src, Config.RegistrationCost, 'business-register') then
        return notify(src, 'Business', ('You need $%d in the bank to register.'):format(Config.RegistrationCost), 'error')
    end
    local id
    local okIns = pcall(function()
        id = MySQL.insert.await(
            'INSERT INTO palm6_businesses (owner_cid, name, biz_type, account_balance, supply_units, day_key, day_npc_income) VALUES (?,?,?,0,0,?,0)',
            { cid, name, typeKey, dayKey() })
    end)
    if not okIns or not id then
        Bridge.CreditBankByCitizenId(cid, Config.RegistrationCost, 'business-register-refund')
        return notify(src, 'Business', 'Could not register (name may have just been taken). Refunded.', 'error')
    end
    local okMem = pcall(function()
        MySQL.insert.await(
            'INSERT INTO palm6_business_members (citizenid, business_id, role, wage, clocked_in, name) VALUES (?,?,?,0,1,?)',
            { cid, id, Config.Role.Owner, Bridge.GetPlayerName(src) })
    end)
    if not okMem then
        MySQL.update.await('DELETE FROM palm6_businesses WHERE id = ?', { id })
        Bridge.CreditBankByCitizenId(cid, Config.RegistrationCost, 'business-register-refund')
        return notify(src, 'Business', 'Could not register. Refunded.', 'error')
    end
    insertLedger(id, cid, 'register', 0, 0, ('Registered %s (fee $%d)'):format(ti.label, Config.RegistrationCost))
    notify(src, 'Business', ('%s is registered. Open /%s to run it.'):format(name, Config.Command), 'success')
    pushMenu(src)
end

local function opDeposit(src, amount)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can move the account.', 'error') end
    amount = clampInt(amount, Config.MinAmount, Config.MaxPerAction)
    if not amount or amount < Config.MinAmount then return notify(src, 'Business', 'Invalid amount.', 'error') end
    -- Charge-before-credit. NOTE: the player-side debit is qbx in-memory
    -- (persisted on the next player-save), while creditAccount is immediately
    -- durable. A HARD crash (not a graceful stop, which saves players) after the
    -- account credit but before that save could keep the account gain without the
    -- player's debit. This is the SAME in-memory window every ChargeBank->durable
    -- -write path in this codebase carries (lottery/flashdrop/etc.); a graceful
    -- deploy-restart is safe. Accepted, codebase-wide; not special-cased here.
    if not Bridge.ChargeBank(src, amount, 'business-deposit') then
        return notify(src, 'Business', 'Not enough in your bank.', 'error')
    end
    local bal = creditAccount(m.business_id, amount, cid, 'deposit', 'Owner deposit')
    if not bal then  -- business closed between the charge and the credit — refund
        Bridge.CreditBankByCitizenId(cid, amount, 'business-deposit-refund')
        return notify(src, 'Business', 'That business just closed — your deposit was refunded.', 'error')
    end
    notify(src, 'Business', ('Deposited $%d. Account: $%d.'):format(amount, bal), 'success')
    pushMenu(src)
end

local function opWithdraw(src, amount)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can move the account.', 'error') end
    amount = clampInt(amount, Config.MinAmount, Config.MaxPerAction)
    if not amount or amount < Config.MinAmount then return notify(src, 'Business', 'Invalid amount.', 'error') end
    local bal = debitAccountWithPending(m.business_id, amount, cid)
    if not bal then return notify(src, 'Business', 'The business account cannot cover that (or a payout is still settling).', 'error') end
    local res = settlePayout(m.business_id, cid, amount, 'business-withdraw')
    if res == 'paid' then
        insertLedger(m.business_id, cid, 'withdraw', -amount, bal, 'Owner withdraw')
        notify(src, 'Business', ('Withdrew $%d. Account: $%d.'):format(amount, bal), 'success')
        pushMenu(src)
    elseif res == 'lost' then
        notify(src, 'Business', 'Payout failed, reversed. Try again.', 'error')
    else
        notify(src, 'Business', 'That payout was already processed.', 'inform')
    end
end

local function opBuyStock(src, qty)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < minManageRole() then return notify(src, 'Business', 'You do not have permission to buy supply.', 'error') end
    local svc = serviceOf(m.biz_type)
    qty = clampInt(qty, 1, Config.StockMaxPerBuy)
    if not qty or qty < 1 then return notify(src, 'Business', 'Invalid quantity.', 'error') end
    local room = svc.maxSupply - (m.supply_units or 0)
    if room <= 0 then return notify(src, 'Business', 'Supply storage is full.', 'error') end
    if qty > room then qty = room end
    local cost = qty * svc.stockCost
    if not Bridge.ChargeBank(src, cost, 'business-stock') then
        return notify(src, 'Business', ('You need $%d for %d supply.'):format(cost, qty), 'error')
    end
    -- Atomic guard uses the per-type ceiling (same shape; svc.maxSupply == global
    -- Config.MaxSupplyUnits while PerTypeMechanics is off).
    local aff = MySQL.update.await(
        'UPDATE palm6_businesses SET supply_units = supply_units + ? WHERE id = ? AND supply_units + ? <= ?',
        { qty, m.business_id, qty, svc.maxSupply })
    if aff ~= 1 then
        Bridge.CreditBankByCitizenId(cid, cost, 'business-stock-refund')
        return notify(src, 'Business', 'Storage filled up. Refunded.', 'error')
    end
    local bal = MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { m.business_id }) or 0
    insertLedger(m.business_id, cid, 'stock', 0, bal, ('Bought %dx supply ($%d)'):format(qty, cost))
    notify(src, 'Business', ('Bought %d supply for $%d.'):format(qty, cost), 'success')
    pushMenu(src)
end

-- NPC walk-in serve — the ONE faucet. Bounded by: clocked-in worker + supply
-- (cost basis) + per-worker cooldown + per-business daily cap. The client
-- skill-check is UX (active play); the money gates below are the real controls.
local function opServe(src)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m then return notify(src, 'Business', 'You do not work anywhere.', 'error') end
    if m.clocked_in ~= 1 then return notify(src, 'Business', 'Clock in first.', 'error') end
    local svc = serviceOf(m.biz_type)
    if Config.NpcRequiresSupply and (m.supply_units or 0) < 1 then
        return notify(src, 'Business', ('No %s to serve with.'):format(svc.supplyNoun), 'error')
    end
    if (nowSec() - (m.last_serve_at or 0)) < svc.cooldown then
        return notify(src, 'Business', 'Serving too fast — wait a moment.', 'error')
    end
    local today = dayKey()
    local dayIncome = (m.day_key == today) and (m.day_npc_income or 0) or 0
    if dayIncome + svc.payout > svc.dailyCap then
        return notify(src, 'Business', 'This business hit its daily walk-in limit.', 'error')
    end
    -- Phase 1: a walk-in is served AT the shop. Only bites when Phase 1 is on AND a
    -- storefront is placed; a business with no storefront serves as it did in Phase 0.
    -- This is an immersion gate, not a money control — the faucet stays bounded by
    -- supply/cooldown/daily-cap regardless of where the serve is triggered.
    if phase1() then
        local sf = storefrontOf(m.business_id)
        if hasLoc(sf) and not nearLoc(src, sf) then
            return notify(src, 'Business', "Serve walk-ins at your storefront — it's marked on your map.", 'error')
        end
    end
    -- Atomic: consume 1 supply + credit payout + bump today's income, all guarded
    -- on supply>=1 AND the daily cap (WHERE reads the pre-update row). affected=0
    -- means a race lost the supply or the cap; re-read to message. pay/cap are the
    -- per-type values (== global while PerTypeMechanics is off).
    local pay, cap = svc.payout, svc.dailyCap
    local aff = MySQL.update.await([[
        UPDATE palm6_businesses
           SET supply_units = supply_units - 1,
               account_balance = account_balance + ?,
               day_npc_income = IF(day_key = ?, day_npc_income, 0) + ?,
               day_key = ?
         WHERE id = ?
           AND supply_units >= 1
           AND (IF(day_key = ?, day_npc_income, 0) + ?) <= ?
    ]], { pay, today, pay, today, m.business_id, today, pay, cap })
    if aff ~= 1 then
        return notify(src, 'Business', 'Could not serve (out of supply or at the daily limit).', 'error')
    end
    local bal = MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { m.business_id }) or 0
    insertLedger(m.business_id, '__NPC__', 'npc_sale', pay, bal, ('Walk-in %s'):format(svc.serveNoun))
    MySQL.update.await('UPDATE palm6_business_members SET last_serve_at = ? WHERE citizenid = ?', { nowSec(), cid })
    -- No pushMenu here: serving is a rapid, repeated action and reopening the
    -- root context menu each time would interrupt it. The notify confirms the
    -- payout; /business reopens with fresh supply/day figures.
    notify(src, 'Business', ('Served a %s (+$%d).'):format(svc.serveNoun, pay), 'success')
end

local function opClock(src, wantIn)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m then return notify(src, 'Business', 'You do not work anywhere.', 'error') end
    local val = wantIn and 1 or 0
    MySQL.update.await('UPDATE palm6_business_members SET clocked_in = ? WHERE citizenid = ?', { val, cid })
    notify(src, 'Business', val == 1 and 'Clocked in.' or 'Clocked out.', 'inform')
    pushMenu(src)
end

local function opHireNearest(src)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < minManageRole() then return notify(src, 'Business', 'You do not have permission to hire.', 'error') end
    if onCooldown(hireCd, src, Config.HireCooldownSec) then return notify(src, 'Business', 'Slow down.', 'error') end
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM palm6_business_members WHERE business_id = ?', { m.business_id }) or 0
    if count >= (Config.MaxEmployees + 1) then return notify(src, 'Business', 'Your roster is full.', 'error') end
    local myC = Bridge.GetCoords(src)
    if not myC then return end
    local bestSrc, bestDist
    for _, sid in ipairs(Bridge.GetOnlinePlayers()) do
        if sid ~= src then
            local theirCid = Bridge.GetCitizenId(sid)
            if theirCid and not getMembership(theirCid) then
                local c = Bridge.GetCoords(sid)
                if c then
                    local d = Bridge.Distance(myC, c)
                    if d <= Config.HireRadius and (not bestDist or d < bestDist) then
                        bestSrc, bestDist = sid, d
                    end
                end
            end
        end
    end
    if not bestSrc then return notify(src, 'Business', 'No unaffiliated person nearby.', 'error') end
    hireCd[src] = nowSec()
    pendingHire[bestSrc] = { businessId = m.business_id, businessName = m.business_name, ownerCid = cid, expiresAt = nowSec() + Config.HireExpirySec }
    TriggerClientEvent('palm6_business:hirePrompt', bestSrc, { businessName = m.business_name })
    notify(src, 'Business', 'Offer sent.', 'inform')
end

local function opAcceptHire(src)
    if not enabled() then return end
    local p = pendingHire[src]
    pendingHire[src] = nil
    if not p or nowSec() > p.expiresAt then return notify(src, 'Business', 'That offer expired.', 'error') end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if getMembership(cid) then return notify(src, 'Business', 'You already belong to a business.', 'error') end
    if not getBusinessById(p.businessId) then return notify(src, 'Business', 'That business no longer exists.', 'error') end
    -- Atomic conditional insert: the roster-cap COUNT is evaluated INSIDE the
    -- insert statement (wrapped in a derived table to satisfy MySQL's
    -- same-table-in-subquery rule), so there is no check-then-insert TOCTOU where
    -- two concurrent accepts could both pass a stale count and overshoot the cap.
    -- affected = 1 -> joined; 0 -> the roster was already at cap. The citizenid
    -- PRIMARY KEY remains the hard backstop against a double-join.
    local cap = Config.MaxEmployees + 1
    local affected = 0
    local ok = pcall(function()
        affected = MySQL.update.await([[
            INSERT INTO palm6_business_members (citizenid, business_id, role, wage, clocked_in, name)
            SELECT ?, ?, ?, 0, 0, ?
              FROM (SELECT COUNT(*) AS cnt FROM palm6_business_members WHERE business_id = ?) AS c
             WHERE c.cnt < ?
               AND EXISTS (SELECT 1 FROM palm6_businesses WHERE id = ?)
        ]], { cid, p.businessId, Config.Role.Employee, Bridge.GetPlayerName(src), p.businessId, cap, p.businessId })
    end)
    if not ok then return notify(src, 'Business', 'Could not join.', 'error') end
    -- affected=0 also covers a business CLOSED (deleted) in this exact window: the
    -- EXISTS guard makes the INSERT a no-op instead of writing an orphan member row
    -- that would permanently soft-lock the hire (getMembership INNER-JOINs businesses).
    if affected ~= 1 then return notify(src, 'Business', 'Could not join (the roster filled up or the business closed).', 'error') end
    notify(src, 'Business', ('You joined %s.'):format(p.businessName), 'success')
    local ownerSrc = Bridge.GetSourceByCitizenId(p.ownerCid)
    if ownerSrc then notify(ownerSrc, 'Business', ('%s joined the team.'):format(Bridge.GetPlayerName(src)), 'success') end
end

local function opFire(src, targetCid)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < minManageRole() then return notify(src, 'Business', 'You do not have permission to fire.', 'error') end
    if type(targetCid) ~= 'string' or targetCid == '' or targetCid == cid then return end
    -- Target must rank strictly BELOW the actor: an owner (3) can fire managers +
    -- employees; a manager (2) can fire employees only — never a peer manager or the
    -- owner. `role < ?actorRole` enforces this in the DELETE itself (server-authoritative).
    local aff = MySQL.update.await(
        'DELETE FROM palm6_business_members WHERE citizenid = ? AND business_id = ? AND role < ?',
        { targetCid, m.business_id, m.role })
    if aff ~= 1 then return notify(src, 'Business', 'Not on your roster (or outranks you).', 'error') end
    notify(src, 'Business', 'Removed from the roster.', 'inform')
    local ts = Bridge.GetSourceByCitizenId(targetCid)
    if ts then notify(ts, 'Business', ('You were let go from %s.'):format(m.business_name), 'inform') end
    pushMenu(src)
end

local function opSetWage(src, targetCid, amount)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner sets wages.', 'error') end
    if type(targetCid) ~= 'string' or targetCid == '' then return end
    amount = clampInt(amount, 0, Config.MaxWage)
    if amount == nil then return notify(src, 'Business', 'Invalid wage.', 'error') end
    local aff = MySQL.update.await(
        'UPDATE palm6_business_members SET wage = ? WHERE citizenid = ? AND business_id = ? AND role < ?',
        { amount, targetCid, m.business_id, Config.Role.Owner })
    if aff ~= 1 then return notify(src, 'Business', 'Not on your roster.', 'error') end
    notify(src, 'Business', ('Wage set to $%d/run.'):format(amount), 'success')
    pushMenu(src)
end

-- Promote an employee to Manager (owner-only + manager gate). Atomic: the manager
-- cap is evaluated INSIDE the UPDATE via a materialised derived table (dodging
-- MySQL's can't-self-select-in-UPDATE rule, same idiom as opAcceptHire), and the
-- target must currently be an Employee. affected=1 -> promoted; 0 -> not a
-- promotable employee on this roster, or the manager slots are full.
local function opPromote(src, targetCid)
    if not enabled() or not managerEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can promote.', 'error') end
    if type(targetCid) ~= 'string' or targetCid == '' or targetCid == cid then return end
    local cap = Config.MaxManagers or 0
    local affected = 0
    local ok = pcall(function()
        affected = MySQL.update.await([[
            UPDATE palm6_business_members AS t
              JOIN (SELECT COUNT(*) AS cnt FROM palm6_business_members WHERE business_id = ? AND role = ?) AS c
                SET t.role = ?
              WHERE t.citizenid = ? AND t.business_id = ? AND t.role = ? AND c.cnt < ?
        ]], { m.business_id, Config.Role.Manager, Config.Role.Manager, targetCid, m.business_id, Config.Role.Employee, cap })
    end)
    if not ok then return notify(src, 'Business', 'Could not promote.', 'error') end
    if affected ~= 1 then return notify(src, 'Business', 'Not a promotable employee, or the manager slots are full.', 'error') end
    notify(src, 'Business', 'Promoted to Manager.', 'success')
    local ts = Bridge.GetSourceByCitizenId(targetCid)
    if ts then notify(ts, 'Business', ('You were promoted to Manager at %s.'):format(m.business_name), 'success') end
    pushMenu(src)
end

-- Demote a Manager back to Employee (owner-only + manager gate). Only a current
-- Manager is affected; an owner can never be demoted (role = Manager guard).
local function opDemote(src, targetCid)
    if not enabled() or not managerEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can demote.', 'error') end
    if type(targetCid) ~= 'string' or targetCid == '' or targetCid == cid then return end
    local aff = MySQL.update.await(
        'UPDATE palm6_business_members SET role = ? WHERE citizenid = ? AND business_id = ? AND role = ?',
        { Config.Role.Employee, targetCid, m.business_id, Config.Role.Manager })
    if aff ~= 1 then return notify(src, 'Business', 'That person is not a manager here.', 'error') end
    notify(src, 'Business', 'Demoted to Employee.', 'inform')
    local ts = Bridge.GetSourceByCitizenId(targetCid)
    if ts then notify(ts, 'Business', ('You were demoted to Employee at %s.'):format(m.business_name), 'inform') end
    pushMenu(src)
end

-- Transfer ownership to an existing roster member. Owner-only + lifecycle gate. The
-- target is PROMOTED FIRST under an affected-row guard, so if they just resigned the
-- transfer aborts BEFORE the old owner is demoted — the business can never end up
-- ownerless. No money moves. (Owner-serial, rare action; a mid-sequence DB failure
-- leaves at worst a recoverable two-owner state, never money loss.)
local function opTransfer(src, targetCid)
    if not lifecycleEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can transfer the business.', 'error') end
    if type(targetCid) ~= 'string' or targetCid == '' or targetCid == cid then
        return notify(src, 'Business', 'Pick a different roster member to hand it to.', 'error')
    end
    -- Serialize the whole ownership lifecycle per business: a transfer/close already
    -- in flight makes this refuse. Set synchronously right after getMembership (no
    -- yield between its resolve and here), so two concurrent transfers can't both
    -- promote a target and mint TWO owners, and a close can't delete mid-transfer.
    local bizId = m.business_id
    if lifecycleBusy[bizId] or settleBusy[bizId] or payrollBusy[bizId] then
        return notify(src, 'Business', 'The business is busy — try again in a moment.', 'error')
    end
    lifecycleBusy[bizId] = true
    -- Promote the target to Owner ONLY IF they are currently a member of THIS business
    -- ranked below owner. affected=1 -> they are valid + now owner; 0 -> not on the roster.
    local promoted = MySQL.update.await(
        'UPDATE palm6_business_members SET role = ? WHERE citizenid = ? AND business_id = ? AND role < ?',
        { Config.Role.Owner, targetCid, bizId, Config.Role.Owner })
    if promoted ~= 1 then
        lifecycleBusy[bizId] = nil
        return notify(src, 'Business', 'That person is not on your roster.', 'error')
    end
    -- Old owner steps down to Employee; business owner_cid follows.
    MySQL.update.await('UPDATE palm6_business_members SET role = ? WHERE citizenid = ? AND business_id = ? AND role = ?',
        { Config.Role.Employee, cid, bizId, Config.Role.Owner })
    MySQL.update.await('UPDATE palm6_businesses SET owner_cid = ? WHERE id = ?', { targetCid, bizId })
    -- Starter Pack: premium cosmetics belong to the OWNER's entitlement, so they
    -- must not outlive a transfer to someone who didn't buy the pack. Clear the
    -- nameplate/skin unless the NEW owner is entitled. Guarded by starterPackEnabled()
    -- so a gate-off transfer never references the 0073 columns.
    if starterPackEnabled() and not hasStarterEntitlement(targetCid) then
        MySQL.update.await('UPDATE palm6_businesses SET nameplate = NULL, skin = NULL WHERE id = ?', { bizId })
    end
    insertLedger(bizId, cid, 'transfer', 0,
        MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { bizId }) or 0,
        ('Ownership transferred to %s'):format(targetCid))
    lifecycleBusy[bizId] = nil
    notify(src, 'Business', ('You handed %s over. You are now an employee.'):format(m.business_name), 'success')
    local ts = Bridge.GetSourceByCitizenId(targetCid)
    if ts then notify(ts, 'Business', ('You are now the owner of %s.'):format(m.business_name), 'success') end
    pushMenu(src)
end

-- Close/dissolve the business. Owner-only + lifecycle gate. The remaining account
-- balance is refunded to the OWNER (their own money) via the crash-safe pending
-- idiom, THEN the business + roster are deleted. Reuses opClose's serialization
-- through the pending marker (guarded pending_amount=0): the capture zeroes the
-- account and stashes the exact balance in one atomic UPDATE, so no serve can race
-- money in after the refund amount is fixed. The ledger is kept (audit trail).
local function opClose(src)
    if not lifecycleEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can close the business.', 'error') end
    local bizId = m.business_id
    -- Refuse while a payout/payroll is mid-settle for this business: during the
    -- claim->credit window the marker is cleared and the account is 0, so the delete
    -- guard alone can't see the in-limbo payout. These in-memory flags are set
    -- synchronously before any DB await, so a settle already in flight is visible here.
    if settleBusy[bizId] or payrollBusy[bizId] or lifecycleBusy[bizId] then
        return notify(src, 'Business', 'The business is busy — try again in a moment.', 'error')
    end
    -- Hold the lifecycle lock for the whole close so a concurrent transfer can't
    -- re-own (and lose) a business mid-delete. Cleared at every exit below.
    lifecycleBusy[bizId] = true
    -- Atomically drain the whole balance INTO the pending marker (MySQL evaluates SET
    -- left-to-right, so pending_amount reads the OLD balance before it is zeroed). The
    -- pending_amount=0 guard means a payout already mid-settle blocks the close — retry.
    local captured = MySQL.update.await([[
        UPDATE palm6_businesses
           SET pending_cid = ?, pending_amount = account_balance, pending_at = ?, account_balance = 0
         WHERE id = ? AND pending_amount = 0
    ]], { cid, nowSec(), bizId })
    if captured ~= 1 then lifecycleBusy[bizId] = nil; return notify(src, 'Business', 'Cannot close right now (a payout is still settling). Try again.', 'error') end
    local amount = MySQL.scalar.await('SELECT pending_amount FROM palm6_businesses WHERE id = ?', { bizId }) or 0
    if amount > 0 then
        local res = settlePayout(bizId, cid, amount, 'business-close-refund')
        if res ~= 'paid' then
            -- Credit failed + account already refunded by settlePayout('lost'), or a
            -- reconcile claimed it ('taken'). Either way the money is safe but NOT
            -- fully in hand this call — do NOT delete; the owner keeps the business.
            lifecycleBusy[bizId] = nil
            return notify(src, 'Business', 'Refund could not complete — business kept. Try closing again.', 'error')
        end
    else
        -- Nothing to refund; clear the (zero) marker we set so the row is clean.
        MySQL.update.await('UPDATE palm6_businesses SET pending_cid = NULL, pending_amount = 0, pending_at = 0 WHERE id = ?', { bizId })
    end
    -- Delete the BUSINESS ROW FIRST, guarded on an empty account. The credit paths
    -- (opServe faucet, creditAccount for charge/deposit) don't hold the pending
    -- marker, so a serve/charge could have raced money into the account after the
    -- capture. If so, this DELETE affects 0 rows and the business SURVIVES with that
    -- residual — the owner already got `amount` back and simply re-closes to sweep
    -- the rest. We therefore NEVER delete a business that still holds money, so no
    -- credited money is destroyed. Once the row is gone, getMembership + every credit
    -- UPDATE (WHERE id=?) affect 0 rows — creditAccount returns nil and its callers
    -- refund the payer — so members can be removed safely afterwards.
    local delBiz = MySQL.update.await('DELETE FROM palm6_businesses WHERE id = ? AND account_balance = 0 AND pending_amount = 0', { bizId })
    if delBiz ~= 1 then
        lifecycleBusy[bizId] = nil
        return notify(src, 'Business', ('Activity landed mid-close — %s refunded, but funds came in. Close again to finish.'):format(m.business_name), 'inform')
    end
    -- Ledger rows are kept as an orphaned audit trail (ids never reused).
    local members = MySQL.query.await('SELECT citizenid FROM palm6_business_members WHERE business_id = ?', { bizId }) or {}
    MySQL.update.await('DELETE FROM palm6_business_members WHERE business_id = ?', { bizId })
    insertLedger(bizId, cid, 'close', -amount, 0, ('Business closed — $%d refunded'):format(amount))
    notify(src, 'Business', ('%s is closed. $%d returned to your bank.'):format(m.business_name, amount), 'success')
    for _, e in ipairs(members) do
        if e.citizenid ~= cid then
            local es = Bridge.GetSourceByCitizenId(e.citizenid)
            if es then notify(es, 'Business', ('%s has shut down.'):format(m.business_name), 'inform') end
        end
    end
    lifecycleBusy[bizId] = nil
    if phase1() then broadcastStorefronts() end  -- drop the closed business's blip/target
    pushMenu(src)
end

-- Pay each clocked-in employee (wage>0) from the account, capped at the live
-- balance — the atomic debit means payroll can NEVER overdraw. Stops when funds
-- run out; nothing is minted.
local function runPayroll(src, m)
    -- Payee set = ranks STRICTLY BELOW THE ACTOR (role < m.role), NOT a constant
    -- Owner. This keeps the actor out of their own payee set: a manager (2) pays
    -- employees only, never themselves or a peer manager; an owner (3) still pays
    -- managers + employees (role < 3) — so with ManagerRole off (only the owner
    -- ever reaches here, m.role=3) the payee set is byte-for-byte the old role<Owner.
    -- Without this, a manager was inside their own payee set and could pay themselves.
    --
    -- DAY-LOCK (only while the delegate feature is on): each member is paid at most
    -- once per UTC day, so a manager can disburse an owner-set wage only ONCE per
    -- period — not spam payroll to drain the account to a colluding clocked-in
    -- employee. Off = live Phase-0 behaviour (no lock), untouched.
    local today = dayKey()
    local lockOn = managerEnabled()
    local sql = 'SELECT citizenid, wage, name FROM palm6_business_members WHERE business_id = ? AND role < ? AND wage > 0 AND clocked_in = 1'
    local params = { m.business_id, m.role }
    if lockOn then
        sql = sql .. ' AND (last_payroll_day IS NULL OR last_payroll_day <> ?)'
        params[#params + 1] = today
    end
    local emps = MySQL.query.await(sql, params) or {}
    if #emps == 0 then
        return notify(src, 'Business', lockOn and 'Everyone eligible has already been paid this period.' or 'No clocked-in employees with a wage.', 'error')
    end
    local paid, total, ranDry = 0, 0, false
    for _, e in ipairs(emps) do
        local bal = debitAccountWithPending(m.business_id, e.wage, e.citizenid)
        if not bal then ranDry = true break end  -- insufficient funds (or a prior payout still settling)
        local res = settlePayout(m.business_id, e.citizenid, e.wage, 'business-payroll')
        if res == 'paid' then
            -- Stamp AFTER a confirmed pay so a dry-run (no funds) never marks someone
            -- paid-for-the-day without actually paying them. (A crash between settle
            -- and this stamp could allow one same-day re-pay of a single wage on the
            -- next run — rare + bounded; the pending-marker reconcile still pays once.)
            if lockOn then
                MySQL.update.await('UPDATE palm6_business_members SET last_payroll_day = ? WHERE citizenid = ? AND business_id = ?', { today, e.citizenid, m.business_id })
            end
            insertLedger(m.business_id, e.citizenid, 'payroll', -e.wage, bal, ('Wage to %s'):format(e.name or e.citizenid))
            paid = paid + 1
            total = total + e.wage
            local es = Bridge.GetSourceByCitizenId(e.citizenid)
            if es then notify(es, 'Business', ('Payday: +$%d from %s.'):format(e.wage, m.business_name), 'success') end
        end
        -- 'lost' (credit failed -> account refunded) and 'taken' both leave money safe; skip.
    end
    notify(src, 'Business', ('Paid %d for $%d%s.'):format(paid, total, ranDry and ' (account ran out)' or ''), ranDry and 'error' or 'success')
    pushMenu(src)
end

-- Payroll entry point. SERIALIZES per business: the day-lock check and the stamp
-- are separate statements, so two concurrent runs could otherwise interleave past
-- the pay/stamp window and re-pay a member. An in-memory per-business in-flight
-- flag (set synchronously before any DB await, so a second call always sees it)
-- makes each business's payroll strictly one-at-a-time. Cleared in a finally-style
-- unconditional line after the pcall so it can never stick, even on error.
local function opPayroll(src)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < minManageRole() then return notify(src, 'Business', 'You do not have permission to run payroll.', 'error') end
    if payrollBusy[m.business_id] then return notify(src, 'Business', 'A payroll run is already in progress.', 'error') end
    payrollBusy[m.business_id] = true
    local ok, err = pcall(runPayroll, src, m)
    payrollBusy[m.business_id] = nil
    if not ok then
        print(('[palm6_business] payroll error (business %s): %s'):format(m.business_id, tostring(err)))
        notify(src, 'Business', 'Payroll could not complete.', 'error')
    end
end

local function opChargeNearest(src, amount, memo)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m then return notify(src, 'Business', 'You do not work anywhere.', 'error') end
    if onCooldown(chargeCd, src, Config.ChargeCooldownSec) then return notify(src, 'Business', 'Slow down.', 'error') end
    amount = clampInt(amount, Config.MinAmount, Config.ChargeMax)
    if not amount or amount < Config.MinAmount then return notify(src, 'Business', 'Invalid amount.', 'error') end
    memo = (type(memo) == 'string' and memo ~= '') and memo:sub(1, 64) or 'Sale'
    memo = memo:gsub("[^%w %&'%-%.,]", '')
    local myC = Bridge.GetCoords(src)
    if not myC then return end
    local bestSrc, bestDist
    for _, sid in ipairs(Bridge.GetOnlinePlayers()) do
        if sid ~= src then
            local c = Bridge.GetCoords(sid)
            if c then
                local d = Bridge.Distance(myC, c)
                if d <= Config.ChargeRadius and (not bestDist or d < bestDist) then bestSrc, bestDist = sid, d end
            end
        end
    end
    if not bestSrc then return notify(src, 'Business', 'No customer nearby.', 'error') end
    chargeCd[src] = nowSec()
    pendingCharge[bestSrc] = { businessId = m.business_id, businessName = m.business_name, cashierCid = cid, amount = amount, memo = memo, expiresAt = nowSec() + Config.ChargeExpirySec }
    TriggerClientEvent('palm6_business:chargePrompt', bestSrc, { businessName = m.business_name, amount = amount, memo = memo })
    notify(src, 'Business', 'Charge sent to the customer.', 'inform')
end

local function opAcceptCharge(src)
    if not enabled() then return end
    local p = pendingCharge[src]
    pendingCharge[src] = nil
    if not p or nowSec() > p.expiresAt then return notify(src, 'Business', 'That charge expired.', 'error') end
    if not getBusinessById(p.businessId) then return notify(src, 'Business', 'That business no longer exists.', 'error') end
    local customerCid = Bridge.GetCitizenId(src)
    if not customerCid then return end
    -- Charge-before-credit: pull the customer's bank first.
    if not Bridge.ChargeBank(src, p.amount, 'business-charge') then
        local cs = Bridge.GetSourceByCitizenId(p.cashierCid)
        if cs then notify(cs, 'Business', 'Customer could not pay.', 'error') end
        return notify(src, 'Business', 'You could not cover that charge.', 'error')
    end
    if not creditAccount(p.businessId, p.amount, customerCid, 'charge', p.memo) then
        -- The business was closed between this customer's ChargeBank and the credit
        -- landing — refund the customer so their real money is never destroyed.
        Bridge.CreditBankByCitizenId(customerCid, p.amount, 'business-charge-refund')
        return notify(src, 'Business', 'That business just closed — your payment was refunded.', 'error')
    end
    notify(src, 'Business', ('Paid $%d to %s.'):format(p.amount, p.businessName), 'success')
    local cs = Bridge.GetSourceByCitizenId(p.cashierCid)
    if cs then notify(cs, 'Business', ('Collected $%d from a customer.'):format(p.amount), 'success') end
end

local function opRename(src, rawName)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can rename.', 'error') end
    local name = sanitizeName(rawName)
    if not name then return notify(src, 'Business', 'Invalid name.', 'error') end
    if MySQL.scalar.await('SELECT id FROM palm6_businesses WHERE name = ? AND id <> ?', { name, m.business_id }) then
        return notify(src, 'Business', 'That name is taken.', 'error')
    end
    MySQL.update.await('UPDATE palm6_businesses SET name = ? WHERE id = ?', { name, m.business_id })
    notify(src, 'Business', ('Renamed to %s.'):format(name), 'success')
    -- Storefront blip/target labels carry the business name — refresh them on all
    -- clients (same idiom as opClose), else they show the OLD name until the next
    -- unrelated storefront mutation or a client reconnect.
    if phase1() then broadcastStorefronts() end
    pushMenu(src)
end

local function opResign(src)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m then return end
    if m.role >= Config.Role.Owner then
        return notify(src, 'Business', 'An owner cannot resign — transfer or close is coming later.', 'error')
    end
    -- Only claim "you left" if a row was actually removed. Guards the TOCTOU where a
    -- concurrent transfer promoted this member to Owner between getMembership and this
    -- DELETE (role<Owner now fails, 0 rows) — they're the new owner, not a leaver.
    local left = MySQL.update.await('DELETE FROM palm6_business_members WHERE citizenid = ? AND business_id = ? AND role < ?', { cid, m.business_id, Config.Role.Owner })
    if left ~= 1 then return pushMenu(src) end
    notify(src, 'Business', ('You left %s.'):format(m.business_name), 'inform')
    pushMenu(src)
end

local function opViewLedger(src)
    if not enabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m then return end
    local rows = MySQL.query.await(
        'SELECT action, amount, balance_after, memo, created_at FROM palm6_business_ledger WHERE business_id = ? ORDER BY id DESC LIMIT 15',
        { m.business_id }) or {}
    TriggerClientEvent('palm6_business:ledgerData', src, { name = m.business_name, rows = rows })
end

-- ---------------------------------------------------------------------------
-- Phase 1 — storefront placement + cosmetics + walk-up. All owner-gated (except
-- the walk-up, which serves staff and passersby differently) and behind phase1().
-- Location/heading are captured from the caller's REAL server-side ped position,
-- never a client-supplied coordinate. No money moves in any of these.
-- ---------------------------------------------------------------------------

local function opSetStorefront(src)
    if not phase1() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can place the storefront.', 'error') end
    local c = Bridge.GetCoords(src)
    if not c then return notify(src, 'Business', 'Could not read your position — try again.', 'error') end
    local h = Bridge.GetHeading(src)
    -- Preserve any previously-chosen blip look; only seed defaults on first placement.
    local sf = storefrontOf(m.business_id)
    local sprite = (sf and sf.blip_sprite) or defaultSprite(m.biz_type)
    local color = (sf and sf.blip_color) or defaultColor()
    MySQL.update.await(
        'UPDATE palm6_businesses SET loc_x = ?, loc_y = ?, loc_z = ?, loc_h = ?, blip_sprite = ?, blip_color = ? WHERE id = ?',
        { c.x, c.y, c.z, h, sprite, color, m.business_id })
    notify(src, 'Business', "Storefront placed here — it's on the map now.", 'success')
    broadcastStorefronts()
    pushMenu(src)
end

local function opClearStorefront(src)
    if not phase1() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can remove the storefront.', 'error') end
    -- Null the coords (keeps blip_sprite/color so a re-place remembers the look).
    MySQL.update.await('UPDATE palm6_businesses SET loc_x = NULL, loc_y = NULL, loc_z = NULL, loc_h = NULL WHERE id = ?', { m.business_id })
    notify(src, 'Business', 'Storefront removed from the map.', 'inform')
    broadcastStorefronts()
    pushMenu(src)
end

local function opSetBlip(src, sprite, color)
    if not phase1() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can restyle the blip.', 'error') end
    sprite = sanitizeInt(sprite)
    color = sanitizeInt(color)
    if not sprite or not ALLOWED_SPRITE[sprite] then return notify(src, 'Business', 'That blip icon is not allowed.', 'error') end
    if not color or not ALLOWED_COLOR[color] then return notify(src, 'Business', 'That blip colour is not allowed.', 'error') end
    MySQL.update.await('UPDATE palm6_businesses SET blip_sprite = ?, blip_color = ? WHERE id = ?', { sprite, color, m.business_id })
    notify(src, 'Business', 'Blip updated.', 'success')
    broadcastStorefronts()
    pushMenu(src)
end

-- Starter Pack: set the storefront's custom nameplate. Owner-only + requires the
-- per-owner Starter Pack entitlement + validated/sanitised server-side. An empty
-- input CLEARS it; a non-empty input that sanitises away (all-stripped or
-- blocklisted) is REJECTED (distinct from clear). Cosmetic only — no money.
local function opSetNameplate(src, raw)
    if not starterPackEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can set the nameplate.', 'error') end
    local rawTrim = (type(raw) == 'string' and raw:gsub('^%s+', ''):gsub('%s+$', '')) or ''
    -- CLEAR is always allowed for an owner (even without the entitlement) so a
    -- cosmetic can never get stuck. Setting a NEW nameplate requires the pack.
    if rawTrim == '' then
        MySQL.update.await('UPDATE palm6_businesses SET nameplate = NULL WHERE id = ?', { m.business_id })
        notify(src, 'Business', 'Nameplate cleared.', 'success')
        broadcastStorefronts(); pushMenu(src); return
    end
    if not hasStarterEntitlement(cid) then return notify(src, 'Business', 'The Business Starter Pack unlocks custom nameplates.', 'error') end
    local plate = sanitizeNameplate(raw)
    if not plate then return notify(src, 'Business', "That nameplate isn't allowed.", 'error') end
    MySQL.update.await('UPDATE palm6_businesses SET nameplate = ? WHERE id = ?', { plate, m.business_id })
    notify(src, 'Business', 'Nameplate updated.', 'success')
    broadcastStorefronts()
    pushMenu(src)
end

-- Starter Pack: set the storefront's premium blip skin. Owner-only + requires the
-- entitlement + the skin key must be in the Config.StarterPack.Skins allowlist. An
-- empty key CLEARS it (back to the base blip). Cosmetic only — no money.
local function opSetSkin(src, skinKey)
    if not starterPackEnabled() then return end
    local cid = Bridge.GetCitizenId(src)
    local m = getMembership(cid)
    if not m or m.role < Config.Role.Owner then return notify(src, 'Business', 'Only the owner can set the skin.', 'error') end
    -- CLEAR is always allowed for an owner (even without the entitlement); setting
    -- a premium skin requires the pack.
    if skinKey == nil or skinKey == '' then
        MySQL.update.await('UPDATE palm6_businesses SET skin = NULL WHERE id = ?', { m.business_id })
        notify(src, 'Business', 'Skin cleared.', 'success')
        broadcastStorefronts(); pushMenu(src); return
    end
    if not hasStarterEntitlement(cid) then return notify(src, 'Business', 'The Business Starter Pack unlocks premium skins.', 'error') end
    if type(skinKey) ~= 'string' or not SKIN_BY_KEY[skinKey] then
        return notify(src, 'Business', 'That skin is not allowed.', 'error')
    end
    MySQL.update.await('UPDATE palm6_businesses SET skin = ? WHERE id = ?', { skinKey, m.business_id })
    notify(src, 'Business', 'Skin updated.', 'success')
    broadcastStorefronts()
    pushMenu(src)
end

-- Walk-up to a storefront target. Staff of THAT business open management (pushMenu
-- re-computes atStorefront so the proximity gate still applies); anyone else gets a
-- read-only info card. No membership leak: a passerby never receives roster/balance.
local function opOpenHere(src, businessId)
    if not phase1() then return end
    businessId = sanitizeInt(businessId)
    if not businessId then return end
    local b = getBusinessById(businessId)
    if not b then return end
    local cid = Bridge.GetCitizenId(src)
    local m = cid and getMembership(cid) or nil
    if m and m.business_id == businessId then
        return pushMenu(src)
    end
    -- Passerby (not a member): only reveal the read-only card for a business that
    -- ACTUALLY PLACED a storefront AND that the caller is physically standing at —
    -- the card is meant to be reachable only by walking up to a real storefront
    -- target. Without these two checks a modified client could fire openHere(id) for
    -- id=1..N from anywhere and harvest every business's name/type/owner-character
    -- name (an enumeration oracle), including Phase-0 businesses with no map surface.
    local sf = storefrontOf(businessId)
    if not hasLoc(sf) or not nearLoc(src, sf) then return end
    local ownerName = MySQL.scalar.await(
        'SELECT name FROM palm6_business_members WHERE business_id = ? AND role = ? ORDER BY hired_at ASC LIMIT 1',
        { businessId, Config.Role.Owner })
    -- Starter Pack: a custom nameplate (when the pack is on) rides on the card too.
    local nameplate = nil
    if starterPackEnabled() then
        local p = MySQL.scalar.await('SELECT nameplate FROM palm6_businesses WHERE id = ?', { businessId })
        if p and p ~= '' then nameplate = p end
    end
    TriggerClientEvent('palm6_business:infoCard', src, {
        name = b.name, biz_type = b.biz_type, owner = ownerName or 'Unknown',
        nameplate = nameplate,
    })
end

-- Rob a business's register at its storefront. Non-member only; a CAPPED cut of the
-- account paid to the robber's bank — pure redistribution (atomic guarded debit,
-- never minted, never overdrawn), bounded by percent + hard cap + per-business +
-- per-robber cooldown, with a police alert + owner ping. Only the codebase-wide
-- ChargeBank->durable in-memory window applies (graceful-restart safe).
local function opRob(src, businessId)
    if not robberyEnabled() then return end
    businessId = sanitizeInt(businessId)
    if not businessId then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    -- Per-robber cooldown: checked here, STAMPED on a successful rob (below). The
    -- hard anti-stack guards are proximity (one storefront in reach) + the atomic
    -- per-business cooldown + the eventguard budget, so the on-success stamp (rather
    -- than a pre-yield stamp) can't be gamed — you can't rob two shops from one spot.
    if onCooldown(robberCd, src, Config.Rob.RobberCooldownSec) then
        return notify(src, 'Business', 'Lay low for a bit before your next job.', 'error')
    end
    local m = getMembership(cid)
    if m and m.business_id == businessId then
        return notify(src, 'Business', "You can't rob your own business.", 'error')
    end
    local sf = storefrontOf(businessId)
    if not hasLoc(sf) then return notify(src, 'Business', 'Nothing to rob here.', 'error') end
    local pc = Bridge.GetCoords(src)
    if not pc or Bridge.Distance(pc, { x = sf.loc_x, y = sf.loc_y, z = sf.loc_z }) > Config.Rob.Radius then
        return notify(src, 'Business', 'Get to the register first.', 'error')
    end
    -- Capture the owner cid alongside the balance so a credit-failure rollback can
    -- reroute the take to the owner if the business was CLOSED (deleted) mid-robbery.
    local biz = MySQL.single.await('SELECT account_balance, owner_cid FROM palm6_businesses WHERE id = ?', { businessId })
    local bal = (biz and biz.account_balance) or 0
    local ownerCidAtStart = biz and biz.owner_cid or nil
    if bal < Config.Rob.Min then
        return notify(src, 'Business', 'The register is basically empty — not worth it.', 'error')
    end
    local amount = math.floor(bal * Config.Rob.Pct)
    if amount > Config.Rob.Max then amount = Config.Rob.Max end
    if amount < 1 then return notify(src, 'Business', 'Nothing worth taking.', 'error') end
    local now = nowSec()
    -- Atomic: debit + stamp the per-business cooldown, guarded on balance, cooldown
    -- elapsed, and no payout mid-settle. affected=0 -> raced / on cooldown / a payout
    -- is pending -> refuse. This one statement also anti-double-robs: a second robber
    -- fails the cooldown guard the instant the first stamps last_robbed_at.
    local aff = MySQL.update.await([[
        UPDATE palm6_businesses
           SET account_balance = account_balance - ?, last_robbed_at = ?
         WHERE id = ?
           AND account_balance >= ?
           AND pending_amount = 0
           AND (last_robbed_at IS NULL OR last_robbed_at + ? <= ?)
    ]], { amount, now, businessId, amount, Config.Rob.CooldownSec, now })
    if aff ~= 1 then
        return notify(src, 'Business', 'The register is locked down right now — try later.', 'error')
    end
    -- Pay the robber. On a credit failure, put the money back and clear the cooldown
    -- so the shop isn't wrongly locked for a rob that never paid out. If the business
    -- was CLOSED mid-robbery the restore affects 0 rows (row gone) — reroute the take
    -- to the owner's bank so the debited money is never destroyed (mirrors
    -- settlePayout's orphan-refund; the owner already got the close refund of the rest).
    if not Bridge.CreditBankByCitizenId(cid, amount, 'business-robbery') then
        local restored = MySQL.update.await('UPDATE palm6_businesses SET account_balance = account_balance + ?, last_robbed_at = NULL WHERE id = ?', { amount, businessId })
        if restored ~= 1 and ownerCidAtStart then
            Bridge.CreditBankByCitizenId(ownerCidAtStart, amount, 'business-robbery-orphan-refund')
        end
        return notify(src, 'Business', "Couldn't grab the cash — try again.", 'error')
    end
    robberCd[src] = now
    local bizRow = getBusinessById(businessId)
    insertLedger(businessId, cid, 'robbery', -amount, (bizRow and bizRow.account_balance) or 0, 'Register robbed')
    notify(src, 'Business', ('You cracked the register — +$%d.'):format(amount), 'success')
    if bizRow and bizRow.owner_cid then
        local os = Bridge.GetSourceByCitizenId(bizRow.owner_cid)
        if os then notify(os, 'Business', ('%s is being robbed!'):format(bizRow.name or 'Your business'), 'error') end
    end
    if math.random() < (Config.Rob.AlertChance or 0) then
        Bridge.PoliceAlert(src, 'Business robbery in progress')
    end
end

-- ---------------------------------------------------------------------------
-- Net events (guarded by palm6_eventguard — ensure order in custom.cfg).
-- ---------------------------------------------------------------------------
-- (No palm6_business:openMenu net event: the /business command opens the menu
-- server-side via cmd()->pushMenu, and every op re-pushes it. A client-triggered
-- open is only needed once Phase 1 adds a storefront ped/target, and will be
-- re-added with its eventguard budget then.)
RegisterNetEvent('palm6_business:register',   function(name, typeKey) opRegister(source, name, typeKey) end)
RegisterNetEvent('palm6_business:deposit',    function(amt) opDeposit(source, amt) end)
RegisterNetEvent('palm6_business:withdraw',   function(amt) opWithdraw(source, amt) end)
RegisterNetEvent('palm6_business:buyStock',   function(qty) opBuyStock(source, qty) end)
RegisterNetEvent('palm6_business:serve',      function() opServe(source) end)
RegisterNetEvent('palm6_business:clock',      function(wantIn) opClock(source, wantIn == true) end)
RegisterNetEvent('palm6_business:hireNearest',function() opHireNearest(source) end)
RegisterNetEvent('palm6_business:acceptHire', function() opAcceptHire(source) end)
RegisterNetEvent('palm6_business:fire',       function(cid) opFire(source, cid) end)
RegisterNetEvent('palm6_business:setWage',    function(cid, amt) opSetWage(source, cid, amt) end)
RegisterNetEvent('palm6_business:promote',    function(cid) opPromote(source, cid) end)
RegisterNetEvent('palm6_business:demote',     function(cid) opDemote(source, cid) end)
RegisterNetEvent('palm6_business:transfer',   function(cid) opTransfer(source, cid) end)
RegisterNetEvent('palm6_business:close',      function() opClose(source) end)
RegisterNetEvent('palm6_business:runPayroll', function() opPayroll(source) end)
RegisterNetEvent('palm6_business:chargeNearest', function(amt, memo) opChargeNearest(source, amt, memo) end)
RegisterNetEvent('palm6_business:acceptCharge',  function() opAcceptCharge(source) end)
RegisterNetEvent('palm6_business:viewLedger', function() opViewLedger(source) end)
RegisterNetEvent('palm6_business:rename',     function(name) opRename(source, name) end)
RegisterNetEvent('palm6_business:resign',     function() opResign(source) end)
-- Phase 1 storefront net events.
RegisterNetEvent('palm6_business:setStorefront',   function() opSetStorefront(source) end)
RegisterNetEvent('palm6_business:clearStorefront', function() opClearStorefront(source) end)
RegisterNetEvent('palm6_business:setBlip',         function(sprite, color) opSetBlip(source, sprite, color) end)
RegisterNetEvent('palm6_business:openHere',        function(businessId) opOpenHere(source, businessId) end)
RegisterNetEvent('palm6_business:requestStorefronts', function() sendStorefronts(source) end)
RegisterNetEvent('palm6_business:rob',             function(businessId) opRob(source, businessId) end)
RegisterNetEvent('palm6_business:setNameplate',    function(text) opSetNameplate(source, text) end)
RegisterNetEvent('palm6_business:setSkin',         function(key) opSetSkin(source, key) end)

AddEventHandler('playerDropped', function()
    local s = source
    pendingHire[s] = nil
    pendingCharge[s] = nil
    hireCd[s] = nil
    chargeCd[s] = nil
    robberCd[s] = nil
end)

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------
local function cmd(source)
    if not enabled() then
        return notify(source, 'Business', 'Businesses are not open yet.', 'error')
    end
    pushMenu(source)
end
Bridge.RegisterCommand(Config.Command, function(source) cmd(source) end)
if Config.CommandAlias and Config.CommandAlias ~= '' then
    Bridge.RegisterCommand(Config.CommandAlias, function(source) cmd(source) end)
end

-- Admin grant/revoke of the Starter Pack entitlement — a bridge until the Tebex
-- -> bot -> web chain writes palm6_business_entitlements directly. ACE-gated
-- (console/src 0 is always allowed; a player source needs Config.StarterPack.
-- AdminAce). Server-authoritative. Usage: /grantstarterpack <citizenid> [revoke].
if Config.StarterPack then
    Bridge.RegisterCommand('grantstarterpack', function(source, args)
        if source ~= 0 and not IsPlayerAceAllowed(source, Config.StarterPack.AdminAce) then
            return notify(source, 'Business', 'Not authorised.', 'error')
        end
        local target = args and args[1]
        if not target or target == '' then
            if source ~= 0 then notify(source, 'Business', 'Usage: /grantstarterpack <citizenid> [revoke]', 'error') end
            return
        end
        -- pcall-wrap the 0073-schema writes: this command is usable before the pack
        -- is enabled (to pre-seed test entitlements), so if it runs on a box where
        -- migration 0073 hasn't landed yet, degrade to a clear message instead of a
        -- raw SQL error (mirrors the HasStarterPack export's lagged-migration guard).
        if args[2] == 'revoke' then
            local ok = pcall(function()
                MySQL.update.await('DELETE FROM palm6_business_entitlements WHERE citizenid = ? AND pack = ?', { target, STARTER_KEY })
                -- Revocation reverts the cosmetics too (refund honesty): clear the
                -- nameplate/skin on every business this citizen CURRENTLY owns. (A
                -- business they transferred to an unentitled owner was already
                -- cleared at transfer time, so this covers the whole refund case.)
                MySQL.update.await('UPDATE palm6_businesses SET nameplate = NULL, skin = NULL WHERE owner_cid = ?', { target })
            end)
            if not ok then
                if source ~= 0 then notify(source, 'Business', 'Starter Pack storage not migrated yet.', 'error') end
                return
            end
            if starterPackEnabled() then pcall(broadcastStorefronts) end
            if source ~= 0 then notify(source, 'Business', ('Revoked Starter Pack from %s.'):format(target), 'success') end
            print(('[palm6_business] Starter Pack revoked: %s'):format(target))
        else
            local ok = pcall(function()
                MySQL.insert.await(
                    'INSERT INTO palm6_business_entitlements (citizenid, pack, granted_at, source) VALUES (?,?,?,?) ' ..
                    'ON DUPLICATE KEY UPDATE granted_at = VALUES(granted_at), source = VALUES(source)',
                    { target, STARTER_KEY, nowSec(), (source == 0 and 'console' or 'admin') })
            end)
            if not ok then
                if source ~= 0 then notify(source, 'Business', 'Starter Pack storage not migrated yet.', 'error') end
                return
            end
            if source ~= 0 then notify(source, 'Business', ('Granted Starter Pack to %s.'):format(target), 'success') end
            print(('[palm6_business] Starter Pack granted: %s'):format(target))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Exports (server-only) — seams for palm6_protection (Phase 1) + any future POS.
-- ---------------------------------------------------------------------------

-- Summary of the caller-cid's business, or nil.
exports('GetBusinessOf', function(citizenid)
    if not enabled() then return nil end
    local m = getMembership(citizenid)
    if not m then return nil end
    return {
        id = m.business_id, name = m.business_name, biz_type = m.biz_type,
        role = m.role, balance = m.account_balance or 0, ownerCid = m.owner_cid,
    }
end)

-- Generic revenue seam: charge an ONLINE payer's bank into a business account.
-- Always player -> business (never mints). Returns true on success.
exports('Charge', function(businessId, payerCid, amount, memo)
    if not enabled() then return false end
    amount = sanitizeInt(amount)
    if not amount or amount < 1 then return false end
    if not getBusinessById(businessId) then return false end
    local psrc = Bridge.GetSourceByCitizenId(payerCid)
    if not psrc then return false end
    if not Bridge.ChargeBank(psrc, amount, 'business-charge-export') then return false end
    if not creditAccount(businessId, amount, payerCid, 'charge', (type(memo) == 'string' and memo:sub(1, 64)) or 'Charge') then
        -- Business closed between the charge and the credit — refund the payer.
        Bridge.CreditBankByCitizenId(payerCid, amount, 'business-charge-export-refund')
        return false
    end
    return true
end)

exports('GetAccountBalance', function(businessId)
    if not enabled() then return 0 end
    return MySQL.scalar.await('SELECT account_balance FROM palm6_businesses WHERE id = ?', { businessId }) or 0
end)

-- Phase-1 seam: a business's storefront coords/heading, or nil if unplaced. For a
-- future greeter ped, delivery target, or palm6_protection "shake down the shop".
exports('GetStorefront', function(businessId)
    if not phase1() then return nil end
    local sf = storefrontOf(businessId)
    if not hasLoc(sf) then return nil end
    return { x = sf.loc_x, y = sf.loc_y, z = sf.loc_z, h = sf.loc_h or 0.0 }
end)

-- Starter Pack entitlement lookup. The "Discord business-registry badge" perk is
-- granted Discord-side from this same entitlement; this export lets the bot / web
-- (or any resource) read whether a citizen holds the pack. Guarded; never throws.
exports('HasStarterPack', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local ok, res = pcall(hasStarterEntitlement, citizenid)
    return ok and res or false
end)

-- ---------------------------------------------------------------------------
-- palm6_protection shake-down seam (see docs/superpowers/specs/
-- 2026-07-20-palm6-protection-extort-owned-design.md). All three are guarded by
-- GetInvokingResource() == 'palm6_protection' — only the racket may reach a
-- business this way. They add NO Phase-0 behaviour: nothing calls them unless
-- palm6_protection has Config.ExtortOwned = true (dark by default).
-- ---------------------------------------------------------------------------

-- Nearest PLACED storefront within `radius` of a point, with the fields the racket
-- needs to shake it down. phase1()-gated (an unplaced/Phase-0 business has no map
-- surface to stand at) + invoking-guarded so it can't become an owned-business
-- location/identity enumeration oracle (cf. the 2fe2331 storefront info-card lesson).
exports('BusinessAtCoords', function(x, y, z, radius)
    if not phase1() then return nil end
    if GetInvokingResource() ~= 'palm6_protection' then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    radius = tonumber(radius) or 0.0
    if not x or not y or not z then return nil end
    local rows = MySQL.query.await([[
        SELECT id, name, biz_type, account_balance, owner_cid, loc_x, loc_y, loc_z
          FROM palm6_businesses
         WHERE loc_x IS NOT NULL AND loc_y IS NOT NULL AND loc_z IS NOT NULL
    ]]) or {}
    local here = { x = x, y = y, z = z }
    local best, bestD
    for _, r in ipairs(rows) do
        local d = Bridge.Distance(here, { x = r.loc_x, y = r.loc_y, z = r.loc_z })
        if d <= radius and (not bestD or d < bestD) then best, bestD = r, d end
    end
    if not best then return nil end
    return {
        id = best.id, name = best.name, biz_type = best.biz_type,
        balance = best.account_balance or 0, ownerCid = best.owner_cid,
        x = best.loc_x, y = best.loc_y, z = best.loc_z,
    }
end)

-- Drain `amount` of a business's REAL pooled account as a shakedown. Atomic guarded
-- debit (WHERE account_balance >= amount — never overdraws, never mints), writes an
-- `extortion` ledger row, notifies the owner if online. Returns the amount actually
-- taken (0 if the account can't cover the full amount, the business is closed, or
-- the system is dark). All-or-nothing at the caller-capped amount; no partial debit.
exports('Extort', function(businessId, amount, collectorCid, memo)
    if not enabled() then return 0 end
    if GetInvokingResource() ~= 'palm6_protection' then return 0 end
    amount = sanitizeInt(amount)
    if not amount or amount < 1 then return 0 end
    -- No self-shakedown: a MEMBER (owner OR employee) can't extort their own
    -- workplace — the same guard the register robbery enforces (opRob). Without it a
    -- non-owner employee in the controlling gang could drain the owner's pooled
    -- account into their own dirty pocket, bypassing the owner-only withdraw.
    local mem = getMembership(collectorCid)
    if mem and mem.business_id == businessId then return 0 end
    local bal = debitAccount(businessId, amount)   -- nil if it can't cover / gone
    if not bal then return 0 end
    local actor = (type(collectorCid) == 'string' and collectorCid) or 'unknown'
    local m = (type(memo) == 'string' and memo:sub(1, 64)) or 'Shakedown'
    insertLedger(businessId, actor, 'extortion', -amount, bal, m)
    -- Passive turf-tax: tell the owner if they're online (the ledger is the record
    -- either way). Best-effort — a missing owner/src just means no live ping.
    local biz = getBusinessById(businessId)
    if biz and biz.owner_cid then
        local osrc = Bridge.GetSourceByCitizenId(biz.owner_cid)
        if osrc then
            notify(osrc, 'Business',
                ('%s was shaken down for $%d in protection money.'):format(biz.name or 'Your business', amount), 'error')
        end
    end
    return amount
end)

-- Compensating credit when palm6_protection fails to hand the collector the cash
-- AFTER Extort already debited — makes the business whole. creditAccount returns nil
-- only if the business was CLOSED in the gap: opClose captured the already-reduced
-- balance (it excludes this in-flight drain), so the drained amount is NOT in the
-- owner's close-refund and cannot be credited back — it is DESTROYED (deflationary,
-- never minted/duplicated). A false return means exactly that; the caller logs it.
-- This owner-close race is a second, narrower instance of the documented item-payout
-- deflation window (cf. the spec's Money-safety ordering) — accepted, not routed
-- through the pending marker, because that marker is re-driven as a BANK credit by
-- reconcilePending on boot and would mint on an item payout. Returns success.
exports('RefundExtortion', function(businessId, amount, memo)
    if not enabled() then return false end
    if GetInvokingResource() ~= 'palm6_protection' then return false end
    amount = sanitizeInt(amount)
    if not amount or amount < 1 then return false end
    local m = (type(memo) == 'string' and memo:sub(1, 64)) or 'Shakedown voided'
    return creditAccount(businessId, amount, 'system', 'extortion-refund', m) ~= nil
end)

CreateThread(function()
    if enabled() then
        print('[palm6_business] ENABLED — player-owned businesses live.')
    else
        print('[palm6_business] loaded DARK (Config.Enabled=false) — prod-inert.')
    end
    -- Boot reconcile any account->bank payout stranded by a crash between the
    -- debit and the bank credit (withdraw/payroll). Runs after dbmigrate 0068 +
    -- oxmysql are up. Safe while DARK (no pending rows exist if never enabled);
    -- pcall-guarded so a not-yet-created table can never error the resource.
    Wait(12000)
    pcall(reconcilePending)
    -- Phase 1: push the storefront set to everyone already connected (covers a
    -- live resource restart; fresh joins pull it via requestStorefronts). No-op
    -- while Phase 1 is off (broadcastStorefronts early-returns).
    if phase1() then pcall(broadcastStorefronts) end
end)
