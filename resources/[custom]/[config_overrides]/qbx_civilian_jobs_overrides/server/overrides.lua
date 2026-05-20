-- ============================================================================
-- qbx_civilian_jobs_overrides/server/overrides.lua
-- ============================================================================

local function validate()
    assert(type(Config) == 'table', 'Config missing')
    local pays = exports.qbx_economy_overrides:GetJobPaychecks()
    local mn, mx = Config.PayoutBounds.min, Config.PayoutBounds.max

    for jobName, cfg in pairs(Config.Jobs) do
        assert(pays[jobName], ('civilian job %q has no paycheck ladder'):format(jobName))
        assert(cfg.label and #cfg.label > 0, ('%s: label required'):format(jobName))
        assert(cfg.starter_npc and cfg.starter_npc.coords,
            ('%s: starter_npc.coords required'):format(jobName))
        assert(cfg.runs and #cfg.runs > 0,
            ('%s: at least one run required'):format(jobName))
        for i, r in ipairs(cfg.runs) do
            assert(r.payout >= mn and r.payout <= mx,
                ('%s run %d: payout %d out of bounds [%d,%d]'):format(
                    jobName, i, r.payout, mn, mx))
            assert(r.cooldown_seconds and r.cooldown_seconds > 0,
                ('%s run %d: positive cooldown required'):format(jobName, i))
        end
    end
end

local function publish()
    validate()
    local count = 0
    for _ in pairs(Config.Jobs) do count = count + 1 end
    SetConvar('qbx:civilian_jobs_count', tostring(count))
    print(('[qbx_civilian_jobs_overrides] curated %d jobs (bounds %d..%d)'):format(
        count, Config.PayoutBounds.min, Config.PayoutBounds.max
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    publish()
end)

exports('GetJobs',         function() return Config.Jobs end)
exports('GetJob',          function(name) return Config.Jobs[name] end)
exports('GetPayoutBounds', function() return Config.PayoutBounds end)
