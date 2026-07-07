-- ============================================================================
-- gtarp_perf/server/main.lua
--
-- Server-thread hitch sampler. One CreateThread loop, Wait(SamplePeriodMs).
-- Records overshoot in a ring buffer; emits a summary every ReportEveryMinutes.
-- ============================================================================

local Samples = {}
local MaxSamples = 1200  -- 250ms * 1200 = 5 minutes of samples

local function pushSample(deltaMs)
    Samples[#Samples + 1] = deltaMs
    if #Samples > MaxSamples then table.remove(Samples, 1) end
end

local function percentile(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.max(1, math.ceil(#sorted * p))
    return sorted[i]
end

local function summarize()
    if #Samples == 0 then return nil end
    local copy = {}
    local hitches = 0
    local maxv = 0
    for i = 1, #Samples do
        copy[i] = Samples[i]
        if Samples[i] > maxv then maxv = Samples[i] end
        if Samples[i] >= Config.HitchThresholdMs then hitches = hitches + 1 end
    end
    table.sort(copy)
    return {
        count   = #copy,
        p95     = percentile(copy, 0.95),
        p99     = percentile(copy, 0.99),
        max     = maxv,
        hitches = hitches,
    }
end

local function report()
    local s = summarize()
    if not s then return end
    print(('[gtarp_perf] samples=%d p95=%dms p99=%dms max=%dms hitches=%d'):format(
        s.count, s.p95, s.p99, s.max, s.hitches))

    if s.hitches < (Config.WebhookHitchThreshold or 5) then return end
    local url = GetConvar(Config.WebhookConvar, '')
    if url == '' then return end
    local body = json.encode({
        username = 'gtarp-perf',
        content  = ('hitches=%d p95=%dms p99=%dms max=%dms'):format(
            s.hitches, s.p95, s.p99, s.max),
    })
    PerformHttpRequest(url, function() end, 'POST', body,
        { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    local period = Config.SamplePeriodMs or 250
    local last = Bridge.GetTimerMs()
    while true do
        Wait(period)
        local now = Bridge.GetTimerMs()
        local delta = now - last
        pushSample(delta)
        last = now
    end
end)

CreateThread(function()
    local everyMs = (Config.ReportEveryMinutes or 5) * 60 * 1000
    while true do
        Wait(everyMs)
        report()
    end
end)

-- ---------------------------------------------------------------------------
-- /diag — one-glance custom-layer health for staff. ACE-restricted
-- (command.diag). Aggregates only data this layer already owns: resource
-- states, the sampler summary, and eventguard's per-player violation counts.
-- ---------------------------------------------------------------------------
local function diagLines()
    local lines = {}

    local states = Bridge.CustomResources('gtarp_')
    local up, down = 0, {}
    for name, state in pairs(states) do
        if state == 'started' then up = up + 1 else down[#down + 1] = ('%s(%s)'):format(name, state) end
    end
    table.sort(down)
    lines[#lines + 1] = ('resources: %d gtarp up%s'):format(
        up, #down > 0 and (' — DOWN: ' .. table.concat(down, ', ')) or '')

    local s = summarize()
    lines[#lines + 1] = s
        and ('perf: p95=%dms p99=%dms max=%dms hitches=%d (last %d samples)'):format(
            s.p95, s.p99, s.max, s.hitches, s.count)
        or 'perf: no samples yet'

    local players = Bridge.GetPlayers()
    if Bridge.ResourceState('gtarp_eventguard') == 'started' then
        local total, offenders = 0, {}
        for _, pid in ipairs(players) do
            local ok, v = pcall(function()
                return exports.gtarp_eventguard:GetViolations(tonumber(pid))
            end)
            v = ok and tonumber(v) or 0
            if v > 0 then
                total = total + v
                offenders[#offenders + 1] = ('src %s: %d'):format(pid, v)
            end
        end
        lines[#lines + 1] = ('eventguard: %d violation(s) across %d online player(s)%s'):format(
            total, #players, #offenders > 0 and (' — ' .. table.concat(offenders, ', ')) or '')
    else
        lines[#lines + 1] = ('eventguard: NOT RUNNING — %d online player(s) unguarded'):format(#players)
    end

    return lines
end

local function diag(src)
    Bridge.Reply(src, diagLines())
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if Config.DiagCommand then
        Bridge.RegisterCommand(Config.DiagCommand, function(source) diag(source) end)
    end
    print(('[gtarp_perf] sampling every %dms, reporting every %dm, hitch>=%dms%s'):format(
        Config.SamplePeriodMs, Config.ReportEveryMinutes, Config.HitchThresholdMs,
        Config.DiagCommand and (' — /' .. Config.DiagCommand .. ' online') or ''))
end)

exports('GetSummary', summarize)
exports('RunDiag', diagLines)
