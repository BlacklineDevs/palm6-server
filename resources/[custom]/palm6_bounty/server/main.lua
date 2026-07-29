-- ============================================================================
-- palm6_bounty/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The wanted board. Two contract kinds share one ledger:
--   - STATE contracts are auto-posted (and kept in sync) against every
--     citizen carrying an active palm6_mdt warrant. Read-only cross-read of
--     palm6_mdt_warrants — the same house pattern palm6_pumpcoin/
--     palm6_clout/palm6_flashdrop use to read palm6_turf. This resource
--     never writes to palm6_mdt's tables. Funded by the city — no player is
--     ever debited for a state contract.
--   - PRIVATE contracts are posted by a citizen on another citizen, cash
--     escrowed from the poster's bank at post time, refundable (minus a
--     cancel fee) on cancel or in full on natural TTL expiry.
--
-- Claiming ("capture") never trusts the client: hunter proximity and the
-- target's health are both read server-side off the live synced entities,
-- and the claim is a guarded UPDATE ... WHERE status = 'active' so two
-- hunters racing the same contract can't both get paid.
-- ============================================================================

local lastAction = {}    -- [src] = { [key] = ts } — chat-command spam guard
local lastPost = {}      -- [citizenid] = ts — private-contract post cooldown
local lastCapture = {}   -- [citizenid] = ts — per-hunter capture cooldown
-- [citizenid] = last heat premium applied to their LIVE state contract. Used
-- only to fire the "the city raised the price on your head" notify on an
-- INCREASE, so a premium decaying tier by tier cannot spam the target every
-- sweep. Rebuilt against the live warrant set at the end of every sync, so it
-- can never hold more entries than there are open state contracts. A restart
-- clears it, which USED to cost one repeated notify per target; the
-- heatBonusPrimed gate below now makes the first post-boot sweep seed silently,
-- so it costs none.
local stateHeatBonus = {}

-- False until the first sweep after boot has finished seeding stateHeatBonus.
-- Gates the "the city raised the price on your head" notify so a restart cannot
-- re-announce a premium that was already on the contract before the reboot.
local heatBonusPrimed = false

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating table). Same shape as palm6_courier/palm6_ems:
-- per-statement pcall, everything IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with no
-- palm6_bounty_contracts. EVERY query in this file is pcall-guarded, so a
-- missing table is not an error, it is SILENCE: /bounties reports "no open
-- contracts", the state sweep posts nothing, and worst of all /postbounty
-- charges the poster's bank BEFORE the INSERT — the insert-failure path does
-- refund, but the board looks permanently empty with nothing in the console
-- saying why. On the live box these statements are pure no-ops.
--
-- The CREATE is copied VERBATIM from sql/0027_bounty.sql (trailing `;` dropped
-- so oxmysql sees a single statement); the ALTER is copied VERBATIM from
-- sql/0055_bounty_settlement.sql. The ALTER is repeated here even though
-- palm6_dbmigrate also runs it: the two boot on independent threads, whichever
-- runs second is a no-op, and neither can lose the race. `settled` DEFAULT 1 is
-- load-bearing and must NOT be changed to 0 — see the FIRST-BOOT SAFETY note in
-- sql/0055: DEFAULT 0 would make the boot reconcile re-pay the entire contract
-- history exactly once.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- Statements THIS resource owns and can answer for. Only these feed
    -- SchemaReady. See the ALTER note below for why they are kept separate.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_bounty_contracts` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    kind ENUM('state','private') NOT NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    target_name VARCHAR(100) NOT NULL DEFAULT '',
    poster_citizenid VARCHAR(64) DEFAULT NULL,
    poster_name VARCHAR(100) DEFAULT NULL,
    amount INT UNSIGNED NOT NULL,
    reason VARCHAR(200) NOT NULL DEFAULT '',
    status ENUM('active','claimed','cancelled','expired') NOT NULL DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NULL DEFAULT NULL,
    claimed_by_citizenid VARCHAR(64) DEFAULT NULL,
    claimed_by_name VARCHAR(100) DEFAULT NULL,
    claimed_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_bounty_target (target_citizenid, kind, status),
    INDEX idx_palm6_bounty_poster (poster_citizenid, status),
    INDEX idx_palm6_bounty_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    -- Best effort, deliberately NOT part of SchemaReady. `ADD COLUMN IF NOT
    -- EXISTS` is MariaDB-only: on MySQL 8 it THROWS even when the column
    -- already exists. Folding it into SchemaReady would make a perfectly
    -- healthy MySQL box print `schema MISSING` on every boot, which is the
    -- permanent false alarm that trains an operator to ignore the banner.
    -- palm6_bounty_contracts is the table this resource owns and is what
    -- SchemaReady answers for; `settled` is additive and its absence is
    -- reported on its own line instead. Same pattern as palm6_courier and
    -- palm6_mdt's schemaOk.
    local alters = {
        [[
ALTER TABLE `palm6_bounty_contracts`
    ADD COLUMN IF NOT EXISTS `settled` TINYINT NOT NULL DEFAULT 1
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_bounty] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    for _, sql in ipairs(alters) do
        local ok = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            print('^3[palm6_bounty] additive ALTER skipped (expected on MySQL 8, ' ..
                  'harmless if the column already exists)^0')
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- Free the src-keyed spam guard when a player disconnects so the table cannot
-- grow without bound over the server's uptime (the citizenid-keyed cooldowns are
-- naturally bounded by the player base and reused on reconnect).
AddEventHandler('playerDropped', function()
    lastAction[source] = nil
end)

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_bounty] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function atBoard(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Board.coords) <= Config.Board.radius
end

local function normCid(s)
    return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function openPrivateCount(cid)
    local n = 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_bounty_contracts WHERE poster_citizenid = ? AND kind = 'private' AND status = 'active'",
            { cid })
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function activeContract(id)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT * FROM palm6_bounty_contracts WHERE id = ? AND status = 'active'", { id })
    end)
    return row
end

-- Claim a terminal contract's payout flag atomically; true iff WE flipped
-- settled 0->1 for a row still in the expected terminal status. This is the
-- load-bearing CLAIM-BEFORE-CREDIT guard: every bank credit/refund below (live
-- /capture, /cancelbounty, the TTL sweep, and the boot reconcile) claims it
-- BEFORE the money moves, so exactly one settlement run ever pays a contract —
-- an already-credited row has settled=1 and is skipped. NEVER credit-then-mark
-- (that would re-mint on a boot replay); the worst a crash between the claim and
-- the credit can do is a rare one-payout shortfall (visible, fixable), never a
-- mint. Mirrors palm6_fightclub's claimBet / purse_paid idiom. Requires the
-- 0055 `settled` column (added by palm6_dbmigrate) — if it is missing the UPDATE
-- errors, the pcall swallows it, claimed stays false, and no credit fires.
local function claimSettled(id, terminalStatus)
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_bounty_contracts SET settled = 1 WHERE id = ? AND status = ? AND settled = 0",
            { id, terminalStatus }) == 1
    end)
    return claimed
end

-- ---------------------------------------------------------------------------
-- Durable police-attention premium on a STATE contract. Returns (bonus, tier),
-- (0, nil) whenever the flag is off, palm6_heat is not started, the export
-- throws or returns a non-string, or the tier carries no entry, so every
-- failure mode lands on exactly today's warrant-count-only amount.
--
-- Read through GetTier ONLY. palm6_heat stores heat alongside an updated_at and
-- settles the decay on READ, so a direct palm6_heat_state query would keep
-- pricing a citizen who cooled off hours ago as WANTED.
--
-- Never negative, hard-capped, and only ever called from inside the loop over
-- LIVE warrant rows, so it can only ADD to a contract the warrant table already
-- justified and can never mint one on its own. See Config.State.HeatBonus for
-- the full anti-farm argument.
-- ---------------------------------------------------------------------------
local function heatPremium(cid)
    local HB = Config.State.HeatBonus
    if not HB or not HB.Enabled then return 0, nil end
    if type(cid) ~= 'string' or cid == '' then return 0, nil end
    if GetResourceState('palm6_heat') ~= 'started' then return 0, nil end
    local tier
    pcall(function() tier = exports.palm6_heat:GetTier(cid) end)
    if type(tier) ~= 'string' then return 0, nil end
    local bonus = math.floor(tonumber((HB.PerTier or {})[tier]) or 0)
    if bonus < 0 then bonus = 0 end
    local cap = math.floor(tonumber(HB.Cap) or 0)
    if cap < 0 then cap = 0 end
    if bonus > cap then bonus = cap end
    return bonus, tier
end

-- The board line for a state contract. With no premium applied this returns the
-- EXACT literal the INSERT has always written, so a flag-off board is unchanged
-- character for character. With a premium applied it names the tier, so
-- /bounties explains WHY the price on that head is higher instead of the number
-- silently moving.
local function stateReason(bonus, tier)
    if bonus > 0 and type(tier) == 'string' then
        return ('Active warrant(s) on file · %s heat'):format(tier)
    end
    return 'Active warrant(s) on file'
end

-- ---------------------------------------------------------------------------
-- /postbounty <citizenid> <amount> <reason...> — private contract
-- ---------------------------------------------------------------------------
local function cmdPostBounty(src, args)
    if src == 0 then return end
    if not rl(src, 'postbounty') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atBoard(src) then
        Bridge.Notify(src, 'Bounty Board', ('You need to be at %s.'):format(Config.Board.label), 'error')
        return
    end

    local P = Config.Private
    local target = normCid(args[1])
    local amount = math.floor(tonumber(args[2]) or 0)
    local reason = table.concat(args, ' ', 3):gsub('^%s+', ''):gsub('%s+$', '')

    if target == '' or amount < P.MinAmount or amount > P.MaxAmount
        or #reason < P.ReasonMin or #reason > P.ReasonMax then
        Bridge.Notify(src, 'Bounty Board',
            ('Usage: /postbounty [citizenid] [$%d-%d] [reason %d-%d chars]')
            :format(P.MinAmount, P.MaxAmount, P.ReasonMin, P.ReasonMax), 'error')
        return
    end
    if target == cid then
        Bridge.Notify(src, 'Bounty Board', 'You cannot post a bounty on yourself.', 'error')
        return
    end

    local t = now()
    if (lastPost[cid] or 0) + P.PostCooldownSec > t then
        Bridge.Notify(src, 'Bounty Board', 'You just posted a contract — wait a bit.', 'error')
        return
    end
    if openPrivateCount(cid) >= P.MaxOpenPerCitizen then
        Bridge.Notify(src, 'Bounty Board',
            ('You already have %d open contract(s) — cancel one first.'):format(P.MaxOpenPerCitizen), 'error')
        return
    end

    local targetName = Bridge.GetCitizenName(target)
    if not targetName then
        Bridge.Notify(src, 'Bounty Board', 'No citizen with that id on record.', 'error')
        return
    end

    if not Bridge.ChargeBank(src, amount, 'bounty-post') then
        Bridge.Notify(src, 'Bounty Board', ('You need $%d in the bank (escrowed until claimed/cancelled).'):format(amount), 'error')
        return
    end

    local posterName = Bridge.GetPlayerName(src)
    local ok, contractId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_bounty_contracts
                (kind, target_citizenid, target_name, poster_citizenid, poster_name, amount, reason, expires_at)
            VALUES ('private', ?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? HOUR)
        ]], { target, targetName, cid, posterName, amount, reason, P.TtlHours })
    end)
    if not ok or not contractId then
        Bridge.CreditBankByCitizenId(cid, amount, 'bounty-post-refund')
        Bridge.Notify(src, 'Bounty Board', 'The board is down — you were refunded.', 'error')
        return
    end

    lastPost[cid] = t
    Bridge.Notify(src, 'Bounty Board',
        ('Contract #%d posted: %s, $%d. Expires in %dh if unclaimed.')
        :format(contractId, targetName, amount, P.TtlHours), 'success')
    dbg(('contract #%d posted by %s on %s ($%d)'):format(contractId, cid, target, amount))
end

-- ---------------------------------------------------------------------------
-- /cancelbounty <id> — poster only, unclaimed only
-- ---------------------------------------------------------------------------
local function cmdCancelBounty(src, args)
    if src == 0 then return end
    if not rl(src, 'cancelbounty') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'Bounty Board', 'Usage: /cancelbounty [contract #]', 'error')
        return
    end

    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, amount FROM palm6_bounty_contracts WHERE id = ? AND poster_citizenid = ? AND kind = 'private' AND status = 'active'",
            { id, cid })
    end)
    if not row then
        Bridge.Notify(src, 'Bounty Board', 'No open contract of yours with that number.', 'error')
        return
    end

    -- Mark cancelled BEFORE refunding — a refund that double-fires costs
    -- the city money, an unrefunded cancelled row is visible and fixable.
    local marked = false
    pcall(function()
        marked = MySQL.update.await(
            "UPDATE palm6_bounty_contracts SET status = 'cancelled', settled = 0 WHERE id = ? AND status = 'active'",
            { id }) == 1
    end)
    if not marked then
        Bridge.Notify(src, 'Bounty Board', 'That contract was already resolved.', 'error')
        return
    end

    local amount = tonumber(row.amount) or 0
    local fee = math.floor(amount * Config.Private.CancelFeePct)
    local refund = amount - fee
    -- Claim the settle flag BEFORE refunding so a crash between the 'cancelled'
    -- flip and this credit is re-driven by the boot reconcile exactly once,
    -- never double-refunding the poster. If we lost the claim, the reconcile
    -- (or a racing path) already handled the refund — don't credit again.
    if not claimSettled(id, 'cancelled') then
        Bridge.Notify(src, 'Bounty Board', ('Contract #%d cancelled.'):format(id), 'success')
        dbg(('contract #%d cancel: already settled, refund skipped'):format(id))
        return
    end
    if refund > 0 and not Bridge.CreditBankByCitizenId(cid, refund, 'bounty-cancel-refund') then
        -- settled is already 1; per the house shortfall-over-mint bias we do NOT
        -- roll it back (a false return can't be trusted to mean "money didn't
        -- move"). The cancelled row is visible and fixable.
        dbg(('contract #%d cancel: refund credit returned false — $%d shortfall'):format(id, refund))
    end
    Bridge.Notify(src, 'Bounty Board',
        ('Contract #%d cancelled — $%d refunded ($%d posting fee kept).'):format(id, refund, fee), 'success')
    dbg(('contract #%d cancelled by %s'):format(id, cid))
end

-- ---------------------------------------------------------------------------
-- /bounties — open contracts, highest reward first
-- ---------------------------------------------------------------------------
local function cmdBounties(src)
    if src == 0 then return end
    if not rl(src, 'bounties') then return end

    local rows = {}
    pcall(function()
        rows = MySQL.query.await([[
            SELECT id, kind, target_name, poster_name, amount, reason,
                   TIMESTAMPDIFF(HOUR, NOW(), expires_at) AS hrs_left
            FROM palm6_bounty_contracts
            WHERE status = 'active'
            ORDER BY amount DESC LIMIT ?
        ]], { Config.Private.ListLimit }) or {}
    end)

    if #rows == 0 then
        Bridge.Reply(src, { 'no open contracts' })
        return
    end
    local lines = {}
    for _, c in ipairs(rows) do
        if c.kind == 'state' then
            lines[#lines + 1] = ('#%d [STATE] %s — $%d — %s'):format(c.id, c.target_name, c.amount, c.reason)
        else
            local exp = tonumber(c.hrs_left)
            lines[#lines + 1] = ('#%d [PRIVATE by %s] %s — $%d — %s (%s)'):format(
                c.id, c.poster_name or 'unknown', c.target_name, c.amount, c.reason,
                (exp and exp >= 0) and ('expires %dh'):format(exp) or 'expiring soon')
        end
    end
    -- Say the pricing rule out loud, but ONLY while the premium is on: with the
    -- flag off a state price is a pure function of warrant count and does not
    -- drift, so this line would be noise, and the reply is byte-identical to
    -- today's. With the flag on the amount above tracks the target's live heat
    -- and is re-read from the row at /capture, so a hunter who reads the board
    -- and then spends twenty minutes hunting can be paid less than the figure
    -- printed here. Quoting a number and paying another without a word is how a
    -- consequence gets mistaken for a bug.
    local HB = Config.State.HeatBonus
    if Config.State.Enabled and HB and HB.Enabled then
        lines[#lines + 1] = ('State prices track the target\'s heat and are re-checked every %ds. You are paid what the contract is worth when you capture, not what it says now.')
            :format(Config.State.SweepSec)
    end
    lines[#lines + 1] = 'Get close and beat them down, then /capture [#].'
    Bridge.Reply(src, lines)
end

-- ---------------------------------------------------------------------------
-- /capture <id> — server-validated proximity + health, guarded claim
-- ---------------------------------------------------------------------------
local function cmdCapture(src, args)
    if src == 0 then return end
    if not rl(src, 'capture') then return end
    local hunterCid = Bridge.GetCitizenId(src)
    if not hunterCid then return end

    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'Bounty Board', 'Usage: /capture [contract #]', 'error')
        return
    end

    local t = now()
    if (lastCapture[hunterCid] or 0) + Config.Capture.CooldownSec > t then
        Bridge.Notify(src, 'Bounty Board', 'Catch your breath first.', 'error')
        return
    end

    local contract = activeContract(id)
    if not contract then
        Bridge.Notify(src, 'Bounty Board', 'No active contract with that number.', 'error')
        return
    end
    if contract.poster_citizenid and contract.poster_citizenid == hunterCid then
        Bridge.Notify(src, 'Bounty Board', 'You cannot claim your own contract.', 'error')
        return
    end
    if contract.target_citizenid == hunterCid then
        Bridge.Notify(src, 'Bounty Board', 'You cannot claim a bounty on yourself.', 'error')
        return
    end

    local targetSrc = Bridge.GetSourceByCitizenId(contract.target_citizenid)
    if not targetSrc then
        Bridge.Notify(src, 'Bounty Board', 'That target is not online right now.', 'error')
        return
    end

    local hunterCoords = Bridge.GetCoords(src)
    local targetCoords = Bridge.GetCoords(targetSrc)
    if not hunterCoords or not targetCoords
        or Bridge.Distance(hunterCoords, targetCoords) > Config.Capture.Radius then
        Bridge.Notify(src, 'Bounty Board', 'You need to be right on top of them.', 'error')
        return
    end

    local health = Bridge.GetHealth(targetSrc)
    if not health or health > Config.Capture.HealthThreshold then
        Bridge.Notify(src, 'Bounty Board', 'They are still putting up too much of a fight.', 'error')
        return
    end

    -- Mark claimed BEFORE paying — the guarded WHERE stops two hunters
    -- racing the same contract from both getting paid.
    local hunterName = Bridge.GetPlayerName(src)
    local marked = false
    pcall(function()
        marked = MySQL.update.await(
            "UPDATE palm6_bounty_contracts SET status = 'claimed', claimed_by_citizenid = ?, claimed_by_name = ?, claimed_at = NOW(), settled = 0 WHERE id = ? AND status = 'active'",
            { hunterCid, hunterName, id }) == 1
    end)
    if not marked then
        Bridge.Notify(src, 'Bounty Board', 'Someone beat you to that contract.', 'error')
        return
    end

    lastCapture[hunterCid] = t
    local amount = tonumber(contract.amount) or 0
    -- palm6_pulse "Bounty Surge" window boosts the hunter's payout. NOTE: this is
    -- a DELIBERATE, capped (<=Config.MaxModifier=2.0), time-windowed, cooldowned
    -- economic-stimulus faucet — the amount above the poster's escrow is minted,
    -- matching the shipped Pulse design ("posted bounty payouts up"). Server-read +
    -- pcall+ResourceState-gated (bounty runs standalone if pulse is absent).
    pcall(function()
        if GetResourceState('palm6_pulse') == 'started' then
            local m = exports.palm6_pulse:GetActiveModifier('bounty')
            if type(m) == 'number' and m > 1 then amount = math.floor(amount * m) end
        end
    end)
    -- Claim the settle flag BEFORE paying the hunter so a crash between the
    -- 'claimed' flip and this credit is re-driven by the boot reconcile exactly
    -- once, never double-paying. If we lost the claim, the reconcile (or a
    -- racing path) already paid this contract — do not credit again.
    if not claimSettled(id, 'claimed') then
        Bridge.Notify(src, 'Bounty Board',
            ('Contract #%d claimed: %s.'):format(id, contract.target_name), 'success')
        dbg(('contract #%d capture: already settled, credit skipped'):format(id))
        return
    end
    if not Bridge.CreditBankByCitizenId(hunterCid, amount, 'bounty-capture') then
        -- settled is already 1; per the house shortfall-over-mint bias we do NOT
        -- roll it back. Surface an honest message instead of claiming it landed.
        dbg(('contract #%d capture: credit returned false — $%d shortfall'):format(id, amount))
        Bridge.Notify(src, 'Bounty Board',
            ('Contract #%d claimed — payout is delayed, contact an admin if $%d never lands.'):format(id, amount), 'error')
        Bridge.Notify(targetSrc, 'Bounty Board',
            ('%s just collected the bounty on your head.'):format(hunterName), 'error')
        return
    end
    Bridge.Notify(src, 'Bounty Board',
        ('Contract #%d claimed: %s. $%d landed in your bank.'):format(id, contract.target_name, amount), 'success')
    Bridge.Notify(targetSrc, 'Bounty Board',
        ('%s just collected the bounty on your head.'):format(hunterName), 'error')
    dbg(('contract #%d claimed by %s (target %s, $%d)'):format(id, hunterCid, contract.target_citizenid, amount))
end

-- ---------------------------------------------------------------------------
-- State-contract sync — mirrors palm6_mdt's live warrant table. Read-only:
-- this resource never writes to palm6_mdt_warrants.
-- ---------------------------------------------------------------------------
local function syncStateContracts()
    if not Config.State.Enabled then return end
    if Config.State.RequireMdt and not Bridge.ResourceStarted('palm6_mdt') then return end

    -- Eligibility predicate (Config.State.RequireCase, ships dark). When off
    -- this is the empty string and the query is byte-for-byte what it always
    -- was. When on, only warrants the city can point at a real case file - or
    -- one of the AUTOMATED issuers - put money on a head. case_id is the
    -- column palm6_mdt writes at server/main.lua:335; officer_name is what
    -- each automated issuer passes as its officerLabel. There are four of
    -- them, not one (Config.State.SystemIssuers documents each with its call
    -- site), so the placeholder list is built from the config rather than
    -- hard-coded: a single-issuer predicate would have silently dropped
    -- bail-skip and kidnapping warrants.
    local eligibility, params = '', {}
    if Config.State.RequireCase then
        local issuers = Config.State.SystemIssuers or {}
        local marks = {}
        for _, label in ipairs(issuers) do
            marks[#marks + 1] = '?'
            params[#params + 1] = label
        end
        if #marks > 0 then
            eligibility = (' AND (case_id IS NOT NULL OR officer_name IN (%s))'):format(
                table.concat(marks, ','))
        else
            -- No automated issuers configured: case file or nothing.
            eligibility = ' AND case_id IS NOT NULL'
        end
    end

    local warrantRows = {}
    pcall(function()
        warrantRows = MySQL.query.await(([[
            SELECT citizenid, citizen_name, COUNT(*) AS n
            FROM palm6_mdt_warrants
            WHERE status = 'active'%s
            GROUP BY citizenid, citizen_name
        ]]):format(eligibility), params) or {}
    end)

    local S = Config.State
    local liveTargets = {}
    for _, w in ipairs(warrantRows) do
        local cid = w.citizenid
        liveTargets[cid] = true
        local n = tonumber(w.n) or 1
        local amount = math.min(S.Cap, S.BaseAmount + S.PerWarrantExtra * math.max(0, n - 1))

        -- The existing-contract lookup runs FIRST so the premium read can be
        -- skipped where it cannot change anything. `status` is selected because
        -- that decision needs it; nothing else reads the column, and with the
        -- premium off the rows matched and the writes performed below are
        -- exactly what this sync has always matched and performed.
        local existing
        pcall(function()
            existing = MySQL.single.await(
                "SELECT id, status FROM palm6_bounty_contracts WHERE target_citizenid = ? AND kind = 'state' AND status IN ('active','claimed')",
                { cid })
        end)

        -- heatPremium is a DB round-trip, so only spend it where the answer can
        -- be written. A 'claimed' state contract is TERMINAL: the refresh below
        -- is pinned to status='active' so it could only ever match zero rows,
        -- and Config.State.HeatBonus rule 3 means the row is never re-opened.
        -- Both warrants and claimed state rows persist indefinitely, so without
        -- this test every citizen who was ever captured while still carrying a
        -- warrant would cost one wasted GetTier round-trip per sweep, forever,
        -- and that set only grows. Off-path: heatPremium returns (0, nil)
        -- unconditionally while the flag is false, so skipping it changes
        -- nothing at all with the flag off.
        local repriceable = (existing == nil) or (existing.status == 'active')
        local bonus, tier = 0, nil
        if repriceable then bonus, tier = heatPremium(cid) end
        local posted = amount + bonus

        if existing then
            if not (S.HeatBonus and S.HeatBonus.Enabled) then
                -- Premium OFF: verbatim the statement this sync has always run,
                -- with the same unguarded WHERE and the same values (bonus is 0
                -- on this path, so `posted` is the warrant-count amount).
                pcall(function()
                    MySQL.update.await(
                        "UPDATE palm6_bounty_contracts SET amount = ?, target_name = ? WHERE id = ?",
                        { posted, w.citizen_name, existing.id })
                end)
            elseif repriceable then
                -- Premium ON, contract still ACTIVE: re-price it. The UPDATE
                -- stays GUARDED to status='active' anyway, because status can
                -- change between the SELECT above and this write (a hunter can
                -- /capture in that gap). reconcileUnsettled re-pays a crashed
                -- capture from THIS column and heat decays continuously, so an
                -- unguarded refresh could hand the boot reconcile a number
                -- neither the hunter nor the board ever saw. `reason` is written
                -- too, so the board line keeps naming the tier as it changes.
                --
                -- What this DOES freeze is the amount from the moment of CLAIM
                -- onward, not from the moment a hunter read /bounties. While a
                -- contract is active its price tracks the target's live tier and
                -- can fall between sweeps, so a hunter who read the board and
                -- then took twenty minutes to find the target can be paid less
                -- than the board said. /bounties says so out loud while this
                -- flag is on (cmdBounties) rather than the number just moving.
                local refreshed = 0
                pcall(function()
                    refreshed = MySQL.update.await(
                        "UPDATE palm6_bounty_contracts SET amount = ?, target_name = ?, reason = ? WHERE id = ? AND status = 'active'",
                        { posted, w.citizen_name, stateReason(bonus, tier), existing.id }) or 0
                end)
                -- Legibility: tell the target, but ONLY when the premium they
                -- carry goes UP, so a decaying premium does not notify them
                -- every SweepSec. An offline target is simply skipped: the
                -- board still shows it, and /myheat still explains it.
                --
                -- Gated on `refreshed`, not just on the bonus rising: the row may
                -- have been claimed between the SELECT above and this UPDATE, in
                -- which case the guarded write matched nothing and "the city
                -- raised the price on your head" would be a flat lie about a
                -- contract that is already settled.
                if heatBonusPrimed and refreshed == 1 and bonus > (stateHeatBonus[cid] or 0) then
                    local s = Bridge.GetSourceByCitizenId(cid)
                    if s then
                        Bridge.Notify(s, 'Bounty Board',
                            ('The city raised the price on your head to $%d. You are %s.')
                                :format(posted, tostring(tier)), 'error')
                    end
                end
                stateHeatBonus[cid] = bonus
            end
            -- Remaining case: premium ON and the found row is already 'claimed'.
            -- Nothing to do and nothing skipped. The only write this branch has
            -- while the premium is on is the status='active'-guarded UPDATE
            -- above, which cannot match a claimed row, so running it would spend
            -- a round-trip to change zero rows. stateHeatBonus is deliberately
            -- left alone here: it only gates the notify, that notify is gated on
            -- `refreshed == 1` which a claimed row can never reach, and the
            -- sweep's prune below still clears the key when the warrant clears.
        else
            -- `reason` moved from an inline literal to a placeholder. With the
            -- premium off stateReason returns that exact literal, so the value
            -- written is unchanged.
            pcall(function()
                MySQL.insert.await([[
                    INSERT INTO palm6_bounty_contracts
                        (kind, target_citizenid, target_name, amount, reason)
                    VALUES ('state', ?, ?, ?, ?)
                ]], { cid, w.citizen_name, posted, stateReason(bonus, tier) })
            end)
            stateHeatBonus[cid] = bonus
            dbg(('state contract opened on %s ($%d = $%d warrant + $%d heat[%s], %d warrant(s))')
                :format(cid, posted, amount, bonus, tostring(tier), n))
        end
    end

    -- Bound the notify ledger: an entry for a citizen with no live warrant can
    -- no longer gate anything. Assigning nil to the CURRENT key inside pairs()
    -- is the one table mutation Lua explicitly permits during traversal.
    for known in pairs(stateHeatBonus) do
        if not liveTargets[known] then stateHeatBonus[known] = nil end
    end

    -- The FIRST sweep after a boot only seeds the ledger; it never notifies.
    -- stateHeatBonus is memory-only, so after a restart every already-premium
    -- target reads as "0 before, N now" and gets told the city raised the price
    -- on their head again, for a premium that has been sitting on their contract
    -- since before the reboot. The seeding pass above has now recorded the
    -- current bonus for every live target, so from the second sweep onward a
    -- notify means an actual INCREASE, which is what the message claims.
    heatBonusPrimed = true

    -- Expire state contracts for anyone whose warrants all cleared without
    -- being captured - no player money involved, nothing to refund. With
    -- RequireCase ON this also retracts a contract whose warrant no longer
    -- qualifies, which is the same "the city stopped wanting them" outcome and
    -- equally refund-free. 'claimed' rows are never selected here, so a payout
    -- in flight is untouched.
    local openState = {}
    pcall(function()
        openState = MySQL.query.await(
            "SELECT id, target_citizenid FROM palm6_bounty_contracts WHERE kind = 'state' AND status = 'active'") or {}
    end)
    for _, row in ipairs(openState) do
        if not liveTargets[row.target_citizenid] then
            pcall(function()
                MySQL.update.await(
                    "UPDATE palm6_bounty_contracts SET status = 'expired' WHERE id = ? AND status = 'active'",
                    { row.id })
            end)
            dbg(('state contract #%d expired — warrant cleared'):format(row.id))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Private-contract TTL sweep — full refund, no cancel fee (natural expiry).
-- ---------------------------------------------------------------------------
local function sweepExpiredPrivate()
    local due = {}
    pcall(function()
        due = MySQL.query.await(
            "SELECT id, poster_citizenid, amount FROM palm6_bounty_contracts WHERE kind = 'private' AND status = 'active' AND expires_at IS NOT NULL AND expires_at <= NOW()") or {}
    end)
    for _, c in ipairs(due) do
        local marked = false
        pcall(function()
            marked = MySQL.update.await(
                "UPDATE palm6_bounty_contracts SET status = 'expired', settled = 0 WHERE id = ? AND status = 'active'",
                { c.id }) == 1
        end)
        if marked then
            local amount = tonumber(c.amount) or 0
            -- Claim-before-credit (same guard as /capture and /cancelbounty) so a
            -- crash between the 'expired' flip and this refund is re-driven by the
            -- boot reconcile exactly once, never double-refunding. This sweep only
            -- ever selects kind='private' rows, so the escrow is real.
            if amount > 0 and c.poster_citizenid and claimSettled(c.id, 'expired') then
                if Bridge.CreditBankByCitizenId(c.poster_citizenid, amount, 'bounty-expire-refund') then
                    local s = Bridge.GetSourceByCitizenId(c.poster_citizenid)
                    if s then
                        Bridge.Notify(s, 'Bounty Board',
                            ('Contract #%d expired unclaimed — $%d refunded.'):format(c.id, amount), 'inform')
                    end
                else
                    dbg(('contract #%d expire: refund credit returned false — $%d shortfall'):format(c.id, amount))
                end
            end
            dbg(('contract #%d expired, refunded %d'):format(c.id, amount))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Boot reconcile — re-drive any terminal contract whose escrow payout never
-- landed (the server died between the guarded status flip and the bank credit).
-- Idempotent: claimSettled flips settled 0->1 BEFORE each credit, so an
-- already-paid row (settled=1) is skipped and this only ever pays what a crash
-- left owing. Deterministic — every amount is recomputed from the contract row.
-- Delayed (see onResourceStart) so palm6_dbmigrate's 0055 `settled` column has
-- landed first; before that the WHERE settled=0 query errors (pcall-swallowed)
-- and recovers nothing.
--
-- Scope mirrors the live paths that hold escrow:
--   claimed   — hunter payout (claimed_by_citizenid), BOTH kinds: a 'state'
--               claim is city-funded, a 'private' claim is escrow-backed; both
--               owe the hunter. Recovery pays the base contract amount (no
--               palm6_pulse surge — that live-only faucet isn't replayed).
--   cancelled — poster refund minus the cancel fee, PRIVATE only (a 'state'
--               contract is never cancelled).
--   expired   — poster full refund, PRIVATE only. A 'state' 'expired' row is a
--               cleared warrant that never escrowed a cent — refunding it would
--               MINT money, so it is excluded here exactly as the TTL sweep
--               (kind='private') and syncStateContracts (no refund) intend.
-- ---------------------------------------------------------------------------
local function reconcileUnsettled()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await([[
            SELECT id, kind, status, amount, poster_citizenid, claimed_by_citizenid
            FROM palm6_bounty_contracts
            WHERE settled = 0
              AND ( status = 'claimed'
                 OR (status = 'cancelled' AND kind = 'private')
                 OR (status = 'expired'  AND kind = 'private') )
        ]]) or {}
    end)
    local recovered = 0
    for _, c in ipairs(pending) do
        local amount = tonumber(c.amount) or 0
        if c.status == 'claimed' then
            if c.claimed_by_citizenid and claimSettled(c.id, 'claimed') then
                if amount > 0 and not Bridge.CreditBankByCitizenId(c.claimed_by_citizenid, amount, 'bounty-capture-recovered') then
                    dbg(('reconcile: contract #%d hunter credit returned false — $%d shortfall'):format(c.id, amount))
                end
                recovered = recovered + 1
                dbg(('reconcile: contract #%d hunter payout $%d recovered'):format(c.id, amount))
            end
        elseif c.status == 'cancelled' then
            if c.poster_citizenid and claimSettled(c.id, 'cancelled') then
                local refund = amount - math.floor(amount * Config.Private.CancelFeePct)
                if refund > 0 and not Bridge.CreditBankByCitizenId(c.poster_citizenid, refund, 'bounty-cancel-refund-recovered') then
                    dbg(('reconcile: contract #%d cancel refund returned false — $%d shortfall'):format(c.id, refund))
                end
                recovered = recovered + 1
                dbg(('reconcile: contract #%d cancel refund $%d recovered'):format(c.id, refund))
            end
        elseif c.status == 'expired' then
            if c.poster_citizenid and claimSettled(c.id, 'expired') then
                if amount > 0 and not Bridge.CreditBankByCitizenId(c.poster_citizenid, amount, 'bounty-expire-refund-recovered') then
                    dbg(('reconcile: contract #%d expire refund returned false — $%d shortfall'):format(c.id, amount))
                end
                recovered = recovered + 1
                dbg(('reconcile: contract #%d expire refund $%d recovered'):format(c.id, amount))
            end
        end
    end
    if recovered > 0 then
        print(('[palm6_bounty] boot reconcile settled %d interrupted payout(s)'):format(recovered))
    end
end

CreateThread(function()
    while true do
        Wait((Config.State.SweepSec or 180) * 1000)
        syncStateContracts()
        sweepExpiredPrivate()
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('postbounty', function(source, args) cmdPostBounty(source, args) end)
Bridge.RegisterCommand('cancelbounty', function(source, args) cmdCancelBounty(source, args) end)
Bridge.RegisterCommand('bounties', function(source) cmdBounties(source) end)
Bridge.RegisterCommand('capture', function(source, args) cmdCapture(source, args) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- The whole boot sequence runs on this thread because ensureSchema has to
    -- Wait for oxmysql's connection before it can issue any query, and neither
    -- the banner count nor the warrant sync may run before the contracts table
    -- is guaranteed to exist. Timings are preserved: the sync used to fire at
    -- 2s and the reconcile at 8s; they now fire at 3s and 8s.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()
        local activeN, totalAmount = 0, 0
        pcall(function()
            local r = MySQL.single.await(
                "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM palm6_bounty_contracts WHERE status = 'active'")
            activeN = r and tonumber(r.n) or 0
            totalAmount = r and tonumber(r.total) or 0
        end)
        print(('[palm6_bounty] board open — %d contract(s) posted ($%d total); warrant sync %s')
            :format(activeN, totalAmount,
                (Config.State.Enabled and (not Config.State.RequireMdt or Bridge.ResourceStarted('palm6_mdt')))
                    and 'ONLINE' or 'off'))
        -- Said out loud so the fresh-box case cannot be mistaken for a quiet
        -- board: without the table every count above reads 0 and every command
        -- silently no-ops.
        if not SchemaReady then
            print('^1[palm6_bounty] schema MISSING - the wanted board is INERT on this box.^0')
        end
        -- Sync once on boot so a restart doesn't wait a full SweepSec for the
        -- board to reflect the live warrant table.
        syncStateContracts()
        -- Recover any escrow payout interrupted by the last restart, once oxmysql +
        -- palm6_dbmigrate (the 0055 `settled` column) are up. Non-time-critical, so
        -- wait the 8s out — matching palm6_fightclub's reconcile delay. Before the
        -- column lands the reconcile's WHERE settled=0 query errors (pcall-swallowed)
        -- and recovers nothing, so the wait is load-bearing.
        Wait(5000)
        reconcileUnsettled()
    end)
end)

---Contract counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { activeContracts = 0, totalAmount = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM palm6_bounty_contracts WHERE status = 'active'")
        out.activeContracts = r and tonumber(r.n) or 0
        out.totalAmount = r and tonumber(r.total) or 0
    end)
    return out
end)
