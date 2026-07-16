-- ============================================================================
-- palm6_ransom/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- The recipe's `qbx_police`/`qbx_radialmenu` already ship a raw "Kidnap"/
-- "Take Hostage" physical mechanic (drag a restrained citizen into a
-- vehicle trunk) — zero economy, zero paper trail. This resource listens
-- to that same net event (`police:server:KidnapPlayer`) and hangs a ransom
-- ledger + felony record off it. It never re-implements the restrain/trunk
-- mechanic itself.
--
-- Client-trust note: `police:server:KidnapPlayer` is a globally addressable
-- net event already registered by qbx_police. Registering a SECOND handler
-- here (below) does not run "after" or "gated by" the recipe's own handler
-- — FiveM fires every registered handler independently. A modified client
-- could TriggerServerEvent this event directly with a fabricated victim id,
-- so this handler re-derives validity itself (both players real and online,
-- genuinely restrained per Bridge.IsRestrained, genuinely close per
-- Bridge.Distance) rather than trusting "the event fired" — the same
-- lesson palm6_courier's payout exploit and palm6_mdt's spoofable-source
-- bug taught this session.
-- ============================================================================

local lastAction = {}    -- [src] = { [key] = ts } — chat-command spam guard
AddEventHandler('playerDropped', function() lastAction[source] = nil end)  -- reclaim on disconnect
local lastKidnapBy = {}  -- [kidnapperCid] = { victimCid, victimName, ts } — validated kidnap, pending a demand

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_ransom] ' .. msg) end
end

local function rl(src, key, window)
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function atDropPoint(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.DropPoint.coords) <= Config.DropPoint.radius
end

local function activeCaseById(id)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT * FROM palm6_ransom_cases WHERE id = ? AND status = 'active'", { id })
    end)
    return row
end

local function activeCaseForVictim(victimCid)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id FROM palm6_ransom_cases WHERE victim_citizenid = ? AND status = 'active'", { victimCid })
    end)
    return row
end

-- ---------------------------------------------------------------------------
-- Kidnap validation — re-derives the whole event independently of the
-- recipe's own handler (see module header). Records the pairing in memory
-- so /demandransom can be gated on a real, recent, server-verified event.
-- ---------------------------------------------------------------------------
RegisterNetEvent('police:server:KidnapPlayer', function(kidnapedSrc)
    local src = source
    kidnapedSrc = tonumber(kidnapedSrc)
    if not kidnapedSrc or kidnapedSrc == src then return end

    local kidnapperCid = Bridge.GetCitizenId(src)
    local victimCid = Bridge.GetCitizenId(kidnapedSrc)
    if not kidnapperCid or not victimCid then return end

    if not Bridge.IsRestrained(kidnapedSrc) then return end

    local a, b = Bridge.GetCoords(src), Bridge.GetCoords(kidnapedSrc)
    if not a or not b or Bridge.Distance(a, b) > 5.0 then return end

    lastKidnapBy[kidnapperCid] = {
        victimCid = victimCid,
        victimName = Bridge.GetPlayerName(kidnapedSrc),
        ts = now(),
    }
    dbg(('validated kidnap: %s took %s'):format(kidnapperCid, victimCid))
end)

-- ---------------------------------------------------------------------------
-- /demandransom <amount> <instructions...> — only valid against a citizen
-- this same source was just server-verified to have kidnapped.
-- ---------------------------------------------------------------------------
local function cmdDemandRansom(src, args)
    if src == 0 then return end
    if not rl(src, 'demandransom', Config.Ransom.PostCooldownSec) then return end
    local kidnapperCid = Bridge.GetCitizenId(src)
    if not kidnapperCid then return end

    local R = Config.Ransom
    local amount = math.floor(tonumber(args[1]) or 0)
    local instructions = table.concat(args, ' ', 2):gsub('^%s+', ''):gsub('%s+$', '')

    if amount < R.MinAmount or amount > R.MaxAmount
        or #instructions < R.InstructionsMin or #instructions > R.InstructionsMax then
        Bridge.Notify(src, 'Ransom',
            ('Usage: /demandransom [$%d-%d] [instructions %d-%d chars]')
            :format(R.MinAmount, R.MaxAmount, R.InstructionsMin, R.InstructionsMax), 'error')
        return
    end

    local pending = lastKidnapBy[kidnapperCid]
    if not pending or (pending.ts + R.DemandWindowSec) < now() then
        Bridge.Notify(src, 'Ransom', 'You have not just kidnapped anyone.', 'error')
        return
    end

    if activeCaseForVictim(pending.victimCid) then
        Bridge.Notify(src, 'Ransom', 'There is already an active ransom on that person.', 'error')
        return
    end

    -- Consume the pending kidnap so a second /demandransom can't open a
    -- second case off the same physical kidnap.
    lastKidnapBy[kidnapperCid] = nil

    local kidnapperName = Bridge.GetPlayerName(src)
    local ok, caseId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_ransom_cases
                (kidnapper_citizenid, kidnapper_name, victim_citizenid, victim_name, amount, instructions, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? MINUTE)
        ]], { kidnapperCid, kidnapperName, pending.victimCid, pending.victimName, amount, instructions, R.TimeoutMinutes })
    end)
    if not ok or not caseId then
        Bridge.Notify(src, 'Ransom', 'Could not open a ransom case — try again.', 'error')
        return
    end

    local evidenceCaseId
    if Bridge.ResourceStarted('palm6_evidence') then
        pcall(function()
            evidenceCaseId = exports.palm6_evidence:EnsureCase(nil, 'Kidnapping — ransom demand', kidnapperCid)
            if evidenceCaseId then
                exports.palm6_evidence:AppendEntry(evidenceCaseId, 'ransom_demand', {
                    ransom_case_id = caseId, amount = amount, instructions = instructions,
                    victim_citizenid = pending.victimCid,
                }, 'palm6_ransom')
                exports.palm6_evidence:LinkSuspect(evidenceCaseId, kidnapperCid, nil)
            end
        end)
    end
    if evidenceCaseId then
        pcall(function()
            MySQL.update.await('UPDATE palm6_ransom_cases SET evidence_case_id = ? WHERE id = ?',
                { evidenceCaseId, caseId })
        end)
    end

    Bridge.Notify(src, 'Ransom', ('Ransom #%d demanded: $%d.'):format(caseId, amount), 'success')
    local victimSrc = Bridge.GetSourceByCitizenId(pending.victimCid)
    if victimSrc then
        Bridge.Notify(victimSrc, 'Ransom',
            ('A $%d ransom has been demanded for your release: "%s"'):format(amount, instructions), 'error')
    end
    dbg(('case #%d: %s demands $%d for %s'):format(caseId, kidnapperCid, amount, pending.victimCid))
end

-- ---------------------------------------------------------------------------
-- Close a case (paid or expired). Always escalates to an mdt warrant —
-- kidnapping is a felony regardless of whether the ransom was ever paid.
-- Server-authoritative: caller passes only the row already fetched under a
-- guarded UPDATE, never client input.
-- ---------------------------------------------------------------------------
local function issueWarrantForCase(row)
    if not Bridge.ResourceStarted('palm6_mdt') then return end
    pcall(function()
        exports.palm6_mdt:IssueWarrant(row.kidnapper_citizenid,
            ('kidnapping — ransom case #%d (%s)'):format(row.id, row.victim_name),
            'Anonymous Tip')
    end)
end

local function closeCaseEvidence(row, kind, payload)
    if not row.evidence_case_id or not Bridge.ResourceStarted('palm6_evidence') then return end
    pcall(function()
        exports.palm6_evidence:AppendEntry(row.evidence_case_id, kind, payload, 'palm6_ransom')
    end)
end

-- ---------------------------------------------------------------------------
-- Recoverable kidnapper payout (claim-before-credit).
--
-- Once a case is flipped status='paid' (payer already charged), the kidnapper's
-- bank credit is the last, yielding step — and before this the crash window
-- between the flip and that credit stranded the payer's money forever. This
-- extracted settle does the payout IDEMPOTENTLY and is callable from BOTH the
-- live /payransom path AND the boot reconcile: it re-reads the recorded case
-- (kidnapper + amount) so a replay is deterministic, then CLAIMS
-- payout_credited=1 (guarded WHERE status='paid' AND payout_credited=0) BEFORE
-- the money moves and credits ONLY if it won the claim. A boot reconcile that
-- re-drives an already-credited case sees payout_credited=1, loses the claim,
-- and skips — no double-pay. The Bias (matching /fcbet's consume-before-grant
-- and fightclub's settleMatch): a crash in the tiny window between claiming the
-- flag and the credit costs that one payout — a rare self-inflicted shortfall,
-- never a mint — while the common crash (before the credit started) is fully
-- recovered on the next boot. Returns true iff WE credited this run.
-- ---------------------------------------------------------------------------
local function settleRansomPayout(caseId)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT kidnapper_citizenid, amount FROM palm6_ransom_cases WHERE id = ? AND status = 'paid'",
            { caseId })
    end)
    -- No paid row (or the fetch failed): do NOT claim. A transient DB failure
    -- here is retried by reconcileUncredited on the next boot.
    if not row then
        dbg(('settle #%d skipped — paid-row fetch failed; will retry on boot'):format(caseId))
        return false
    end

    -- Atomic claim BEFORE the credit: exactly one settlement run (live or boot-
    -- recovery) ever flips payout_credited 0->1, so exactly one ever credits.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_ransom_cases SET payout_credited = 1 WHERE id = ? AND status = 'paid' AND payout_credited = 0",
            { caseId }) == 1
    end)
    if not claimed then return false end

    Bridge.CreditBankByCitizenId(row.kidnapper_citizenid, tonumber(row.amount) or 0, 'ransom-payout')
    return true
end

-- Boot reconcile — re-drive any case flipped 'paid' whose kidnapper payout never
-- landed (server died between the 'paid' flip and the credit). Idempotent:
-- settleRansomPayout skips any already-credited (payout_credited=1) case, so this
-- only pays what a crash left owing. Delayed so palm6_dbmigrate's 0058 ALTER (the
-- payout_credited column) has landed first — before that the WHERE payout_credited=0
-- query would error (pcall-swallowed) and recover nothing.
local function reconcileUncredited()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            "SELECT id FROM palm6_ransom_cases WHERE status = 'paid' AND payout_credited = 0") or {}
    end)
    for _, r in ipairs(pending) do
        settleRansomPayout(r.id)
    end
    if #pending > 0 then
        print(('[palm6_ransom] boot reconcile credited %d interrupted ransom payout(s)'):format(#pending))
    end
end

-- ---------------------------------------------------------------------------
-- /payransom <caseId> — anyone can pay, from the drop point, in full.
-- Guarded UPDATE ... WHERE status='active' so a race between two payers (or
-- a payer and the expiry sweep) can only land once.
-- ---------------------------------------------------------------------------
local function cmdPayRansom(src, args)
    if src == 0 then return end
    if not rl(src, 'payransom', Config.Ransom.PayCooldownSec) then return end
    local payerCid = Bridge.GetCitizenId(src)
    if not payerCid then return end

    local id = tonumber(args[1])
    if not id then
        Bridge.Notify(src, 'Ransom', 'Usage: /payransom [case #]', 'error')
        return
    end

    if not atDropPoint(src) then
        Bridge.Notify(src, 'Ransom', ('You need to be at %s.'):format(Config.DropPoint.label), 'error')
        return
    end

    local row = activeCaseById(id)
    if not row then
        Bridge.Notify(src, 'Ransom', 'No active ransom with that number.', 'error')
        return
    end

    local amount = tonumber(row.amount) or 0
    if not Bridge.ChargeBank(src, amount, 'ransom-payment') then
        Bridge.Notify(src, 'Ransom', ('You need $%d in the bank.'):format(amount), 'error')
        return
    end

    -- Mark paid BEFORE crediting the kidnapper — the guarded WHERE stops a
    -- second payer (or the expiry sweep firing concurrently) from also
    -- landing on the same case. A lost race refunds the payer in full.
    -- payout_credited = 0 resets the idempotency flag at the exact 'active'->
    -- 'paid' transition, so this newly-resolved case is recoverable by the boot
    -- reconcile until settleRansomPayout claims it. The WHERE status='active'
    -- guard means only a genuine new transition resets it — pre-deploy 'paid'
    -- rows (backfilled payout_credited=1 by migration 0058) are never re-flipped.
    local marked = false
    pcall(function()
        marked = MySQL.update.await(
            "UPDATE palm6_ransom_cases SET status = 'paid', paid_by_citizenid = ?, resolved_at = NOW(), payout_credited = 0 WHERE id = ? AND status = 'active'",
            { payerCid, id }) == 1
    end)
    if not marked then
        Bridge.CreditBankByCitizenId(payerCid, amount, 'ransom-payment-refund')
        Bridge.Notify(src, 'Ransom', 'That ransom was already resolved — refunded.', 'error')
        return
    end

    -- Claim-before-credit kidnapper payout. In the live path the case was just
    -- flipped 'paid' with payout_credited=0, so this wins the claim and credits
    -- now; if the server dies before this line the boot reconcile drives it
    -- instead. Idempotent either way — the payer's charged money can no longer
    -- strand.
    local credited = settleRansomPayout(id)
    closeCaseEvidence(row, 'ransom_paid', { amount = amount, payer_citizenid = payerCid })
    issueWarrantForCase(row)

    Bridge.Notify(src, 'Ransom', ('Ransom #%d paid — $%d.'):format(id, amount), 'success')
    if credited then
        local kidnapperSrc = Bridge.GetSourceByCitizenId(row.kidnapper_citizenid)
        if kidnapperSrc then
            Bridge.Notify(kidnapperSrc, 'Ransom', ('Ransom #%d was paid — $%d landed in your bank.'):format(id, amount), 'success')
        end
    end
    local victimSrc = Bridge.GetSourceByCitizenId(row.victim_citizenid)
    if victimSrc then
        Bridge.Notify(victimSrc, 'Ransom', 'Your ransom has been paid.', 'success')
    end
    dbg(('case #%d paid by %s ($%d)'):format(id, payerCid, amount))
end

-- ---------------------------------------------------------------------------
-- Expiry sweep — unpaid past due closes 'expired'. No refund owed (nobody
-- paid), but still escalates to a warrant: the kidnapping happened either way.
-- ---------------------------------------------------------------------------
local function sweepExpired()
    local due = {}
    pcall(function()
        due = MySQL.query.await(
            "SELECT * FROM palm6_ransom_cases WHERE status = 'active' AND expires_at <= NOW()") or {}
    end)
    for _, row in ipairs(due) do
        local marked = false
        pcall(function()
            marked = MySQL.update.await(
                "UPDATE palm6_ransom_cases SET status = 'expired', resolved_at = NOW() WHERE id = ? AND status = 'active'",
                { row.id }) == 1
        end)
        if marked then
            closeCaseEvidence(row, 'ransom_expired', {})
            issueWarrantForCase(row)
            dbg(('case #%d expired unpaid'):format(row.id))
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Ransom.SweepSec * 1000)
        sweepExpired()
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('demandransom', function(source, args) cmdDemandRansom(source, args) end)
Bridge.RegisterCommand('payransom', function(source, args) cmdPayRansom(source, args) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local activeN, totalAmount = 0, 0
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM palm6_ransom_cases WHERE status = 'active'")
        activeN = r and tonumber(r.n) or 0
        totalAmount = r and tonumber(r.total) or 0
    end)
    print(('[palm6_ransom] ledger open — %d active case(s) ($%d demanded); mdt escalation %s')
        :format(activeN, totalAmount, Bridge.ResourceStarted('palm6_mdt') and 'ONLINE' or 'offline'))
    -- Recover any kidnapper payout interrupted by the last restart, once oxmysql
    -- + palm6_dbmigrate (0058 payout_credited column) are up. Non-time-critical,
    -- so wait it out — before the column exists the WHERE payout_credited=0 query
    -- would error (pcall-swallowed) and recover nothing.
    CreateThread(function()
        Wait(8000)
        reconcileUncredited()
    end)
end)

---Case counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { activeCases = 0, totalDemanded = 0 }
    pcall(function()
        local r = MySQL.single.await(
            "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM palm6_ransom_cases WHERE status = 'active'")
        out.activeCases = r and tonumber(r.n) or 0
        out.totalDemanded = r and tonumber(r.total) or 0
    end)
    return out
end)
