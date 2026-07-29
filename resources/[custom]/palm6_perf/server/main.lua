-- ============================================================================
-- palm6_perf/server/main.lua
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
    print(('[palm6_perf] samples=%d p95=%dms p99=%dms max=%dms hitches=%d'):format(
        s.count, s.p95, s.p99, s.max, s.hitches))

    if s.hitches < (Config.WebhookHitchThreshold or 5) then return end
    local url = GetConvar(Config.WebhookConvar, '')
    if url == '' then return end
    local body = json.encode({
        username = 'palm6-perf',
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
-- Boot schema check.
--
-- The custom layer's sql/ migrations are applied BY HAND (deploy/README.md)
-- and CI never touches the DB, so a restored backup or a new box can boot with
-- half its tables absent. Because nearly every query in the layer is
-- pcall-wrapped, that state is SILENT: no errors, no warnings, features just
-- quietly do nothing. This is the one always-on assertion that makes it loud.
--
-- Deliberate properties:
--   * ONE read-only information_schema SELECT for the whole layer. No
--     per-table queries, no writes, no DDL. This resource must stay cheap.
--   * It NEVER blocks startup and never stops anything. It prints and exits.
--   * Only STARTED resources are checked, so a dark resource is not noise.
--   * The result is cached and surfaced in /diag, so staff can see it in-game
--     long after the boot console scrolled away. Only the BOOT run publishes to
--     that cache (publish=true); an on-demand re-run returns its own snapshot
--     and leaves what /diag reports alone.
-- ---------------------------------------------------------------------------
local SchemaReport = nil   -- { checked, missing = { [resource] = {tables} }, missingCount, ok, err }

local function runSchemaCheck(publish)
    -- server/tables.lua owns RequiredTables. If that file is ever missing from
    -- a deploy the whole check would otherwise die inside its caller's pcall
    -- and /diag would say "has not run yet" forever, which is the silent state
    -- this feature exists to abolish. Say so instead.
    if type(RequiredTables) ~= 'table' then
        local report = { checked = 0, missing = {}, missingCount = 0, ok = false,
            err = 'RequiredTables is nil (server/tables.lua did not load)' }
        if publish then SchemaReport = report end
        print('^1[palm6_perf] SCHEMA CHECK COULD NOT RUN - ' .. report.err .. '^0')
        return report
    end

    local present, err = {}, nil
    local queried = pcall(function()
        local rows = MySQL.query.await(
            'SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE()') or {}
        -- MySQL returns the alias case-folded differently across versions/drivers,
        -- so accept either spelling rather than depending on one.
        for _, r in ipairs(rows) do
            local name = r.t or r.T
            if name then present[name] = true end
        end
    end)
    if not queried or next(present) == nil then
        err = 'information_schema unreadable (is oxmysql connected?)'
        local report = { checked = 0, missing = {}, missingCount = 0, ok = false, err = err }
        if publish then SchemaReport = report end
        print('^1[palm6_perf] SCHEMA CHECK COULD NOT RUN - ' .. err .. '^0')
        return report
    end

    local names = {}
    for resource in pairs(RequiredTables) do names[#names + 1] = resource end
    table.sort(names)

    local checked, missingCount = 0, 0
    local missing = {}
    for _, resource in ipairs(names) do
        if GetResourceState(resource) == 'started' then
            checked = checked + 1
            local gone = {}
            for _, t in ipairs(RequiredTables[resource]) do
                if not present[t] then gone[#gone + 1] = t end
            end
            if #gone > 0 then
                missing[resource] = gone
                missingCount = missingCount + #gone
            end
        end
    end

    local report = {
        checked = checked, missing = missing, missingCount = missingCount,
        ok = (missingCount == 0), err = nil,
    }
    if publish then SchemaReport = report end

    if missingCount == 0 then
        print(('[palm6_perf] schema check PASS - every table present for %d started resource(s)')
            :format(checked))
    else
        local ordered = {}
        for resource in pairs(missing) do ordered[#ordered + 1] = resource end
        table.sort(ordered)
        print('^1[palm6_perf] ============================================^0')
        print(('^1[palm6_perf] SCHEMA CHECK: %d TABLE(S) MISSING across %d resource(s).^0')
            :format(missingCount, #ordered))
        for _, resource in ipairs(ordered) do
            print(('^1[palm6_perf]   %s MISSING %s^0'):format(resource, table.concat(missing[resource], ', ')))
        end
        print('^1[palm6_perf] These resources are RUNNING but their queries are pcall-swallowed -^0')
        print('^1[palm6_perf] they will fail SILENTLY. Apply the matching sql/ migration.^0')
        print('^1[palm6_perf] ============================================^0')
    end
    return report
end

-- ---------------------------------------------------------------------------
-- /diag — one-glance custom-layer health for staff. ACE-restricted
-- (command.diag). Aggregates only data this layer already owns: resource
-- states, the sampler summary, and eventguard's per-player violation counts.
-- ---------------------------------------------------------------------------
local function diagLines()
    local lines = {}

    local states = Bridge.CustomResources('palm6_')
    local up, down = 0, {}
    for name, state in pairs(states) do
        if state == 'started' then up = up + 1 else down[#down + 1] = ('%s(%s)'):format(name, state) end
    end
    table.sort(down)
    lines[#lines + 1] = ('resources: %d palm6 up%s'):format(
        up, #down > 0 and (' — DOWN: ' .. table.concat(down, ', ')) or '')

    local s = summarize()
    lines[#lines + 1] = s
        and ('perf: p95=%dms p99=%dms max=%dms hitches=%d (last %d samples)'):format(
            s.p95, s.p99, s.max, s.hitches, s.count)
        or 'perf: no samples yet'

    local players = Bridge.GetPlayers()
    if Bridge.ResourceState('palm6_eventguard') == 'started' then
        local total, offenders = 0, {}
        for _, pid in ipairs(players) do
            local ok, v = pcall(function()
                return exports.palm6_eventguard:GetViolations(tonumber(pid))
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

    -- Schema line: the boot banner scrolls away, this does not.
    if not Config.SchemaCheck then
        lines[#lines + 1] = 'schema: check disabled (Config.SchemaCheck = false)'
    elseif not SchemaReport then
        lines[#lines + 1] = 'schema: check has not run yet'
    elseif SchemaReport.err then
        lines[#lines + 1] = 'schema: CHECK FAILED - ' .. SchemaReport.err
    elseif SchemaReport.ok then
        lines[#lines + 1] = ('schema: OK - all tables present for %d started resource(s)')
            :format(SchemaReport.checked)
    else
        local parts = {}
        for resource, tables in pairs(SchemaReport.missing) do
            parts[#parts + 1] = ('%s(%s)'):format(resource, table.concat(tables, '/'))
        end
        table.sort(parts)
        lines[#lines + 1] = ('schema: %d TABLE(S) MISSING - %s'):format(
            SchemaReport.missingCount, table.concat(parts, ', '))
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
    print(('[palm6_perf] sampling every %dms, reporting every %dm, hitch>=%dms%s'):format(
        Config.SamplePeriodMs, Config.ReportEveryMinutes, Config.HitchThresholdMs,
        Config.DiagCommand and (' — /' .. Config.DiagCommand .. ' online') or ''))

    -- Schema check on its own thread so a slow DB can never delay this
    -- resource's start, and long enough after boot that the self-creating
    -- resources and palm6_dbmigrate have finished their own work.
    if Config.SchemaCheck then
        CreateThread(function()
            Wait(Config.SchemaCheckDelayMs or 20000)
            -- The boot run is the only one that publishes to SchemaReport.
            pcall(function() runSchemaCheck(true) end)
        end)
    end
end)

exports('GetSummary', summarize)
exports('RunDiag', diagLines)

-- The required-table map, so palm6_devtest (and anything else) reads the ONE
-- authority instead of keeping a second copy that drifts.
exports('GetRequiredTables', function() return RequiredTables end)

-- Last schema-check result, or nil if it has not run. Read-only snapshot.
exports('GetSchemaReport', function() return SchemaReport end)

-- Re-run the check on demand (used by palm6_devtest so its run reflects the
-- state at test time rather than at boot). Read-only, cheap, one SELECT, and
-- read-only in the other sense too: it returns a FRESH snapshot and does NOT
-- overwrite the cached boot report, so running the devtest suite cannot change
-- what /diag says for the rest of the boot. Honours Config.SchemaCheck: an
-- operator who turned the check off gets no query, and the returned report says
-- why rather than pretending everything passed.
exports('CheckSchema', function()
    if not Config.SchemaCheck then
        return { checked = 0, missing = {}, missingCount = 0, ok = false,
            err = 'schema check disabled (Config.SchemaCheck = false)' }
    end
    return runSchemaCheck(false)
end)
