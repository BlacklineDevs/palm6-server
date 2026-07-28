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

-- Resolve a policy's plan tier config, defaulting to Standard for any unknown /
-- missing tier (pre-tier policies backfill to 'standard' via sql/0064, but this
-- guards a bad value too).
local function tierCfg(key)
    return Config.Tiers[key] or Config.Tiers[Config.DefaultTier]
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
            "SELECT id, citizenid, coverage, deductible, vehicle_value, premium_paid, tier, created_at, expires_at, UNIX_TIMESTAMP(created_at) AS created_ts FROM palm6_insurance_policies WHERE REPLACE(UPPER(plate), ' ', '') = ? AND status = 'active' AND expires_at > NOW() LIMIT 1",
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
-- Clamp a model's catalog value into the underwritable band.
local function clampedValue(model)
    local U = Config.Underwriting
    local value = Bridge.GetVehicleValue(model) or U.MinValue
    if value < U.MinValue then value = U.MinValue end
    if value > U.MaxValue then value = U.MaxValue end
    return value
end

-- Premium / coverage / deductible for a clamped value at a given tier. Shared by
-- the quote (display) and the buy (charge) paths so a quote can never disagree
-- with what is actually charged.
local function quoteFor(value, tier)
    local premium    = math.max(Config.Underwriting.MinPremium, math.floor(value * tier.PremiumPct))
    local coverage   = math.floor(value * tier.CoveragePct)
    local deductible = math.floor(coverage * tier.DeductibleP)
    return premium, coverage, deductible
end

-- doInsure — the authoritative underwrite. `tierKey` is the plan CHOICE; the
-- price is always recomputed server-side from the resolved tier, so a modified
-- client can never buy a richer plan than it pays for. Returns true on success.
local function doInsure(src, plate, tierKey)
    if src == 0 then return end
    if not rl(src, 'insure') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atOffice(src) then
        Bridge.Notify(src, 'Mors Mutual', 'You need to be at the insurance desk.', 'error')
        return
    end
    plate = normPlate(plate)
    if plate == '' then
        Bridge.Notify(src, 'Mors Mutual', 'Usage: /insure [plate] [basic|standard|premium]', 'error')
        return
    end
    local tier = tierCfg(tierKey)  -- unknown/absent -> Standard (never a free upgrade)

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
        ]], { plate, Config.Underwriting.ReinsureLockHours })
    end)
    if recentDamage then
        Bridge.Notify(src, 'Mors Mutual', 'A recent damage claim is on file for that plate. Get it repaired and come back once the claim window resets.', 'error')
        return
    end

    local value = clampedValue(veh.vehicle)
    local premium, coverage, deductible = quoteFor(value, tier)

    if not Bridge.ChargeBank(src, premium, 'insurance-premium') then
        Bridge.Notify(src, 'Mors Mutual', ('The %s premium is $%d (bank).'):format(tier.label, premium), 'error')
        return
    end

    local ok, policyId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO palm6_insurance_policies
                (plate, citizenid, vehicle_model, vehicle_value, premium_paid, coverage, deductible, tier, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? HOUR)
        ]], { veh.plate, cid, veh.vehicle, value, premium, coverage, deductible, tier.key, tier.TermHours })
    end)
    if not ok or not policyId then
        Bridge.CreditBankByCitizenId(cid, premium, 'insurance-premium-refund')
        Bridge.Notify(src, 'Mors Mutual', 'Underwriting failed — you were refunded.', 'error')
        return
    end

    dbg(('policy #%d %s (%s) tier=%s value=%d premium=%d'):format(policyId, veh.plate, veh.vehicle, tier.key, value, premium))
    Bridge.Notify(src, 'Mors Mutual',
        ('%s policy issued for %s: $%d coverage, $%d deductible, %dh term. Premium $%d paid.')
        :format(tier.label, plate, coverage, deductible, tier.TermHours, premium), 'success')
end

-- /insure [plate] [tier] — bare command path; defaults to the Standard tier so
-- pre-agent muscle memory still works exactly as before.
local function cmdInsure(src, args)
    local tierKey = (args[2] and tostring(args[2]) ~= '') and tostring(args[2]):lower() or Config.DefaultTier
    doInsure(src, args[1], tierKey)
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
    local tier = tierCfg(policy.tier)  -- payout speed + theft % come from the policy's plan

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
        assessed = math.floor(coverage * tier.TheftPayoutPct) - deductible
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
        if kind == 'total_loss' then
            -- The car is a write-off (consumed below) — pay the full tier coverage.
            assessed = math.floor(coverage * frac) - deductible
        else
            -- Repairable damage: the owner KEEPS the car, so this is a repair
            -- SUBSIDY, not a slice of value. The insurer covers most of an
            -- estimated repair bill (scales with damage + value, absolutely
            -- capped), minus the owner's share. Makes a real accident worth
            -- claiming but self-inflicted ram-and-claim unprofitable — each claim
            -- retires the policy (re-buy premium to claim again) and the subsidy
            -- never beats premium + owner share + the mechanic bill. Independent
            -- of tier: a kept car doesn't earn more just because it's Premium.
            local value = tonumber(policy.vehicle_value) or 0
            local repairBill = math.min(
                math.floor(value * Config.Claims.DamageRepairPct * frac),
                Config.Claims.DamageMaxPayout)
            assessed = repairBill - math.floor(repairBill * Config.Claims.DamageOwnerSharePct)
            -- Never pay a damage claim more than a fraction of the premium paid, so
            -- self-inflicting is net-negative at every tier/value (the car is kept,
            -- so the payout must not exceed what they put in). Premium scales with
            -- tier/value; this ceiling therefore scales too.
            local premCap = math.floor((tonumber(policy.premium_paid) or 0) * Config.Claims.DamagePayoutVsPremiumPct)
            if assessed > premCap then assessed = premCap end
        end
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
              json.encode(factors), tier.ProcessingSec })
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
        :format(claimId, kind, assessed, math.ceil(tier.ProcessingSec / 60)), 'success')
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
            "SELECT plate, coverage, deductible, tier, TIMESTAMPDIFF(HOUR, NOW(), expires_at) AS hrs FROM palm6_insurance_policies WHERE citizenid = ? AND status = 'active' AND expires_at > NOW()",
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
            ('%s [%s] — $%d coverage, $%d deductible, %dh left'):format(
                normPlate(p.plate), tierCfg(p.tier).label, p.coverage, p.deductible, math.max(0, tonumber(p.hrs) or 0)), 'inform')
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

-- ---------------------------------------------------------------------------
-- Agent NPC net events. The client menu is presentation only — every handler
-- re-runs the exact server-side authority (rate limit, at-office, ownership,
-- and, for buy, the full underwrite that recomputes the price from the resolved
-- tier). A modified client can only ever choose WHICH plan/plate to act on; it
-- can never set a price, forge ownership, or skip a guard. Rate-limited here AND
-- registered in palm6_eventguard (DoS budget).
-- ---------------------------------------------------------------------------

-- Quote the three tiers for the vehicle the player drove up in (display only;
-- the authoritative charge happens in doInsure on buy).
RegisterNetEvent('palm6_insurance:agent:quote', function(plate)
    local src = source
    if src == 0 then return end
    if not rl(src, 'quote') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if not atOffice(src) then
        Bridge.Notify(src, 'Mors Mutual', 'You need to be at the insurance desk.', 'error')
        return
    end
    plate = normPlate(plate)
    local veh = ownedVehicle(cid, plate)
    if not veh then
        Bridge.Notify(src, 'Mors Mutual', 'Get in a vehicle registered to you, then talk to me.', 'error')
        return
    end
    if activePolicy(plate) then
        Bridge.Notify(src, 'Mors Mutual', 'That vehicle already carries an active policy.', 'error')
        return
    end
    local value = clampedValue(veh.vehicle)
    local quotes = {}
    for _, key in ipairs(Config.TierOrder) do
        local tier = Config.Tiers[key]
        local premium, coverage, deductible = quoteFor(value, tier)
        quotes[#quotes + 1] = {
            key = key, label = tier.label, blurb = tier.blurb,
            premium = premium, coverage = coverage, deductible = deductible,
            termHours = tier.TermHours, payoutMin = math.ceil(tier.ProcessingSec / 60),
            theftPct = math.floor(tier.TheftPayoutPct * 100),
        }
    end
    TriggerClientEvent('palm6_insurance:agent:quoteData', src, { plate = plate, quotes = quotes })
end)

-- Buy a policy at the chosen tier. doInsure re-validates everything and
-- recomputes the premium server-side from the resolved tier.
RegisterNetEvent('palm6_insurance:agent:buy', function(plate, tierKey)
    doInsure(source, plate, tostring(tierKey or ''):lower())
end)

-- File a claim (damage|theft) on the given plate — same pipeline as /fileclaim.
RegisterNetEvent('palm6_insurance:agent:fileclaim', function(plate, declared)
    cmdFileClaim(source, { plate, tostring(declared or ''):lower() })
end)

-- Show the caller their active policies + pending claims — same as /policy.
RegisterNetEvent('palm6_insurance:agent:policies', function()
    cmdPolicy(source)
end)

-- Structured list of the caller's active-policy plates, for the "File a claim"
-- menu (theft claims can't use the vehicle you're sitting in — the car is gone —
-- so the player picks the plate). Display only; the actual claim re-validates.
RegisterNetEvent('palm6_insurance:agent:claimList', function()
    local src = source
    if src == 0 then return end
    if not rl(src, 'claimlist') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    local rows = {}
    pcall(function()
        rows = MySQL.query.await(
            "SELECT plate, tier, coverage FROM palm6_insurance_policies WHERE citizenid = ? AND status = 'active' AND expires_at > NOW()",
            { cid }) or {}
    end)
    local policies = {}
    for _, p in ipairs(rows) do
        policies[#policies + 1] = { plate = normPlate(p.plate), tier = tierCfg(p.tier).label, coverage = tonumber(p.coverage) or 0 }
    end
    TriggerClientEvent('palm6_insurance:agent:claimListData', src, { policies = policies })
end)

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Same pattern as palm6_mdt/server/main.lua:
-- Wait(3000) for oxmysql, per-statement pcall, CREATE TABLE IF NOT EXISTS.
-- sql/ files are applied BY HAND (deploy/README.md; CI never touches the DB),
-- so a fresh box that missed one left every query here pcall-swallowed into
-- silence - premiums taken with no policy written and claims that never
-- resolve, with the boot banner cheerfully reporting zeros. Re-runs are
-- harmless no-ops on the live box, which already has these tables.
--
-- Both CREATEs below are copied VERBATIM from the matching sql/ file so the
-- two can never diverge:
--   palm6_insurance_policies, palm6_insurance_claims  <- sql/0021_insurance.sql
-- and three BEST-EFFORT ALTERs, run separately below:
--   policies.tier                <- sql/0064_insurance_tier.sql
--   policies.status +'claimed'   <- sql/0065_insurance_status_claimed.sql
--   claims.credited_at           <- sql/0057_insurance_settlement.sql
--
-- The ALTERs are deliberately kept OUT of the schemaOk signal. ADD COLUMN IF
-- NOT EXISTS is MariaDB syntax; MySQL 8 has no such form and THROWS on it even
-- on a box where those columns were already applied by hand. Folding that throw
-- into schemaOk would make a perfectly healthy MySQL box print "schema MISSING"
-- every boot, which is the opposite of the signal this banner exists to give.
-- The two CREATEs are the tables this resource owns and are what schemaOk
-- answers for; the ALTERs warn on their own line and are left to the operator.
-- (0065's MODIFY COLUMN is portable, but it is grouped with the others because
-- it is meaningless without the table the CREATEs make and it is an ALTER, not
-- part of this resource's owned-table contract.)
-- ---------------------------------------------------------------------------
local schemaOk = true

local function ensureSchema()
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_insurance_policies` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plate VARCHAR(15) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    vehicle_model VARCHAR(50) NOT NULL,
    vehicle_value INT UNSIGNED NOT NULL,
    premium_paid INT UNSIGNED NOT NULL,
    coverage INT UNSIGNED NOT NULL,
    deductible INT UNSIGNED NOT NULL,
    status ENUM('active','lapsed','cancelled') NOT NULL DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    INDEX idx_palm6_insurance_policies_plate (plate, status),
    INDEX idx_palm6_insurance_policies_cid (citizenid),
    INDEX idx_palm6_insurance_policies_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_insurance_claims` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    policy_id INT UNSIGNED NOT NULL,
    plate VARCHAR(15) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    kind ENUM('damage','total_loss','theft') NOT NULL,
    assessed INT UNSIGNED NOT NULL,
    risk_score TINYINT UNSIGNED NOT NULL DEFAULT 0,
    risk_factors TEXT DEFAULT NULL,
    status ENUM('processing','paid','flagged_paid') NOT NULL DEFAULT 'processing',
    case_id INT UNSIGNED DEFAULT NULL,
    filed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    due_at TIMESTAMP NOT NULL,
    resolved_at TIMESTAMP NULL DEFAULT NULL,
    INDEX idx_palm6_insurance_claims_cid (citizenid),
    INDEX idx_palm6_insurance_claims_status_due (status, due_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        ]],
    }
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            schemaOk = false
            print(('^1[palm6_insurance] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end

    -- Best effort, NOT part of schemaOk (see the header note): mostly MariaDB-only
    -- syntax that throws on MySQL 8 whether or not the column is already there.
    local alters = {
        { file = 'sql/0064_insurance_tier.sql', sql = [[
ALTER TABLE `palm6_insurance_policies`
    ADD COLUMN IF NOT EXISTS `tier` VARCHAR(16) NOT NULL DEFAULT 'standard';
        ]] },
        { file = 'sql/0065_insurance_status_claimed.sql', sql = [[
ALTER TABLE `palm6_insurance_policies`
    MODIFY COLUMN `status` ENUM('active','lapsed','cancelled','claimed') NOT NULL DEFAULT 'active';
        ]] },
        { file = 'sql/0057_insurance_settlement.sql', sql = [[
ALTER TABLE `palm6_insurance_claims`
    ADD COLUMN IF NOT EXISTS `credited_at` BIGINT NOT NULL DEFAULT 1;
        ]] },
    }
    for _, a in ipairs(alters) do
        local ok, err = pcall(function() MySQL.query.await(a.sql) end)
        if not ok then
            print(('^3[palm6_insurance] column self-heal skipped (%s) -> %s. Apply it by hand if tiers, policy retirement, or claim payout recovery misbehave.^0')
                :format(a.file, tostring(err)))
        end
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- Schema + the counts that read it move into a thread so the DDL lands
    -- before anything SELECTs. Nothing above this point touches the DB.
    CreateThread(function()
        Wait(3000) -- let oxmysql establish its connection first
        ensureSchema()

        local active, pending = 0, 0
        pcall(function()
            local a = MySQL.single.await(
                "SELECT COUNT(*) AS n FROM palm6_insurance_policies WHERE status = 'active' AND expires_at > NOW()")
            active = a and tonumber(a.n) or 0
            local p = MySQL.single.await(
                "SELECT COUNT(*) AS n FROM palm6_insurance_claims WHERE resolved_at IS NULL")
            pending = p and tonumber(p.n) or 0
        end)
        print(('[palm6_insurance] Mors Mutual open — %d active policy(ies), %d claim(s) processing; replay forensics %s, schema %s')
            :format(active, pending,
                Bridge.ResourceStarted('palm6_replay') and 'ONLINE' or 'offline (no-scene signal disabled)',
                schemaOk and 'OK' or '^1MISSING^0'))
    end)
    -- Recover any claim payout interrupted by the last restart, once oxmysql +
    -- palm6_dbmigrate (0057 credited_at column) are up. Non-time-critical, so
    -- wait it out before the WHERE credited_at = 0 query runs. The 8s also
    -- clears the 3s schema thread above, so on a fresh box the table exists
    -- before the reconcile reads it.
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
