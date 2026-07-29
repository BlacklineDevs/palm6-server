-- ============================================================================
-- palm6_mapeditor/shared/diff.lua
--
-- Snapshot DIFF: what actually CHANGED between two sets of props (and lights).
-- Pure functions only — no natives, no MySQL, no events — so the same code can
-- be reasoned about (and unit-run) outside the game. server/live.lua feeds it
-- two decoded revision blobs (or one blob and the live state) and ships the
-- summary to the NUI; nothing here reads or writes any table.
--
-- WHY THIS EXISTS
--   The revision list tells you a snapshot has 412 props. It does not tell you
--   that restoring it would delete the 30 props you added this morning. This
--   turns "412 props, 2h ago" into "restoring drops 30 props, brings back 6, and
--   moves 4" BEFORE the destructive click.
--
-- HOW A PROP IS MATCHED ACROSS TWO SETS (read this before trusting a diff)
--   Three passes, each consuming what it matches, in this order:
--     1. BY ID     — only when BOTH entries carry an id. A prop id is the
--                    palm6_mapeditor_props row id, so an id match means "the same
--                    DB row", which is the only exact identity available.
--     2. BY POSITION — same model within `posEps` metres. This is what carries
--                    the whole diff for older snapshots (see the caveat below).
--     3. BY MOVE   — same model, nearest unmatched partner within `moveRadius`
--                    metres. This is what turns a remove+add pair into "moved".
--   Whatever is left over is genuinely added (only in B) or removed (only in A).
--
-- WHERE THE MATCHING CAN BE WRONG — all four of these are real, not theoretical:
--   * ids are NOT stable across an edit. /maplivegrab DELETES the row and
--     /mapcommit re-INSERTS it, and a restore re-inserts every prop, so a prop
--     that was moved (or a map that was rolled back) comes out with a new id.
--     Pass 1 therefore recognises only untouched props; every genuine MOVE is
--     found by pass 3, positionally.
--   * snapshots written before this file existed carry NO ids at all, so a diff
--     involving one is 100% positional. The result reports `idPairs` so the UI
--     can say so.
--   * pass 3 is greedy nearest-neighbour, not a global optimum. Two identical
--     models that swapped places, or a dense row of identical props where one
--     was deleted and another moved, can be paired the wrong way round. The
--     counts stay right (n moved + n added + n removed is conserved); WHICH prop
--     moved where can be wrong.
--   * a prop moved further than `moveRadius` is reported as one removed + one
--     added, not as a move. That is deliberate: pairing across a whole map would
--     turn "deleted a cone here, placed a cone 400m away" into a phantom move.
--
-- ROTATION is compared per-euler-axis (largest axis delta wins). Two eulers that
-- describe the same orientation through different axis values (gimbal aliasing)
-- read as a rotation change. It over-reports rather than under-reports, which is
-- the safe direction for a "what will I lose" screen.
-- ============================================================================

MapDiff = {}

local DEFAULTS = {
    posEps     = 0.05,    -- m: same position (a prop nudged less than this reads unchanged)
    rotEps     = 0.5,     -- deg: same rotation
    moveRadius = 25.0,    -- m: furthest a prop can travel and still be called "moved"
    budget     = 200000,  -- candidate comparisons before the diff gives up (dense maps)
    yieldEvery = 2000,    -- comparisons between optional yield() calls
    cap        = 40,      -- rows per list in a summary
}

-- Finite number or 0.0 (a snapshot blob is JSON off the wire; never trust it).
local function fin(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return 0.0 end
    return v
end

-- Smallest absolute angle between two degree values, 0..180.
local function angDelta(a, b)
    local d = (fin(a) - fin(b)) % 360.0
    if d > 180.0 then d = 360.0 - d end
    return d
end

local function rotDelta(p, q)
    local dx, dy, dz = angDelta(p.rx, q.rx), angDelta(p.ry, q.ry), angDelta(p.rz, q.rz)
    if dy > dx then dx = dy end
    if dz > dx then dx = dz end
    return dx
end

local function dist2(p, q)
    local dx, dy, dz = fin(p.x) - fin(q.x), fin(p.y) - fin(q.y), fin(p.z) - fin(q.z)
    return dx * dx + dy * dy + dz * dz
end

local function cellOf(p, cell)
    return math.floor(fin(p.x) / cell), math.floor(fin(p.y) / cell), math.floor(fin(p.z) / cell)
end

-- Bucket the still-unmatched entries of `list` into a uniform grid. `withModel`
-- puts the model name in the key so a lookup only ever sees same-model
-- candidates (that is the single biggest cost saving on a real map).
local function buildIndex(list, alive, cell, withModel)
    local idx = {}
    for i = 1, #list do
        if alive[i] then
            local p = list[i]
            local cx, cy, cz = cellOf(p, cell)
            local k = (withModel and (tostring(p.model) .. '|') or '') .. cx .. ',' .. cy .. ',' .. cz
            local b = idx[k]
            if not b then b = {}; idx[k] = b end
            b[#b + 1] = i
        end
    end
    return idx
end

-- The 27 buckets touching p's cell. A partner within one cell width is always in
-- one of them, which is why the cell size is chosen as the search radius.
local function neighbourBuckets(idx, p, cell, model)
    local cx, cy, cz = cellOf(p, cell)
    local pre = model and (tostring(model) .. '|') or ''
    local out = {}
    for ox = -1, 1 do
        for oy = -1, 1 do
            for oz = -1, 1 do
                local b = idx[pre .. (cx + ox) .. ',' .. (cy + oy) .. ',' .. (cz + oz)]
                if b then out[#out + 1] = b end
            end
        end
    end
    return out
end

-- Normalise one entry off a snapshot blob (or the live mirror) into the shape
-- the passes below use. Returns nil for anything without a usable model.
local function cleanProp(p)
    if type(p) ~= 'table' then return nil end
    local m = p.model
    if type(m) ~= 'string' or m == '' then return nil end
    return {
        id = tonumber(p.id), model = m,
        x = fin(p.x), y = fin(p.y), z = fin(p.z),
        rx = fin(p.rx), ry = fin(p.ry), rz = fin(p.rz),
    }
end

local function cleanList(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        local c = cleanProp(list[i])
        if c then out[#out + 1] = c end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- MapDiff.props(a, b, opts)
--   a = the OLDER set, b = the NEWER set (both lists of {model,x,y,z,rx,ry,rz,id?})
-- Returns:
--   { added = {prop...}, removed = {prop...},
--     moved = { { model, dist, rot, from = {x,y,z}, to = {x,y,z}, byId = bool }, ... },
--     unchanged = n, rotated = n,          -- rotated: same spot, different angle
--     idPairs = n, posPairs = n, movePairs = n,
--     aTotal = n, bTotal = n, truncated = bool }
-- `moved` holds every pair whose position OR rotation changed; `rotated` counts
-- the subset that only turned. Counts always satisfy:
--   aTotal = unchanged + #moved + #removed   and   bTotal = unchanged + #moved + #added
-- ---------------------------------------------------------------------------
function MapDiff.props(a, b, opts)
    opts = opts or {}
    local posEps     = opts.posEps or DEFAULTS.posEps
    local rotEps     = opts.rotEps or DEFAULTS.rotEps
    local moveRadius = opts.moveRadius or DEFAULTS.moveRadius
    local budget     = opts.budget or DEFAULTS.budget
    local yieldEvery = opts.yieldEvery or DEFAULTS.yieldEvery
    local yield      = opts.yield

    local A, B = cleanList(a), cleanList(b)
    local aAlive, bAlive = {}, {}
    for i = 1, #A do aAlive[i] = true end
    for i = 1, #B do bAlive[i] = true end

    local res = {
        added = {}, removed = {}, moved = {},
        unchanged = 0, rotated = 0,
        idPairs = 0, posPairs = 0, movePairs = 0,
        aTotal = #A, bTotal = #B, truncated = false,
    }

    local steps = 0
    local function tick(n)
        budget = budget - n
        steps = steps + n
        if yield and steps >= yieldEvery then steps = 0; yield() end
        return budget > 0
    end

    -- Record one matched pair and classify it.
    local function pair(ai, bi, byId)
        aAlive[ai] = nil; bAlive[bi] = nil
        local p, q = A[ai], B[bi]
        local d = math.sqrt(dist2(p, q))
        local r = rotDelta(p, q)
        if d <= posEps and r <= rotEps then
            res.unchanged = res.unchanged + 1
            return
        end
        if d <= posEps then res.rotated = res.rotated + 1 end
        res.moved[#res.moved + 1] = {
            model = q.model, dist = d, rot = r, byId = byId and true or false,
            from = { x = p.x, y = p.y, z = p.z },
            to   = { x = q.x, y = q.y, z = q.z },
        }
    end

    -- Pass 1 — by id. Only pairs entries that BOTH carry one; an id collision
    -- across two different maps is impossible (ids are the props table PK).
    local aById = {}
    for i = 1, #A do
        local id = A[i].id
        if id and not aById[id] then aById[id] = i end
    end
    if next(aById) ~= nil then
        for j = 1, #B do
            local id = B[j].id
            if id then
                local i = aById[id]
                -- Same row id but a different model is a reused-id coincidence
                -- (the table is AUTO_INCREMENT, so this means the two snapshots
                -- straddle a delete + insert). Leave it to the positional passes.
                if i and aAlive[i] and A[i].model == B[j].model then
                    res.idPairs = res.idPairs + 1
                    pair(i, j, true)
                end
            end
        end
    end

    -- Pass 2 — same model, same place (within posEps). Fine grid: the cell is
    -- the tolerance, so each lookup touches a handful of entries.
    local fineCell = math.max(posEps * 2.0, 0.01)
    local fineIdx = buildIndex(A, aAlive, fineCell, true)
    local eps2 = posEps * posEps
    for j = 1, #B do
        if bAlive[j] then
            local q = B[j]
            local buckets = neighbourBuckets(fineIdx, q, fineCell, q.model)
            local found, scanned = nil, 0
            for bi = 1, #buckets do
                local bucket = buckets[bi]
                for k = 1, #bucket do
                    local i = bucket[k]
                    if aAlive[i] then
                        scanned = scanned + 1
                        if dist2(A[i], q) <= eps2 then found = i; break end
                    end
                end
                if found then break end
            end
            if not tick(scanned > 0 and scanned or 1) then res.truncated = true; break end
            if found then
                res.posPairs = res.posPairs + 1
                pair(found, j, false)
            end
        end
    end

    -- Pass 3 — same model, nearest surviving partner within moveRadius. Built
    -- from what is LEFT after pass 2, so on a normal edit this walks a handful
    -- of props rather than the whole map.
    if not res.truncated then
        local coarse = math.max(moveRadius, 0.5)
        local coarseIdx = buildIndex(A, aAlive, coarse, true)
        local rad2 = moveRadius * moveRadius
        for j = 1, #B do
            if bAlive[j] then
                local q = B[j]
                local buckets = neighbourBuckets(coarseIdx, q, coarse, q.model)
                local best, bestD, scanned = nil, nil, 0
                for bi = 1, #buckets do
                    local bucket = buckets[bi]
                    for k = 1, #bucket do
                        local i = bucket[k]
                        if aAlive[i] then
                            local d = dist2(A[i], q)
                            scanned = scanned + 1
                            -- `<` not `<=`: first (lowest-index) candidate wins a
                            -- tie, so the same two sets always diff identically.
                            if d <= rad2 and (not bestD or d < bestD) then best, bestD = i, d end
                        end
                    end
                end
                if not tick(scanned > 0 and scanned or 1) then res.truncated = true; break end
                if best then
                    res.movePairs = res.movePairs + 1
                    pair(best, j, false)
                end
            end
        end
    end

    -- Leftovers. On a truncated run these are "everything we never got to",
    -- which is why `truncated` has to reach the UI.
    for i = 1, #A do if aAlive[i] then res.removed[#res.removed + 1] = A[i] end end
    for j = 1, #B do if bAlive[j] then res.added[#res.added + 1] = B[j] end end
    return res
end

-- ---------------------------------------------------------------------------
-- Lights. Same shape, much simpler: lights have no model, so they are matched by
-- position only (within posEps), and a matched pair whose colour / range /
-- intensity / kind differs counts as "changed". No move detection: a light has
-- no identity beyond where it is, so a moved light is honestly an add + a remove.
-- ---------------------------------------------------------------------------
local function cleanLight(l)
    if type(l) ~= 'table' then return nil end
    return {
        id = tonumber(l.id), x = fin(l.x), y = fin(l.y), z = fin(l.z),
        r = fin(l.r), g = fin(l.g), b = fin(l.b),
        range = fin(l.range), intensity = fin(l.intensity),
        kind = (l.kind == 'spot') and 'spot' or 'point',
    }
end

function MapDiff.lights(a, b, opts)
    opts = opts or {}
    local posEps = opts.posEps or DEFAULTS.posEps
    local A, B = {}, {}
    if type(a) == 'table' then for i = 1, #a do local c = cleanLight(a[i]); if c then A[#A + 1] = c end end end
    if type(b) == 'table' then for i = 1, #b do local c = cleanLight(b[i]); if c then B[#B + 1] = c end end end
    local aAlive = {}
    for i = 1, #A do aAlive[i] = true end
    local out = { added = 0, removed = 0, changed = 0, unchanged = 0, aTotal = #A, bTotal = #B }
    local cell = math.max(posEps * 2.0, 0.01)
    local idx = buildIndex(A, aAlive, cell, false)
    local eps2 = posEps * posEps
    for j = 1, #B do
        local q = B[j]
        local buckets = neighbourBuckets(idx, q, cell, nil)
        local found = nil
        for bi = 1, #buckets do
            local bucket = buckets[bi]
            for k = 1, #bucket do
                local i = bucket[k]
                if aAlive[i] and dist2(A[i], q) <= eps2 then found = i; break end
            end
            if found then break end
        end
        if found then
            aAlive[found] = nil
            local p = A[found]
            if p.r ~= q.r or p.g ~= q.g or p.b ~= q.b or p.range ~= q.range
                or p.intensity ~= q.intensity or p.kind ~= q.kind then
                out.changed = out.changed + 1
            else
                out.unchanged = out.unchanged + 1
            end
        else
            out.added = out.added + 1
        end
    end
    for i = 1, #A do if aAlive[i] then out.removed = out.removed + 1 end end
    return out
end

-- ---------------------------------------------------------------------------
-- Fold a raw result into the bounded payload the NUI gets. Added/removed props
-- are grouped BY MODEL (a build is normally "18 more of the same fence", not 18
-- unrelated things); moves are listed individually, furthest first, because the
-- distance is the interesting part. Both lists are capped so a 6000-prop diff
-- can never ship a 6000-row message into CEF.
-- ---------------------------------------------------------------------------
local function groupByModel(list, cap)
    local counts, order = {}, {}
    for i = 1, #list do
        local m = list[i].model
        if counts[m] == nil then counts[m] = 0; order[#order + 1] = m end
        counts[m] = counts[m] + 1
    end
    table.sort(order, function(x, y)
        if counts[x] ~= counts[y] then return counts[x] > counts[y] end
        return x < y
    end)
    local out, shown = {}, 0
    for i = 1, #order do
        if i > cap then break end
        out[#out + 1] = { model = order[i], n = counts[order[i]] }
        shown = shown + counts[order[i]]
    end
    return out, #list - shown, #order
end

function MapDiff.summarise(res, cap)
    cap = cap or DEFAULTS.cap
    local addedGroups, addedMore, addedModels = groupByModel(res.added, cap)
    local removedGroups, removedMore, removedModels = groupByModel(res.removed, cap)
    local moved = {}
    for i = 1, #res.moved do moved[i] = res.moved[i] end
    table.sort(moved, function(x, y)
        if x.dist ~= y.dist then return x.dist > y.dist end
        return (x.model or '') < (y.model or '')
    end)
    local movedTop = {}
    for i = 1, math.min(#moved, cap) do
        local m = moved[i]
        movedTop[i] = {
            model = m.model, dist = m.dist, rot = m.rot, byId = m.byId,
            x = m.to.x, y = m.to.y, z = m.to.z,
        }
    end
    return {
        counts = {
            added = #res.added, removed = #res.removed, moved = #res.moved,
            rotated = res.rotated, unchanged = res.unchanged,
            aTotal = res.aTotal, bTotal = res.bTotal,
        },
        match = { byId = res.idPairs, byPos = res.posPairs, byMove = res.movePairs },
        addedGroups = addedGroups, addedMore = addedMore, addedModels = addedModels,
        removedGroups = removedGroups, removedMore = removedMore, removedModels = removedModels,
        movedTop = movedTop, movedMore = math.max(0, #moved - #movedTop),
        truncated = res.truncated and true or false,
    }
end
