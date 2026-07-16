-- ============================================================================
-- palm6_insurance/server/main.lua
--
-- Pure logic. Calls Bridge.* (bridge/sv_framework.lua) for all framework /
-- native access. No direct framework / native calls here (§6 gate).
--
-- Mors Mutual: buy a policy on a vehicle you own, file claims on damage,
-- total loss, or theft. Every input the payout math trusts is server-read:
-- ownership from player_vehicles, damage from the synced entity's health,
-- theft from state+absence, and the fraud score from the city's own
-- forensics (palm6_replay scenes). Flagged claims still pay — they just
-- open a palm6_evidence case for police to work the fraud angle in RP.
--
-- Deliberately no client-trusted net events: both commands take effect
-- entirely from server-side reads.
-- ============================================================================

local lastAction = {}   -- [src] = { [key] = ts } per-source rate limits
local lastClaim = {}    -- [citizenid] = ts; in-memory, resets on restart (repeat-claim scoring covers the gap)

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_insurance] ' .. msg) end
end

local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

local function atOffice(src)
    local c = Bridge.GetCoords(src)
    if not c then return false end
    return Bridge.Distance(c, Config.Office.coords) <= Config.Office.radius
end

local function normPlate(plate)
    return tostring(plate or ''):upper():gsub('%s+', '')
end

-- Owned vehicle row for (cid, plate), or nil. Plate comparison is
-- whitespace-insensitive (GTA pads plates to 8).
local function ownedVehicle(cid, plate)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, vehicle, plate, state, engine, body FROM player_vehicles WHERE citizenid = ? AND REPLACE(UPPER(plate), ' ', '') = ?",
            { cid, plate })
    end)
    return row
end

local function activePolicy(plate)
    local row
    pcall(function()
        row = MySQL.single.await(
            "SELECT id, citizenid, coverage, deductible, created_at, expires_at, UNIX_TIMESTAMP(created_at) AS created_ts FROM palm6_insurance_policies WHERE REPLACE(UPPER(plate), ' ', '') = ? AND status = 'active' AND expires_at > NOW() LIMIT 1",
            { plate })
    end)
    return row
end

-- ---------------------------------------------------------------------------
-- Evidence hand-off (frozen sibling API, pcall-guarded)
-- ---------------------------------------------------------------------------
local function openFraudCase(claimId, cid, name, plate, kind, factors, assessed)
    if not Bridge.ResourceStarted('palm6_evidence') then return nil end
    local caseId
    pcall(function()
        caseId = exports.palm6_evidence:EnsureCase(
            ('insurance:claim:%d'):format(claimId),
            ('Suspected insurance fraud — %s claim on %s'):format(kind, plate),
            'palm6_insurance')
        if caseId then
            exports.palm6_evidence:AppendEntry(caseId, 'note', {
                claim_id = claimId,
                plate = plate,
                kind = kind,
                payout = assessed,
                risk_factors = factors,
            }, 'palm6_insurance')
            exports.palm6_evidence:LinkSuspect(caseId, cid, nil)
        end
    end)
    return caseId
end

-- ---------------------------------------------------------------------------
-- Fraud scoring — every signal server-derived
-- ---------------------------------------------------------------------------
local function scoreClaim(cid, policy, kind, vehCoords, assessed, coverage)
    local score, factors, deny = 0, {}, false

    local ageMin = math.floor((now() - (tonumber(policy.created_ts) or now())) / 60)
    if ageMin < Config.Risk.FreshPolicyMin then
        score = score + Config.Risk.FreshPolicyScore
        factors[#factors + 1] = ('policy only %d min old at filing'):format(ageMin)
    end

    local priors = 0
    pcall(function()
        local r = MySQL.single.await(
            'SELECT COUNT(*) AS n FROM palm6_insurance_claims WHERE citizenid = ? AND filed_at >= NOW() - INTERVAL ? HOUR',
            { cid, Config.Risk.RepeatWindowH })
        priors = r and tonumber(r.n) or 0
    end)
    if priors > 0 then
        score = score + priors * Config.Risk.RepeatScoreEach
        factors[#factors + 1] = ('%d prior claim(s) in %dh'):format(priors, Config.Risk.RepeatWindowH)
    end

    -- Undocumented damage: no replay incident scene near the vehicle with
    -- the claimant as a participant. Only scored when palm6_replay is
    -- actually running — absence of the black box is not evidence of fraud.
    if vehCoords and Bridge.ResourceStarted('palm6_replay') then
        local scenes = 0
        pcall(function()
            local r = MySQL.single.await([[
                SELECT COUNT(*) AS n
                FROM palm6_replay_scenes s
                JOIN palm6_replay_participants p ON p.scene_id = s.id
                WHERE p.citizenid = ?
                  AND s.created_at >= NOW() - INTERVAL ? MINUTE
                  AND ABS(s.x - ?) <= ? AND ABS(s.y - ?) <= ?
            ]], { cid, Config.Risk.SceneWindowMin,
                  vehCoords.x, Config.Risk.SceneRadius,
                  vehCoords.y, Config.Risk.SceneRadius })
            scenes = r and tonumber(r.n) or 0
        end)
        if scenes == 0 then
            score = score + Config.Risk.NoSceneScore
            factors[#factors + 1] = 'no black-box incident scene near the vehicle'
            -- Synced entity health is client-authored under one-sync, so a
            -- damage/total_loss payout must be corroborated by a real replay
            -- incident scene. When forensics is running and finds none, deny
            -- the payout outright rather than merely flagging it.
            deny = true
        end
    end

    if assessed >= coverage then
        score = score + Config.Risk.MaxPayoutScore
        factors[#factors + 1] = 'claim maxes the coverage cap'
    end

    return math.min(score, 255), factors, deny
end

-- ---------------------------------------------------------------------------
-- /insure <plate>
-- ---------------------------------------------------------------------------
local function cmdInsure(src, args)
    if src == 0 then return end
    if not rl(src, 'insure') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atOffice(src) then
        Bridge.Notify(src, 'Mors Mutual', 'You need to be at the insurance desk.', 'error')
        return
    end
    local plate = normPlate(args[1])
    if plate == '' then
        Bridge.Notify(src, 'Mors Mutual', 'Usage: /insure [plate]', 'error')
        return
    end

    local veh = ownedVehicle(cid, plate)
    if not veh then
        Bridge.Notify(src, 'Mors Mutual', 'No vehicle with that plate is registered to you.', 'error')
        return
    end
    if activePolicy(plate) then
        Bridge.Notify(src, 'Mors Mutual', 'That plate already carries an active policy.', 'error')
        return
    end

    -- A vehicle that has already been written off (theft or total loss) is not
    -- re-insurable. Without this gate, insure -> file theft/total-loss claim ->
    -- policy retires to 'claimed' -> re-insure the same plate is a strictly
    -- net-positive money loop (premium 5% vs payout ~54% of value). Repairable
    -- minor-damage claims do NOT write the vehicle off, so they stay insurable.
    local writeOff
    pcall(function()
        writeOff = MySQL.single.await([[
            SELECT id FROM palm6_insurance_claims
            WHERE REPLACE(UPPER(plate), ' ', '') = ?
              AND kind IN ('theft', 'total_loss')
              AND status IN ('processing', 'paid', 'flagged_paid')
            LIMIT 1
        ]], { plate })
    end)
    if writeOff then
        Bridge.Notify(src, 'Mors Mutual', 'That vehicle is on record as a total loss / theft and can no longer be insured.', 'error')
        return
    end

    -- Damage claims are repairable (they intentionally do NOT write the vehicle
    -- off), but without this gate you could re-insure ($ premium) and re-file a
    -- damage claim on the SAME unrepaired damage every claim-cooldown — a large
    -- net-positive faucet. Lock re-insuring a plate for one policy term after a
    -- paid/processing damage claim, so the same damage cannot fund a second
    -- claim within the window (the car is expected to be repaired by then).
    local recentDamage
    pcall(function()
        recentDamage = MySQL.single.await([[
            SELECT id FROM palm6_insurance_claims
            WHERE REPLACE(UPPER(plate), ' ', '') = ?
              AND kind = 'damage'
              AND status IN ('processing', 'paid', 'flagged_paid')
              AND filed_at > NOW() - INTERVAL ? HOUR
            LIMIT 1
        ]], { plate, Config.Underwriting.TermHours })
    end)
    if recentDamage then
        Bridge.Notify(src, 'Mors Mutual', 'A recent damage claim is on file for that plate. Get it repaired and come back once the claim window resets.', 'error')
        return
    end

    local U = Config.Underwriting
    local value = Bridge.GetVehicleValue(veh.vehicle) or U.MinValue
    if value < U.MinValue then value = U.MinValue end
    if value > U.MaxValue then value = U.MaxValue end
    local premium = math.max(U.MinPremium, math.floor(value * U.PremiumPct))
    local coverage = math.floor(value * U.CoveragePct)
    local deductible = math.floor(coverage * U.DeductibleP)

    if not Bridge.ChargeBank(src, premium, 'insurance-premium') then
        Bridge.Notify(src, 'Mors Mutual', ('The premium is $%d (bank).'):format(premium), 'error')
        return
    end

    local ok, policyId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_insurance_policies
                (plate, citizenid, vehicle_model, vehicle_value, premium_paid, coverage, deductible, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? HOUR)
        ]], { veh.plate, cid, veh.vehicle, value, premium, coverage, deductible, U.TermHours })
    end)
    if not ok or not policyId then
        Bridge.CreditBankByCitizenId(cid, premium, 'insurance-premium-refund')
        Bridge.Notify(src, 'Mors Mutual', 'Underwriting failed — you were refunded.', 'error')
        return
    end

    dbg(('policy #%d %s (%s) value=%d premium=%d'):format(policyId, veh.plate, veh.vehicle, value, premium))
    Bridge.Notify(src, 'Mors Mutual',
        ('Policy issued for %s: $%d coverage, $%d deductible, %dh term. Premium $%d paid.')
        :format(plate, coverage, deductible, U.TermHours, premium), 'success')
end

-- ---------------------------------------------------------------------------
-- /fileclaim <plate> <damage|theft>
-- ---------------------------------------------------------------------------
local function cmdFileClaim(src, args)
    if src == 0 then return end
    if not rl(src, 'fileclaim') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atOffice(src) then
        Bridge.Notify(src, 'Mors Mutual', 'You need to be at the insurance desk.', 'error')
        return
    end

    local plate = normPlate(args[1])
    local declared = tostring(args[2] or ''):lower()
    if plate == '' or (declared ~= 'damage' and declared ~= 'theft') then
        Bridge.Notify(src, 'Mors Mutual', 'Usage: /fileclaim [plate] [damage|theft]', 'error')
        return
    end

    local t = now()
    if (lastClaim[cid] or 0) + Config.Claims.PerCitizenCdSec > t then
        Bridge.Notify(src, 'Mors Mutual', 'Your adjuster is still processing your last claim. Come back later.', 'error')
        return
    end

    local veh = ownedVehicle(cid, plate)
    if not veh then
        Bridge.Notify(src, 'Mors Mutual', 'No vehicle with that plate is registered to you.', 'error')
        return
    end
    local policy = activePolicy(plate)
    if not policy then
        Bridge.Notify(src, 'Mors Mutual', 'No active policy on that plate.', 'error')
        return
    end
    if policy.citizenid ~= cid then
        Bridge.Notify(src, 'Mors Mutual', 'The policyholder has to file this claim.', 'error')
        return
    end

    local kind, assessed, vehCoords
    local coverage = tonumber(policy.coverage) or 0
    local deductible = tonumber(policy.deductible) or 0

    if declared == 'theft' then
        -- Stolen means: the city thinks it's out AND it isn't anywhere in
        -- the synced world.
        if tonumber(veh.state) ~= 0 then
            Bridge.Notify(src, 'Mors Mutual', 'Our records show that vehicle is stored, not stolen.', 'error')
            return
        end
        if Bridge.FindVehicleByPlate(plate) then
            Bridge.Notify(src, 'Mors Mutual', 'That vehicle is on the street right now. Claim denied.', 'error')
            return
        end
        kind = 'theft'
        assessed = math.floor(coverage * Config.Claims.TheftPayoutPct) - deductible
    else
        local entity = Bridge.FindVehicleByPlate(plate)
        if not entity then
            Bridge.Notify(src, 'Mors Mutual', 'Bring the damaged vehicle into the city so the adjuster can inspect it.', 'error')
            return
        end
        local frac = Bridge.GetVehicleDamageFrac(entity)
        if frac < Config.Claims.MinDamageFrac then
            Bridge.Notify(src, 'Mors Mutual',
                ('The adjuster assessed %d%% damage — below the %d%% claim floor.')
                :format(math.floor(frac * 100), math.floor(Config.Claims.MinDamageFrac * 100)), 'error')
            return
        end
        kind = frac >= Config.Claims.TotalLossFrac and 'total_loss' or 'damage'
        assessed = math.floor(coverage * frac) - deductible
        vehCoords = Bridge.GetVehicleCoords(entity)
    end

    if assessed <= 0 then
        Bridge.Notify(src, 'Mors Mutual', 'After the deductible there is nothing to pay out.', 'error')
        return
    end
    if assessed > coverage then assessed = coverage end

    local score, factors, deny = scoreClaim(cid, policy, kind, vehCoords, assessed, coverage)
    if deny then
        Bridge.Notify(src, 'Mors Mutual',
            'No incident scene on record for that vehicle — the adjuster cannot verify the damage. Claim denied.', 'error')
        return
    end

    local ok, claimId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_insurance_claims
                (policy_id, plate, citizenid, kind, assessed, risk_score, risk_factors, status, due_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'processing', NOW() + INTERVAL ? SECOND)
        ]], { policy.id, veh.plate, cid, kind, assessed, score,
              json.encode(factors), Config.Claims.ProcessingSec })
    end)
    if not ok or not claimId then
        Bridge.Notify(src, 'Mors Mutual', 'Claim system is down — nothing was filed.', 'error')
        return
    end
    lastClaim[cid] = t

    -- Retire the policy so activePolicy() (which filters status = 'active')
    -- can never re-select it: one payout per policy, matching Mors Mutual.
    pcall(function()
        MySQL.update.await(
            "UPDATE palm6_insurance_policies SET status = 'claimed' WHERE id = ? AND status = 'active'",
            { policy.id })
    end)

    -- Consume the asset on a write-off. A theft or total-loss claim means the
    -- vehicle is GONE — retire the player_vehicles ownership row so the owner
    -- cannot keep driving / re-summoning the same car AND pocket the payout
    -- (that was an unbounded faucet: mere absence-from-sync was treated as
    -- theft, and the car was never removed). Damage claims are repairable and
    -- deliberately leave the row intact. scoreClaim's deny check already ran
    -- above, so a rejected theft claim never reaches this point.
    if kind == 'theft' or kind == 'total_loss' then
        pcall(function()
            MySQL.update.await(
                'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?',
                { veh.plate, cid })
        end)
    end

    if score >= Config.Risk.FlagThreshold then
        local caseId = openFraudCase(claimId, cid, Bridge.GetPlayerName(src), veh.plate, kind, factors, assessed)
        if caseId then
            pcall(function()
                MySQL.update.await('UPDATE palm6_insurance_claims SET case_id = ? WHERE id = ?',
                    { caseId, claimId })
            end)
        end
        dbg(('claim #%d FLAGGED score=%d case=%s'):format(claimId, score, tostring(caseId)))
    end

    Bridge.Notify(src, 'Mors Mutual',
        ('Claim #%d filed (%s, $%d). Payout lands in your bank in ~%d minutes.')
        :format(claimId, kind, assessed, math.ceil(Config.Claims.ProcessingSec / 60)), 'success')
end

-- ---------------------------------------------------------------------------
-- /policy — active policies + pending claims
-- ---------------------------------------------------------------------------
local function cmdPolicy(src)
    if src == 0 then return end
    if not rl(src, 'policy') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local pols, claims = {}, {}
    pcall(function()
        pols = MySQL.query.await(
            "SELECT plate, coverage, deductible, TIMESTAMPDIFF(HOUR, NOW(), expires_at) AS hrs FROM palm6_insurance_policies WHERE citizenid = ? AND status = 'active' AND expires_at > NOW()",
            { cid }) or {}
        claims = MySQL.query.await(
            "SELECT id, plate, assessed FROM palm6_insurance_claims WHERE citizenid = ? AND resolved_at IS NULL",
            { cid }) or {}
    end)

    if #pols == 0 and #claims == 0 then
        Bridge.Notify(src, 'Mors Mutual', 'No active policies. /insure [plate] at the desk.', 'inform')
        return
    end
    for _, p in ipairs(pols) do
        Bridge.Notify(src, 'Mors Mutual',
            ('%s — $%d coverage, $%d deductible, %dh left'):format(
                normPlate(p.plate), p.coverage, p.deductible, math.max(0, tonumber(p.hrs) or 0)), 'inform')
    end
    for _, c in ipairs(claims) do
        Bridge.Notify(src, 'Mors Mutual',
            ('Claim #%d (%s) — $%d processing'):format(c.id, normPlate(c.plate), c.assessed), 'inform')
    end
end

-- ---------------------------------------------------------------------------
-- Recoverable claim credit.
--
-- creditClaim() is the RECOVERABLE, IDEMPOTENT bank payout, callable from BOTH
-- the live sweep AND the boot reconcile. It CLAIMS the credited_at flag BEFORE
-- the money moves (UPDATE ... WHERE credited_at = 0 returns 1), and credits ONLY
-- if the claim succeeded. This makes the payout re-drivable from a clean boot
-- (see reconcileUncredited) with NO double-pay — an already-credited claim has
-- credited_at > 0 and is skipped.
--
-- Bias (matching /insure's charge-before-issue): a crash in the tiny window
-- between claiming credited_at and the bank credit costs that one payout — a
-- rare self-inflicted shortfall, never a mint — while the common crash (before
-- the credit started, or after the status flip) is fully recovered on the next
-- boot. Only bank money is reconciled here; the write-off DELETE of
-- player_vehicles happens at file time, not payout, so it is untouched.
-- ---------------------------------------------------------------------------
local function creditClaim(c)
    -- Atomic claim: flip credited_at 0 -> now exactly once. Only the run that
    -- flips it (live sweep OR boot recovery) proceeds to the bank credit.
    local claimed = false
    pcall(function()
        claimed = MySQL.update.await(
            "UPDATE palm6_insurance_claims SET credited_at = ? WHERE id = ? AND credited_at = 0",
            { now(), c.id }) == 1
    end)
    if not claimed then return end

    Bridge.CreditBankByCitizenId(c.citizenid, tonumber(c.assessed) or 0, 'insurance-claim')
    local s = Bridge.GetSourceByCitizenId(c.citizenid)
    if s then
        Bridge.Notify(s, 'Mors Mutual',
            ('Claim #%d paid out: $%d landed in your bank.'):format(c.id, c.assessed), 'success')
    end
    dbg(('claim #%d paid %d to %s'):format(c.id, c.assessed, c.citizenid))
end

-- Boot reconcile — re-drive any claim already flipped to a terminal paid status
-- whose bank credit never landed (server died between the status flip and the
-- credit, or between the credited_at claim and the credit). Idempotent:
-- creditClaim only credits a claim whose credited_at is still 0, so this pays
-- exactly what a crash left owing and never double-pays. Delayed so
-- palm6_dbmigrate's 0057 ALTER (the credited_at column) has landed first —
-- before that the WHERE credited_at = 0 query would error (pcall-swallowed) and
-- recover nothing.
local function reconcileUncredited()
    local pending = {}
    pcall(function()
        pending = MySQL.query.await(
            "SELECT id, citizenid, assessed FROM palm6_insurance_claims WHERE status IN ('paid', 'flagged_paid') AND credited_at = 0") or {}
    end)
    for _, c in ipairs(pending) do
        creditClaim(c)
    end
    if #pending > 0 then
        print(('[palm6_insurance] boot reconcile credited %d interrupted claim payout(s)'):format(#pending))
    end
end

-- ---------------------------------------------------------------------------
-- Sweeps: payout release + policy lapse
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(30000)
        local due = {}
        pcall(function()
            due = MySQL.query.await(
                "SELECT id, citizenid, assessed, risk_score FROM palm6_insurance_claims WHERE status = 'processing' AND resolved_at IS NULL AND due_at <= NOW()") or {}
        end)
        for _, c in ipairs(due) do
            -- Flip to the terminal paid status BEFORE paying (guarded WHERE
            -- resolved_at IS NULL so exactly one sweep flips it), then hand off
            -- to creditClaim, which CLAIMS credited_at before the bank credit.
            -- A payout that double-fires costs the city money; an unpaid marked
            -- row (credited_at=0) is visible and recovered by the boot reconcile
            -- — the cheap failure is the recoverable one.
            -- Reset credited_at=0 in this SAME guarded flip so a NEWLY-paid claim
            -- is uncredited until creditClaim stamps it. The migration backfills
            -- pre-existing terminal rows to credited_at=1 (already settled); the
            -- WHERE resolved_at IS NULL guard means only a genuine new transition
            -- resets it, so those historical rows are never re-flipped to 0 and
            -- stay skipped by the reconcile.
            local marked = false
            pcall(function()
                marked = MySQL.update.await(
                    "UPDATE palm6_insurance_claims SET status = ?, resolved_at = NOW(), credited_at = 0 WHERE id = ? AND resolved_at IS NULL",
                    { (tonumber(c.risk_score) or 0) >= Config.Risk.FlagThreshold and 'flagged_paid' or 'paid',
                      c.id }) == 1
            end)
            if marked then
                creditClaim(c)
            end
        end

        pcall(function()
            MySQL.update.await(
                "UPDATE palm6_insurance_policies SET status = 'lapsed' WHERE status = 'active' AND expires_at <= NOW()")
        end)
    end
end)

-- ---------------------------------------------------------------------------
-- Commands + boot
-- ---------------------------------------------------------------------------
Bridge.RegisterCommand('insure', function(source, args) cmdInsure(source, args) end)
Bridge.RegisterCommand('fileclaim', function(source, args) cmdFileClaim(source, args) end)
Bridge.RegisterCommand('policy', function(source) cmdPolicy(source) end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local active, pending = 0, 0
    pcall(function()
        local a = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_insurance_policies WHERE status = 'active' AND expires_at > NOW()")
        active = a and tonumber(a.n) or 0
        local p = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_insurance_claims WHERE resolved_at IS NULL")
        pending = p and tonumber(p.n) or 0
    end)
    print(('[palm6_insurance] Mors Mutual open — %d active policy(ies), %d claim(s) processing; replay forensics %s')
        :format(active, pending,
            Bridge.ResourceStarted('palm6_replay') and 'ONLINE' or 'offline (no-scene signal disabled)'))
    -- Recover any claim payout interrupted by the last restart, once oxmysql +
    -- palm6_dbmigrate (0057 credited_at column) are up. Non-time-critical, so
    -- wait it out before the WHERE credited_at = 0 query runs.
    CreateThread(function()
        Wait(8000)
        reconcileUncredited()
    end)
end)

---Claim/policy counts for devtest and future consumers.
exports('GetSummary', function()
    local out = { activePolicies = 0, pendingClaims = 0 }
    pcall(function()
        local a = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_insurance_policies WHERE status = 'active' AND expires_at > NOW()")
        out.activePolicies = a and tonumber(a.n) or 0
        local p = MySQL.single.await(
            "SELECT COUNT(*) AS n FROM palm6_insurance_claims WHERE resolved_at IS NULL")
        out.pendingClaims = p and tonumber(p.n) or 0
    end)
    return out
end)
