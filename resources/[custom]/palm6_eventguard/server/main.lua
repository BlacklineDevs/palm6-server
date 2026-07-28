-- ============================================================================
-- palm6_eventguard/server/main.lua
--
-- Ratelimits the events listed in Config.Events. Wraps the existing
-- handler chain by registering ourselves first; when a player exceeds the
-- budget we log to event_violations and drop the event. After
-- Config.KickThreshold breaches in a session, the player is kicked.
-- ============================================================================

local Counts     = {}  -- [eventName][src] = { calls = {ts...}, breaches = 0 }
local Violations = {}  -- [src] = total breaches this session

local function now() return os.time() end

local function bucket(eventName, src)
    Counts[eventName] = Counts[eventName] or {}
    Counts[eventName][src] = Counts[eventName][src] or { calls = {}, breaches = 0 }
    return Counts[eventName][src]
end

local function prune(b, window)
    local t = now()
    local i = 1
    while i <= #b.calls do
        if b.calls[i] < (t - window) then
            table.remove(b.calls, i)
        else
            i = i + 1
        end
    end
end

local function record(src, eventName, reason)
    Violations[src] = (Violations[src] or 0) + 1
    local detail = ('event=%s reason=%s breaches_session=%d'):format(
        eventName, reason, Violations[src])
    print(('[palm6_eventguard] VIOLATION src=%d %s'):format(src, detail))

    -- Best-effort: an unguarded await here THREW on any DB error (and
    -- event_violations ships only in sql/0008_security_events.sql, so a rebuilt DB
    -- may not have it), which unwound record() and skipped BOTH the staff log and
    -- the 3-strike kick below. pcall keeps the violation flow alive; the row is
    -- forensics, the kick is the control. (The drop itself already happened in
    -- guard() before this is ever called.) Also registered in palm6_dbmigrate now.
    pcall(function()
        MySQL.insert.await(
            "INSERT INTO event_violations (player_src, identifier, event_name, reason, created_at) VALUES (?,?,?,?, NOW())",
            { src, Bridge.GetPrimaryIdentifier(src), eventName, reason }
        )
    end)

    pcall(function()
        exports.palm6_staff:Log('eventguard', 0, src, detail)
    end)

    if Violations[src] >= (Config.KickThreshold or 3) then
        Bridge.Kick(src, 'kicked by eventguard: repeated event violations')
    end
end

-- Wrap one event with the ratelimit. Returns the wrapper handler.
local function guard(eventName, budget)
    AddEventHandler(eventName, function(...)
        -- SERVER-RAISE PREDICATE. This is the repo's shared test, not a local
        -- invention: a raise from inside the server VM surfaces as nil, <= 0,
        -- OR 65535 - never a real player id. The two other consumers of
        -- police:server:policeAlert reasoned this out independently and now
        -- share it verbatim: palm6_mdt/bridge/sv_framework.lua:249-250
        -- (`local invoker = tonumber(source)` / `not (invoker == nil or
        -- invoker <= 0 or invoker == 65535)`) and
        -- palm6_witnesses/server/main.lua:494-495 (`local isServerCall =
        -- invoker == nil or invoker <= 0 or invoker == 65535`). Keep all three
        -- identical; two consumers of one event must not disagree about what
        -- its source means.
        --
        -- The old test here was `src == 0` only. That missed 65535 and missed
        -- negatives, so a SERVER-side TriggerEvent that surfaced as 65535 got
        -- bucketed under a phantom src, counted against a client budget, and on
        -- the (budget+1)-th raise hit CancelEvent() - killing a REAL event for
        -- every handler registered after this one - then record()'d violations
        -- and eventually called Bridge.Kick(65535, ...). This predicate is the
        -- root protection for EVERY budget in config.lua, not just the 911 one.
        local src = tonumber(source)
        if src == nil or src <= 0 or src == 65535 then return end  -- server-emitted
        local b = bucket(eventName, src)
        prune(b, budget.window_seconds)
        if #b.calls >= budget.calls then
            -- CANCEL FIRST — before ANY yielding call. CancelEvent() only takes
            -- effect while this handler is still running SYNCHRONOUSLY. record()
            -- below performs a yielding DB insert (and a yielding staff log), and
            -- in FiveM a yield hands control back to the event dispatcher, which
            -- immediately invokes the NEXT handler — the real one. Cancelling
            -- AFTER record() therefore arrived too late: the over-budget event was
            -- already delivered, so the limiter logged violations but never
            -- actually dropped anything (every non-combat budget was inert; only
            -- the combat branch, which cancelled before returning, worked).
            -- Dropping is load-bearing; logging is best-effort. Order matters.
            CancelEvent()
            -- DROP-WITHOUT-KICK budgets: drop the over-budget event but NEVER
            -- call record(): no violation row, no Violations[src]++ , no
            -- 3-strike kick. Two spellings, one behaviour:
            --   'combat'    - the original fc striking/finisher case. A legit
            --                 flurry of palm6_fc_combat:strike/connect/block/
            --                 break can burst past the budget; the server
            --                 move-clock (palm6_fc_combat), not eventguard, is
            --                 the combat authority, and the §7 finisher :break
            --                 mash would trip the kick model instantly.
            --   'drop_only' - the same branch for events that have nothing to
            --                 do with fighting (racing checkpoints, 911
            --                 alerts). Added because 'combat' was being used as
            --                 a de-facto alias on non-combat events, which read
            --                 as a miscategorisation to the next reader.
            -- Money/menu events keep the strike-and-kick model via record().
            if budget.class == 'combat' or budget.class == 'drop_only' then return end
            record(src, eventName, ('over budget %d/%ds'):format(
                budget.calls, budget.window_seconds))
            return
        end
        b.calls[#b.calls + 1] = now()
    end)
end

-- onResourceStart can fire more than once for this resource's own name in
-- some boot sequences (observed: guards silently double-registering,
-- halving every rate-limit budget and doubling violation counts — false
-- kicks after as few as 2 real breaches). Guard registration is not safe
-- to run twice in the same VM, so make it idempotent regardless of how
-- many times the event fires.
local guardsRegistered = false

-- Every budget in config.lua is only real because this resource registers its
-- handler BEFORE the owning resource registers its own - custom.cfg ensures
-- palm6_eventguard at the top of the list for exactly that reason. FiveM appends
-- handlers to a chain in registration order and CancelEvent() only stops
-- handlers that have not run yet, so a guard added at the END of a chain can
-- never drop anything: the real handler already ran.
--
-- That means a lone `restart palm6_eventguard` on a live box silently converts
-- every budget in this file into a no-op, while the boot banner below still
-- cheerfully prints "guarding N events". Detect it and say so in red. We infer
-- it from the guarded event names: 'palm6_drugs:sell' belongs to palm6_drugs,
-- so if palm6_drugs is ALREADY 'started' when we boot, we are not first in its
-- chain.
--
-- ONLY palm6_* prefixes count toward the alarm, and that restriction is
-- load-bearing rather than cosmetic. ASSUMPTION, not a verified fact from this
-- repo: custom.cfg execs from the BOTTOM of the panel-generated server.cfg.
-- server.cfg is panel-managed and is NOT in this tree, so nothing here can
-- prove it; if the panel is ever reordered to exec custom.cfg first, revisit
-- this whole block. On the assumed ordering the recipe's own resources
-- (ox_inventory, and the qbx_police resources behind the 'police:' and
-- 'evidence:' event namespaces) are ALREADY started before this resource exists.
-- Counting those would fire the red banner on every clean start and train
-- whoever reads the console to ignore it, which would cost more than it buys.
-- Every palm6_* consumer, by contrast, is ensured by custom.cfg strictly AFTER
-- palm6_eventguard, so on a clean boot this returns an empty list and prints
-- nothing, and a non-empty list is real evidence of an out-of-order restart.
--
-- KNOWN AND ACCEPTED, documented here so nobody rediscovers it as a bug: the
-- ox_inventory / police / evidence budgets cannot drop anything for the RECIPE's
-- own handlers on a normal boot, for the same ordering reason, and no ensure
-- order inside custom.cfg can fix that because those resources start before
-- custom.cfg is even read. Against those handlers they are defense-in-depth on
-- top of the resources' own validation, not the authority.
--
-- DO NOT generalise that into "those budgets are inert", which is what an
-- earlier version of this comment said and which is false. A non-palm6_* event
-- name can still have palm6_* consumers, and THOSE are ensured after this
-- resource, so the guard IS first in the chain ahead of them and its
-- CancelEvent() does bite. police:server:policeAlert is exactly that case:
-- palm6_witnesses (custom.cfg:146) and palm6_mdt (custom.cfg:179) both register
-- handlers on it and both start after palm6_eventguard (custom.cfg:112). Read
-- the sizing note on that entry in config.lua before touching it.
--
-- Prefixes that are not resource names at all just resolve to a non-'started'
-- state and are skipped. This is a console warning only - zero runtime effect.
local function lateChainConsumers()
    local seen, late = {}, {}
    for name in pairs(Config.Events) do
        local res = name:match('^([^:]+)')
        if res and not seen[res] then
            seen[res] = true
            if res ~= GetCurrentResourceName()
                and res:sub(1, 6) == 'palm6_'
                and GetResourceState(res) == 'started' then
                late[#late + 1] = res
            end
        end
    end
    table.sort(late)
    return late
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if guardsRegistered then return end
    guardsRegistered = true

    local late = lateChainConsumers()

    local n = 0
    for name, budget in pairs(Config.Events) do
        guard(name, budget)
        n = n + 1
    end
    print(('[palm6_eventguard] guarding %d events; kick threshold=%d'):format(
        n, Config.KickThreshold or 3))

    if #late > 0 then
        print(('^1[palm6_eventguard] RESTARTED after consumers - guards are NOT first in the chain; budgets are INERT until a full server restart^0'))
        print(('^1[palm6_eventguard] %d guarded resource(s) were already started: %s^0'):format(
            #late, table.concat(late, ', ')))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    Violations[src] = nil
    for name, t in pairs(Counts) do t[src] = nil end
end)

exports('GetViolations', function(src) return Violations[src] or 0 end)
