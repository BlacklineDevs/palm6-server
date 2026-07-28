-- ============================================================================
-- palm6_witnesses/server/main.lua
--
-- Living NPC witnesses for every crime. An event bus (weaponDamageEvent,
-- the recipe's police:server:policeAlert fan-in, palm6_robbery, plus a
-- ReportCrime export for siblings) snapshots 1-4 ambient NPC peds near a
-- crime into server-side witness records carrying partial suspect facts.
-- Police canvass witnesses to feed a palm6_evidence v2 case file; the
-- suspect can press (aim a weapon ~5s) or pay witnesses off — but pressing
-- in view of another witness spawns a fresh intimidation incident.
--
-- Pure logic — all framework/native access via Bridge.* (§6 gate). Our own
-- palm6_witnesses_* SQL is portable, so it stays here (see
-- docs/GTA6-READINESS.md, Section 3).
--
-- SERVER AUTHORITY: every fact is captured and stored here at crime time;
-- the peds players see are just markers. Canvass/press are two-phase with
-- min AND max elapsed windows, fresh server-side proximity + position
-- anchors, per-citizen cooldowns, and per-source rate limits. The payoff
-- charge, the armed check for pressing, and the on-duty gate for
-- canvassing are all validated here. Case-file writes go through the
-- FROZEN palm6_evidence v2 exports (EnsureCase / AppendEntry /
-- LinkSuspect) — never raw table writes, never a parallel evidence store.
--
-- Duplication guarantees (per the review):
--   * Witness creation is SILENT. The opt-in alert layer (default OFF)
--     only ever fires for hooks qbx does NOT already alert on, and it
--     reuses police:server:policeAlert — no parallel dispatch.
--   * Testimonial only: no casings/blood/fingerprints (qbx_police owns
--     physical forensics). Plates stay partial (3 chars) so qbx ANPR
--     remains the full-plate source.
-- ============================================================================

local RESOURCE_TAG = Config.Evidence.Source

-- ---------------------------------------------------------------------------
-- Runtime state (DB-backed; loaded on start, authoritative in memory)
-- ---------------------------------------------------------------------------
local Incidents = {}          -- [incidentId] = incident record
local Witnesses = {}          -- [witnessId]  = witness record
local pendingAppearance = {}  -- [nonce] = draft incident awaiting suspect-client appearance
local pendingCanvass = {}     -- [src] = { wid, startedAt, startCoords }
local pendingPress   = {}     -- [src] = { wid, startedAt, startCoords }
local lastAction = {}         -- [src] = { [key] = ts } per-source rate limits
local Cooldowns  = {}         -- [citizenid] = { [key] = ts } per-character cooldowns
local lastNpcScan = {}        -- [citizenid] = ts of the last weaponDamage NPC scan
local selfAlerting = false    -- reentrancy latch: true while WE fire police:server:policeAlert

math.randomseed(os.time())

local function now() return os.time() end

local function dbg(msg)
    if Config.Debug then print('[palm6_witnesses] ' .. msg) end
end

local SchemaReady = false  -- flipped by ensureSchema(); reported in the boot banner

-- ---------------------------------------------------------------------------
-- Boot DDL (self-creating tables). Mirrors palm6_ems/server/main.lua's
-- ensureSchema: Wait-for-oxmysql on the caller's thread, per-statement pcall,
-- every statement IF NOT EXISTS so re-runs are harmless no-ops.
--
-- Why this exists: sql/ is applied BY HAND (deploy/README.md) and CI never
-- touches the DB, so a restored backup or a brand new box boots with neither
-- witness table. persistIncident is fully pcall-wrapped and DELETEs its own
-- incident row when the witness insert fails, so a missing table is SILENT and
-- indistinguishable from "nobody was around to see it": crimes fire alerts,
-- no markers ever appear, canvassing finds nothing, and the boot banner still
-- prints "ready" with 0 reloaded. On the live box (0019 already applied by
-- hand) these statements are pure no-ops.
--
-- DDL copied VERBATIM from sql/0019_witnesses.sql, inline `--` column comments
-- included. Note those comments are the SQL file's own text: they are reproduced
-- unedited on purpose so this block can be diffed byte-for-byte against 0019.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    -- The tables THIS resource owns and can answer for. Only these feed SchemaReady.
    local stmts = {
        [[
CREATE TABLE IF NOT EXISTS `palm6_witnesses_incidents` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    -- Opaque incident token; feeds the palm6_evidence EnsureCase
    -- incident_key ('palm6_witnesses:<uid>') so concurrent canvasses of
    -- the same incident converge on one case.
    uid CHAR(16) NOT NULL UNIQUE,
    crime VARCHAR(32) NOT NULL,
    label VARCHAR(64) NOT NULL,
    suspect_citizenid VARCHAR(64) NOT NULL,
    -- Crime location (marker anchor for the incident, not the witnesses).
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    -- Everything the suspect exposed at crime time, captured server-side
    -- (JSON array of { key, text }). Witnesses hold subsets of this.
    fact_pool TEXT NOT NULL,
    -- Set on first canvass via the palm6_evidence v2 EnsureCase export.
    case_id INT UNSIGNED DEFAULT NULL,
    created_at INT UNSIGNED NOT NULL,
    expires_at INT UNSIGNED NOT NULL,
    INDEX idx_palm6_witnesses_incidents_suspect (suspect_citizenid),
    INDEX idx_palm6_witnesses_incidents_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
        [[
CREATE TABLE IF NOT EXISTS `palm6_witnesses` (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    incident_id INT UNSIGNED NOT NULL,
    -- Street-corner position the witness was snapshotted at (the marker).
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    -- The 1-2 facts this witness actually holds (JSON array of
    -- { key, text }) — dealt from the incident's fact_pool at crime time.
    facts TEXT NOT NULL,
    -- Generated when the witness is pressed: same shape as `facts` but
    -- wrong (wrong colour, flipped mask, scrambled plate). A canvass of a
    -- pressed witness feeds these to the case file as if they were real.
    corrupted_facts TEXT DEFAULT NULL,
    -- active    -> marker live, canvass yields real facts
    -- pressed   -> canvass yields corrupted facts or nothing
    -- paid      -> canvass yields nothing ("never saw you")
    -- canvassed -> spent; marker gone (each witness talks once)
    status ENUM('active','pressed','paid','canvassed') NOT NULL DEFAULT 'active',
    -- citizenid of whoever changed the status (canvassing officer,
    -- pressing/paying suspect) — audit trail.
    status_by VARCHAR(64) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_palm6_witnesses_incident (incident_id),
    INDEX idx_palm6_witnesses_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    }

    local failed = 0
    for _, sql in ipairs(stmts) do
        local ok, err = pcall(function() MySQL.query.await(sql) end)
        if not ok then
            failed = failed + 1
            print(('^1[palm6_witnesses] schema init FAILED -> %s^0'):format(tostring(err)))
        end
    end
    SchemaReady = (failed == 0)
    return SchemaReady
end

-- Per-source rate limit (returns true when the call is allowed).
local function rl(src, key)
    local window = Config.RateLimits[key] or 1
    lastAction[src] = lastAction[src] or {}
    local t = now()
    if (lastAction[src][key] or 0) + window > t then return false end
    lastAction[src][key] = t
    return true
end

-- Per-citizen cooldowns, palm6_pumpcoin pattern: check-and-consume returns
-- true (reject) while cooling down, else stamps and returns false.
local function onCooldown(cid, key, secs)
    local c = Cooldowns[cid]
    if not c then c = {} Cooldowns[cid] = c end
    local t = now()
    if c[key] and (t - c[key]) < secs then return true end
    c[key] = t
    return false
end

-- Peek without consuming (cheap early bail on the hot weapon-damage path).
local function peekCooldown(cid, key, secs)
    local c = Cooldowns[cid]
    return c ~= nil and c[key] ~= nil and (now() - c[key]) < secs
end

-- Un-stamp a consumed cooldown when the gated action fails for reasons
-- that were not the player's spam (no witnesses around, DB error).
local function refundCooldown(cid, key)
    local c = Cooldowns[cid]
    if c then c[key] = nil end
end

local UID_CHARS = '0123456789abcdef'
local function makeUid()
    local out = {}
    for i = 1, 16 do
        local n = math.random(#UID_CHARS)
        out[i] = UID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Fact model. A fact = { key, text }. The pool is built from what the
-- suspect actually exposed; each witness is dealt 1-2 distinct facts.
-- ---------------------------------------------------------------------------

-- Deterministic coarse colour from the suspect ped's REAL torso variation
-- (drawable/texture ids reported by the suspect's own client and clamped
-- here). Same outfit = same witness statement, every time.
local function topColorFor(drawable, texture)
    local n = (drawable * 31 + texture * 7) % #Config.TopColors
    return Config.TopColors[n + 1]
end

local function sanitizePlate(plate)
    plate = tostring(plate or ''):gsub('%s+', ''):upper()
    return plate:sub(1, Config.PlateChars)
end

-- appearance = { topDrawable, topTexture, maskOn } (already clamped) or nil.
-- vehicle = Bridge.GetVehicleFacts() result or nil.
local function buildFactPool(appearance, vehicle)
    local pool = {}
    if appearance then
        pool[#pool + 1] = { key = 'top_color',
            text = ('was wearing a %s top'):format(topColorFor(appearance.topDrawable, appearance.topTexture)) }
        pool[#pool + 1] = { key = 'mask',
            text = appearance.maskOn and 'had their face covered by a mask'
                or 'was not wearing a mask — face was visible' }
    end
    if vehicle then
        local classLabel = Config.VehicleClassLabels[vehicle.typeName] or 'a vehicle'
        pool[#pool + 1] = { key = 'vehicle', text = ('was in %s'):format(classLabel) }
        local partial = sanitizePlate(vehicle.plate)
        if #partial > 0 then
            pool[#pool + 1] = { key = 'plate',
                text = ('plate started with "%s"'):format(partial) }
        end
    end
    return pool
end

-- Deal `count` distinct random facts from the pool.
local function dealFacts(pool, count)
    if #pool == 0 then return {} end
    local idx = {}
    for i = 1, #pool do idx[i] = i end
    for i = #idx, 2, -1 do
        local j = math.random(i)
        idx[i], idx[j] = idx[j], idx[i]
    end
    local out = {}
    for i = 1, math.min(count, #idx) do
        out[#out + 1] = pool[idx[i]]
    end
    return out
end

-- Corrupted counterparts for a pressed witness: wrong colour, flipped
-- mask, wrong vehicle class, scrambled plate. Same shape as real facts so
-- the canvassing officer cannot tell them apart.
local function corruptFacts(facts)
    local out = {}
    for _, f in ipairs(facts) do
        if f.key == 'top_color' then
            local wrong = Config.TopColors[math.random(#Config.TopColors)]
            out[#out + 1] = { key = f.key, text = ('was wearing a %s top'):format(wrong) }
        elseif f.key == 'mask' then
            local flipped = f.text:find('covered') and
                'was not wearing a mask — face was visible' or 'had their face covered by a mask'
            out[#out + 1] = { key = f.key, text = flipped }
        elseif f.key == 'vehicle' then
            local labels = {}
            for _, v in pairs(Config.VehicleClassLabels) do labels[#labels + 1] = v end
            out[#out + 1] = { key = f.key, text = ('was in %s'):format(labels[math.random(#labels)]) }
        elseif f.key == 'plate' then
            local chars = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789'
            local fake = {}
            for i = 1, Config.PlateChars do
                local n = math.random(#chars)
                fake[i] = chars:sub(n, n)
            end
            out[#out + 1] = { key = f.key,
                text = ('plate started with "%s"'):format(table.concat(fake)) }
        end
    end
    return out
end

local function factTexts(facts)
    local out = {}
    for _, f in ipairs(facts) do out[#out + 1] = f.text end
    return out
end

-- ---------------------------------------------------------------------------
-- Sync: each client only ever receives the witnesses it is entitled to.
-- Police (on duty) see markers for every un-canvassed witness — including
-- pressed/paid ones, because officers cannot tell a silenced witness from
-- a talkative one until they knock. Suspects see only the still-ACTIVE
-- witnesses to their own incidents (pressed/paid = handled).
-- ---------------------------------------------------------------------------
local function entitledWitnesses(src, cid, isPolice)
    local out = {}
    for wid, w in pairs(Witnesses) do
        local inc = Incidents[w.incidentId]
        if inc then
            if isPolice and w.status ~= 'canvassed' then
                out[#out + 1] = { id = wid, x = w.coords.x, y = w.coords.y, z = w.coords.z,
                                  role = 'police', label = inc.label }
            elseif not isPolice and cid and inc.suspectCid == cid and w.status == 'active' then
                out[#out + 1] = { id = wid, x = w.coords.x, y = w.coords.y, z = w.coords.z,
                                  role = 'suspect', label = inc.label }
            end
        end
    end
    return out
end

local function syncOne(src)
    local cid = Bridge.GetCitizenId(src)
    local isPolice = Bridge.IsOnDutyPolice(src)
    TriggerClientEvent('palm6_witnesses:sync', src,
        entitledWitnesses(src, cid, isPolice), {
            canvassRadius = Config.Canvass.Radius,
            pressRadius   = Config.Press.Radius,
            payoffRadius  = Config.Payoff.Radius,
            payoffPrice   = Config.Payoff.Price,
        })
end

-- Push fresh entitlements to everyone affected (48-slot cheap; state
-- changes are rare events, never per-frame).
local function syncAll()
    for _, src in ipairs(Bridge.GetPlayerSources()) do
        if src then syncOne(src) end
    end
end

-- ---------------------------------------------------------------------------
-- Incident creation pipeline
-- ---------------------------------------------------------------------------

local function persistIncident(inc, witnessDrafts)
    local okInc, incidentId = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO palm6_witnesses_incidents (uid, crime, label, suspect_citizenid, x, y, z, fact_pool, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { inc.uid, inc.crime, inc.label, inc.suspectCid,
              inc.coords.x, inc.coords.y, inc.coords.z,
              json.encode(inc.pool), inc.createdAt, inc.expiresAt })
    end)
    if not okInc or not incidentId then return nil end

    local ids = {}
    for _, d in ipairs(witnessDrafts) do
        local okW, wid = pcall(function()
            return MySQL.insert.await(
                'INSERT INTO palm6_witnesses (incident_id, x, y, z, facts, status) VALUES (?, ?, ?, ?, ?, ?)',
                { incidentId, d.coords.x, d.coords.y, d.coords.z,
                  json.encode(d.facts), 'active' })
        end)
        if okW and wid then
            ids[#ids + 1] = { id = wid, draft = d }
        end
    end
    if #ids == 0 then
        pcall(function()
            MySQL.update.await('DELETE FROM palm6_witnesses_incidents WHERE id = ?', { incidentId })
        end)
        return nil
    end
    return incidentId, ids
end

-- Finalize a draft: build the fact pool, deal facts, persist, go live.
-- `draft` = { src, cid, hook, coords, npcCoords, vehicle, appearance }.
local function finalizeIncident(draft)
    local pool = buildFactPool(draft.appearance, draft.vehicle)

    local witnessDrafts = {}
    for _, c in ipairs(draft.npcCoords) do
        local n = math.random(Config.FactsPerWitnessMin, Config.FactsPerWitnessMax)
        witnessDrafts[#witnessDrafts + 1] = { coords = c, facts = dealFacts(pool, n) }
    end

    local t = now()
    local inc = {
        uid = makeUid(),
        crime = draft.hook.crime,
        label = draft.hook.label,
        suspectCid = draft.cid,
        coords = draft.coords,
        pool = pool,
        caseId = nil,
        createdAt = t,
        expiresAt = t + Config.WitnessTtlMin * 60,
    }

    local incidentId, rows = persistIncident(inc, witnessDrafts)
    if not incidentId then
        -- Only refund a stamp this pipeline actually consumed (the
        -- intimidation path bypasses the cooldown entirely).
        if not draft.skipCooldown then refundCooldown(draft.cid, 'incident') end
        dbg('incident persist failed — dropped')
        return
    end

    inc.id = incidentId
    inc.witnesses = {}
    Incidents[incidentId] = inc
    for _, r in ipairs(rows) do
        Witnesses[r.id] = {
            id = r.id,
            incidentId = incidentId,
            coords = r.draft.coords,
            facts = r.draft.facts,
            corrupted = nil,
            status = 'active',
        }
        inc.witnesses[r.id] = true
    end

    dbg(('incident #%d (%s) — %d witnesses'):format(incidentId, inc.crime, #rows))

    -- The suspect learns they were seen (that dread is the game).
    Bridge.Notify(draft.src, 'Witnesses',
        ('Someone saw that. %d pair%s of eyes on you.'):format(#rows, #rows == 1 and '' or 's'), 'error')

    -- Persistent police attention: a crime with living witnesses is a crime the
    -- city remembers. This is the only portable hook that reaches the heavy qbx
    -- crimes (they are not in this repo). See Config.Heat for the weight table,
    -- for which crimes are deliberately absent from it, and for the
    -- `emitterOwnsHeat` suppression that keeps an in-repo crime from being
    -- charged twice. Keyed to the incident's OWN suspect cid, and fired only
    -- after the incident actually persisted above, so a dropped incident scores
    -- nothing. Soft-dep + pcall: a stopped palm6_heat never touches this path.
    if Config.Heat.Enabled and draft.cid and not draft.emitterOwnsHeat then
        local weight = Config.Heat.Weights[inc.crime]
        local exempt = Config.Heat.ExemptOnDutyPolice and Bridge.IsOnDutyPolice(draft.src)
        if weight and weight > 0 and not exempt
            and GetResourceState('palm6_heat') == 'started' then
            pcall(function()
                exports.palm6_heat:AddHeat(draft.cid, weight, inc.crime,
                    Bridge.GetPlayerName(draft.src))
            end)
        end
    end

    -- Opt-in alert layer. NEVER for hooks qbx already alerts on — those
    -- resources roll their own NPC-reported alerts for the same crimes,
    -- and a second ping would double-dispatch every robbery.
    if Config.FirePoliceAlerts and not draft.hook.qbxAlerts then
        -- Latch: our own policeAlert hook below hears this very event
        -- (server TriggerEvent is synchronous); without the latch every
        -- alert-eligible incident would echo into a second shadow
        -- 'reported_crime' incident against the same suspect.
        selfAlerting = true
        Bridge.PoliceAlert(draft.src, ('A bystander reported %s'):format(inc.label))
        selfAlerting = false
    end

    syncAll()
end

-- The bus entry point. `witnessCoordsOverride` lets the intimidation path
-- seed witnesses from known observer positions instead of a fresh NPC
-- scan. `emitterOwnsHeat` marks a crime whose OWNING resource already scores
-- its own palm6_heat (see Config.Heat): witnesses are still created, only the
-- heat charge is suppressed. Returns true if an incident draft was accepted.
local function reportCrime(src, hook, witnessCoordsOverride, emitterOwnsHeat)
    if not hook or not hook.enabled then return false end
    src = tonumber(src)
    if not src or src <= 0 then return false end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return false end

    -- One incident per suspect per window; intimidation bypasses (it is a
    -- consequence of a press, which carries its own cooldown).
    if not witnessCoordsOverride then
        if onCooldown(cid, 'incident', Config.IncidentCooldownSec) then return false end
    end

    local coords = Bridge.GetCoords(src)
    if not coords then
        if not witnessCoordsOverride then refundCooldown(cid, 'incident') end
        return false
    end

    local npcCoords = witnessCoordsOverride
        or Bridge.GetNearbyNpcCoords(coords, Config.WitnessRadius, Config.MaxWitnesses)
    if #npcCoords < Config.MinWitnesses then
        -- Crime in the desert: unseen. Don't burn the cooldown.
        if not witnessCoordsOverride then refundCooldown(cid, 'incident') end
        return false
    end

    local draft = {
        src = src,
        cid = cid,
        hook = hook,
        coords = coords,
        npcCoords = npcCoords,
        vehicle = Bridge.GetVehicleFacts(src),  -- server-side natives only
        appearance = nil,
        skipCooldown = witnessCoordsOverride ~= nil,
        emitterOwnsHeat = emitterOwnsHeat == true,
    }

    -- Appearance (top variation + mask) needs the suspect's client. A
    -- nonce-gated one-shot round trip with a hard server timeout; if the
    -- client stalls or lies about the shape, the incident finalizes with
    -- vehicle facts only. TRUST BOUNDARY: a modded client can misreport
    -- its own outfit — that corrupts nothing but the cheater's own
    -- description (no payout, no state, no other player is touched), and
    -- the values are clamped to sane integer ranges below.
    local nonce = makeUid()
    pendingAppearance[nonce] = draft
    TriggerClientEvent('palm6_witnesses:captureAppearance', src, nonce)
    SetTimeout(3000, function()
        local d = pendingAppearance[nonce]
        if d then
            pendingAppearance[nonce] = nil
            finalizeIncident(d)
        end
    end)
    return true
end

RegisterNetEvent('palm6_witnesses:appearanceResult', function(nonce, sig)
    local src = source
    if type(nonce) ~= 'string' then return end
    local draft = pendingAppearance[nonce]
    if not draft or draft.src ~= src then return end
    pendingAppearance[nonce] = nil

    if type(sig) == 'table' then
        local d = math.floor(tonumber(sig.topDrawable) or -1)
        local t = math.floor(tonumber(sig.topTexture) or -1)
        if d >= 0 and d <= 1000 and t >= 0 and t <= 1000 then
            draft.appearance = {
                topDrawable = d,
                topTexture = t,
                maskOn = sig.maskOn == true,
            }
        end
    end
    finalizeIncident(draft)
end)

-- ---------------------------------------------------------------------------
-- The event bus hooks
-- ---------------------------------------------------------------------------

-- Weapon fire / armed assault: the built-in server game event. Fires per
-- damage tick, so bail as cheaply as possible: hook toggle, then a
-- no-write cooldown peek, before any native or framework call.
AddEventHandler('weaponDamageEvent', function(sender, _)
    local hook = Config.Hooks.weaponDamage
    if not hook or not hook.enabled then return end
    local src = tonumber(sender)
    if not src or src <= 0 then return end

    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if peekCooldown(cid, 'incident', Config.IncidentCooldownSec) then return end

    -- Scan throttle, separate from the incident cooldown: when a crime
    -- goes UNSEEN reportCrime refunds the incident stamp (by design — the
    -- desert shooter shouldn't burn a 120s window), so the peek above
    -- never blocks and every damage tick of a magazine dump would run a
    -- full GetAllPeds enumeration. Cap the expensive scan per citizen.
    local t = now()
    if (lastNpcScan[cid] or 0) + Config.WeaponScanThrottleSec > t then return end
    lastNpcScan[cid] = t

    if not Bridge.IsArmed(src) then return end  -- fist fights don't count

    reportCrime(src, hook)
end)

-- Robbery-style triggers: every qbx crime that alerts police funnels
-- through police:server:policeAlert (qbx_storerobbery client-side
-- alertPolice(), qbx_drugs cornerselling's TriggerEvent(...) with a
-- playerSource, jewelery, houserobbery, bankrobbery). Shadow-listening on
-- the alert covers them all with zero coupling — and since the alert we
-- heard IS the qbx alert, this hook is hard-wired silent (qbxAlerts=true).
RegisterNetEvent('police:server:policeAlert', function(_, _, playerSource)
    local hook = Config.Hooks.policeAlert
    if not hook or not hook.enabled then return end
    if selfAlerting then return end  -- our own opt-in alert echoing back

    -- TRUST BOUNDARY: this is a client-triggerable net event, so arg 3
    -- (playerSource) is only honoured when the invocation came from a
    -- server-side TriggerEvent (cornerselling style — no real network
    -- source). When a client fired it (storerobbery style), the suspect
    -- IS the caller and a client-supplied playerSource is IGNORED, so a
    -- modded client can never mint witnesses against another player.
    local invoker = tonumber(source)
    local isServerCall = invoker == nil or invoker <= 0 or invoker == 65535
    local src = isServerCall and tonumber(playerSource) or invoker
    if not src or src <= 0 or src == 65535 then return end
    if not rl(src, 'policeAlert') then return end

    -- HEAT SUPPRESSION (see Config.Heat). `isServerCall` is not just a trust
    -- discriminator, it is also the emitter discriminator: every in-repo
    -- palm6_* resource that raises this alert does so from its own
    -- bridge/sv_framework.lua with a server-side TriggerEvent and an explicit
    -- playerSource (business, counterfeit, drugs, laundering, protection,
    -- smuggling, and this resource itself; grep 'police:server:policeAlert'),
    -- and each of those already owns its AddHeat wire. The qbx robbery clients
    -- this hook exists for fire the alert from the CLIENT, so the suspect is
    -- the caller and isServerCall is false. Pass the flag through so a
    -- server-side emitter still gets witnesses but is never charged twice.
    reportCrime(src, hook, nil, isServerCall)
end)

-- palm6_robbery ATM hold-ups (custom layer). SERVER-ONLY listener
-- (AddEventHandler, never RegisterNetEvent): palm6_robbery fires this via
-- TriggerEvent only AFTER all of its start gates pass (police count,
-- weapon, cooldown, proximity). Hooking the raw client-triggerable
-- 'palm6_robbery:start' net event would create witnesses for rejected —
-- or entirely forged — robberies.
if Config.Hooks.palm6Robbery and Config.Hooks.palm6Robbery.enabled then
    AddEventHandler(Config.Hooks.palm6Robbery.event, function(robberSrc)
        reportCrime(robberSrc, Config.Hooks.palm6Robbery)
    end)
end

-- Sibling resources can feed the bus directly:
--   exports.palm6_witnesses:ReportCrime(src, 'arson', 'a fire being set', false)
-- `alertEligible` opts the crime into the (globally opt-in) alert layer.
exports('ReportCrime', function(src, crime, label, alertEligible)
    if type(crime) ~= 'string' or #crime == 0 then return false end
    return reportCrime(src, {
        enabled = true,
        crime = crime:sub(1, 32),
        label = type(label) == 'string' and label:sub(1, 64) or crime,
        qbxAlerts = alertEligible ~= true,
    }) == true
end)

-- ---------------------------------------------------------------------------
-- Case-file plumbing (palm6_evidence v2 FROZEN exports — the only write
-- path; we never touch palm6_evidence tables and keep no parallel store).
-- ---------------------------------------------------------------------------
local function ensureCaseFor(inc)
    if inc.caseId then return inc.caseId end
    local ok, caseId = pcall(function()
        return exports.palm6_evidence:EnsureCase(
            ('%s:%s'):format(RESOURCE_TAG, inc.uid),
            Config.Evidence.TitleFmt:format(inc.label),
            RESOURCE_TAG)
    end)
    if not ok or not caseId then return nil end
    inc.caseId = caseId
    pcall(function()
        MySQL.update.await('UPDATE palm6_witnesses_incidents SET case_id = ? WHERE id = ?',
            { caseId, inc.id })
    end)
    return caseId
end

local function appendTestimony(inc, w, facts, officerName)
    local caseId = ensureCaseFor(inc)
    if not caseId then return false end
    local texts = factTexts(facts)
    local statement = ('Witness #%d (canvassed by %s, re: %s): the suspect %s.')
        :format(w.id, officerName, inc.label, table.concat(texts, '; '))
    local ok, entryId = pcall(function()
        return exports.palm6_evidence:AppendEntry(caseId, 'fact', statement, RESOURCE_TAG)
    end)
    if not ok or not entryId then return false end
    pcall(function()
        exports.palm6_evidence:LinkSuspect(caseId, nil, table.concat(texts, ', '))
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Police canvass (two-phase)
-- ---------------------------------------------------------------------------

local function witnessForUpdate(wid)
    wid = math.floor(tonumber(wid) or 0)
    local w = Witnesses[wid]
    if not w then return nil end
    local inc = Incidents[w.incidentId]
    if not inc or inc.expiresAt <= now() then return nil end
    return w, inc
end

local function setWitnessStatus(w, status, byCid, corrupted)
    w.status = status
    w.corrupted = corrupted or w.corrupted
    pcall(function()
        MySQL.update.await(
            'UPDATE palm6_witnesses SET status = ?, status_by = ?, corrupted_facts = ? WHERE id = ?',
            { status, byCid, w.corrupted and json.encode(w.corrupted) or nil, w.id })
    end)
end

RegisterNetEvent('palm6_witnesses:canvass:start', function(wid)
    local src = source
    if not rl(src, 'canvass') then return end
    if not Bridge.IsOnDutyPolice(src) then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if pendingCanvass[src] then return end

    local w = witnessForUpdate(wid)
    if not w or w.status == 'canvassed' then return end

    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, w.coords) > Config.Canvass.Radius + 3.0 then
        Bridge.Notify(src, 'Canvass', 'Get closer to the witness.', 'error')
        return
    end
    if onCooldown(cid, 'canvass', Config.Canvass.CooldownSec) then
        Bridge.Notify(src, 'Canvass', 'Give it a second.', 'error')
        return
    end

    pendingCanvass[src] = { wid = w.id, startedAt = now(), startCoords = here, cid = cid }
    TriggerClientEvent('palm6_witnesses:beginCanvass', src, Config.Canvass.DurationSec)
end)

RegisterNetEvent('palm6_witnesses:canvass:finish', function()
    local src = source
    local pend = pendingCanvass[src]
    if not pend then return end
    pendingCanvass[src] = nil

    -- Two-phase window: min AND max elapsed, server clock.
    local elapsed = now() - pend.startedAt
    if elapsed < Config.Canvass.DurationSec - 1
        or elapsed > Config.Canvass.DurationSec + Config.Canvass.GraceSec then
        return
    end
    -- Gates re-checked at finish: duty can be toggled and positions moved
    -- during the window.
    if not Bridge.IsOnDutyPolice(src) then return end
    local w, inc = witnessForUpdate(pend.wid)
    if not w or w.status == 'canvassed' then return end

    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, w.coords) > Config.Canvass.Radius + 3.0 then return end
    if pend.startCoords and Bridge.Distance(here, pend.startCoords) > Config.Press.AnchorRadius then return end

    -- Claim the witness BEFORE the yielding palm6_evidence export calls in
    -- appendTestimony: two officers finishing concurrently both pass the
    -- status check above (status only flips at the end), and without this
    -- latch the same statement would be logged to the case file twice.
    if w.busy then return end
    w.busy = true

    local officerName = Bridge.GetPlayerName(src)
    local title, body

    if w.status == 'paid' then
        -- Bought silence: nothing enters the case file. The officer only
        -- sees an uncooperative bystander — identical to a shaken one.
        title = 'Witness Canvass'
        body = ('"Didn\'t see anything, officer. Wasn\'t even looking that way."\n\n_Witness #%d refuses to give a statement._'):format(w.id)
    elseif w.status == 'pressed' then
        if w.corrupted and #w.corrupted > 0 and math.random() < Config.Press.CorruptedFactChance then
            -- Corrupted testimony reads EXACTLY like the real thing.
            local ok = appendTestimony(inc, w, w.corrupted, officerName)
            title = 'Witness Canvass'
            body = ('"Okay... okay. Here\'s what I saw."\n\nThe suspect %s.\n\n%s')
                :format(table.concat(factTexts(w.corrupted), '; '),
                    ok and ('_Statement logged to case #%d._'):format(inc.caseId or 0)
                       or '_Failed to log the statement — check palm6_evidence._')
        else
            title = 'Witness Canvass'
            body = ('"I— I don\'t remember. Please leave me alone."\n\n_Witness #%d is too shaken to talk._'):format(w.id)
        end
    else
        if #w.facts == 0 then
            title = 'Witness Canvass'
            body = ('"I heard it, but I honestly couldn\'t make anything out."\n\n_Witness #%d saw nothing usable._'):format(w.id)
        else
            local ok = appendTestimony(inc, w, w.facts, officerName)
            title = 'Witness Canvass'
            body = ('"Yes, I saw it — %s, right over there."\n\nThe suspect %s.\n\n%s')
                :format(inc.label, table.concat(factTexts(w.facts), '; '),
                    ok and ('_Statement logged to case #%d._'):format(inc.caseId or 0)
                       or '_Failed to log the statement — check palm6_evidence._')
        end
    end

    setWitnessStatus(w, 'canvassed', Bridge.GetCitizenId(src))
    w.busy = nil
    TriggerClientEvent('palm6_witnesses:showStatement', src, title, body)
    syncAll()
end)

RegisterNetEvent('palm6_witnesses:canvass:cancel', function()
    pendingCanvass[source] = nil
end)

-- ---------------------------------------------------------------------------
-- Criminal counterplay: press (aim ~5s) and payoff. Suspect-only,
-- server-enforced — you cannot scrub someone else's crime scene.
-- ---------------------------------------------------------------------------

RegisterNetEvent('palm6_witnesses:press:start', function(wid)
    local src = source
    if not rl(src, 'press') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end
    if pendingPress[src] then return end

    local w, inc = witnessForUpdate(wid)
    if not w or w.status ~= 'active' then return end
    if inc.suspectCid ~= cid then return end             -- requires-X, server-side
    if not Bridge.IsArmed(src) then                       -- armed, server-side
        Bridge.Notify(src, 'Witness', 'You\'ll need to look a lot more convincing than that.', 'error')
        return
    end

    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, w.coords) > Config.Press.Radius + 3.0 then return end
    if onCooldown(cid, 'press', Config.Press.CooldownSec) then
        Bridge.Notify(src, 'Witness', 'Let the last one stop shaking first.', 'error')
        return
    end

    pendingPress[src] = { wid = w.id, startedAt = now(), startCoords = here, cid = cid }
    TriggerClientEvent('palm6_witnesses:beginPress', src, Config.Press.AimSec)
end)

RegisterNetEvent('palm6_witnesses:press:finish', function()
    local src = source
    local pend = pendingPress[src]
    if not pend then return end
    pendingPress[src] = nil

    -- Min AND max elapsed, server clock — no instant presses, no parked ones.
    local elapsed = now() - pend.startedAt
    if elapsed < Config.Press.AimSec - 1
        or elapsed > Config.Press.AimSec + Config.Press.GraceSec then
        return
    end

    local cid = Bridge.GetCitizenId(src)
    if not cid or cid ~= pend.cid then return end
    local w, inc = witnessForUpdate(pend.wid)
    if not w or w.status ~= 'active' or inc.suspectCid ~= cid then return end
    if not Bridge.IsArmed(src) then return end            -- still armed at finish

    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, w.coords) > Config.Press.Radius + 3.0 then return end
    if pend.startCoords and Bridge.Distance(here, pend.startCoords) > Config.Press.AnchorRadius then return end

    setWitnessStatus(w, 'pressed', cid, corruptFacts(w.facts))
    Bridge.Notify(src, 'Witness',
        'They got the message. Whatever they tell the cops now won\'t be the truth.', 'success')

    -- Pressing in view of another witness creates a NEW intimidation
    -- incident against the presser — observers seeded from real witness
    -- positions ("in view" = radius; no server-side raycast exists).
    local observers = {}
    for owid, ow in pairs(Witnesses) do
        if owid ~= w.id and ow.status == 'active'
            and Bridge.Distance(ow.coords, w.coords) <= Config.Intimidation.WitnessRadius then
            local oinc = Incidents[ow.incidentId]
            if oinc and oinc.expiresAt > now() then
                observers[#observers + 1] = { x = ow.coords.x, y = ow.coords.y, z = ow.coords.z }
                if #observers >= Config.MaxWitnesses then break end
            end
        end
    end
    if #observers > 0 then
        reportCrime(src, {
            enabled = true,
            crime = 'intimidation',
            label = Config.Intimidation.CrimeLabel,
            qbxAlerts = false,
        }, observers)
    end

    syncAll()
end)

RegisterNetEvent('palm6_witnesses:press:cancel', function()
    pendingPress[source] = nil
end)

RegisterNetEvent('palm6_witnesses:payoff', function(wid)
    local src = source
    if not rl(src, 'payoff') then return end
    local cid = Bridge.GetCitizenId(src)
    if not cid then return end

    local w, inc = witnessForUpdate(wid)
    if not w or w.status ~= 'active' then return end
    if inc.suspectCid ~= cid then return end

    local here = Bridge.GetCoords(src)
    if not here or Bridge.Distance(here, w.coords) > Config.Payoff.Radius + 3.0 then
        Bridge.Notify(src, 'Witness', 'You need to be face to face for that.', 'error')
        return
    end
    if onCooldown(cid, 'payoff', Config.Payoff.CooldownSec) then return end

    -- Charge LAST, after every gate passed (framework-checked affordability).
    if not Bridge.ChargeCash(src, Config.Payoff.Price, 'witness-payoff') then
        refundCooldown(cid, 'payoff')
        Bridge.Notify(src, 'Witness', ('They want $%d, cash.'):format(Config.Payoff.Price), 'error')
        return
    end

    setWitnessStatus(w, 'paid', cid)
    Bridge.Notify(src, 'Witness',
        ('$%d and a sudden case of amnesia. "Never saw you before in my life."'):format(Config.Payoff.Price), 'success')
    syncAll()
end)

-- ---------------------------------------------------------------------------
-- Sync + status
-- ---------------------------------------------------------------------------

RegisterNetEvent('palm6_witnesses:requestSync', function()
    local src = source
    if not rl(src, 'sync') then return end
    syncOne(src)
end)

-- /witnesses — admin status (ace: command.witnesses).
--   status       counts of live incidents/witnesses
--   sim          simulate a crime at your position (QA)
RegisterCommand('witnesses', function(src, args)
    local sub = args[1] and args[1]:lower() or 'status'
    if sub == 'sim' then
        if src == 0 then
            print('[palm6_witnesses] sim needs an in-game admin')
            return
        end
        local ok = reportCrime(src, {
            enabled = true, crime = 'sim', label = 'a simulated crime', qbxAlerts = true,
        })
        Bridge.Notify(src, 'Witnesses',
            ok and 'Simulated crime reported — check for markers in a few seconds.'
               or 'No incident (no NPCs in range, or you are on incident cooldown).',
            ok and 'success' or 'error')
        return
    end

    local nInc, nWit, nActive = 0, 0, 0
    for _ in pairs(Incidents) do nInc = nInc + 1 end
    for _, w in pairs(Witnesses) do
        nWit = nWit + 1
        if w.status == 'active' then nActive = nActive + 1 end
    end
    Bridge.Notify(src, 'Witnesses',
        ('%d live incident(s), %d witness(es) (%d still active).'):format(nInc, nWit, nActive), 'inform')
end, true)

-- ---------------------------------------------------------------------------
-- Housekeeping: expiry sweep + pending janitors (30s tick — never per-frame)
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(30000)
        local t = now()
        local expired = false

        for id, inc in pairs(Incidents) do
            if inc.expiresAt <= t then
                for wid in pairs(inc.witnesses) do Witnesses[wid] = nil end
                Incidents[id] = nil
                expired = true
                dbg(('incident #%d expired'):format(id))
            end
        end

        -- Void two-phase sessions whose client never sent finish/cancel.
        local canvassMax = Config.Canvass.DurationSec + Config.Canvass.GraceSec + 5
        for src, pend in pairs(pendingCanvass) do
            if t - pend.startedAt > canvassMax then pendingCanvass[src] = nil end
        end
        local pressMax = Config.Press.AimSec + Config.Press.GraceSec + 5
        for src, pend in pairs(pendingPress) do
            if t - pend.startedAt > pressMax then pendingPress[src] = nil end
        end

        if expired then syncAll() end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastAction[src] = nil
    pendingCanvass[src] = nil
    pendingPress[src] = nil
end)

-- ---------------------------------------------------------------------------
-- Boot: presence-check the palm6_evidence v2 export surface (loud, not
-- fatal — canvassing degrades to statements-without-case-files if the
-- sibling is missing), then reload live witnesses from the DB so markers
-- survive restarts.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    local okApi = pcall(function()
        -- EnsureCase(nil, nil, nil) is an invalid-input no-op that returns
        -- nil without side effects — perfect as a presence probe.
        exports.palm6_evidence:EnsureCase(nil, nil, nil)
    end)
    if not okApi then
        print('^1[palm6_witnesses] WARNING: palm6_evidence v2 exports are unreachable. '
            .. 'Canvassed statements will NOT reach case files until palm6_evidence '
            .. '(v0.2.0+) is started before this resource.^0')
    end

    -- The DB half of boot runs on its own thread because ensureSchema has to
    -- Wait for oxmysql's connection before it can issue any query, and the
    -- reload below must not run before the tables are guaranteed to exist.
    -- Nothing gates on Incidents/Witnesses being populated (a canvass of an
    -- unknown witness id is already refused), so no extra ready flag is needed;
    -- the closing syncAll repairs any client that asked for a sync during the
    -- wait and got an empty marker set.
    CreateThread(function()
    Wait(3000) -- let oxmysql establish its connection first
    ensureSchema()
    -- Banner FIRST, with nothing that can throw between it and ensureSchema().
    -- It is the only line that can report the fresh-box case: the reload is
    -- pcall'd, so a missing table prints the same "ready, 0 reloaded" line a
    -- freshly restarted quiet server prints.
    if not SchemaReady then
        print('^1[palm6_witnesses] schema MISSING - no witness ever persists on this box.^0')
    end

    local t = now()
    local loadedInc, loadedWit = 0, 0
    pcall(function()
        local incRows = MySQL.query.await(
            'SELECT * FROM palm6_witnesses_incidents WHERE expires_at > ?', { t }) or {}
        for _, r in ipairs(incRows) do
            local okPool, pool = pcall(json.decode, r.fact_pool or '[]')
            Incidents[r.id] = {
                id = r.id,
                uid = r.uid,
                crime = r.crime,
                label = r.label,
                suspectCid = r.suspect_citizenid,
                coords = { x = r.x, y = r.y, z = r.z },
                pool = okPool and pool or {},
                caseId = r.case_id,
                createdAt = r.created_at,
                expiresAt = r.expires_at,
                witnesses = {},
            }
            loadedInc = loadedInc + 1
        end
        local witRows = MySQL.query.await(
            "SELECT w.* FROM palm6_witnesses w JOIN palm6_witnesses_incidents i ON i.id = w.incident_id WHERE i.expires_at > ? AND w.status <> 'canvassed'",
            { t }) or {}
        for _, r in ipairs(witRows) do
            local inc = Incidents[r.incident_id]
            if inc then
                local okF, facts = pcall(json.decode, r.facts or '[]')
                local okC, corrupted = pcall(json.decode, r.corrupted_facts or 'null')
                Witnesses[r.id] = {
                    id = r.id,
                    incidentId = r.incident_id,
                    coords = { x = r.x, y = r.y, z = r.z },
                    facts = okF and facts or {},
                    corrupted = (okC and type(corrupted) == 'table') and corrupted or nil,
                    status = r.status,
                }
                inc.witnesses[r.id] = true
                loadedWit = loadedWit + 1
            end
        end
    end)

    print(('[palm6_witnesses] ready — %d live incident(s), %d witness(es) reloaded; alerts %s')
        :format(loadedInc, loadedWit, Config.FirePoliceAlerts and 'OPT-IN ON' or 'off (default)'))
    syncAll()
    end)
end)
