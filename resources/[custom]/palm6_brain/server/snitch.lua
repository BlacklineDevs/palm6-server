-- ============================================================================
-- palm6_brain/server/snitch.lua — INTEL+ SNITCH / INFORMANT.
--
-- A ped who WITNESSED a crime may talk: an informant reports it to POLICE
-- DISPATCH. This is the bridge between the social layer's "who saw what"
-- (server/witness.lua fires a `crime_witnessed` social event) and the live
-- police bus the Director's crime path already uses (Bridge.AlertPolice). A
-- disguise (mask) suppresses the odds — the roadmap's "a mask reduces the
-- chance someone snitches" mechanic, LLM-world flavoured but purely scripted.
--
-- WHERE IT SITS:
--   witness.lua ──(Social.ReportEvent 'crime_witnessed')──▶ THIS ──▶ Bridge.AlertPolice
-- It subscribes to the SAME Social.OnEvent seam every other social module uses,
-- so it never edits witness/gossip/etc. It reuses the Director's exact dispatch
-- discipline: never report to an empty PD (CountOnDutyPolice >= 1) and a global
-- rate limit between reports, so a crowd of witnesses can't flood dispatch.
--
-- Dark by default (Config.Social.Enabled). Every Bridge call is pcall-isolated —
-- a missing/broken Bridge must never error a witness event — and the handler
-- never yields (all reads + a fire-and-forget alert).
-- ============================================================================

local CFG = Config.Social or {}
local function enabled() return (Config.Social or {}).Enabled == true end

-- Readable 911 text per crime kind (fed to Bridge.AlertPolice). Unknown kinds
-- fall back to a generic label so an unmapped crime still dispatches sanely.
local CRIME_LABELS = {
    rob     = 'Robbery',
    robbery = 'Robbery',
    mug     = 'Mugging',
    steal   = 'Theft',
    theft   = 'Theft',
    assault = 'Assault',
    attack  = 'Assault',
    shoot   = 'Shots fired',
    gunshot = 'Shots fired',
    kill    = 'Homicide',
    deal    = 'Suspected narcotics activity',
}
local function crimeLabel(kind)
    return CRIME_LABELS[tostring(kind or ''):lower()] or 'Suspicious activity'
end

-- ── RATE LIMIT + METER STATE (bounded — two scalars) ─────────────────────────
local GLOBAL_COOLDOWN_SEC = 30   -- server-wide floor between ANY two snitch reports
local lastSnitch = 0             -- epoch of the last dispatch we fired (0 = never)
local snitchCount = 0            -- total reports fired this session (meter)

-- Pure decision: given witness count + disguise, how likely is a report? Base
-- chance nudged UP by extra witnesses (more eyes = more likely someone talks),
-- knocked DOWN by a disguise, clamped so it's never a certainty.
local function snitchChance(witnesses, disguised)
    local base = tonumber(CFG.SnitchBaseChance) or 0.5
    local n = tonumber(witnesses) or 1
    local chance = base * (1 + 0.15 * math.max(0, n - 1))   -- +15% per extra witness
    if disguised then
        chance = chance * (1 - (tonumber(CFG.SnitchMaskReduction) or 0.6))
    end
    if chance < 0 then chance = 0 end
    if chance > 0.95 then chance = 0.95 end
    return chance
end

-- Fire a police dispatch for a witnessed crime, if the roll AND the gates pass.
-- Returns true if a report was dispatched. Never yields.
local function tryReport(evt)
    if not enabled() or type(evt) ~= 'table' then return false end
    if type(evt.coords) ~= 'table' then return false end

    -- 1) ROLL — did an informant decide to talk?
    if math.random() >= snitchChance(evt.witnesses, evt.disguised) then return false end

    -- 2) GATE: never dispatch to an empty PD (mirrors the Director's crime path).
    local okCnt, onDuty = pcall(function()
        return (Bridge and Bridge.CountOnDutyPolice and Bridge.CountOnDutyPolice()) or 0
    end)
    if not okCnt or (onDuty or 0) < 1 then return false end

    -- 3) GATE: global rate limit so a crowd of witnesses can't spam dispatch.
    local now = os.time()
    if (now - lastSnitch) < GLOBAL_COOLDOWN_SEC then return false end

    -- FIRE — a 911 blip + notify to on-duty cops, then record the cooldown.
    local label = ('%s reported nearby'):format(crimeLabel(evt.crimeKind))
    local okFire = pcall(function()
        if not (Bridge and Bridge.AlertPolice) then error('no-bridge') end
        Bridge.AlertPolice(evt.coords, label, 90, 161, 1, 1.2)
    end)
    if not okFire then return false end

    lastSnitch = now
    snitchCount = snitchCount + 1
    if CFG.Debug then
        print(('[palm6_brain:snitch] informant reported: %s (%d witness(es)%s)')
            :format(label, tonumber(evt.witnesses) or 1, evt.disguised and ', disguised' or ''))
    end
    return true
end

-- ── SUBSCRIBE to the Social event seam ───────────────────────────────────────
if Social and Social.OnEvent then
    Social.OnEvent(function(evt)
        if type(evt) == 'table' and evt.kind == 'crime_witnessed' then
            tryReport(evt)   -- pcall-isolated internally; the seam also pcalls us
        end
    end)
end

-- ── METER ────────────────────────────────────────────────────────────────────
-- Last snitch time + running count, for observability (David's "ship the meter").
exports('GetSnitchSummary', function()
    return { lastSnitch = lastSnitch, count = snitchCount, cooldownSec = GLOBAL_COOLDOWN_SEC }
end)

-- ── DEV COMMAND (ACE: command.snitchtest) ────────────────────────────────────
-- Fire a fake crime_witnessed event so you can watch a dispatch land. Needs a cop
-- on duty (the CountOnDutyPolice gate) and the layer Enabled. 3 witnesses, no
-- disguise = the most likely path.
RegisterCommand('snitchtest', function(src)
    if not enabled() then
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { color = { 230, 120, 120 },
            args = { 'snitch', 'social layer is dark (Config.Social.Enabled=false)' } }) end
        print('[palm6_brain:snitch] /snitchtest ignored — Config.Social.Enabled is false')
        return
    end
    local fired = tryReport({
        kind = 'crime_witnessed', crimeKind = 'rob', cid = 'test',
        coords = { x = 195.0, y = -934.0, z = 30.7 }, witnesses = 3, disguised = false,
    })
    local msg = fired and 'dispatch FIRED (cop on duty, roll + gates passed)'
        or 'no dispatch (roll failed, no cop on duty, or within cooldown)'
    print('[palm6_brain:snitch] /snitchtest — ' .. msg)
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { color = fired and { 120, 220, 140 } or { 200, 200, 120 },
            args = { 'snitch', msg } })
    end
end, true)

print(('[palm6_brain:snitch] informant module ready (%s) — witnesses report crimes to dispatch.')
    :format(enabled() and 'ENABLED' or 'dark'))
