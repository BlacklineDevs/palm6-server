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
    local last = GetGameTimer()
    while true do
        Wait(period)
        local now = GetGameTimer()
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

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print(('[gtarp_perf] sampling every %dms, reporting every %dm, hitch>=%dms'):format(
        Config.SamplePeriodMs, Config.ReportEveryMinutes, Config.HitchThresholdMs))
end)

exports('GetSummary', summarize)
