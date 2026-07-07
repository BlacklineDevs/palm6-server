-- ============================================================================
-- gtarp_devtest/server/main.lua
--
-- Boot-time self-test of the CROSS-RESOURCE CONTRACTS the custom layer's
-- resources depend on — the things a banner-only boot check can't see:
--
--   * gtarp_evidence's FROZEN v2 export API (EnsureCase idempotency,
--     AppendEntry, LinkSuspect, GetCase round-trip)
--   * gtarp_staff's Log export actually landing an audit_log row
--   * gtarp_courier GetOpenPostings / gtarp_eventguard GetViolations /
--     gtarp_perf GetSummary shapes
--   * every ExtraItems name actually registered in ox_inventory (the
--     runtime-merge no-op bug shipped silently for weeks — this catches a
--     fresh deploy where tools/patch-ox-items.sh wasn't run)
--   * every DB table each started gtarp resource needs actually existing
--     (deploy does NOT auto-apply sql/ migrations — this catches the miss
--     loudly instead of via first-use query errors)
--
-- Gated on the `gtarp:devtest` convar (default OFF — production never runs
-- this). Enable for one boot on the local test server:
--     set gtarp:devtest 1
-- Every DB row the tests create is deleted afterwards. Tests that need a
-- live player (allowlist role checks, witnesses.ReportCrime) are reported
-- as SKIP, not silently omitted.
--
-- No bridge/ folder on purpose: this resource calls only sibling gtarp
-- exports (portable by definition) and engine-agnostic runtime facilities
-- (GetConvar / GetResourceState / CreateThread / os.time). It ships in no
-- marketplace deliverable and is not part of the §6 game-native surface.
-- ============================================================================

local passed, failed, skipped = 0, 0, 0

local function pass(msg) passed = passed + 1; print(('[gtarp_devtest] PASS %s'):format(msg)) end
local function fail(msg) failed = failed + 1; print(('[gtarp_devtest] FAIL %s'):format(msg)) end
local function skip(msg) skipped = skipped + 1; print(('[gtarp_devtest] SKIP %s'):format(msg)) end

local function check(cond, msg)
    if cond then pass(msg) else fail(msg) end
    return cond
end

-- pcall a zero-arg fn; on error report FAIL with the error text.
local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok then fail(('%s — errored: %s'):format(label, tostring(err))) end
    return ok
end

local function resourceUp(name)
    return GetResourceState(name) == 'started'
end

-- ---------------------------------------------------------------------------
-- Test groups
-- ---------------------------------------------------------------------------

local function testEvidence()
    if not resourceUp('gtarp_evidence') then
        fail('evidence — resource not started')
        return
    end
    local key = ('devtest:%d'):format(os.time())
    local caseId, caseId2, entryId, linked, full

    if not try('evidence.EnsureCase', function()
        caseId = exports.gtarp_evidence:EnsureCase(key, 'devtest self-test case', 'gtarp_devtest')
        caseId2 = exports.gtarp_evidence:EnsureCase(key, 'devtest self-test case', 'gtarp_devtest')
    end) then return end

    if not check(type(caseId) == 'number', 'evidence.EnsureCase returns numeric caseId') then return end
    check(caseId == caseId2, ('evidence.EnsureCase idempotent per incidentKey (case %d)'):format(caseId))

    try('evidence.AppendEntry', function()
        entryId = exports.gtarp_evidence:AppendEntry(caseId, 'note', { probe = true, tag = 'devtest' }, 'gtarp_devtest')
    end)
    check(type(entryId) == 'number', 'evidence.AppendEntry returns numeric entryId (table payload json-encoded)')

    try('evidence.LinkSuspect', function()
        linked = exports.gtarp_evidence:LinkSuspect(caseId, nil, 'devtest descriptor: tall, red hoodie')
    end)
    check(linked == true, 'evidence.LinkSuspect (descriptor-only) returns true')

    try('evidence.GetCase', function()
        full = exports.gtarp_evidence:GetCase(caseId)
    end)
    if check(type(full) == 'table', 'evidence.GetCase returns case table') then
        check(full.incident_key == key, 'evidence.GetCase round-trips incident_key')
        check(type(full.entries) == 'table' and #full.entries >= 1, 'evidence.GetCase includes appended entry')
        check(type(full.suspects) == 'table' and #full.suspects >= 1, 'evidence.GetCase includes linked suspect')
    end

    -- ListCases (additive export, consumed by gtarp_mdt) — probe case is
    -- still open here, so it must appear in the open list.
    try('evidence.ListCases', function()
        local rows = exports.gtarp_evidence:ListCases('open', 25)
        if check(type(rows) == 'table', 'evidence.ListCases returns table') then
            local found = false
            for _, r in ipairs(rows) do
                if tonumber(r.id) == caseId then found = true break end
            end
            check(found, 'evidence.ListCases includes the open probe case')
        end
    end)

    -- cleanup (children first — no FK cascade assumed)
    pcall(function()
        MySQL.update.await('DELETE FROM gtarp_evidence WHERE case_id = ?', { caseId })
        MySQL.update.await('DELETE FROM gtarp_evidence_suspects WHERE case_id = ?', { caseId })
        MySQL.update.await('DELETE FROM gtarp_evidence_cases WHERE id = ?', { caseId })
    end)
end

local function testStaffLog()
    if not resourceUp('gtarp_staff') then
        fail('staff — resource not started')
        return
    end
    local marker = ('devtest-%d'):format(os.time())
    if not try('staff.Log', function()
        exports.gtarp_staff:Log('devtest', 0, nil, marker)
    end) then return end

    local row
    pcall(function()
        row = MySQL.single.await(
            'SELECT id, actor_name FROM audit_log WHERE action = ? AND detail = ? ORDER BY id DESC LIMIT 1',
            { 'devtest', marker })
    end)
    if check(row ~= nil, 'staff.Log lands an audit_log row') then
        check(row.actor_name == 'console', 'staff.Log records console actor for src 0')
        pcall(function() MySQL.update.await('DELETE FROM audit_log WHERE id = ?', { row.id }) end)
    end
end

local function testShapes()
    if resourceUp('gtarp_courier') then
        try('courier.GetOpenPostings', function()
            local p = exports.gtarp_courier:GetOpenPostings()
            check(type(p) == 'table', 'courier.GetOpenPostings returns table')
        end)
    else
        fail('courier — resource not started')
    end

    if resourceUp('gtarp_eventguard') then
        try('eventguard.GetViolations', function()
            local v = exports.gtarp_eventguard:GetViolations(999999)
            check(v == 0, 'eventguard.GetViolations returns 0 for unknown src')
        end)
    else
        fail('eventguard — resource not started')
    end

    if resourceUp('gtarp_mdt') then
        try('mdt.GetSummary', function()
            local s = exports.gtarp_mdt:GetSummary()
            check(type(s) == 'table' and type(s.activeBolos) == 'number'
                and type(s.reports) == 'number',
                'mdt.GetSummary returns {activeBolos, reports}')
        end)
    else
        fail('mdt — resource not started')
    end

    if resourceUp('gtarp_insurance') then
        try('insurance.GetSummary', function()
            local s = exports.gtarp_insurance:GetSummary()
            check(type(s) == 'table' and type(s.activePolicies) == 'number'
                and type(s.pendingClaims) == 'number',
                'insurance.GetSummary returns {activePolicies, pendingClaims}')
        end)
    else
        fail('insurance — resource not started')
    end

    if resourceUp('gtarp_perf') then
        try('perf.GetSummary', function()
            local s = exports.gtarp_perf:GetSummary()
            check(type(s) == 'table', 'perf.GetSummary returns table')
        end)
        try('perf.RunDiag', function()
            local lines = exports.gtarp_perf:RunDiag()
            check(type(lines) == 'table' and #lines >= 3,
                ('perf.RunDiag returns >=3 readout lines (got %s)')
                    :format(type(lines) == 'table' and tostring(#lines) or type(lines)))
        end)
        -- Also dispatch the actual /diag command through the ACE layer
        -- (resource.gtarp_devtest is granted command.diag in custom.cfg —
        -- without it this is silently access-denied, which is exactly the
        -- regression this line exists to catch in the boot log).
        try('perf — /diag console invocation', function()
            ExecuteCommand('diag')
        end)
    else
        fail('perf — resource not started')
    end
end

-- Every ExtraItems declaration must be visible in ox_inventory's runtime
-- items table. exports.ox_inventory:Items() returns a msgpack COPY — safe
-- for reading presence, useless for writing (which is exactly the bug this
-- test exists to catch).
local function testItems()
    if not resourceUp('ox_inventory') then
        fail('items — ox_inventory not started')
        return
    end
    if not resourceUp('ox_inventory_overrides') then
        fail('items — ox_inventory_overrides not started')
        return
    end

    local src = LoadResourceFile('ox_inventory_overrides', 'data/items.lua')
    if not check(type(src) == 'string' and #src > 0,
        'items — ExtraItems declaration file readable') then return end

    local env = {}
    local chunk, lerr = load(src, '@ox_inventory_overrides/data/items.lua', 't', env)
    if not check(chunk ~= nil,
        ('items — ExtraItems file compiles%s'):format(chunk and '' or (': ' .. tostring(lerr)))) then return end
    if not try('items — ExtraItems file runs', chunk) then return end

    local names = {}
    for name in pairs(env.ExtraItems or {}) do names[#names + 1] = name end
    table.sort(names)
    if not check(#names > 0, 'items — ExtraItems declares at least one item') then return end

    local registered
    if not try('items — ox_inventory:Items()', function()
        registered = exports.ox_inventory:Items()
    end) then return end
    if not check(type(registered) == 'table', 'items — ox_inventory:Items() returns table') then return end

    local missing = {}
    for _, n in ipairs(names) do
        if registered[n] == nil then missing[#missing + 1] = n end
    end
    check(#missing == 0, #missing == 0
        and ('items — all %d custom items registered in ox_inventory'):format(#names)
        or ('items — %d/%d custom items MISSING from ox_inventory: %s — run tools/patch-ox-items.sh against the deployed resources dir')
            :format(#missing, #names, table.concat(missing, ', ')))
end

-- Each started gtarp resource's tables must exist. One information_schema
-- round-trip, then set lookups — no per-table queries.
local REQUIRED_TABLES = {
    gtarp_allowlist   = { 'allowlist' },
    gtarp_clout       = { 'gtarp_clout_streamers', 'gtarp_clout_deals', 'gtarp_clout_vod' },
    gtarp_counterfeit = { 'gtarp_counterfeit_printers', 'gtarp_counterfeit_batches',
                          'gtarp_counterfeit_wads', 'gtarp_counterfeit_hops',
                          'gtarp_counterfeit_leads', 'gtarp_counterfeit_heat' },
    gtarp_courier     = { 'courier_postings' },
    gtarp_eventguard  = { 'event_violations' },
    gtarp_evidence    = { 'gtarp_evidence', 'gtarp_evidence_cases', 'gtarp_evidence_suspects' },
    gtarp_flashdrop   = { 'gtarp_flashdrop_drops', 'gtarp_flashdrop_serials',
                          'gtarp_flashdrop_provenance', 'gtarp_flashdrop_listings' },
    gtarp_grind       = { 'grind_skill' },
    gtarp_insurance   = { 'gtarp_insurance_policies', 'gtarp_insurance_claims' },
    gtarp_mdt         = { 'gtarp_mdt_bolos', 'gtarp_mdt_reports' },
    gtarp_pumpcoin    = { 'gtarp_pumpcoin_coins', 'gtarp_pumpcoin_holdings', 'gtarp_pumpcoin_trades' },
    gtarp_replay      = { 'gtarp_replay_scenes', 'gtarp_replay_participants' },
    gtarp_staff       = { 'audit_log' },
    gtarp_turf        = { 'gtarp_turf' },
    gtarp_witnesses   = { 'gtarp_witnesses_incidents', 'gtarp_witnesses' },
}

local function testTables()
    local present = {}
    local ok = pcall(function()
        local rows = MySQL.query.await(
            'SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE()') or {}
        for _, r in ipairs(rows) do present[r.t or r.T] = true end
    end)
    if not check(ok and next(present) ~= nil, 'tables — information_schema readable') then return end

    local resources = {}
    for resource in pairs(REQUIRED_TABLES) do resources[#resources + 1] = resource end
    table.sort(resources)
    for _, resource in ipairs(resources) do
        if resourceUp(resource) then
            local missing = {}
            for _, t in ipairs(REQUIRED_TABLES[resource]) do
                if not present[t] then missing[#missing + 1] = t end
            end
            check(#missing == 0, #missing == 0
                and ('tables — %s: all %d present'):format(resource, #REQUIRED_TABLES[resource])
                or ('tables — %s MISSING %s — apply the matching sql/ migration')
                    :format(resource, table.concat(missing, ', ')))
        end
    end
end

-- gtarp_discord's announce contract: shape, unknown-feed rejection, and —
-- when any feed has a webhook configured on this boot — a real queue accept
-- (delivery itself lands in the console as an HTTP failure line if the
-- webhook is bad, and posts a clearly-labelled probe embed if it's good).
local function testDiscord()
    if not resourceUp('gtarp_discord') then
        fail('discord — resource not started')
        return
    end

    local stats
    if not try('discord.GetStats', function()
        stats = exports.gtarp_discord:GetStats()
    end) then return end
    if not check(type(stats) == 'table' and type(stats.liveFeeds) == 'table'
        and type(stats.queued) == 'number' and type(stats.dropped) == 'number',
        'discord.GetStats returns {queued, dropped, liveFeeds}') then return end

    try('discord.Announce unknown feed', function()
        check(exports.gtarp_discord:Announce('no_such_feed', { title = 'x' }) == false,
            'discord.Announce(unknown feed) returns false')
    end)

    if #stats.liveFeeds == 0 then
        skip('discord.Announce delivery — no feed webhooks configured on this boot')
    else
        try('discord.Announce live feed', function()
            check(exports.gtarp_discord:Announce(stats.liveFeeds[1], {
                title = '[devtest] contract probe',
                description = 'Queued by gtarp_devtest — safe to ignore.',
            }) == true, ('discord.Announce queues to live feed "%s"'):format(stats.liveFeeds[1]))
        end)
    end
end

local function testPlayerBound()
    -- These contracts need a live player source; exercising them with a
    -- fake src would test error paths, not the contract. Visible SKIPs so
    -- the summary never over-claims coverage.
    skip('allowlist.IsAllowlisted / HasAllowedRole — needs live player src')
    skip('whitelist_jobs.IsAllowed — needs live player src')
    skip('witnesses.ReportCrime — needs live player position + ambient peds')
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if GetConvar('gtarp:devtest', '0') ~= '1' then
        print('[gtarp_devtest] disabled (set gtarp:devtest 1 to run contract self-tests)')
        return
    end

    -- Let siblings finish their own onResourceStart work first.
    CreateThread(function()
        Wait(3000)
        print('[gtarp_devtest] ▶ running cross-resource contract self-tests')
        testEvidence()
        testStaffLog()
        testShapes()
        testItems()
        testTables()
        testDiscord()
        testPlayerBound()
        local mark = failed == 0 and '✔' or '✘'
        print(('[gtarp_devtest] %s %d passed, %d failed, %d skipped'):format(mark, passed, failed, skipped))
        if failed > 0 then
            print('[gtarp_devtest] CONTRACTS BROKEN — do not ship until the FAIL lines above are fixed.')
        end
    end)
end)
