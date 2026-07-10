-- ============================================================================
-- gtarp_bounty/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The wanted board. Two contract kinds share one ledger:
--   - STATE contracts are auto-posted (and kept in sync) against every
--     citizen carrying an active gtarp_mdt warrant. Read-only cross-read of
--     gtarp_mdt_warrants — the same house pattern gtarp_pumpcoin/
--     gtarp_clout/gtarp_flashdrop use to read gtarp_turf. This resource
--     never writes to gtarp_mdt's tables. Funded by the city — no player is
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

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[gtarp_bounty] ' .. msg) end
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
            "SELECT COUNT(*) AS n FROM gtarp_bounty_contracts WHERE poster_citizenid = ? AND kind = 'private' AND status = 'active'",
            { cid })
        n = r and tonumber(r.n) or 0
    end)
    return n
end

local function activeContract(id)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT * FROM gtarp_bounty_contracts WHERE id = ? AND status = 'active'", { id })
    end)
    return row
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
            INSERT INTO gtarp_bounty_contracts
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
            "SELECT id, amount FROM gtarp_bounty_contracts WHERE id = ? AND poster_citizenid = ? AND kind = 'private' AND status = 'active'",
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
            "UPDATE gtarp_bounty_contracts SET status = 'cancelled' WHERE id = ? AND status = 'active'",
            { id }) == 1
    end)
    if not marked then
        Bridge.Notify(src, 'Bounty Board', 'That contract was already resolved.', 'error')
        return
    end

    local amount = tonumber(row.amount) or 0
    local fee = math.floor(amount * Config.Private.CancelFeePct)
    local refund = amount - fee
    if refund > 0 then Bridge.CreditBankByCitizenId(cid, refund, 'bounty-cancel-refund') end
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
            FROM gtarp_bounty_contracts
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
            "UPDATE gtarp_bounty_contracts SET status = 'claimed', claimed_by_citizenid = ?, claimed_by_name = ?, claimed_at = NOW() WHERE id = ? AND status = 'active'",
            { hunterCid, hunterName, id }) == 1
    end)
    if not marked then
        Bridge.Notify(src, 'Bounty Board', 'Someone beat you to that contract.', 'error')
        return
    end

    lastCapture[hunterCid] = t
    local amount = tonumber(contract.amount) or 0
    Bridge.CreditBankByCitizenId(hunterCid, amount, 'bounty-capture')
    Bridge.Notify(src, 'Bounty Board',
        ('Contract #%d claimed: %s. $%d landed in your bank.'):format(id, contract.target_name, amount), 'success')
    Bridge.Notify(targetSrc, 'Bounty Board',
        ('%s just collected the bounty on your head.'):format(hunterName), 'error')
    dbg(('contract #%d claimed by %s (target %s, $%d)'):format(id, hunterCid, contract.target_citizenid, amount))
end

-- ---------------------------------------------------------------------------
-- State-contract sync — mirrors gtarp_mdt's live warrant table. Read-only:
-- this resource never writes to gtarp_mdt_warrants.
-- ---------------------------------------------------------------------------
local function syncStateContracts()
    if not Config.State.Enabled then return end
    if Config.State.RequireMdt and not Bridge.ResourceStarted('gtarp_mdt') then return end

    local warrantRows = {}
    pcall(function()
        warrantRows = MySQL.query.await([[
            SELECT citizenid, citizen_name, COUNT(*) AS n
            FROM gtarp_mdt_warrants
            WHERE status = 'active'
            GROUP BY citizenid, citizen_name
        ]]) or {}
    end)

    local S = Config.State
    local liveTargets = {}
    for _, w in ipairs(warrantRows) do
        local cid = w.citizenid
        liveTargets[cid] = true
        local n = tonumber(w.n) or 1
        local amount = math.min(S.Cap, S.BaseAmount + S.PerWarrantExtra * math.max(0, n - 1))

        local existing
        pcall(function()
            existing = MySQL.single.await(
                "SELECT id FROM gtarp_bounty_contracts WHERE target_citizenid = ? AND kind = 'state' AND status IN ('active','claimed')",
                { cid })
        end)
        if existing then
            pcall(function()
                MySQL.update.await(
                    "UPDATE gtarp_bounty_contracts SET amount = ?, target_name = ? WHERE id = ?",
                    { amount, w.citizen_name, existing.id })
            end)
        else
            pcall(function()
                MySQL.insert.await([[
                    INSERT INTO gtarp_bounty_contracts
                        (kind, target_citizenid, target_name, amount, reason)
                    VALUES ('state', ?, ?, ?, 'Active warrant(s) on file')
                ]], { cid, w.citizen_name, amount })
            end)
            dbg(('state contract opened on %s ($%d, %d warrant(s))'):format(cid, amount, n))
        end
    end

    -- Expire state contracts for anyone whose warrants all cleared without
    -- being captured — no player money involved, nothing to refund.
    local openState = {}
    pcall(function()
        openState = MySQL.query.await(
            "SELECT id, target_citizenid FROM gtarp_bounty_contracts WHERE kind = 'state' AND status = 'active'") or {}
    end)
    for _, row in ipairs(openState) do
        if not liveTargets[row.target_citizenid] then
            pcall(function()
                MySQL.update.await(
                    "UPDATE gtarp_bounty_contracts SET status = 'expired' WHERE id = ? AND status = 'active'",
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
            "SELECT id, poster_citizenid, amount FROM gtarp_bounty_contracts WHERE kind = 'private' AND status = 'active' AND expires_at IS NOT NULL AND expires_at <= NOW()") or {}
    end)
    for _, c in ipairs(due) do
        local marked = false
        pcall(function()
            marked = MySQL.update.await(
                "UPDATE gtarp_bounty_contracts SET status = 'expired' WHERE id = ? AND status = 'active'",
                { c.id }) == 1
        end)
        if marked then
            local amount = tonumber(c.amount) or 0
            if amount > 0 and c.poster_citizenid then
                Bridge.CreditBankByCitizenId(c.poster_citizenid, amount, 'bounty-expire-refund')
                local s = Bridge.GetSourceByCitizenId(c.poster_citizenid)
                if s then
                    Bridge.Notify(s, 'Bounty Board',
                        ('Contract #%d expired unclaimed — $%d refunded.'):format(c.id, amount), 'inform')
                end
            end
            dbg(('contract #%d expired, refunded %d'):format(c.id, amount))
        end
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
    local activeN, totalAmount = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM gtarp_bounty_contracts WHERE status = 'active'")
        activeN = r and tonumber(r.n) or 0
        totalAmount = r and tonumber(r.total) or 0
    end)
    print(('[gtarp_bounty] board open — %d contract(s) posted ($%d total); warrant sync %s')
        :format(activeN, totalAmount,
            (Config.State.Enabled and (not Config.State.RequireMdt or Bridge.ResourceStarted('gtarp_mdt')))
                and 'ONLINE' or 'off'))
    -- Sync once on boot so a restart doesn't wait a full SweepSec for the
    -- board to reflect the live warrant table.
    SetTimeout(2000, syncStateContracts)
end)

---Contract counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { activeContracts = 0, totalAmount = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM gtarp_bounty_contracts WHERE status = 'active'")
        out.activeContracts = r and tonumber(r.n) or 0
        out.totalAmount = r and tonumber(r.total) or 0
    end)
    return out
end)
